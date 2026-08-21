// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;
using Vchm.View;
using GLib;

namespace Vchm {

    public class AppView : ApplicationWindow {
        public const string ACTION_PREFIX = "win.";
        public const string ACTION_QUIT = "quit";
        public const string ACTION_OPEN = "open";
        public const string ACTION_CLOSE = "close";
        public const string ACTION_BACK = "back";
        public const string ACTION_FORWARD = "forward";
        public const string ACTION_HOME = "home";
        public const string ACTION_FONT_INCREASE = "font_increase";
        public const string ACTION_FONT_DECREASE = "font_decrease";
        public const string ACTION_FONT_RESET = "font_reset";
        public const string ACTION_FIND = "find";
        public const string ACTION_TOGGLE_TOPICS = "toggle_topics";
        public const string ACTION_TOGGLE_INDEX = "toggle_index";
        public const string ACTION_TOGGLE_SEARCH = "toggle_search";
        public const string ACTION_ABOUT = "about";
        public const string ACTION_PREFERENCES = "preferences";

        private Elmish.Dispatch<AppMessage> dispatch;
        private Gtk.Application app;

        // Main layout
        private Paned main_paned;
        private Box sidebar_box;
        private Notebook sidebar_notebook;
        private ScrolledWindow viewer_scrolled;
        
        // Sub-views
        private TopicsView topics_view;
        private IndexView index_view;
        private SearchView search_view;
        private ViewerView viewer_view;
        private ToolbarView toolbar_view;
        private StatusBarView statusbar_view;

        // Find bar
        private Revealer find_revealer;
        private Entry find_entry;
        private Label find_count_label;

        public AppView (Gtk.Application app) {
            Object (application: app);
            this.app = app;
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;
            model.set_parent_dispatch (dispatch);

            setup_actions ();
            setup_window (model);
            setup_header_bar (model);
            setup_find_bar ();  // Must be called before setup_main_layout since find_revealer is used there
            setup_main_layout (model);
        }

        private void setup_actions () {
            ActionEntry[] action_entries = {
                { ACTION_QUIT, () => app.quit (), null, null },
                { ACTION_OPEN, () => on_open_file (), null, null },
                { ACTION_CLOSE, () => dispatch (new CloseFileMessage ()), null, null },
                { ACTION_BACK, () => dispatch (new GoBackMessage ()), null, null },
                { ACTION_FORWARD, () => dispatch (new GoForwardMessage ()), null, null },
                { ACTION_HOME, () => dispatch (new GoHomeMessage ()), null, null },
                { ACTION_FONT_INCREASE, () => dispatch (new ViewerFontIncreaseMessage ()), null, null },
                { ACTION_FONT_DECREASE, () => dispatch (new ViewerFontDecreaseMessage ()), null, null },
                { ACTION_FONT_RESET, () => dispatch (new ViewerFontResetMessage ()), null, null },
                { ACTION_FIND, () => toggle_find_bar (), null, null },
                { ACTION_TOGGLE_TOPICS, () => dispatch (new ToggleTopicsPanelMessage ()), null, null },
                { ACTION_TOGGLE_INDEX, () => dispatch (new ToggleIndexPanelMessage ()), null, null },
                { ACTION_TOGGLE_SEARCH, () => dispatch (new ToggleSearchPanelMessage ()), null, null },
                { ACTION_ABOUT, () => dispatch (new AboutDialogMessage ()), null, null },
                { ACTION_PREFERENCES, () => dispatch (new PreferencesDialogMessage ()), null, null },
            };
            add_action_entries (action_entries, this);

            application.set_accels_for_action (ACTION_PREFIX + ACTION_QUIT, {"<Control>q"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_OPEN, {"<Control>o"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_CLOSE, {"<Control>w"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_BACK, {"<Alt>Left"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FORWARD, {"<Alt>Right"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_HOME, {"<Alt>Home"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_INCREASE, {"<Control>plus", "<Control>equal"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_DECREASE, {"<Control>minus"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_RESET, {"<Control>0"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FIND, {"<Control>f"});
        }

        private void setup_window (AppModel model) {
            set_title ("vCHM");
            set_default_size (model.settings.window_width, model.settings.window_height);
            
            if (model.settings.window_x >= 0 && model.settings.window_y >= 0) {
                // In GTK4, use Gdk.Display to position window
                var display = Gdk.Display.get_default ();
                if (display != null) {
                    // We can't directly move in GTK4, but we can use default size/position
                    // For now, we'll just not move as GTK4 handles positioning differently
                }
            }
            
            if (model.settings.window_maximized) {
                maximize ();
            }

            close_request.connect (() => {
                app.quit ();
                return false;
            });
        }

        private void setup_header_bar (AppModel model) {
            var header = new HeaderBar () {
                show_title_buttons = true,
            };
            
            // Add menu button
            var menu_button = new MenuButton () {
                icon_name = "open-menu-symbolic",
                tooltip_text = _("Menu"),
                menu_model = create_app_menu (),
            };
            header.pack_end (menu_button);
            
            // Add toolbar as custom title widget (but it must be a direct child)
            // Actually, let's put toolbar in the header bar properly
            header.set_title_widget (toolbar_view);
            
            set_titlebar (header);
        }
        
        private GLib.Menu create_app_menu () {
            var menu = new GLib.Menu ();
            
            // File section
            var file_section = new GLib.Menu ();
            file_section.append (_("Open..."), "win.open");
            file_section.append (_("Close"), "win.close");
            file_section.append (_("Quit"), "win.quit");
            menu.append_section (_("File"), file_section);
            
            // View section
            var view_section = new GLib.Menu ();
            view_section.append (_("Contents"), "win.toggle_topics");
            view_section.append (_("Index"), "win.toggle_index");
            view_section.append (_("Search"), "win.toggle_search");
            view_section.append (_("Increase Font Size"), "win.font_increase");
            view_section.append (_("Decrease Font Size"), "win.font_decrease");
            view_section.append (_("Reset Font Size"), "win.font_reset");
            view_section.append (_("Find in Page..."), "win.find");
            menu.append_section (_("View"), view_section);
            
            // Help section
            var help_section = new GLib.Menu ();
            help_section.append (_("About"), "win.about");
            menu.append_section (_("Help"), help_section);
            
            return menu;
        }

private void setup_main_layout (AppModel model) {
            // Create sub-views
            toolbar_view = new ToolbarView ();
            toolbar_view.build_ui (dispatch, model);
            
            topics_view = new TopicsView ();
            topics_view.build_ui (dispatch, model);
            
            index_view = new IndexView ();
            index_view.build_ui (dispatch, model);
            
            search_view = new SearchView ();
            search_view.build_ui (dispatch, model);
            
            viewer_view = new ViewerView ();
            viewer_view.build_ui (dispatch, model);
            
            statusbar_view = new StatusBarView ();
            statusbar_view.build_ui (dispatch, model);

            // Setup header bar after toolbar is created
            setup_header_bar (model);

            // Sidebar notebook with tabs
            sidebar_notebook = new Notebook ();
            sidebar_notebook.append_page (topics_view, new Label (_("Contents")));
            sidebar_notebook.append_page (index_view, new Label (_("Index")));
            sidebar_notebook.append_page (search_view, new Label (_("Search")));
            sidebar_notebook.set_show_tabs (true);
            sidebar_notebook.set_show_border (false);

            sidebar_box = new Box (Orientation.VERTICAL, 0);
            sidebar_box.append (sidebar_notebook);

            // Viewer area
            viewer_scrolled = new ScrolledWindow () {
                hexpand = true,
                vexpand = true,
                child = viewer_view
            };

            // Main paned
            main_paned = new Paned (Orientation.HORIZONTAL) {
                start_child = sidebar_box,
                end_child = viewer_scrolled,
                position = model.settings.sash_position,
                wide_handle = true
            };
            main_paned.set_shrink_start_child (false);
            main_paned.set_shrink_end_child (false);

            // Connect paned position change
            main_paned.notify["position"].connect (() => {
                dispatch (new SetSashPositionMessage (main_paned.position));
            });

            // Connect sidebar page change
            sidebar_notebook.notify["page"].connect (() => {
                dispatch (new SetActiveSidePanelMessage (sidebar_notebook.page));
            });

            // Main content box
            var content_box = new Box (Orientation.VERTICAL, 0);
            content_box.append (main_paned);
            content_box.append (find_revealer);
            content_box.append (statusbar_view);

            set_child (content_box);
        }

        private void setup_find_bar () {
            var find_box = new Box (Orientation.HORIZONTAL, 6) {
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 12,
                margin_end = 12
            };
            
            find_revealer = new Revealer () {
                transition_type = RevealerTransitionType.SLIDE_DOWN,
                reveal_child = false,
                child = find_box
            };
            
            var find_label = new Label (_("Find:")) { use_markup = true };
            find_entry = new Entry () {
                hexpand = true,
                placeholder_text = _("Search in page...")
            };
            find_count_label = new Label ("");
            var prev_btn = new Button.from_icon_name ("go-previous-symbolic") {
                tooltip_text = _("Previous")
            };
            prev_btn.clicked.connect (() => dispatch (new ViewerFindPrevMessage ()));
            var next_btn = new Button.from_icon_name ("go-next-symbolic") {
                tooltip_text = _("Next")
            };
            next_btn.clicked.connect (() => dispatch (new ViewerFindNextMessage ()));
            var close_btn = new Button.from_icon_name ("window-close-symbolic") {
                tooltip_text = _("Close")
            };
            close_btn.clicked.connect (() => toggle_find_bar ());
            
            find_box.append (find_label);
            find_box.append (find_entry);
            find_box.append (find_count_label);
            find_box.append (prev_btn);
            find_box.append (next_btn);
            find_box.append (close_btn);

            find_entry.activate.connect (() => {
                var text = find_entry.text;
                if (text != "") {
                    dispatch (new ViewerFindMessage (text));
                }
            });

            find_entry.changed.connect (() => {
                var text = find_entry.text;
                if (text != "") {
                    dispatch (new ViewerFindMessage (text));
                }
            });
        }

        private void toggle_find_bar () {
            find_revealer.reveal_child = !find_revealer.reveal_child;
            if (find_revealer.reveal_child) {
                find_entry.grab_focus ();
            }
        }

        private void on_open_file () {
            var dialog = new FileDialog () {
                title = _("Open CHM File"),
                initial_name = ""
            };
            var filter = new FileFilter () { name = _("CHM Files") };
            filter.add_pattern ("*.chm");
            filter.add_pattern ("*.CHM");
            dialog.default_filter = filter;
            
            dialog.open.begin (this, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    dispatch (new OpenFileMessage (file.get_path ()));
                } catch (GLib.Error e) {
                    if (!(e is GLib.IOError.CANCELLED)) {
                        warning ("Open dialog: %s", e.message);
                    }
                }
            });
        }

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE: {
                    var done_msg = (OpenFileDoneMessage) msg;
                    set_title ("vCHM - %s".printf (done_msg.title));
                    break;
                }

                case AppMessageKind.OPEN_FILE_FAILED: {
                    // Error handled by toast
                    break;
                }

                case AppMessageKind.CLOSE_FILE: {
                    set_title ("vCHM");
                    break;
                }

                case AppMessageKind.NAVIGATE_DONE: {
                    var done_msg = (NavigateDoneMessage) msg;
                    set_title ("vCHM - %s".printf (done_msg.title));
                    break;
                }

                case AppMessageKind.TOGGLE_TOPICS_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
                    break;
                }

                case AppMessageKind.TOGGLE_INDEX_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
                    break;
                }

                case AppMessageKind.TOGGLE_SEARCH_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
                    break;
                }

                case AppMessageKind.SET_ACTIVE_SIDE_PANEL: {
                    sidebar_notebook.page = model.settings.active_side_panel;
                    break;
                }

                case AppMessageKind.SET_SASH_POSITION: {
                    main_paned.position = model.settings.sash_position;
                    break;
                }

                case AppMessageKind.SHOW_TOAST: {
                    var toast_msg = (ShowToastMessage) msg;
                    statusbar_view.show_toast (toast_msg.message);
                    break;
                }

                case AppMessageKind.WINDOW_STATE_CHANGED: {
                    // Handled by model
                    break;
                }

                case AppMessageKind.WINDOW_MAXIMIZED_CHANGED: {
                    if (model.settings.window_maximized) {
                        maximize ();
                    } else {
                        unmaximize ();
                    }
                    break;
                }

                case AppMessageKind.APP_QUIT: {
                    destroy ();
                    break;
                }

                default:
                    break;
            }

            // Forward to sub-views
            topics_view.update (msg, model);
            index_view.update (msg, model);
            search_view.update (msg, model);
            viewer_view.update (msg, model);
            toolbar_view.update (msg, model);
            statusbar_view.update (msg, model);
        }
    }
}