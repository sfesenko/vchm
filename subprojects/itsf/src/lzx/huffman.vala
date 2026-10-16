// Canonical Huffman tables + LZX pretree ([MS-PATCH] 2.4/2.5).
// Lengths delta per index against the previous tree (zeros for a first
// block); 17/18 zero-runs, 19 value-run with pretree-coded 2nd symbol.
// Incomplete codes accepted; over-subscribed sets, bad prefixes throw.

namespace Itsf.Lzx {

public class HuffmanTable : Object {
    private const int MAXBITS = 16;

    private int maxlen = 0;
    private int[] counts = new int[0];      // codes per length, index by len
    private int[] first = new int[0];       // first canonical code per len
    private uint32[] symbols = new uint32[0]; // symbols in (len, sym) order

    public void build_from_lengths (uint8[] lens) throws Itsf.Error {
        var bl_count = new int[MAXBITS + 1];
        int ml = 0;
        for (int i = 0; i < lens.length; i++) {
            int len = lens[i];
            if (len > MAXBITS)
                throw new Itsf.Error.READ_FAILED (
                    "Huffman code length %d exceeds maximum %d".printf (len, MAXBITS));
            if (len > 0) {
                bl_count[len]++;
                if (len > ml)
                    ml = len;
            }
        }
        // Canonical first code per length; reject overhanging sets whose
        // codes would not fit in their length.
        var first_code = new int[MAXBITS + 1];
        int code = 0;
        for (int len = 1; len <= MAXBITS; len++) {
            code = (code + bl_count[len - 1]) << 1;
            first_code[len] = code;
            if (code + bl_count[len] > (1 << len))
                throw new Itsf.Error.READ_FAILED (
                    "Huffman code over-subscribed at length %d".printf (len));
        }
        int total = 0;
        for (int len = 1; len <= ml; len++)
            total += bl_count[len];
        var ordered = new uint32[total];
        int k = 0;
        for (int len = 1; len <= ml; len++)
            for (int sym = 0; sym < lens.length; sym++)
                if (lens[sym] == len)
                    ordered[k++] = (uint32) sym;
        counts = bl_count;
        first = first_code;
        symbols = ordered;
        maxlen = ml;
    }

    public uint32 decode_symbol (BitReader br) throws Itsf.Error {
        int code = 0;
        int f = 0;
        int index = 0;
        for (int len = 1; len <= maxlen; len++) {
            code = (code << 1) | (int) br.read_bits (1);
            int count = counts[len];
            if (code >= f && code - f < count)
                return symbols[index + (code - f)];
            index += count;
            f = (f + count) << 1;
        }
        throw new Itsf.Error.READ_FAILED ("invalid Huffman prefix in LZX stream");
    }
}

public class Pretree : Object {
    private const int NSYMS = 20;

    public static uint8[] decode_lengths (BitReader br, int count,
            uint8[]? prev = null) throws Itsf.Error {
        if (count < 0)
            throw new Itsf.Error.INTERNAL (
                "Pretree.decode_lengths: negative count %d".printf (count));
        if (count == 0)
            return new uint8[0];
        // Tree-delta per MS-PATCH 2.5, per index against the previous
        // tree (zeros for a first block); no running element prev.
        unowned uint8[] pv;
        uint8[] zeros = new uint8[0];
        if (prev == null) {
            zeros = new uint8[count];
            pv = zeros;
        } else {
            if (prev.length != count)
                throw new Itsf.Error.INTERNAL (
                    "Pretree.decode_lengths: prev length mismatch");
            pv = prev;
        }
        var pre = new uint8[NSYMS];
        for (int i = 0; i < NSYMS; i++)
            pre[i] = (uint8) br.read_bits (4);
        var result = new uint8[count];
        bool any = false;
        foreach (var l in pre) {
            if (l != 0) {
                any = true;
                break;
            }
        }
        if (!any)
            return result;  // empty pretree: every length is zero
        var table = new HuffmanTable ();
        table.build_from_lengths (pre);
        int i = 0;
        while (i < count) {
            uint32 sym = table.decode_symbol (br);
            if (sym < 17) {
                int x = i;
                result[x] = (uint8) ((pv[x] - (int) sym + 17) % 17);
                i++;
            } else if (sym == 17 || sym == 18) {
                int raw = (int) br.read_bits (sym == 17 ? 4 : 5);
                int run = (sym == 17 ? 4 : 20) + raw;
                for (int k = 0; k < run; k++) {
                    if (i >= count)
                        throw new Itsf.Error.READ_FAILED (
                            "LZX pretree zero-run overruns tree");
                    result[i++] = 0;
                }
            } else {
                int same = (int) br.read_bits (1);
                uint32 s2 = table.decode_symbol (br);
                if (s2 > 16)
                    throw new Itsf.Error.READ_FAILED (
                        "LZX pretree value-run code out of range");
                int len = (pv[i] - (int) s2 + 17) % 17;
                for (int k = 0; k < 4 + same; k++) {
                    if (i >= count)
                        throw new Itsf.Error.READ_FAILED (
                            "LZX pretree value-run overruns tree");
                    result[i++] = (uint8) len;
                }
            }
        }
        return result;
    }
}

} // namespace Itsf.Lzx
