// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Per-book persisted state: font override, last page, scroll, selected
// TOC URL, expanded nodes, navigation history, last access timestamp.
// Serialized like BookmarkStore as 8-field rows with \x1f separation and
// inner \x1e/\x1d escaped hierarchically.

using GLib;
using Gee;

namespace Vchm.Model {

    public class PerBookState : Object {
        public int font_size { get; set; } // -1 = use global
        public string last_url { get; set; }
        public int scroll_y { get; set; }
        public string selected_url { get; set; }
        public Gee.HashSet<string> expanded { get; set; }
        public int64 last_access { get; set; } // unix seconds
        public Gee.ArrayList<HistoryEntry> hist { get; set; }
        public int hist_index { get; set; }

        public PerBookState (int font_size = -1, string last_url = "", int scroll_y = 0) {
            this.font_size = font_size;
            this.last_url = last_url;
            this.scroll_y = scroll_y;
            this.selected_url = "";
            this.expanded = new Gee.HashSet<string> ();
            this.last_access = 0;
            this.hist = new Gee.ArrayList<HistoryEntry> ();
            this.hist_index = -1;
        }
    }

    public class PerBookStore : Object {
        private const string SEP = "\x1f";
        private const string SUB1 = "\x1e";
        private const string SUB2 = "\x1d";
        private const string ESC = "\\";
        private const string ESC_ESC = "\\\\";
        private const string ESC_SEP = "\\e";
        private const string ESC_SUB1 = "\\f";
        private const string ESC_SUB2 = "\\g";
        private const int MAX_PERSIST_HIST = 20;

        private Gee.HashMap<string, PerBookState> by_book =
            new Gee.HashMap<string, PerBookState> ();

        private static string escape_top (string s) {
            if (!s.contains (SEP) && !s.contains (ESC)) return s;
            return s.replace (ESC, ESC_ESC).replace (SEP, ESC_SEP);
        }

        private static string escape_inner (string s) {
            if (!s.contains (SEP) && !s.contains (SUB1) && !s.contains (SUB2) && !s.contains (ESC)) return s;
            return s.replace (ESC, ESC_ESC)
                    .replace (SEP, ESC_SEP)
                    .replace (SUB1, ESC_SUB1)
                    .replace (SUB2, ESC_SUB2);
        }

        private static string unescape_all (string s) {
            if (!s.contains (ESC)) return s;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < s.length) {
                char c = s[i];
                if (c == '\\' && i + 1 < s.length) {
                    char nxt = s[i + 1];
                    if (nxt == '\\') { sb.append_c ('\\'); i += 2; continue; }
                    if (nxt == 'e') { sb.append (SEP); i += 2; continue; }
                    if (nxt == 'f') { sb.append (SUB1); i += 2; continue; }
                    if (nxt == 'g') { sb.append (SUB2); i += 2; continue; }
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
                if (parts.length < 4 || parts[0].length == 0) continue;
                string archive = unescape_all (parts[0]);
                string last_url = unescape_all (parts[1]);
                int font_size = -1;
                int scroll_y = 0;
                int.try_parse (parts[2], out font_size);
                if (font_size < 0) font_size = -1;
                int tmp = 0;
                if (int.try_parse (parts[3], out tmp)) scroll_y = tmp;

                var st = new PerBookState (font_size, last_url, scroll_y);

                if (parts.length >= 8) {
                    // New 8-field format
                    st.selected_url = unescape_all (parts[4]);
                    int64 la = 0;
                    int64.try_parse (parts[5], out la);
                    st.last_access = la;
                    // hist_blob parts[6], expanded_blob parts[7]
                    parse_hist_blob (st, parts[6]);
                    parse_expanded_blob (st, parts[7]);
                } else if (parts.length == 4) {
                    // Legacy: bump last_access to now
                    st.last_access = now_sec ();
                } else {
                    // Partial: try to recover last_access if present
                    if (parts.length > 5) {
                        int64 la = 0;
                        int64.try_parse (parts[5], out la);
                        st.last_access = la != 0 ? la : now_sec ();
                    } else {
                        st.last_access = now_sec ();
                    }
                    if (parts.length > 4) {
                        st.selected_url = unescape_all (parts[4]);
                    }
                }
                // For legacy rows without last_access, ensure non-zero
                if (st.last_access == 0) st.last_access = now_sec ();
                by_book[archive] = st;
            }
        }

        private void parse_hist_blob (PerBookState st, string blob) {
            if (blob.length == 0) return;
            var p1 = blob.split (SUB1);
            if (p1.length == 0) return;
            int idx = -1;
            int.try_parse (p1[0], out idx);
            st.hist_index = idx;
            if (p1.length < 2 || p1[1].length == 0) return;
            var entries_raw = p1[1].split (SUB2);
            foreach (var erow in entries_raw) {
                if (erow.length == 0) continue;
                var f = erow.split (SUB1);
                if (f.length < 2) continue;
                string url = unescape_all (f[0]);
                string title = f.length > 1 ? unescape_all (f[1]) : "";
                string chm_file = f.length > 2 ? unescape_all (f[2]) : "";
                // Trim to MAX_PERSIST_HIST during load as well
                if (st.hist.size >= MAX_PERSIST_HIST) continue;
                var e = new HistoryEntry (title, url, chm_file);
                st.hist.add (e);
            }
            // Clamp index
            if (st.hist.size == 0) st.hist_index = -1;
            else if (st.hist_index < 0 || st.hist_index >= st.hist.size) st.hist_index = st.hist.size - 1;
        }

        private void parse_expanded_blob (PerBookState st, string blob) {
            if (blob.length == 0) return;
            var urls = blob.split (SUB2);
            foreach (var u in urls) {
                if (u.length == 0) continue;
                st.expanded.add (unescape_all (u));
            }
        }

        public string[] save () {
            var out_list = new string[0];
            foreach (var entry in by_book.entries) {
                if (entry.key.length == 0) continue;
                var st = entry.value;
                // Build hist blob
                string hist_blob = "";
                if (st.hist.size > 0) {
                    var sb = new StringBuilder ();
                    sb.append_printf ("%d", st.hist_index);
                    sb.append (SUB1);
                    bool first = true;
                    int start = st.hist.size > MAX_PERSIST_HIST ? st.hist.size - MAX_PERSIST_HIST : 0;
                    for (int i = start; i < st.hist.size; i++) {
                        var e = st.hist[i];
                        if (!first) sb.append (SUB2);
                        sb.append (escape_inner (e.url));
                        sb.append (SUB1);
                        sb.append (escape_inner (e.title));
                        sb.append (SUB1);
                        sb.append (escape_inner (e.chm_file));
                        first = false;
                    }
                    // Adjust index to truncated view
                    if (start > 0) {
                        int new_idx = st.hist_index - start;
                        if (new_idx < 0) new_idx = 0;
                        if (new_idx >= (st.hist.size - start)) new_idx = st.hist.size - start - 1;
                        // Rebuild with corrected index
                        var sb2 = new StringBuilder ();
                        sb2.append_printf ("%d", new_idx);
                        sb2.append (SUB1);
                        var parts = sb.str.split (SUB1, 2);
                        if (parts.length == 2) sb2.append (parts[1]);
                        hist_blob = sb2.str;
                    } else {
                        hist_blob = sb.str;
                    }
                } else {
                    hist_blob = "-1";
                }
                // Expanded blob
                string exp_blob = "";
                if (st.expanded.size > 0) {
                    var arr = st.expanded.to_array ();
                    var enc = new string[0];
                    foreach (var u in arr) enc += escape_inner (u);
                    exp_blob = string.joinv (SUB2, enc);
                }
                out_list += "%s%s%s%s%d%s%d%s%s%s%lld%s%s%s%s".printf (
                    escape_top (entry.key), SEP,
                    escape_top (st.last_url), SEP,
                    st.font_size, SEP,
                    st.scroll_y, SEP,
                    escape_top (st.selected_url), SEP,
                    st.last_access, SEP,
                    hist_blob, SEP,
                    exp_blob);
            }
            return out_list;
        }

        public bool prune (int expire_days) {
            if (expire_days <= 0) return false;
            int64 now = now_sec ();
            int64 limit = expire_days * 86400;
            var to_remove = new Gee.ArrayList<string> ();
            foreach (var entry in by_book.entries) {
                int64 age = now - entry.value.last_access;
                if (age > limit) to_remove.add (entry.key);
            }
            foreach (var k in to_remove) by_book.unset (k);
            return to_remove.size > 0;
        }

        public PerBookState for_book (string archive) {
            if (!by_book.has_key (archive))
                by_book[archive] = new PerBookState ();
            return by_book[archive];
        }

        public bool has_book (string archive) {
            return by_book.has_key (archive);
        }

        public void touch (string archive) {
            for_book (archive).last_access = now_sec ();
        }

        public void set_font_size (string archive, int size) {
            var st = for_book (archive);
            st.font_size = size;
            st.last_access = now_sec ();
        }

        public int get_font_size (string archive, int fallback) {
            if (!by_book.has_key (archive)) return fallback;
            int v = by_book[archive].font_size;
            return v >= 0 ? v : fallback;
        }

        public void set_last_url (string archive, string url) {
            var st = for_book (archive);
            st.last_url = url;
            st.last_access = now_sec ();
        }

        public string get_last_url (string archive) {
            if (!by_book.has_key (archive)) return "";
            return by_book[archive].last_url;
        }

        public void set_scroll (string archive, int y) {
            var st = for_book (archive);
            st.scroll_y = y;
            st.last_access = now_sec ();
        }

        public int get_scroll (string archive) {
            if (!by_book.has_key (archive)) return 0;
            return by_book[archive].scroll_y;
        }

        public void set_selected_url (string archive, string url) {
            var st = for_book (archive);
            st.selected_url = url;
            st.last_access = now_sec ();
        }

        public string get_selected_url (string archive) {
            if (!by_book.has_key (archive)) return "";
            return by_book[archive].selected_url;
        }

        public Gee.HashSet<string> get_expanded (string archive) {
            if (!by_book.has_key (archive)) return new Gee.HashSet<string> ();
            return by_book[archive].expanded;
        }

        public void set_expanded (string archive, Gee.HashSet<string> set) {
            var st = for_book (archive);
            st.expanded = set;
            st.last_access = now_sec ();
        }

        public void set_history (string archive, Gee.ArrayList<HistoryEntry> entries, int current_index) {
            var st = for_book (archive);
            // Copy truncated
            st.hist.clear ();
            int start = entries.size > MAX_PERSIST_HIST ? entries.size - MAX_PERSIST_HIST : 0;
            for (int i = start; i < entries.size; i++) st.hist.add (entries[i]);
            if (start > 0) {
                int new_idx = current_index - start;
                if (new_idx < 0) new_idx = 0;
                if (new_idx >= st.hist.size) new_idx = st.hist.size - 1;
                st.hist_index = new_idx;
            } else {
                st.hist_index = current_index;
            }
            if (st.hist.size == 0) st.hist_index = -1;
            st.last_access = now_sec ();
        }

        public void get_history (string archive, out Gee.ArrayList<HistoryEntry> entries, out int current_index) {
            if (!by_book.has_key (archive)) {
                entries = new Gee.ArrayList<HistoryEntry> ();
                current_index = -1;
                return;
            }
            var st = by_book[archive];
            entries = st.hist;
            current_index = st.hist_index;
        }
    }
}
