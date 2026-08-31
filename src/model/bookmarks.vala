// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using GLib;
using Gee;

namespace Vchm.Model {

    public class Bookmark : Object {
        public string title { get; set; }
        public string url { get; set; }
        public int64 created { get; set; }

        public Bookmark (string title, string url, int64 created = 0) {
            this.title = title;
            this.url = url;
            this.created = created != 0 ? created : new DateTime.now_utc ().to_unix ();
        }
    }

    // Bookmarks grouped per archive. Serialized into a GSettings string
    // array as "archive\x1furl\x1ftitle" rows. Fields are escaped, so
    // titles/URLs containing the unit separator (or backslashes) survive
    // a round-trip instead of being silently dropped on load (review F13).
    public class BookmarkStore : Object {
        private const string SEP = "\x1f";
        private const string ESC = "\\";
        private const string ESC_SEP = "\\e";
        private const string ESC_ESC = "\\\\";

        private Gee.HashMap<string, Gee.ArrayList<Bookmark>> by_book =
            new Gee.HashMap<string, Gee.ArrayList<Bookmark>> ();

        private static string escape_field (string s) {
            if (!s.contains (SEP) && !s.contains (ESC)) return s;
            return s.replace (ESC, ESC_ESC).replace (SEP, ESC_SEP);
        }

        private static string unescape_field (string s) {
            if (!s.contains (ESC)) return s;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < s.length) {
                char c = s[i];
                if (c == '\\' && i + 1 < s.length) {
                    char nxt = s[i + 1];
                    if (nxt == '\\') { sb.append_c ('\\'); i += 2; continue; }
                    if (nxt == 'e') { sb.append (SEP); i += 2; continue; }
                }
                sb.append_c (c);
                i++;
            }
            return sb.str;
        }

        private static int64 now_sec () {
            return new DateTime.now_utc ().to_unix ();
        }

        public void load (string[] raw) {
            by_book.clear ();
            foreach (var row in raw) {
                var parts = row.split (SEP);
                if (parts.length < 3 || parts[0].length == 0) continue;
                string archive = unescape_field (parts[0]);
                string url = unescape_field (parts[1]);
                string title = unescape_field (parts[2]);
                int64 created = now_sec ();
                if (parts.length >= 4) {
                    int64.try_parse (parts[3], out created);
                    if (created == 0) created = now_sec ();
                }
                // Use add_with_time to preserve timestamp
                var list = for_book (archive);
                // dedup by url
                for (int i = list.size - 1; i >= 0; i--) {
                    if (list[i].url == url) list.remove_at (i);
                }
                list.add (new Bookmark (title, url, created));
            }
        }

        public string[] save () {
            var out_list = new string[0];
            foreach (var entry in by_book.entries) {
                // An empty archive key can never be resolved back to a
                // book — dropping it beats emitting an unloadable row.
                if (entry.key.length == 0) continue;
                foreach (var b in entry.value) {
                    out_list += "%s%s%s%s%s%s%lld".printf (
                        escape_field (entry.key), SEP,
                        escape_field (b.url), SEP,
                        escape_field (b.title), SEP,
                        b.created);
                }
            }
            return out_list;
        }

        public bool prune (int expire_days) {
            if (expire_days <= 0) return false;
            int64 now = now_sec ();
            int64 limit = expire_days * 86400;
            bool any = false;
            var to_remove_book = new Gee.ArrayList<string> ();
            foreach (var entry in by_book.entries) {
                var list = entry.value;
                int before = list.size;
                for (int i = list.size - 1; i >= 0; i--) {
                    int64 age = now - list[i].created;
                    if (age > limit) list.remove_at (i);
                }
                if (list.size != before) any = true;
                if (list.size == 0) to_remove_book.add (entry.key);
            }
            foreach (var k in to_remove_book) by_book.unset (k);
            if (to_remove_book.size > 0) any = true;
            return any;
        }

        public Gee.ArrayList<Bookmark> for_book (string archive) {
            if (!by_book.has_key (archive))
                by_book[archive] = new Gee.ArrayList<Bookmark> ();
            return by_book[archive];
        }

        public void add (string archive, string title, string url) {
            var list = for_book (archive);
            // replace existing entry with same URL
            for (int i = list.size - 1; i >= 0; i--) {
                if (list[i].url == url) list.remove_at (i);
            }
            list.add (new Bookmark (title, url));
        }

        public bool remove (string archive, string title) {
            var list = for_book (archive);
            for (int i = 0; i < list.size; i++) {
                if (list[i].title == title) {
                    list.remove_at (i);
                    return true;
                }
            }
            return false;
        }

        public bool remove_by_url (string archive, string url) {
            var list = for_book (archive);
            for (int i = 0; i < list.size; i++) {
                if (list[i].url == url) {
                    list.remove_at (i);
                    return true;
                }
            }
            return false;
        }

        public bool rename (string archive, string url, string new_title) {
            var list = for_book (archive);
            for (int i = 0; i < list.size; i++) {
                if (list[i].url == url) {
                    list[i].title = new_title;
                    return true;
                }
            }
            return false;
        }
    }
}
