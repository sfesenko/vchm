// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
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
        public Gtk.ListStore? list_store { get; private set; }

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
            
Object model;
            if (chm_file.load_index (out model)) {
                list_store = model as Gtk.ListStore;
                
                if (list_store != null) {
                    // Convert ListStore to entries for compatibility
                    TreeIter iter = TreeIter();
                    if (list_store.get_iter_first (out iter)) {
                        do {
                            GLib.Value name_val = new GLib.Value (typeof(string));
                            GLib.Value url_val = new GLib.Value (typeof(string));
                            GLib.Value keyword_val = new GLib.Value (typeof(string));
                            list_store.get_value (iter, 0, out name_val);
                            list_store.get_value (iter, 1, out url_val);
                            list_store.get_value (iter, 2, out keyword_val);
                            string name = name_val.get_string ();
                            string url = url_val.get_string ();
                            string keyword = keyword_val.get_string ();
                            entries.add (new IndexEntry (name, url, keyword));
                        } while (list_store.iter_next (ref iter));
                    }
                }
            }
            
            loading = false;
        }

        // Helper function for case-insensitive string comparison (ASCII only)
    private static bool contains_ci (string haystack, string needle) {
        // Simple ASCII case-insensitive comparison
        var h = ascii_lower (haystack);
        var n = ascii_lower (needle);
        return h.contains (n);
    }

    private static string ascii_lower (string s) {
        var sb = new StringBuilder ();
        for (int i = 0; i < s.length; i++) {
            unichar c = s[i];
            if (c >= 'A' && c <= 'Z') {
                sb.append_c ((char)(c + 32));
            } else {
                sb.append_c ((char)c);
            }
        }
        return sb.str;
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