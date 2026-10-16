// ITSF container + ITSP directory walk (PMGL leaves via PMGI nodes).
// Layout: ITSF v3 (0x60) -> ITSP (0x54) -> fixed-size block chunks;
// PMGL [name][space][start][length] quads, PMGI [name][page_id] pairs,
// CWORD ints (7 bits/byte, high bit continues, most-significant first).

namespace Itsf {

    internal class Container : Object {

        private const uint32 ITSF_HEADER_LEN = 0x60;
        private const uint32 ITSP_HEADER_LEN = 0x54;
        private const uint32 PMGL_HEADER_LEN = 0x14;
        private const uint32 PMGI_HEADER_LEN = 8;

        private static uint32 read_u32 (uint8[] d, uint64 pos) throws Itsf.Error {
            if (pos + 4 > (uint64) d.length || pos + 4 < pos)
                throw new Itsf.Error.INVALID_INDEX ("short read");
            size_t p = (size_t) pos;
            return (uint32) d[p]
                | ((uint32) d[p + 1] << 8)
                | ((uint32) d[p + 2] << 16)
                | ((uint32) d[p + 3] << 24);
        }

        private static int32 read_i32 (uint8[] d, uint64 pos) throws Itsf.Error {
            return (int32) read_u32 (d, pos);
        }

        private static uint64 read_u64 (uint8[] d, uint64 pos) throws Itsf.Error {
            if (pos + 8 > (uint64) d.length || pos + 8 < pos)
                throw new Itsf.Error.INVALID_INDEX ("short read");
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

        // Most-significant group first; high bit set means more follows.
        private static uint64 read_cword (uint8[] d, ref uint64 pos, uint64 limit)
                throws Itsf.Error {
            uint64 v = 0;
            int nbytes = 0;
            while (true) {
                if (pos >= limit || pos >= (uint64) d.length)
                    throw new Itsf.Error.INVALID_INDEX ("truncated cword");
                uint8 b = d[(size_t) pos];
                pos++;
                if (++nbytes > 10)
                    throw new Itsf.Error.INVALID_INDEX ("cword overflow");
                v = (v << 7) | (uint64) (b & 0x7F);
                if ((b & 0x80) == 0)
                    break;
            }
            return v;
        }

        private static string read_name (uint8[] d, ref uint64 pos, uint64 limit,
                out int name_len) throws Itsf.Error {
            uint64 n = read_cword (d, ref pos, limit);
            if (pos + n < pos || pos + n > limit || pos + n > (uint64) d.length)
                throw new Itsf.Error.INVALID_INDEX ("truncated name");
            int len = (int) n;
            uint8[] tmp = new uint8[len + 1];
            for (int i = 0; i < len; i++)
                tmp[i] = d[(size_t) pos + i];
            tmp[len] = 0;
            pos += n;
            name_len = len;
            return (string) tmp;
        }

        private static bool sig_is (uint8[] d, uint64 pos, string sig) throws Itsf.Error {
            if (pos + 4 > (uint64) d.length || pos + 4 < pos)
                throw new Itsf.Error.INVALID_INDEX ("short read");
            size_t p = (size_t) pos;
            for (int i = 0; i < 4; i++)
                if (d[p + i] != (uint8) sig[i])
                    return false;
            return true;
        }

        private static bool at_terminator (uint8[] d, uint64 pos, uint64 chunk_end) {
            if (pos + 4 > chunk_end || pos + 4 < pos)
                return false;
            if (pos + 4 > (uint64) d.length)
                return false;
            size_t p = (size_t) pos;
            return d[p] == 0xFF && d[p + 1] == 0xFF && d[p + 2] == 0xFF && d[p + 3] == 0xFF;
        }

        private static void queue_page (Gee.ArrayList<uint32> pending, int64 cap,
                int32 page, int32 num_blocks, Gee.HashSet<uint32> visited) {
            if (page < 0 || page >= num_blocks)
                return;
            uint32 id = (uint32) page;
            if (visited.contains (id))
                return;
            if ((int64) pending.size >= cap)
                return;
            pending.add (id);
        }

        private static void parse_pmgl (uint8[] d, uint64 chunk_off, uint64 block_len,
                Index index, Gee.ArrayList<uint32> pending, Gee.HashSet<uint32> visited,
                int32 num_blocks, int64 cap) throws Itsf.Error {
            uint64 chunk_end = chunk_off + block_len;
            uint32 free = read_u32 (d, chunk_off + 4);
            if ((uint64) free > block_len - PMGL_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("bad PMGL free space");
            uint64 body_end = chunk_end - (uint64) free;
            int32 nxt = read_i32 (d, chunk_off + 16);
            uint64 pos = chunk_off + PMGL_HEADER_LEN;
            while (pos < body_end) {
                if (at_terminator (d, pos, chunk_end))
                    break;
                int name_len = 0;
                string name = read_name (d, ref pos, body_end, out name_len);
                uint64 space = read_cword (d, ref pos, body_end);
                uint64 start = read_cword (d, ref pos, body_end);
                uint64 length = read_cword (d, ref pos, body_end);
                if (space > 0xFFFFFFFFu)
                    throw new Itsf.Error.INVALID_INDEX ("entry space overflow");
                // An interior NUL would truncate the Vala string; skip those.
                if (name_len > 0 && name.length == name_len)
                    index.add (name, (uint32) space, start, length);
            }
            queue_page (pending, cap, nxt, num_blocks, visited);
        }

        private static void parse_pmgi (uint8[] d, uint64 chunk_off, uint64 block_len,
                Gee.ArrayList<uint32> pending, Gee.HashSet<uint32> visited,
                int32 num_blocks, int64 cap) throws Itsf.Error {
            uint64 chunk_end = chunk_off + block_len;
            uint32 free = read_u32 (d, chunk_off + 4);
            if ((uint64) free > block_len - PMGI_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("bad PMGI free space");
            uint64 body_end = chunk_end - (uint64) free;
            uint64 pos = chunk_off + PMGI_HEADER_LEN;
            while (pos < body_end) {
                int name_len = 0;
                read_name (d, ref pos, body_end, out name_len);
                uint64 page = read_cword (d, ref pos, body_end);
                if (page < (uint64) num_blocks)
                    queue_page (pending, cap, (int32) page, num_blocks, visited);
            }
        }

        public static void parse (uint8[] data, out Index index, out uint64 data_offset)
                throws Itsf.Error {
            index = new Index ();
            data_offset = 0;
            uint64 len = (uint64) data.length;

            if (len < ITSF_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("file too short for ITSF header");
            if (!sig_is (data, 0, "ITSF"))
                throw new Itsf.Error.INVALID_INDEX ("bad ITSF magic");
            if (read_u32 (data, 8) != ITSF_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("bad ITSF header length");
            uint64 dir_offset = read_u64 (data, 72);
            uint64 dir_len = read_u64 (data, 80);
            data_offset = read_u64 (data, 88);
            if (dir_offset + dir_len < dir_offset
                    || dir_offset + dir_len > len)
                throw new Itsf.Error.INVALID_INDEX ("directory outside file");
            if (dir_len < ITSP_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("directory too short");

            uint64 dir_start = dir_offset;
            uint64 dir_end = dir_start + dir_len;
            if (!sig_is (data, dir_start, "ITSP"))
                throw new Itsf.Error.INVALID_INDEX ("bad ITSP magic");
            if (read_u32 (data, dir_start + 8) != ITSP_HEADER_LEN)
                throw new Itsf.Error.INVALID_INDEX ("bad ITSP header length");
            uint32 block_len = read_u32 (data, dir_start + 16);
            int32 depth = read_i32 (data, dir_start + 24);
            int32 root = read_i32 (data, dir_start + 28);
            int32 head = read_i32 (data, dir_start + 32);
            // num_blocks is at +0x28 in fixtures, +0x2C in real books
            // (which carry -1 at +0x28); fall back when +0x28 is implausible.
            int32 num_blocks = read_i32 (data, dir_start + 40);
            if (block_len < 16 || num_blocks <= 0
                    || (uint64) ITSP_HEADER_LEN + (uint64) num_blocks * (uint64) block_len > dir_len) {
                int32 alt = read_i32 (data, dir_start + 44);
                if (alt > 0 && (uint64) ITSP_HEADER_LEN + (uint64) alt * (uint64) block_len <= dir_len)
                    num_blocks = alt;
            }
            if (block_len < 16 || num_blocks <= 0)
                throw new Itsf.Error.INVALID_INDEX ("bad directory sizing");
            if ((uint64) ITSP_HEADER_LEN + (uint64) num_blocks * (uint64) block_len > dir_len)
                throw new Itsf.Error.INVALID_INDEX ("directory blocks overflow dir_len");

            bool rooted = depth > 0 && root >= 0 && root < num_blocks;
            int32 seed = rooted ? root : head;
            if (seed < 0 || seed >= num_blocks)
                throw new Itsf.Error.INVALID_INDEX ("bad index seed");

            var pending = new Gee.ArrayList<uint32> ();
            var visited = new Gee.HashSet<uint32> ();
            int64 cap = (int64) num_blocks + 16;
            pending.add ((uint32) seed);
            int cursor = 0;
            int64 processed = 0;
            while (cursor < pending.size && processed < cap) {
                uint32 id = pending[cursor++];
                if (visited.contains (id))
                    continue;
                visited.add (id);
                processed++;
                uint64 chunk_off = dir_start
                    + (uint64) ITSP_HEADER_LEN
                    + (uint64) id * (uint64) block_len;
                uint64 chunk_end = chunk_off + (uint64) block_len;
                if (chunk_end < chunk_off || chunk_end > dir_end || chunk_end > len)
                    throw new Itsf.Error.INVALID_INDEX ("chunk outside directory");
                if (sig_is (data, chunk_off, "PMGL"))
                    parse_pmgl (data, chunk_off, block_len, index,
                        pending, visited, num_blocks, cap);
                else if (sig_is (data, chunk_off, "PMGI"))
                    parse_pmgi (data, chunk_off, block_len,
                        pending, visited, num_blocks, cap);
                else
                    throw new Itsf.Error.INVALID_INDEX ("bad chunk signature");
            }
        }
    }
}
