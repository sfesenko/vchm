// CHM DataSpace sections: NameList, ControlData, SpanInfo, ResetTable.
// Space != 0 entries slice the decoded section image (usually
// "MSCompressed"); decode is lazy, once per open, via the ResetTable.

namespace Itsf {

internal class SectionCache : Object {

    private const string LZX_GUID = "{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}";
    private const uint64 BLOCK_UNIT = 0x8000u;

    private unowned Index index;
    private unowned uint8[] file_data;
    private uint64 data_offset;
    private Gee.HashMap<uint32, GLib.Bytes> decoded;

    public SectionCache (Index index, uint8[] file_data, uint64 data_offset) {
        this.index = index;
        this.file_data = file_data;
        this.data_offset = data_offset;
        decoded = new Gee.HashMap<uint32, GLib.Bytes> ();
    }

    public GLib.Bytes decode_section (uint32 space) throws Itsf.Error {
        GLib.Bytes? hit = decoded.get (space);
        if (hit != null)
            return hit;
        SectionPlan plan = plan_section (space);
        var section = new GLib.ByteArray ();
        uint64 done = 0;
        for (uint64 k = 0; k < plan.nint; k++) {
            uint64 ol = 0;
            GLib.Bytes dec = decode_interval (plan, k, done, out ol);
            unowned uint8[] ddata = dec.get_data ();
            section.append (ddata);
            done += ol;
        }
        return finish_section (space, plan.uncomp, section, done);
    }

    // Async twin of decode_section: identical bytes, yielding to the main
    // loop after each reset interval.
    public async GLib.Bytes decode_section_async (uint32 space) throws Itsf.Error {
        GLib.Bytes? hit = decoded.get (space);
        if (hit != null)
            return hit;
        SectionPlan plan = plan_section (space);
        var section = new GLib.ByteArray ();
        uint64 done = 0;
        for (uint64 k = 0; k < plan.nint; k++) {
            uint64 ol = 0;
            GLib.Bytes dec = decode_interval (plan, k, done, out ol);
            unowned uint8[] ddata = dec.get_data ();
            section.append (ddata);
            done += ol;
            GLib.Idle.add (decode_section_async.callback);
            yield;
        }
        return finish_section (space, plan.uncomp, section, done);
    }

    private struct SectionPlan {
        uint32 space;
        int window_bits;
        uint64 reset_bytes;
        uint64 uncomp;
        uint64 per;
        uint64 nint;
        uint32 count;
        uint64 comp_len;
        uint64[] table;
        uint8[] comp;
    }

    private SectionPlan plan_section (uint32 space) throws Itsf.Error {
        string[] names = parse_namelist ();
        if (space >= (uint32) names.length)
            throw new Itsf.Error.READ_FAILED (
                "section %u not in NameList".printf (space));
        string storage = "::DataSpace/Storage/" + names[(int) space];
        uint32 version;
        uint64 reset_bytes;
        int window_bits;
        parse_control (storage, out version, out reset_bytes, out window_bits);
        uint64 uncomp = parse_span (storage);
        if (uncomp > (uint64) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("section too large");
        uint32 count;
        uint64 comp_len;
        uint64[] table = parse_reset_table (storage, uncomp, out count,
            out comp_len);
        uint8[] comp = read_space0 (storage + "/Content");
        if ((uint64) comp.length < comp_len)
            throw new Itsf.Error.READ_FAILED (
                "section Content shorter than ResetTable");
        comp = comp[0:(int) comp_len];
        if (reset_bytes == 0 || reset_bytes % BLOCK_UNIT != 0u)
            throw new Itsf.Error.READ_FAILED (
                "section reset interval not a 0x8000 multiple");
        uint64 per = reset_bytes / BLOCK_UNIT;
        uint64 nint = uncomp == 0 ? 0 : (uncomp + reset_bytes - 1u) / reset_bytes;
        var plan = SectionPlan ();
        plan.space = space;
        plan.window_bits = window_bits;
        plan.reset_bytes = reset_bytes;
        plan.uncomp = uncomp;
        plan.per = per;
        plan.nint = nint;
        plan.count = count;
        plan.comp_len = comp_len;
        plan.table = table;
        plan.comp = comp;
        return plan;
    }

    private GLib.Bytes decode_interval (SectionPlan plan, uint64 k,
            uint64 done, out uint64 ol) throws Itsf.Error {
        uint64 rest = plan.uncomp - done;
        ol = rest < plan.reset_bytes ? rest : plan.reset_bytes;
        uint64 b0 = k * plan.per;
        uint64 b1 = b0 + plan.per < (uint64) plan.count ? b0 + plan.per : (uint64) plan.count;
        if (b0 > (uint64) plan.count || b1 > (uint64) plan.count || b0 > b1)
            throw new Itsf.Error.READ_FAILED (
                "section ResetTable interval out of range");
        uint64 cs = plan.table[(int) b0];
        uint64 ce = b1 < (uint64) plan.count ? plan.table[(int) b1] : plan.comp_len;
        if (cs > ce || ce > plan.comp_len)
            throw new Itsf.Error.READ_FAILED (
                "section ResetTable offsets out of range");
        if (ol > (uint64) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("section interval too large");
        if (ce - cs > (uint64) int.MAX)
            throw new Itsf.Error.READ_FAILED ("section interval too large");
        uint8[] slice = plan.comp[(int) cs:(int) ce];
        GLib.Bytes dec = Lzx.Decoder.decode (slice, plan.window_bits, ol);
        if (dec.get_size () != ol)
            throw new Itsf.Error.READ_FAILED (
                "section interval decoded short");
        return dec;
    }

    private GLib.Bytes finish_section (uint32 space, uint64 uncomp,
            GLib.ByteArray section, uint64 done) throws Itsf.Error {
        if (done != uncomp)
            throw new Itsf.Error.INTERNAL ("section length mismatch");
        if (section.len > (uint) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("section too large");
        var result = new GLib.Bytes (section.data[0:(int) section.len]);
        decoded[space] = result;
        return result;
    }

    private uint32 read_u32 (uint8[] d, uint64 pos) throws Itsf.Error {
        if (pos + 4u > (uint64) d.length)
            throw new Itsf.Error.READ_FAILED ("section stream truncated");
        size_t p = (size_t) pos;
        return (uint32) d[p]
            | ((uint32) d[p + 1] << 8)
            | ((uint32) d[p + 2] << 16)
            | ((uint32) d[p + 3] << 24);
    }

    private uint64 read_u64 (uint8[] d, uint64 pos) throws Itsf.Error {
        if (pos + 8u > (uint64) d.length)
            throw new Itsf.Error.READ_FAILED ("section stream truncated");
        size_t p = (size_t) pos;
        return (uint64) d[p]
            | ((uint64) d[p + 1] << 8)
            | ((uint64) d[p + 2] << 16)
            | ((uint64) d[p + 3] << 24)
            | ((uint64) d[p + 4] << 32)
            | ((uint64) d[p + 5] << 40)
            | ((uint64) d[p + 6] << 48)
            | ((uint64) d[p + 7] << 56);
    }

    private uint8[] read_space0 (string path) throws Itsf.Error {
        uint32 space = 0;
        uint64 start = 0;
        uint64 length = 0;
        if (!index.try_lookup (path, out space, out start, out length))
            throw new Itsf.Error.INVALID_PATH ("no such entry: %s".printf (path));
        if (space != 0)
            throw new Itsf.Error.READ_FAILED (
                "section control stream compressed: %s".printf (path));
        if (length == 0)
            return new uint8[0];
        if (length > (uint64) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("section stream too large");
        uint64 file_len = (uint64) file_data.length;
        if (start > uint64.MAX - data_offset)
            throw new Itsf.Error.READ_FAILED ("offset overflow");
        uint64 abs = data_offset + start;
        if (length > uint64.MAX - abs || abs + length > file_len)
            throw new Itsf.Error.READ_FAILED ("entry outside file");
        var buf = new uint8[(int) length];
        int a = (int) abs;
        GLib.Memory.copy (buf, &file_data[a], (size_t) length);
        return buf;
    }

    private string decode_utf16 (uint8[] d, uint64 pos, int units)
            throws Itsf.Error {
        var sb = new GLib.StringBuilder ();
        for (int i = 0; i < units; i++) {
            if (pos + 2u > (uint64) d.length)
                throw new Itsf.Error.READ_FAILED ("NameList truncated");
            size_t p = (size_t) pos;
            uint16 u = (uint16) (d[p] | ((uint16) d[p + 1] << 8));
            pos += 2u;
            if (u < 0x80u) {
                sb.append_c ((char) u);
            } else if (u < 0x800u) {
                sb.append_c ((char) (0xC0u | (u >> 6)));
                sb.append_c ((char) (0x80u | (u & 0x3Fu)));
            } else if (u < 0xD800u || u > 0xDFFFu) {
                sb.append_c ((char) (0xE0u | (u >> 12)));
                sb.append_c ((char) (0x80u | ((u >> 6) & 0x3Fu)));
                sb.append_c ((char) (0x80u | (u & 0x3Fu)));
            } else if (u <= 0xDBFFu) {
                if (i + 1 >= units || pos + 2u > (uint64) d.length)
                    throw new Itsf.Error.READ_FAILED (
                        "NameList truncated surrogate");
                size_t q = (size_t) pos;
                uint16 lo = (uint16) (d[q] | ((uint16) d[q + 1] << 8));
                if (lo < 0xDC00u || lo > 0xDFFFu)
                    throw new Itsf.Error.READ_FAILED (
                        "NameList lone surrogate");
                pos += 2u;
                i++;
                uint32 cp = 0x10000u
                    + (((uint32) u - 0xD800u) << 10)
                    + ((uint32) lo - 0xDC00u);
                sb.append_c ((char) (0xF0u | (cp >> 18)));
                sb.append_c ((char) (0x80u | ((cp >> 12) & 0x3Fu)));
                sb.append_c ((char) (0x80u | ((cp >> 6) & 0x3Fu)));
                sb.append_c ((char) (0x80u | (cp & 0x3Fu)));
            } else {
                throw new Itsf.Error.READ_FAILED (
                    "NameList lone surrogate");
            }
        }
        return sb.str;
    }

    private string[] parse_namelist () throws Itsf.Error {
        uint8[] d = read_space0 ("::DataSpace/NameList");
        if (d.length < 4)
            throw new Itsf.Error.READ_FAILED ("NameList too short");
        uint64 total = (uint64) (d[0] | ((uint16) d[1] << 8));
        if (total * 2u != (uint64) d.length)
            throw new Itsf.Error.READ_FAILED ("NameList length mismatch");
        uint count = (uint) (d[2] | ((uint16) d[3] << 8));
        if (count > (uint) int.MAX)
            throw new Itsf.Error.READ_FAILED ("NameList too large");
        var names = new string[(int) count];
        uint64 pos = 4;
        for (int i = 0; i < (int) count; i++) {
            if (pos + 2u > (uint64) d.length)
                throw new Itsf.Error.READ_FAILED ("NameList truncated");
            size_t p = (size_t) pos;
            uint nchars = (uint) (d[p] | ((uint16) d[p + 1] << 8));
            pos += 2u;
            if (nchars > (uint) int.MAX / 2u)
                throw new Itsf.Error.READ_FAILED ("NameList entry too long");
            names[i] = decode_utf16 (d, pos, (int) nchars);
            pos += (uint64) nchars * 2u;
            if (pos + 2u > (uint64) d.length)
                throw new Itsf.Error.READ_FAILED ("NameList truncated");
            size_t q = (size_t) pos;
            if (d[q] != 0 || d[q + 1] != 0)
                throw new Itsf.Error.READ_FAILED ("NameList not terminated");
            pos += 2u;
        }
        if (pos != (uint64) d.length)
            throw new Itsf.Error.READ_FAILED ("NameList trailing bytes");
        return names;
    }

    private void parse_control (string storage, out uint32 version,
            out uint64 reset_bytes, out int window_bits) throws Itsf.Error {
        uint8[] d = read_space0 (storage + "/ControlData");
        if (d.length < 28)
            throw new Itsf.Error.READ_FAILED ("ControlData too short");
        if (read_u32 (d, 0) != 6u)
            throw new Itsf.Error.READ_FAILED ("ControlData bad count");
        if (read_u32 (d, 4) != 0x43585A4Cu)
            throw new Itsf.Error.READ_FAILED ("ControlData not LZXC");
        version = read_u32 (d, 8);
        if (version > 2u)
            throw new Itsf.Error.READ_FAILED (
                "ControlData version %u unsupported".printf (version));
        uint64 mult = version == 2u ? BLOCK_UNIT : 1u;   // v2 counts in 0x8000-blocks, v1 in bytes
        reset_bytes = (uint64) read_u32 (d, 12) * mult;
        uint64 window_bytes = (uint64) read_u32 (d, 16) * mult;
        window_bits = -1;
        for (int b = 15; b <= 21; b++) {
            if (window_bytes == (1u << b)) {
                window_bits = b;
                break;
            }
        }
        if (window_bits < 0)
            throw new Itsf.Error.READ_FAILED ("ControlData bad window size");
    }

    private uint64 parse_span (string storage) throws Itsf.Error {
        uint8[] d = read_space0 (storage + "/SpanInfo");
        if (d.length < 8)
            throw new Itsf.Error.READ_FAILED ("SpanInfo too short");
        return read_u64 (d, 0);
    }

    private uint64[] parse_reset_table (string storage, uint64 uncomp,
            out uint32 count, out uint64 comp_len) throws Itsf.Error {
        string short_path = storage + "/ResetTable";
        string long_path = storage + "/Transform/" + LZX_GUID
            + "/InstanceData/ResetTable";
        string path = index.contains (short_path) ? short_path : long_path;
        uint8[] d = read_space0 (path);
        if (d.length < 0x28)
            throw new Itsf.Error.READ_FAILED ("ResetTable too short");
        if (read_u32 (d, 0) != 2u)
            throw new Itsf.Error.READ_FAILED ("ResetTable bad version");
        count = read_u32 (d, 4);
        if (read_u32 (d, 8) != 8u || read_u32 (d, 12) != 0x28u)
            throw new Itsf.Error.READ_FAILED ("ResetTable bad header");
        uint64 rt_uncomp = read_u64 (d, 16);
        comp_len = read_u64 (d, 24);
        if (read_u64 (d, 32) != BLOCK_UNIT)
            throw new Itsf.Error.READ_FAILED ("ResetTable bad block size");
        if (rt_uncomp != uncomp)
            throw new Itsf.Error.READ_FAILED (
                "ResetTable/SpanInfo length mismatch");
        uint64 want = uncomp == 0 ? 0
            : (uncomp + BLOCK_UNIT - 1u) / BLOCK_UNIT;
        if ((uint64) count != want)
            throw new Itsf.Error.READ_FAILED ("ResetTable bad entry count");
        if ((uint64) count > (uint64) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("ResetTable too large");
        int nentries = (int) count;
        if (d.length != 0x28 + nentries * 8)
            throw new Itsf.Error.READ_FAILED ("ResetTable length mismatch");
        var table = new uint64[nentries];
        for (int i = 0; i < nentries; i++)
            table[i] = read_u64 (d, 0x28u + (uint64) i * 8u);
        return table;
    }
}

} // namespace Itsf
