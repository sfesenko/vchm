// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using GLib;
using Gee;

namespace Vchm.Model {

    // Model for the search panel
    public class SearchModel : Object {
        public Gee.ArrayList<SearchResult> results { get; public set; }
        public string query { get; set; }
        public bool whole_words { get; set; }
        public bool titles_only { get; set; }
        public int selected_index { get; set; }
        public bool searching { get; set; }
        public string? error { get; set; }

        public SearchModel () {
            results = new Gee.ArrayList<SearchResult> ();
            query = "";
            whole_words = false;
            titles_only = false;
            selected_index = -1;
            searching = false;
        }

        public void clear () {
            results.clear ();
            query = "";
            selected_index = -1;
            error = null;
        }

        public void search (CHMFile chm_file) {
            if (query == "") return;
            clear ();
            searching = true;
            error = null;

            Gee.ArrayList<SearchResult> raw_results;
            chm_file.search (query, whole_words, titles_only, out raw_results);
            results = raw_results;
            if (results.size > 0) {
                selected_index = 0;
            }

            searching = false;
        }
    }
}