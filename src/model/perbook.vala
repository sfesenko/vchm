// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Per-book persisted state: font override, last page, scroll.
// Serialized like BookmarkStore as "archive\x1flast_url\x1ffont_size\x1fscroll_y" rows.
// font_size -1 means use global default; scroll_y -1 means top.

using GLib;
using Gee;

namespace Vchm.Model {

    public class PerBookState : Object {
        public int font_size { get; set; } // -1 = use global
        public string last_url { get; set; }
        public int scroll_y { get; set; }

        public PerBookState (int font_size = -1, string last_url = "", int scroll_y = 0) {
            this.font_size = font_size;
            this.last_url = last_url;
            this.scroll_y = scroll_y;
        }
    }

    public class PerBookStore : Object {
        private const string SEP = "\x1f";
        private const string ESC = "\\";
        private const string ESC_SEP = "\\e";
        private const string ESC_ESC = "\\\\";

        private Gee.HashMap<string, PerBookState> by_book =
            new Gee.HashMap<string, PerBookState> ();

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

        public void load (string[] raw) {
            by_book.clear ();
            foreach (var row in raw) {
                var parts = row.split (SEP);
                if (parts.length != 4 || parts[0].length == 0) continue;
                string archive = unescape_field (parts[0]);
                string last_url = unescape_field (parts[1]);
                int font_size = -1;
                int scroll_y = 0;
                int.try_parse (parts[2], out font_size);
                if (font_size < 0) font_size = -1;
                int tmp = 0;
                if (int.try_parse (parts[3], out tmp)) scroll_y = tmp;
                by_book[archive] = new PerBookState (font_size, last_url, scroll_y);
            }
        }

        public string[] save () {
            var out_list = new string[0];
            foreach (var entry in by_book.entries) {
                if (entry.key.length == 0) continue;
                var st = entry.value;
                out_list += "%s%s%s%s%d%s%d".printf (
                    escape_field (entry.key), SEP,
                    escape_field (st.last_url), SEP,
                    st.font_size, SEP,
                    st.scroll_y);
            }
            return out_list;
        }

        public PerBookState for_book (string archive) {
            if (!by_book.has_key (archive))
                by_book[archive] = new PerBookState ();
            return by_book[archive];
        }

        public bool has_book (string archive) {
            return by_book.has_key (archive);
        }

        public void set_font_size (string archive, int size) {
            for_book (archive).font_size = size;
        }

        public int get_font_size (string archive, int fallback) {
            if (!by_book.has_key (archive)) return fallback;
            int v = by_book[archive].font_size;
            return v >= 0 ? v : fallback;
        }

        public void set_last_url (string archive, string url) {
            for_book (archive).last_url = url;
        }

        public string get_last_url (string archive) {
            if (!by_book.has_key (archive)) return "";
            return by_book[archive].last_url;
        }

        public void set_scroll (string archive, int y) {
            for_book (archive).scroll_y = y;
        }

        public int get_scroll (string archive) {
            if (!by_book.has_key (archive)) return 0;
            return by_book[archive].scroll_y;
        }
    }
}
