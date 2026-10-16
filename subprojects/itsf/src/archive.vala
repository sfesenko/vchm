// Itsf.Archive: public entry point for reading CHM (ITSF) archives.
// Section-0 entries slice the file blob; space != 0 sections decode lazily
// through SectionCache (whole section once per open, later reads slice it).

namespace Itsf {

    public class Archive : Object {

        private Index index;
        private GLib.Bytes? blob;
        private uint64 data_offset;
        private SectionCache? seccache;

        private Archive () {
            index = new Index ();
        }

        public static async Archive open (GLib.File file) throws Itsf.Error {
            GLib.Bytes bytes;
            try {
                string? etag = null;
                bytes = yield file.load_bytes_async (null, out etag);
            } catch (GLib.Error e) {
                throw new Itsf.Error.OPEN_FAILED (
                    "cannot read file: %s".printf (e.message));
            }
            Index idx;
            uint64 off;
            Container.parse (bytes.get_data (), out idx, out off);
            var arc = new Archive ();
            arc.blob = bytes;
            arc.index = idx;
            arc.data_offset = off;
            return arc;
        }

        public bool contains (string path) {
            return index != null && index.contains (path);
        }

        public uint64 uncompressed_size (string path) {
            return index != null ? index.entry_size (path) : 0;
        }

        public string[] list () {
            return index != null ? index.list () : new string[0];
        }

        public GLib.Bytes read (string path) throws Itsf.Error {
            uint32 space = 0;
            uint64 start = 0;
            uint64 length = 0;
            if (index == null || !index.try_lookup (path, out space, out start, out length))
                throw new Itsf.Error.INVALID_PATH ("no such entry: %s".printf (path));
            if (space != 0)
                return read_section (space, start, length);
            return slice (start, length);
        }

        public GLib.Bytes read_range (string path, uint64 offset, uint64 length)
                throws Itsf.Error {
            uint32 space = 0;
            uint64 start = 0;
            uint64 entry_len = 0;
            if (index == null || !index.try_lookup (path, out space, out start, out entry_len))
                throw new Itsf.Error.INVALID_PATH ("no such entry: %s".printf (path));
            if (space != 0)
                return read_section_range (space, start, entry_len,
                    offset, length);
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset >= entry_len)
                return new GLib.Bytes (new uint8[0]);
            uint64 avail = entry_len - offset;
            uint64 take = length < avail ? length : avail;
            if (take == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset > uint64.MAX - start)
                throw new Itsf.Error.READ_FAILED ("offset overflow");
            return slice (start + offset, take);
        }

        // Async twins of read/read_range: identical bytes, yielding to the
        // main loop after each decoded reset interval. Sync stays for workers.
        public async GLib.Bytes read_async (string path) throws Itsf.Error {
            uint32 space = 0;
            uint64 start = 0;
            uint64 length = 0;
            if (index == null || !index.try_lookup (path, out space, out start, out length))
                throw new Itsf.Error.INVALID_PATH ("no such entry: %s".printf (path));
            if (space != 0)
                return yield read_section_async (space, start, length);
            return slice (start, length);
        }

        public async GLib.Bytes read_range_async (string path, uint64 offset,
                uint64 length) throws Itsf.Error {
            uint32 space = 0;
            uint64 start = 0;
            uint64 entry_len = 0;
            if (index == null || !index.try_lookup (path, out space, out start, out entry_len))
                throw new Itsf.Error.INVALID_PATH ("no such entry: %s".printf (path));
            if (space != 0)
                return yield read_section_range_async (space, start, entry_len,
                    offset, length);
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset >= entry_len)
                return new GLib.Bytes (new uint8[0]);
            uint64 avail = entry_len - offset;
            uint64 take = length < avail ? length : avail;
            if (take == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset > uint64.MAX - start)
                throw new Itsf.Error.READ_FAILED ("offset overflow");
            return slice (start + offset, take);
        }

        private SectionCache section_cache () throws Itsf.Error {
            if (seccache == null) {
                if (blob == null || index == null)
                    throw new Itsf.Error.READ_FAILED ("archive is closed");
                seccache = new SectionCache (index, blob.get_data (),
                    data_offset);
            }
            assert (seccache != null);
            return seccache;
        }

        private GLib.Bytes read_section (uint32 space, uint64 start,
                uint64 length) throws Itsf.Error {
            GLib.Bytes sec = section_cache ().decode_section (space);
            uint64 sec_len = sec.get_size ();
            if (start > sec_len || length > sec_len - start)
                throw new Itsf.Error.READ_FAILED ("entry outside section");
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            unowned uint8[] sdata = sec.get_data ();
            if (length > (uint64) int.MAX)
                throw new Itsf.Error.OUT_OF_MEMORY ("entry too large");
            var buf = new uint8[(int) length];
            int s = (int) start;
            GLib.Memory.copy (buf, &sdata[s], (size_t) length);
            return new GLib.Bytes (buf);
        }

        private GLib.Bytes read_section_range (uint32 space, uint64 start,
                uint64 entry_len, uint64 offset, uint64 length)
                throws Itsf.Error {
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset >= entry_len)
                return new GLib.Bytes (new uint8[0]);
            uint64 avail = entry_len - offset;
            uint64 take = length < avail ? length : avail;
            if (take == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset > uint64.MAX - start)
                throw new Itsf.Error.READ_FAILED ("offset overflow");
            return read_section (space, start + offset, take);
        }

        private async GLib.Bytes read_section_async (uint32 space, uint64 start,
                uint64 length) throws Itsf.Error {
            GLib.Bytes sec = yield section_cache ().decode_section_async (space);
            uint64 sec_len = sec.get_size ();
            if (start > sec_len || length > sec_len - start)
                throw new Itsf.Error.READ_FAILED ("entry outside section");
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            unowned uint8[] sdata = sec.get_data ();
            if (length > (uint64) int.MAX)
                throw new Itsf.Error.OUT_OF_MEMORY ("entry too large");
            var buf = new uint8[(int) length];
            int s = (int) start;
            GLib.Memory.copy (buf, &sdata[s], (size_t) length);
            return new GLib.Bytes (buf);
        }

        private async GLib.Bytes read_section_range_async (uint32 space,
                uint64 start, uint64 entry_len, uint64 offset, uint64 length)
                throws Itsf.Error {
            if (length == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset >= entry_len)
                return new GLib.Bytes (new uint8[0]);
            uint64 avail = entry_len - offset;
            uint64 take = length < avail ? length : avail;
            if (take == 0)
                return new GLib.Bytes (new uint8[0]);
            if (offset > uint64.MAX - start)
                throw new Itsf.Error.READ_FAILED ("offset overflow");
            return yield read_section_async (space, start + offset, take);
        }

        private GLib.Bytes slice (uint64 rel_start, uint64 take) throws Itsf.Error {
            if (take == 0)
                return new GLib.Bytes (new uint8[0]);
            if (blob == null)
                throw new Itsf.Error.READ_FAILED ("archive is closed");
            unowned uint8[] file_data = blob.get_data ();
            uint64 file_len = (uint64) file_data.length;
            if (rel_start > uint64.MAX - data_offset)
                throw new Itsf.Error.READ_FAILED ("offset overflow");
            uint64 abs = data_offset + rel_start;
            if (take > uint64.MAX - abs || abs + take < abs || abs + take > file_len)
                throw new Itsf.Error.READ_FAILED ("entry outside file");
            if (take > (uint64) int.MAX)
                throw new Itsf.Error.OUT_OF_MEMORY ("entry too large");
            var buf = new uint8[(int) take];
            int a = (int) abs;
            GLib.Memory.copy (buf, &file_data[a], (size_t) take);
            return new GLib.Bytes (buf);
        }

        public void close () {
            blob = null;
            seccache = null;
            index = new Index ();
            data_offset = 0;
        }
    }
}
