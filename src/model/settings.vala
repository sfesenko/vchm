// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using GLib;

namespace Vchm.Model {

    // Application settings persisted to GSettings
    public class SettingsModel : Object {
        private const string SCHEMA_ID = "org.gnome.vchm";
        private GLib.Settings _settings;
        private bool _schema_available = true;

        // Window state — S1: x/y dropped (GTK4 Wayland, compositor owned)
        public int window_width { get; set; }
        public int window_height { get; set; }
        public bool window_maximized { get; set; }

        // UI state
        public int sash_position { get; set; }
        public bool show_topics { get; set; }
        public bool show_index { get; set; }
        public bool show_search { get; set; }
        public bool show_bookmarks { get; set; }
        public int active_side_panel { get; set; } // 0=topics, 1=index, 2=search, 3=bookmarks

        // Viewer settings
        public int font_size { get; set; }
        public string font_family { get; set; }
        public string fixed_font_family { get; set; }

        // File history
        public string[] recent_files { get; set; }
        public string[] bookmark_rows { get; set; }
        public string[] per_book_rows { get; set; }
        public int per_book_expire_days { get; set; }
        public int bookmarks_expire_days { get; set; }

        // Last opened directory
        public string last_opened_dir { get; set; }

        public SettingsModel () {
            // Check if schema is available before creating Settings object
            // GLib.Settings constructor aborts if schema not found
            var source = SettingsSchemaSource.get_default ();
            if (source != null) {
                var schema = source.lookup (SCHEMA_ID, true);
                if (schema != null) {
                    _settings = new GLib.Settings (SCHEMA_ID);
                } else {
                    _schema_available = false;
                    stderr.printf ("Warning: GSettings schema '%s' not installed, using defaults\n", SCHEMA_ID);
                }
            } else {
                _schema_available = false;
                stderr.printf ("Warning: No GSettings schema source available\n");
            }
            load ();
        }

        public void load () {
            if (!_schema_available) {
                apply_defaults ();
                return;
            }
            
            // GSettings getters do not throw (schema ships defaults),
            // so no try/catch is needed here.
            window_width = _settings.get_int ("window-width");
                window_height = _settings.get_int ("window-height");
                window_maximized = _settings.get_boolean ("window-maximized");
                sash_position = _settings.get_int ("sash-position");
                show_topics = _settings.get_boolean ("show-topics");
                show_index = _settings.get_boolean ("show-index");
                show_search = _settings.get_boolean ("show-search");
                show_bookmarks = _settings.get_boolean ("show-bookmarks");
                active_side_panel = _settings.get_int ("active-side-panel");
                font_size = _settings.get_int ("font-size");
                font_family = _settings.get_string ("font-family");
                fixed_font_family = _settings.get_string ("fixed-font-family");
                recent_files = _settings.get_strv ("recent-files");
            bookmark_rows = _settings.get_strv ("bookmarks");
                per_book_rows = _settings.get_strv ("per-book-rows");
                // TTL keys ship a 180d schema default; direct read is enough.
                per_book_expire_days = _settings.get_int ("per-book-expire-days");
                bookmarks_expire_days = _settings.get_int ("bookmarks-expire-days");
                last_opened_dir = _settings.get_string ("last-opened-dir");
        }

        private void apply_defaults () {
            window_width = 1024;
            window_height = 768;
            window_maximized = false;
            sash_position = 250;
            show_topics = true;
            show_index = true;
            show_search = false;
            show_bookmarks = false;
            active_side_panel = 0;
            font_size = 12;
            font_family = "Sans";
            fixed_font_family = "Monospace";
            recent_files = new string[0];
            bookmark_rows = new string[0];
            per_book_rows = new string[0];
            per_book_expire_days = 180;
            bookmarks_expire_days = 180;
            last_opened_dir = "";
        }

        // Compact snapshot of every persisted value; used to avoid
        // rewriting GSettings when nothing actually changed.
        public string fingerprint () {
            var sb = new StringBuilder ();
            sb.append_printf ("%d;%d;%d;%d;", window_width, window_height,
                               window_maximized ? 1 : 0, sash_position);
            sb.append_printf ("%d;%d;%d;%d;%d;", show_topics ? 1 : 0, show_index ? 1 : 0,
                               show_search ? 1 : 0, show_bookmarks ? 1 : 0, active_side_panel);
            sb.append_printf ("%d;%s;%s;", font_size, font_family,
                               fixed_font_family);
            sb.append_printf ("%d;%d;", per_book_expire_days, bookmarks_expire_days);
            foreach (var f in recent_files) sb.append_printf ("%s,", f);
            sb.append ("|");
            foreach (var r in bookmark_rows) sb.append_printf ("%s,", r);
            sb.append ("|");
            foreach (var r in per_book_rows) sb.append_printf ("%s,", r);
            sb.append ("|");
            sb.append (last_opened_dir);   // lone dir change must persist too
            return sb.str;
        }

        public void save () {
            if (!_schema_available) return;
            
            // GSettings setters do not throw; no try/catch needed.
            _settings.set_int ("window-width", window_width);
                _settings.set_int ("window-height", window_height);
                _settings.set_boolean ("window-maximized", window_maximized);
                _settings.set_int ("sash-position", sash_position);
                _settings.set_boolean ("show-topics", show_topics);
                _settings.set_boolean ("show-index", show_index);
                _settings.set_boolean ("show-search", show_search);
                _settings.set_boolean ("show-bookmarks", show_bookmarks);
                _settings.set_int ("active-side-panel", active_side_panel);
                _settings.set_int ("font-size", font_size);
                _settings.set_string ("font-family", font_family);
                _settings.set_string ("fixed-font-family", fixed_font_family);
                _settings.set_int ("per-book-expire-days", per_book_expire_days);
                _settings.set_int ("bookmarks-expire-days", bookmarks_expire_days);
                _settings.set_strv ("recent-files", recent_files);
            _settings.set_strv ("bookmarks", bookmark_rows);
                _settings.set_strv ("per-book-rows", per_book_rows);
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