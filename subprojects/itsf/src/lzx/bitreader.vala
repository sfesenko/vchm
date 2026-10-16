// LZX bit reader: 16-bit little-endian words, MSB first ([MS-PATCH] 2.1.1).
// Streams are word-aligned; reads past the last full word throw READ_FAILED.

namespace Itsf.Lzx {

public class BitReader : Object {
    private uint8[] data;
    private int pos = 0;        // next unread byte
    private uint32 bitbuf = 0;  // buffered bits, left-aligned (MSB first)
    private int nbits = 0;      // number of valid bits in bitbuf

    public BitReader (uint8[] data) {
        // Copy: the caller's array may be a short-lived literal.
        this.data = data.length > 0 ? data[0:data.length] : new uint8[0];
    }

    public uint32 read_bits (int n) throws Itsf.Error {
        if (n < 0 || n > 24)
            throw new Itsf.Error.INTERNAL (
                "BitReader.read_bits: width %d out of range 0..24".printf (n));
        if (n == 0)
            return 0;
        if (n > 16)
            return (read_bits (n - 16) << 16) | read_bits (16);
        while (nbits < n) {
            if (pos + 2 > data.length)
                throw new Itsf.Error.READ_FAILED ("LZX bitstream overread");
            uint32 word = (uint32) data[pos] | ((uint32) data[pos + 1] << 8);
            pos += 2;
            bitbuf |= word << (16 - nbits);
            nbits += 16;
        }
        uint32 val = bitbuf >> (32 - n);
        bitbuf <<= n;
        nbits -= n;
        return val;
    }

    public bool is_aligned_to_byte () {
        // Bytes consumed = pos * 8 - nbits; pos is always even, so the
        // consumed count is a multiple of 8 exactly when nbits is.
        return (nbits % 8) == 0;
    }

    public void align_to_byte () {
        int drop = nbits % 8;
        bitbuf <<= drop;
        nbits -= drop;
    }

    public void align_to_word () {
        // Discard to the next 16-bit boundary (CHM 0x8000 realignment,
        // type-3 block padding).
        int drop = nbits % 16;
        bitbuf <<= drop;
        nbits -= drop;
    }

    public uint8[] read_raw_bytes (int n) throws Itsf.Error {
        // Raw stream bytes for type-3 blocks; any other state is a bug.
        if (n < 0)
            throw new Itsf.Error.INTERNAL (
                "BitReader.read_raw_bytes: negative count %d".printf (n));
        if (n == 0)
            return new uint8[0];
        var out = new uint8[n];
        int k = 0;
        if (nbits == 16) {
            // Serve the buffered word in little-endian stream-byte order
            // (low byte first), not bit-buffer order.
            if (pos < 2)
                throw new Itsf.Error.INTERNAL (
                    "BitReader.read_raw_bytes: bad buffer state");
            if (n >= 2) {
                out[0] = data[pos - 2];
                out[1] = data[pos - 1];
                k = 2;
                bitbuf = 0;
                nbits = 0;
            } else {
                out[0] = data[pos - 2];
                bitbuf = (uint32) data[pos - 1] << 24;
                nbits = 8;
                return out;
            }
        }
        if (nbits == 8 && k < n) {
            out[k++] = (uint8) (bitbuf >> 24);
            bitbuf = 0;
            nbits = 0;
        }
        if (nbits != 0)
            throw new Itsf.Error.INTERNAL (
                "BitReader.read_raw_bytes: partial buffer");
        uint64 need = (uint64) (n - k);
        if ((uint64) pos + need > (uint64) data.length)
            throw new Itsf.Error.READ_FAILED ("LZX raw byte overread");
        for (int i = k; i < n; i++)
            out[i] = data[pos++];
        return out;
    }
}

} // namespace Itsf.Lzx
