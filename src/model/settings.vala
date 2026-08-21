// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // Application settings persisted to GSettings
    public class SettingsModel : Object {
        private const string SCHEMA_ID = "org.gnome.vchm";
        private GLib.Settings _settings;

        // Window state
        public int window_x { get; set; }
        public int window_y { get; set; }
        public int window_width { get; set; }
        public int window_height { get; set; }
        public bool window_maximized { get; set; }

        // UI state
        public int sash_position { get; set; }
        public bool show_topics { get; set; }
        public bool show_index { get; set; }
        public bool show_search { get; set; }
        public int active_side_panel { get; set; } // 0=topics, 1=index, 2=search

        // Viewer settings
        public int font_size { get; set; }
        public string font_family { get; set; }
        public string fixed_font_family { get; set; }
        public bool show_images { get; set; }

        // File history
        public string[] recent_files { get; set; }

        // Last opened directory
        public string last_opened_dir { get; set; }

        public SettingsModel () {
            _settings = new GLib.Settings (SCHEMA_ID);
            load ();
        }

        public void load () {
            window_x = _settings.get_int ("window-x");
            window_y = _settings.get_int ("window-y");
            window_width = _settings.get_int ("window-width");
            window_height = _settings.get_int ("window-height");
            window_maximized = _settings.get_boolean ("window-maximized");
            sash_position = _settings.get_int ("sash-position");
            show_topics = _settings.get_boolean ("show-topics");
            show_index = _settings.get_boolean ("show-index");
            show_search = _settings.get_boolean ("show-search");
            active_side_panel = _settings.get_int ("active-side-panel");
            font_size = _settings.get_int ("font-size");
            font_family = _settings.get_string ("font-family");
            fixed_font_family = _settings.get_string ("fixed-font-family");
            show_images = _settings.get_boolean ("show-images");
            recent_files = _settings.get_strv ("recent-files");
            last_opened_dir = _settings.get_string ("last-opened-dir");
        }

        public void save () {
            _settings.set_int ("window-x", window_x);
            _settings.set_int ("window-y", window_y);
            _settings.set_int ("window-width", window_width);
            _settings.set_int ("window-height", window_height);
            _settings.set_boolean ("window-maximized", window_maximized);
            _settings.set_int ("sash-position", sash_position);
            _settings.set_boolean ("show-topics", show_topics);
            _settings.set_boolean ("show-index", show_index);
            _settings.set_boolean ("show-search", show_search);
            _settings.set_int ("active-side-panel", active_side_panel);
            _settings.set_int ("font-size", font_size);
            _settings.set_string ("font-family", font_family);
            _settings.set_string ("fixed-font-family", fixed_font_family);
            _settings.set_boolean ("show-images", show_images);
            _settings.set_strv ("recent-files", recent_files);
            _settings.set_string ("last-opened-dir", last_opened_dir);
        }

        public void add_recent_file (string filepath) {
            var files = new Gee.ArrayList<string> ();
            foreach (var f in recent_files) {
                files.add (f);
            }
            // Remove all occurrences of filepath
            for (var i = files.size - 1; i >= 0; i--) {
                if (files[i] == filepath) {
                    files.remove_at (i);
                }
            }
            files.insert (0, filepath);
            while (files.size > 10) {
                files.remove_at (files.size - 1);
            }
            recent_files = files.to_array ();
        }
    }
}