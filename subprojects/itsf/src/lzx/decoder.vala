// LZX block decoder, plain-LZX (CHM) framing per [MS-PATCH] 2.3.2/2.6/2.7:
// E8 bit (first block only), 3-bit type (1/2/3), 24-bit size.
// CHM deviations: NO Extra Length field (length-tree 248 is exactly 257;
// longer matches are split chains); one decode call per reset interval
// (full state reset); 16-bit realignment per 0x8000 output bytes;
// oversize blocks truncate; far match offsets read zero-filled bytes.

namespace Itsf.Lzx {

public class Decoder : Object {

    private static uint slot_fbits (uint32 slot) {
        if (slot < 3)
            return 0;
        uint f = (slot - 2u) / 2u;
        return f < 17u ? f : 17u;
    }

    private static uint32 slot_base (uint32 slot) {
        // MS-PATCH 2.6.2 position-slot table, verified entry by entry:
        // slots 0-2 are the repeated offsets (sbase = slot); from slot 3
        // each sbase advances by 2^footer(prev). Footer is (slot-2)/2
        // capped at 17 (slots 36+ and all higher slots use 17).
        if (slot < 3)
            return slot;
        uint32 sbase = 3;
        for (uint32 s = 4; s <= slot; s++)
            sbase += 1u << slot_fbits (s - 1);
        return sbase;
    }

    private static uint32 read_u32_le (uint8[] d, int off) {
        return (uint32) d[off]
            | ((uint32) d[off + 1] << 8)
            | ((uint32) d[off + 2] << 16)
            | ((uint32) d[off + 3] << 24);
    }

    public static GLib.Bytes decode (uint8[] compressed, int window_bits,
            uint64 expected_out) throws Itsf.Error {
        if (window_bits < 15 || window_bits > 21)
            throw new Itsf.Error.READ_FAILED (
                "LZX window bits %d outside 15..21".printf (window_bits));
        if (expected_out == 0)
            return new GLib.Bytes (new uint8[0]);
        var br = new BitReader (compressed);
        var win = new Window (window_bits, expected_out);
        int slots = window_bits * 2;
        int main_count = 256 + 8 * slots;
        uint32 r0 = 1, r1 = 1, r2 = 1;
        uint8[] pm1 = new uint8[256];
        uint8[] pm2 = new uint8[main_count - 256];
        uint8[] pl = new uint8[249];
        bool first_block = true;
        bool interval_e8 = false;
        while (win.position () < expected_out) {
            uint64 block_start = win.position ();
            bool e8;
            if (first_block) {
                e8 = br.read_bits (1) != 0u;
                interval_e8 = e8;
                first_block = false;
            } else {
                e8 = interval_e8;
            }
            uint32 btype = br.read_bits (3);
            if (btype == 3) {
                br.align_to_word ();
                uint8[] rraw = br.read_raw_bytes (12);
                r0 = read_u32_le (rraw, 0);
                r1 = read_u32_le (rraw, 4);
                r2 = read_u32_le (rraw, 8);
                uint64 take = expected_out - win.position ();
                if (take == 0)
                    throw new Itsf.Error.READ_FAILED (
                        "LZX empty uncompressed block");
                if (take > (uint64) int.MAX)
                    throw new Itsf.Error.OUT_OF_MEMORY (
                        "LZX uncompressed block too large");
                uint8[] payload = br.read_raw_bytes ((int) take);
                for (int i = 0; i < payload.length; i++)
                    win.emit_literal (payload[i]);
                if (payload.length % 2 == 1) {
                    // Word-alignment pad; absent only at exact stream end.
                    if (win.position () < expected_out)
                        br.read_raw_bytes (1);
                    else {
                        try {
                            br.read_raw_bytes (1);
                        } catch (Itsf.Error.READ_FAILED e) {
                        }
                    }
                }
                if (e8)
                    win.e8_fix_block (block_start, take, expected_out);
                continue;
            }
            if (btype != 1 && btype != 2)
                throw new Itsf.Error.READ_FAILED (
                    "LZX invalid block type %u".printf (btype));
            uint64 bsize = br.read_bits (24);
            if (bsize == 0 || bsize > 0xFFFFFFu)
                throw new Itsf.Error.READ_FAILED (
                    "LZX invalid block size");
            uint64 bend = win.position () + bsize;
            if (bend > expected_out)
                bend = expected_out;
            HuffmanTable? aligned = null;
            if (btype == 2) {
                var alens = new uint8[8];
                for (int i = 0; i < 8; i++)
                    alens[i] = (uint8) br.read_bits (3);
                aligned = new HuffmanTable ();
                aligned.build_from_lengths (alens);
            }
            uint8[] m1 = Pretree.decode_lengths (br, 256, pm1);
            uint8[] m2 = Pretree.decode_lengths (br, main_count - 256, pm2);
            uint8[] lt = Pretree.decode_lengths (br, 249, pl);
            pm1 = m1;
            pm2 = m2;
            pl = lt;
            var both = new uint8[main_count];
            for (int i = 0; i < 256; i++)
                both[i] = m1[i];
            for (int i = 0; i < main_count - 256; i++)
                both[256 + i] = m2[i];
            var main_table = new HuffmanTable ();
            main_table.build_from_lengths (both);
            var len_table = new HuffmanTable ();
            len_table.build_from_lengths (lt);
            while (win.position () < bend) {
                uint32 sym = main_table.decode_symbol (br);
                if (sym < 256) {
                    win.emit_literal ((uint8) sym);
                } else {
                    // Length-tree 248 is exactly 257 (no Extra Length field);
                    // longer matches arrive as split chains.
                    uint32 lh = (sym - 256u) & 7u;
                    uint32 mlen = lh == 7u
                        ? len_table.decode_symbol (br) + 9u : lh + 2u;
                    uint32 slot = (sym - 256u) >> 3;
                    uint32 off;
                    if (slot == 0) {
                        off = r0;
                    } else if (slot == 1) {
                        off = r1;
                        uint32 t = r0; r0 = r1; r1 = t;
                    } else if (slot == 2) {
                        off = r2;
                        uint32 t = r0; r0 = r2; r2 = t;
                    } else {
                        if ((int) slot >= slots)
                            throw new Itsf.Error.READ_FAILED (
                                "LZX position slot outside window");
                        uint32 sbase = slot_base (slot);
                        uint fb = slot_fbits (slot);
                        uint32 verb;
                        uint32 al = 0;
                        if (btype == 2 && fb >= 3) {
                            verb = br.read_bits ((int) fb - 3) << 3;
                            assert (aligned != null);
                            al = aligned.decode_symbol (br);
                        } else {
                            verb = br.read_bits ((int) fb);
                        }
                        if (verb + al < verb)
                            throw new Itsf.Error.READ_FAILED (
                                "LZX offset overflow");
                        uint32 form = sbase + verb + al;
                        if (form < 2u)
                            throw new Itsf.Error.READ_FAILED (
                                "LZX formatted offset too small");
                        off = form - 2u;
                        r2 = r1;
                        r1 = r0;
                        r0 = off;
                    }
                    if ((uint64) mlen > bend - win.position ())
                        throw new Itsf.Error.READ_FAILED (
                            "LZX match overruns block");
                    win.emit_match (off, mlen);
                }
                if (win.position () % 0x8000ul == 0ul
                        && win.position () < expected_out)
                    br.align_to_word ();
            }
            if (e8)
                win.e8_fix_block (block_start, bend - block_start,
                    expected_out);
        }
        return win.to_bytes ();
    }
}

} // namespace Itsf.Lzx
