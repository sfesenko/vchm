// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // History entry
    public class HistoryEntry : Object {
        public string title { get; set; }
        public string url { get; set; }
        public string chm_file { get; set; }
        public DateTime timestamp { get; set; }

        public HistoryEntry (string title, string url, string chm_file) {
            this.title = title;
            this.url = url;
            this.chm_file = chm_file;
            this.timestamp = new DateTime.now_local ();
        }
    }

    // Model for navigation history
    public class HistoryModel : Object {
        private const int MAX_HISTORY = 100;
        
        public Gee.ArrayList<HistoryEntry> entries { get; private set; }
        public int current_index { get; set; }

        public HistoryModel () {
            entries = new Gee.ArrayList<HistoryEntry> ();
            current_index = -1;
        }

        public bool can_go_back () {
            return current_index > 0;
        }

        public bool can_go_forward () {
            return current_index >= 0 && current_index < entries.size - 1;
        }

        public HistoryEntry? go_back () {
            if (can_go_back ()) {
                current_index--;
                return entries[current_index];
            }
            return null;
        }

        public HistoryEntry? go_forward () {
            if (can_go_forward ()) {
                current_index++;
                return entries[current_index];
            }
            return null;
        }

        public void add_entry (string title, string url, string chm_file) {
            // Truncate forward history
            while (entries.size > current_index + 1) {
                entries.remove_at (entries.size - 1);
            }
            
            var entry = new HistoryEntry (title, url, chm_file);
            entries.add (entry);
            current_index = entries.size - 1;
            
            // Limit history size
            while (entries.size > MAX_HISTORY) {
                entries.remove_at (0);
                current_index--;
            }
        }

        public void clear () {
            entries.clear ();
            current_index = -1;
        }
    }
}