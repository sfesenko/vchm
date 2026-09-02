// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // Model for the HTML viewer
    public class ViewerModel : Object {
        public string current_url { get; set; }
        public string current_title { get; set; }
        public string current_chm_file { get; set; }
        public bool loading { get; set; }
        public string? error { get; set; }
        public int font_size { get; set; }
        public string font_family { get; set; }
        public string fixed_font_family { get; set; }
        
        // HTML content loaded from CHM
        public string? pending_html { get; set; }
        
        // The intended navigation URL (CHM path), used for history
        public string? intended_url { get; set; }
        
        // Find in page
        public string find_text { get; set; }
        public bool find_case_sensitive { get; set; }

        public ViewerModel () {
            current_url = "/";
            current_title = "";
            current_chm_file = "";
            loading = false;
            font_size = 12;
            font_family = "Sans";
            fixed_font_family = "Monospace";
            find_text = "";
            find_case_sensitive = false;
        }

        public void navigate (string url, string? title, string chm_file) {
            current_url = url;
            current_title = title ?? "";
            current_chm_file = chm_file;
            intended_url = url;
            loading = true;
            error = null;
            pending_html = null;
        }

        public void load_finished (bool success, string? error_msg = null) {
            loading = false;
            error = error_msg;
        }

        public void adjust_font_size (int size) {
            font_size = size.clamp (6, 72);
        }

        public void increase_font_size () {
            adjust_font_size (font_size + 1);
        }

        public void decrease_font_size () {
            adjust_font_size (font_size - 1);
        }

        public void reset_font_size () {
            adjust_font_size (12);
        }
    }
}