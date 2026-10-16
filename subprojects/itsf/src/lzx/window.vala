// LZX sliding window (1 << window_bits, circular) + exact output buffer.
// Matches copy byte-by-byte (overlaps work); E8 edits mirror into both.

namespace Itsf.Lzx {

internal class Window : Object {

    private uint8[] circ;
    private uint32 mask;
    private uint8[] flat;
    private uint64 cap;
    private uint64 pos = 0;

    public Window (int window_bits, uint64 expected_out) throws Itsf.Error {
        if (window_bits < 15 || window_bits > 21)
            throw new Itsf.Error.READ_FAILED (
                "LZX window bits %d outside 15..21".printf (window_bits));
        if (expected_out > (uint64) int.MAX)
            throw new Itsf.Error.OUT_OF_MEMORY ("LZX output too large");
        uint32 size = 1u << window_bits;
        circ = new uint8[size];
        mask = size - 1u;
        flat = new uint8[(int) expected_out];
        cap = expected_out;
    }

    public uint64 position () {
        return pos;
    }

    public void emit_literal (uint8 b) throws Itsf.Error {
        if (pos >= cap)
            throw new Itsf.Error.READ_FAILED ("LZX output overruns block");
        flat[(int) pos] = b;
        circ[(int) (pos & mask)] = b;
        pos++;
    }

    public void emit_match (uint32 offset, uint32 length) throws Itsf.Error {
        if (offset == 0)
            throw new Itsf.Error.READ_FAILED (
                "LZX match offset is zero");
        if (offset > (uint32) circ.length)
            throw new Itsf.Error.READ_FAILED (
                "LZX match offset outside window");
        // Far offsets (not yet emitted) read zero-filled bytes; only the
        // window size bounds the offset, not the output position.
        if (length == 0 || pos + length < pos || pos + length > cap)
            throw new Itsf.Error.READ_FAILED ("LZX match overruns block");
        for (uint32 i = 0; i < length; i++) {
            uint8 b = circ[(int) ((pos - (uint64) offset) & (uint64) mask)];
            flat[(int) pos] = b;
            circ[(int) (pos & mask)] = b;
            pos++;
        }
    }

    public void e8_fix_block (uint64 start, uint64 length, uint64 file_size) {
        // MS-PATCH 2.2.2 decode-side reversal; offsets are interval-relative
        // (one decode call covers one reset interval).
        if (length <= 10 || start >= 0x40000000u)
            return;
        uint64 end = start + length;
        uint64 i = start;
        // MS-PATCH scans i < chunk_size - 10, skipping 4 past each E8.
        while (i + 10 < end) {
            if (flat[(int) i] != 0xE8) {
                i++;
                continue;
            }
            int64 cur = (int64) i;
            int32 value = (int32) (flat[(int) (i + 1)]
                | ((uint32) flat[(int) (i + 2)] << 8)
                | ((uint32) flat[(int) (i + 3)] << 16)
                | ((uint32) flat[(int) (i + 4)] << 24));
            if ((int64) value >= -cur && (int64) value < (int64) file_size) {
                int64 disp = value >= 0 ? (int64) value - cur
                                        : (int64) value + (int64) file_size;
                for (int k = 1; k <= 4; k++) {
                    uint8 b = (uint8) ((disp >> (8 * (k - 1))) & 0xFF);
                    flat[(int) (i + (uint64) k)] = b;
                    circ[(int) ((i + (uint64) k) & (uint64) mask)] = b;
                }
            }
            i += 5;
        }
    }

    public GLib.Bytes to_bytes () {
        return new GLib.Bytes (flat);
    }
}

} // namespace Itsf.Lzx
