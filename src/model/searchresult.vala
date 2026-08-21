// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // Search result entry - kept in core library as it has no GTK dependencies
    public class SearchResult : Object {
        public string title { get; set; }
        public string url { get; set; }
        public int rank { get; set; }

        public SearchResult (string title, string url, int rank = 0) {
            this.title = title;
            this.url = url;
            this.rank = rank;
        }
    }
}