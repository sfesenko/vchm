// ITSF directory index: path -> entry lookup plus the public listing.

namespace Itsf {

    internal class Entry : Object {
        public string path;
        public uint32 space;
        public uint64 start;
        public uint64 length;

        public Entry (string path, uint32 space, uint64 start, uint64 length) {
            this.path = path;
            this.space = space;
            this.start = start;
            this.length = length;
        }
    }

    internal class Index : Object {
        private Gee.HashMap<string, Entry> map;
        private Gee.ArrayList<string> public_paths;

        public Index () {
            map = new Gee.HashMap<string, Entry> ();
            public_paths = new Gee.ArrayList<string> ();
        }

        public static string normalize (string path) {
            string p = path;
            if (!p.has_prefix ("/"))
                p = "/" + p;
            while (p.length > 1 && p.has_suffix ("/"))
                p = p.substring (0, p.length - 1);
            return p;
        }

        // System streams ("/#*", "/$*") and the "::DataSpace" control
        // streams resolve via contains() but stay out of list().
        public static bool is_public (string normalized) {
            if (normalized.contains ("::"))
                return false;
            if (normalized.has_prefix ("/#") || normalized.has_prefix ("/$"))
                return false;
            return true;
        }

        public void add (string raw_path, uint32 space, uint64 start, uint64 length) {
            string key = normalize (raw_path);
            if (map.has_key (key))
                return;
            map[key] = new Entry (key, space, start, length);
            if (is_public (key))
                public_paths.add (key);
        }

        public bool contains (string path) {
            return map.has_key (normalize (path));
        }

        public uint64 entry_size (string path) {
            Entry? e = map.get (normalize (path));
            return e != null ? e.length : 0;
        }

        public bool try_lookup (string path, out uint32 space, out uint64 start, out uint64 length) {
            Entry? e = map.get (normalize (path));
            if (e == null) {
                space = 0;
                start = 0;
                length = 0;
                return false;
            }
            space = e.space;
            start = e.start;
            length = e.length;
            return true;
        }

        public string[] list () {
            return public_paths.to_array ();
        }
    }
}
