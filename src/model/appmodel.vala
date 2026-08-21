// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

namespace Vchm.Model {

    // Main application model containing all sub-models
    public class AppModel : Object {
        // Sub-models
        public CHMFile chm_file { get; private set; }
        public TopicsModel topics { get; private set; }
        public IndexModel index { get; private set; }
        public SearchModel search { get; private set; }
        public HistoryModel history { get; private set; }
        public ViewerModel viewer { get; private set; }
        public SettingsModel settings { get; private set; }

        // UI state
        public bool file_open { get; set; }
        public string status_text { get; set; }
        public string? toast_message { get; set; }

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

            // Apply saved viewer settings
            viewer.font_size = settings.font_size;
            viewer.font_family = settings.font_family;
            viewer.fixed_font_family = settings.fixed_font_family;
            viewer.show_images = settings.show_images;

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