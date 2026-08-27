// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

namespace Vchm.Model {

    // Main application model containing all sub-models
    // One opened archive with everything derived from it. Lives at
    // namespace scope so messages can carry it between worker and UI.
    public class BookContext : Object {
        public CHMFile chm_file = new CHMFile ();
        public TopicsModel topics = new TopicsModel ();
        public IndexModel index = new IndexModel ();
        public HistoryModel history = new HistoryModel ();
        public string title = "";
        public string home = "/";
    }

    public class AppModel : Object {
        // Sub-models
        public CHMFile chm_file { get; set; }
        public TopicsModel topics { get; set; }
        public IndexModel index { get; set; }
        public SearchModel search { get; private set; }
        public HistoryModel history { get; set; } // pointer-swapped on tab switch
        public ViewerModel viewer { get; private set; }
        public SettingsModel settings { get; private set; }
        public BookmarkStore bookmarks { get; private set; }

        // All opened books; [0] mirrors the "active" pointers below.
        public Gee.ArrayList<BookContext> books =
            new Gee.ArrayList<BookContext> ();
        public BookContext? active_book { get; set; }

    // BookContext lives inside AppModel scope for message carrying.

        // UI state
        public bool file_open { get; set; }
        public string status_text { get; set; }
        public string? toast_message { get; set; }

        // Set while a back/forward navigation is in flight so NAVIGATE_DONE
        // does not push a duplicate entry and truncate forward history.
        public bool history_navigation_in_progress { get; set; }

        // The app's dispatch, injected by main after program construction
        private Elmish.Dispatch<AppMessage> parent_dispatch = AppModel.noop_dispatch;
        public static void noop_dispatch (AppMessage msg) {
        }

        public void set_parent_dispatch (Elmish.Dispatch<AppMessage> dispatch) {
            parent_dispatch = dispatch;
        }

        public Elmish.Dispatch<AppMessage> get_parent_dispatch () {
            return parent_dispatch;
        }

        public AppModel () {
            chm_file = new CHMFile ();
            topics = new TopicsModel ();
            index = new IndexModel ();
            search = new SearchModel ();
            history = new HistoryModel ();
            viewer = new ViewerModel ();
            settings = new SettingsModel ();
            bookmarks = new BookmarkStore ();
            bookmarks.load (settings.bookmark_rows);

            // Apply saved viewer settings
            viewer.font_size = settings.font_size;
            viewer.font_family = settings.font_family;
            viewer.fixed_font_family = settings.fixed_font_family;

            file_open = false;
            status_text = "Ready";
        }

        // Method-bound mapper for Cmd.map
        public AppMessage to_app_message (AppMessage msg) {
            return msg;
        }

        public void show_toast (string message) {
            parent_dispatch (new ShowToastMessage (message));
        }
    }
}