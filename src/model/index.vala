// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gee;

namespace Vchm.Model {

    // Index entry
    public class IndexEntry : Object {
        public string name { get; set; }
        public string url { get; set; }
        public string keyword { get; set; }

        public IndexEntry (string name, string url, string keyword = "") {
            this.name = name;
            this.url = url;
            this.keyword = keyword;
        }
    }

    // Model for the index panel
    public class IndexModel : Object {
        public Gee.ArrayList<IndexEntry> entries { get; private set; }
        public string filter_text { get; set; }
        public int selected_index { get; set; }
        public bool loading { get; set; }
        public string? error { get; set; }

        public IndexModel () {
            entries = new Gee.ArrayList<IndexEntry> ();
            filter_text = "";
            selected_index = -1;
            loading = false;
        }

        public void clear () {
            entries.clear ();
            filter_text = "";
            selected_index = -1;
            error = null;
        }

        public void build_from_chm (CHMFile chm_file) {
            clear ();
            loading = true;
            error = null;

            // Prefer the binary $WWKeywordLinks/BTree index; fall back
            // to the .hhk keyword file (see chmfile.vala load_index_entries).
            Gee.ArrayList<SearchResult> raw;
            if (chm_file.load_index_entries (out raw)) {
                foreach (var r in raw) {
                    if (r.url.length > 0 || filter_text.length == 0) {
                        entries.add (new IndexEntry (r.title, r.url));
                    }
                }
                if (entries.size > 0) {
                    selected_index = 0;
                }
            } else {
                error = _("No index in this archive");
            }

            loading = false;
        }

        // Helper function for case-insensitive string comparison (ASCII only)
    private static bool contains_ci (string haystack, string needle) {
        // UTF-8 aware: down() uses g_utf8_strdown, so Ukrainian/Greek/etc.
        // filter text matches too.
        return haystack.down ().contains (needle.down ());
    }

    public Gee.ArrayList<IndexEntry> filtered_entries () {
            if (filter_text == "") {
                return entries;
            }
            var filtered = new Gee.ArrayList<IndexEntry> ();
            foreach (var entry in entries) {
                if (contains_ci (entry.name, filter_text)) {
                    filtered.add (entry);
                }
            }
            return filtered;
        }

        public void select_next () {
            var filtered = filtered_entries ();
            if (filtered.size > 0) {
                selected_index = (selected_index + 1) % filtered.size;
            }
        }

        public void select_prev () {
            var filtered = filtered_entries ();
            if (filtered.size > 0) {
                selected_index = (selected_index - 1 + filtered.size) % filtered.size;
            }
        }
    }
}