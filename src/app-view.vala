// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;
using Vchm.View;
using GLib;

namespace Vchm {

    // One document tab: its own WebView + history; the shared archive
    // model supplies content for whichever tab is active.
    // One document tab: its own WebView + per-tab sub-models. The shared
    // archive registry (CHMFile.by_path) lets every tab serve from its
    // own archive; everything else (history, viewer, search) is per-tab
    // so the F26 race on the shared model.viewer slot is gone.
    public class DocumentTab : Object {
        public Vchm.View.ViewerView view;
        public ViewerModel viewer = new ViewerModel ();
        public HistoryModel? history = null;   // bound when a book attaches
        public string book_path = "";          // "" = placeholder, no book yet
        public string url = "/";
        public string title = _("New page");
        public Gtk.Label title_label;

        public DocumentTab () {
            view = new Vchm.View.ViewerView ();
            title_label = new Gtk.Label (title);
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.width_chars = 12;
        }
    }

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
    public const string ACTION_PRINT = "print";
    public const string ACTION_FULLSCREEN = "fullscreen";
    public const string ACTION_ADD_BOOKMARK = "add-bookmark";
    public const string ACTION_SET_ENCODING = "set-encoding";
        public const string ACTION_TOGGLE_TOPICS = "toggle_topics";
        public const string ACTION_TOGGLE_INDEX = "toggle_index";
        public const string ACTION_TOGGLE_SEARCH = "toggle_search";
        public const string ACTION_TOGGLE_BOOKMARKS = "toggle_bookmarks";
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
        private Gee.ArrayList<DocumentTab> tabs = new Gee.ArrayList<DocumentTab> ();
        private int active_tab = -1;
        private Gtk.Notebook viewer_notebook;

        public ViewerView viewer_view {
            get {
                assert (active_tab >= 0 && active_tab < tabs.size);
                return tabs[active_tab].view;
            }
        }
        // Per-tab ViewerModel: the active tab owns its own viewer state,
        // so two tabs can have different current_url/loading/intended_url
        // without a shared-slot race. The update function's
        // `model.viewer` reads come through this property in the view
        // code; the update function in app-update.vala still uses
        // model.viewer (the shared slot) for backward compatibility.
        public ViewerModel? active_viewer {
            get {
                if (active_tab < 0 || active_tab >= tabs.size) return null;
                return tabs[active_tab].viewer;
            }
        }
        private ToolbarView toolbar_view;
        private StatusBarView statusbar_view;
        private BookmarksView bookmarks_view;

        // Stateful panel-toggle actions (checked = panel visible+active);
        // kept as members so the shell can re-sync their state whenever
        // the active panel changes from any path.
        private GLib.SimpleAction act_topics;
        private GLib.SimpleAction act_index;
        private GLib.SimpleAction act_search;
        private GLib.SimpleAction act_bookmarks;

        // Guards against notify->dispatch->set->notify feedback loops.
        private bool sash_updating = false;

        // Recent files menus (header popover + File submenu)
        private Gtk.MenuButton header_recent_button;
        private GLib.Menu header_recent_menu;
        private GLib.Menu file_recent_submenu;

        // Find bar
        private Revealer find_revealer;
        private Entry find_entry;
        private Label find_count_label;

        public AppView (Gtk.Application app) {
            Object (application: app);
            this.app = app;
        }

        private AppModel? held_model;

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;
            held_model = model;
            model.set_parent_dispatch (dispatch);

            setup_actions ();
            setup_window (model);
            // Header bar is set up inside setup_main_layout, after the
            // toolbar view exists (it is embedded as the title widget).
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
                { ACTION_FULLSCREEN, () => toggle_fullscreen (), null, null },
                { ACTION_ADD_BOOKMARK, () => dispatch (new BookmarkAddMessage ()), null, null },
                { ACTION_PRINT, () => viewer_view.print_page (), null, null },
                // (panel toggles registered as stateful actions below)
                { ACTION_ABOUT, () => dispatch (new AboutDialogMessage ()), null, null },
                { ACTION_PREFERENCES, () => dispatch (new PreferencesDialogMessage ()), null, null },
            };
            add_action_entries (action_entries, this);

            // Stateful panel toggles: menu check-marks and toolbar
            // ToggleButtons stay in sync through the action state.
            // Use change_state (not activate) so the action's new state is
            // authoritative; view sync is deferred to updateView (Idle) where
            // model.settings.* already reflects the toggled value. The old
            // post-dispatch sync_panel_actions read stale model via Elmish
            // coalescing and left the button stuck.
            act_topics = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_TOPICS, null, new Variant.boolean (held_model != null ? held_model.settings.show_topics : true));
            act_topics.change_state.connect ((value) => {
                act_topics.set_state (value);
                dispatch (new ToggleTopicsPanelMessage ());
            });
            act_topics.activate.connect (() => {
                // Toggle via activate (e.g. toolbar ToggleButton) — flip state then change_state path
                var cur = act_topics.get_state ().get_boolean ();
                act_topics.change_state (new Variant.boolean (!cur));
            });
            add_action (act_topics);

            act_index = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_INDEX, null, new Variant.boolean (held_model != null ? held_model.settings.show_index : true));
            act_index.change_state.connect ((value) => {
                act_index.set_state (value);
                dispatch (new ToggleIndexPanelMessage ());
            });
            act_index.activate.connect (() => {
                var cur = act_index.get_state ().get_boolean ();
                act_index.change_state (new Variant.boolean (!cur));
            });
            add_action (act_index);

            act_search = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_SEARCH, null, new Variant.boolean (held_model != null ? held_model.settings.show_search : false));
            act_search.change_state.connect ((value) => {
                act_search.set_state (value);
                dispatch (new ToggleSearchPanelMessage ());
            });
            act_search.activate.connect (() => {
                var cur = act_search.get_state ().get_boolean ();
                act_search.change_state (new Variant.boolean (!cur));
            });
            add_action (act_search);

            // Bookmarks panel toggle — sidebar page 3
            bool show_bookmarks_init = false;
            if (held_model != null) {
                show_bookmarks_init = held_model.settings.show_bookmarks &&
                    held_model.settings.active_side_panel == 3;
            }
            act_bookmarks = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_BOOKMARKS, null, new Variant.boolean (show_bookmarks_init));
            act_bookmarks.change_state.connect ((value) => {
                act_bookmarks.set_state (value);
                dispatch (new ToggleBookmarksPanelMessage ());
            });
            act_bookmarks.activate.connect (() => {
                var cur = act_bookmarks.get_state ().get_boolean ();
                act_bookmarks.change_state (new Variant.boolean (!cur));
            });
            add_action (act_bookmarks);

            var open_recent = new GLib.SimpleAction ("open-recent", GLib.VariantType.STRING);
            open_recent.activate.connect ((parameter) => {
                if (parameter != null) open_file_or_activate (parameter.get_string ());
            });
            add_action (open_recent);

            var set_encoding = new GLib.SimpleAction.stateful (
                ACTION_SET_ENCODING, GLib.VariantType.STRING, "auto");
            set_encoding.activate.connect ((parameter) => {
                if (parameter != null)
                    dispatch (new SetEncodingMessage (parameter.get_string ()));
            });
            add_action (set_encoding);

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
            application.set_accels_for_action (ACTION_PREFIX + ACTION_PRINT, {"<Control>p"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FULLSCREEN, {"F11", "F11"});
            application.set_accels_for_action (ACTION_PREFIX + "set-encoding", {});
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

            // Persist user-driven resizes/maximize. Nothing dispatched
            // WINDOW_STATE_CHANGED before, so the handler in the update
            // function was dead code and every session restored the
            // first-ever size (review F4).
            notify["default-width"].connect (() => save_geometry (model));
            notify["default-height"].connect (() => save_geometry (model));
            notify["maximized"].connect (() => {
                dispatch (new WindowMaximizedChangedMessage (maximized));
            });

            setup_drag_drop ();

            close_request.connect (() => {
                // M1: flush per-book scroll for the active book before quit
                if (active_tab >= 0 && active_tab < tabs.size) {
                    tabs[active_tab].view.save_scroll (held_model ?? model);
                }
                // Flush geometry so a quit right after a resize still
                // restores the final size.
                save_geometry (model);
                model.settings.save ();
                app.quit ();
                return false;
            });
        }

        private void save_geometry (AppModel model) {
            // While maximized/fullscreened default_width/height reflect the
            // maximized size; storing them would blow up the restored
            // window. Maximized state itself rides in its own setting.
            if (!visible || maximized || fullscreened) return;
            dispatch (new WindowStateChangedMessage (
                model.settings.window_x, model.settings.window_y,
                default_width, default_height));
        }

        private void setup_header_bar (AppModel model) {
            var header = new HeaderBar () {
                show_title_buttons = true,
            };
            
            // Recent files popover button (header, quick access)
            header_recent_menu = new GLib.Menu ();
            rebuild_header_recent_menu (model);
            header_recent_button = new Gtk.MenuButton () {
                icon_name = "document-open-recent-symbolic",
                tooltip_text = _("Recent files"),
                menu_model = header_recent_menu,
            };
            header.pack_start (header_recent_button);

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

        private void rebuild_header_recent_menu (AppModel model) {
            header_recent_menu.remove_all ();
            if (model.settings.recent_files.length == 0) {
                header_recent_menu.append (_("No recent files"), null);
                return;
            }
            foreach (var f in model.settings.recent_files) {
                string base_name = GLib.Path.get_basename (f);
                var item = new GLib.MenuItem (base_name, null);
                item.set_action_and_target_value ("win.open-recent", new GLib.Variant.string (f));
                header_recent_menu.append_item (item);
            }
        }

        private void rebuild_file_recent_menu () {
            if (file_recent_submenu == null) return;
            file_recent_submenu.remove_all ();
            if (held_model == null || held_model.settings.recent_files.length == 0) {
                file_recent_submenu.append (_("No recent files"), null);
                return;
            }
            foreach (var f in held_model.settings.recent_files) {
                string base_name = GLib.Path.get_basename (f);
                var item = new GLib.MenuItem (base_name, null);
                item.set_action_and_target_value ("win.open-recent", new GLib.Variant.string (f));
                file_recent_submenu.append_item (item);
            }
        }

        private void refresh_recent_menus () {
            if (held_model == null) return;
            rebuild_header_recent_menu (held_model);
            rebuild_file_recent_menu ();
        }
        
        private GLib.Menu create_app_menu () {
            var menu = new GLib.Menu ();
            
            // File section
            var file_section = new GLib.Menu ();
            file_section.append (_("Open..."), "win.open");
            // Recent files submenu (File → Recent Files)
            file_recent_submenu = new GLib.Menu ();
            rebuild_file_recent_menu ();
            file_section.append_submenu (_("Recent Files"), file_recent_submenu);
            file_section.append (_("Print..."), "win.print");
            file_section.append (_("Close"), "win.close");
            file_section.append (_("Quit"), "win.quit");
            menu.append_section (_("File"), file_section);
            
            // View section
            var view_section = new GLib.Menu ();
            view_section.append (_("Contents"), "win.toggle_topics");
            view_section.append (_("Index"), "win.toggle_index");
            view_section.append (_("Search"), "win.toggle_search");
            view_section.append (_("Bookmarks"), "win.toggle_bookmarks");
            view_section.append (_("Increase Font Size"), "win.font_increase");
            view_section.append (_("Decrease Font Size"), "win.font_decrease");
            view_section.append (_("Reset Font Size"), "win.font_reset");
            view_section.append (_("Find in Page..."), "win.find");
            view_section.append (_("Fullscreen"), "win.fullscreen");

            var enc_section = new GLib.Menu ();
            enc_section.append (_("Automatic"), "win.set-encoding::auto");
            foreach (var enc in new string[] { "UTF-8", "CP1251", "KOI8-U", "KOI8-R", "CP866",
                                               "CP1250", "CP1252", "CP1253", "CP1254",
                                               "CP1255", "CP1256", "CP1257", "CP1258" }) {
                enc_section.append (enc, "win.set-encoding::" + enc);
            }
            view_section.append_submenu (_("Encoding"), enc_section);

            // Bookmarks actions live in the File menu.
            file_section.append (_("Add Bookmark"), "win.add-bookmark");
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

            bookmarks_view = new BookmarksView ();
            bookmarks_view.build_ui (dispatch, model);
            
            viewer_notebook = new Gtk.Notebook () {
                hexpand = true,
                vexpand = true,
                show_border = false
            };
            create_tab (model);
            viewer_notebook.switch_page.connect ((page, num) => {
                if ((int) num != active_tab) activate_tab ((int) num);
            });
            viewer_notebook.page_reordered.connect ((page, page_num) => {
                DocumentTab? moved = null;
                foreach (var t in tabs) {
                    if (t.view == page) { moved = t; break; }
                }
                if (moved == null) return;
                int from = tabs.index_of (moved);
                if (from == (int) page_num) return;

                DocumentTab? was_active = null;
                if (active_tab >= 0 && active_tab < tabs.size)
                    was_active = tabs[active_tab];

                tabs.remove_at (from);
                tabs.insert ((int) page_num, moved);
                // Keep model.books in sync with visual tabs so
                // tab_index == book_index (strict single-tab-per-file).
                // Placeholder tabs (book_path=="") have no BookContext.
                if (held_model != null && held_model.books.size == tabs.size) {
                    // Only when every tab is bound (no placeholder) we can
                    // mirror exactly; otherwise rebuild books order from tabs.
                    var reordered = new Gee.ArrayList<BookContext> ();
                    foreach (var t in tabs) {
                        if (t.book_path == "") continue;
                        var bk = CHMFile.by_path (t.book_path);
                        foreach (var b in held_model.books) {
                            if (b.chm_file == bk) { reordered.add (b); break; }
                        }
                    }
                    // If we matched all books, replace order
                    if (reordered.size == held_model.books.size) {
                        held_model.books.clear ();
                        foreach (var b in reordered) held_model.books.add (b);
                    }
                } else if (held_model != null) {
                    // Fallback: reorder by correlating moved tab's book
                    // when books/tabs differ by placeholder.
                    string moved_path = moved.book_path;
                    if (moved_path != "") {
                        BookContext? moved_ctx = null;
                        int from_b = -1;
                        for (int i = 0; i < held_model.books.size; i++) {
                            if (held_model.books[i].chm_file.filename () == moved_path) {
                                moved_ctx = held_model.books[i]; from_b = i; break;
                            }
                        }
                        if (moved_ctx != null && from_b >= 0) {
                            held_model.books.remove_at (from_b);
                            // Compute insertion index: count bound tabs before page_num
                            int to_b = 0;
                            for (int i = 0; i < (int) page_num; i++) {
                                if (tabs[i].book_path != "") to_b++;
                            }
                            // also handle moving forward vs backward
                            if (to_b > held_model.books.size) to_b = held_model.books.size;
                            held_model.books.insert (to_b, moved_ctx);
                        }
                    }
                }

                if (was_active != null)
                    active_tab = tabs.index_of (was_active);
                // Update model's active_tab_index to track visual reorder
                if (held_model != null) held_model.active_tab_index = active_tab;
            });
            
            statusbar_view = new StatusBarView ();
            statusbar_view.build_ui (dispatch, model);

            // Setup header bar after toolbar is created
            setup_header_bar (model);

            // Sidebar notebook with tabs
            sidebar_notebook = new Notebook ();
            sidebar_notebook.append_page (topics_view, new Label (_("Contents")));
            sidebar_notebook.append_page (index_view, new Label (_("Index")));
            sidebar_notebook.append_page (search_view, new Label (_("Search")));
            sidebar_notebook.append_page (bookmarks_view, new Label (_("Bookmarks")));
            sidebar_notebook.set_show_tabs (true);
            sidebar_notebook.set_show_border (false);

            sidebar_box = new Box (Orientation.VERTICAL, 0);
            sidebar_box.append (sidebar_notebook);
            // Apply restored panel visibility here — only toggle messages
            // touched it before, so the first session after enabling a
            // saved-off panel still showed it (review F18).
            sidebar_box.visible = model.settings.show_topics ||
                                  model.settings.show_index ||
                                  model.settings.show_search ||
                                  model.settings.show_bookmarks;
            sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);

            // Viewer area
            var viewer_scrolled = new Gtk.ScrolledWindow () {
                hexpand = true,
                vexpand = true,
                child = viewer_notebook
            };

            // Main paned
            sash_updating = true;
            main_paned = new Paned (Orientation.HORIZONTAL) {
                start_child = sidebar_box,
                end_child = viewer_scrolled,
                position = model.settings.sash_position,
                wide_handle = true
            };
            sash_updating = false;
            main_paned.set_shrink_start_child (false);
            main_paned.set_shrink_end_child (false);

            // Persist user-driven drags only; programmatic sets are guarded.
            main_paned.notify["position"].connect (() => {
                if (sash_updating) return;
                sash_updating = true;
                dispatch (new SetSashPositionMessage (main_paned.position));
                sash_updating = false;
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
            var find_case_check = new CheckButton () {
                label = _("Match case"),
                tooltip_text = _("Case sensitive search")
            };
            find_case_check.toggled.connect (() => {
                if (find_entry.text != "")
                    dispatch (new ViewerFindMessage (find_entry.text, find_case_check.active));
            });
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
            find_box.append (find_case_check);
            find_box.append (find_count_label);
            find_box.append (prev_btn);
            find_box.append (next_btn);
            find_box.append (close_btn);

            find_entry.activate.connect (() => {
                dispatch (new ViewerFindMessage (find_entry.text, find_case_check.active));
            });

            find_entry.changed.connect (() => {
                dispatch (new ViewerFindMessage (find_entry.text, find_case_check.active));
            });

            // Escape closes the bar and clears highlights.
            var esc = new EventControllerKey ();
            find_entry.add_controller (esc);
            esc.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape) {
                    toggle_find_bar ();
                    return true;
                }
                return false;
            });
        }

        private void setup_drag_drop () {
            var target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            target.drop.connect ((value, x, y) => {
                var list = value as Gdk.FileList;
                if (list == null) return false;

                GLib.File? chosen = null;
                foreach (unowned GLib.File f in list.get_files ()) {
                    var p = f.get_path ();
                    if (p == null) continue;
                    var low = p.down ();
                    if (low.has_suffix (".chm") || low.has_suffix (".chi") ||
                        low.has_suffix (".chw")) {
                        chosen = f;
                        break;
                    }
                    if (chosen == null) chosen = f;   // keep first as fallback
                }
                if (chosen == null || chosen.get_path () == null) return false;
                open_file_or_activate (chosen.get_path ());
                return true;
            });
            // Window implements ShortcutManager; route to Widget API.
            ((Gtk.Widget) this).add_controller (target);
        }

        private void show_about () {
            var about = new Gtk.AboutDialog () {
                program_name = "vCHM",
                version = VERSION,
                title = _("About vCHM"),
                comments = _("A CHM file viewer"),
                website = "***REMOVED***
                website_label = _("Project website"),
                license_type = Gtk.License.MIT_X11,
                transient_for = this,
                modal = true,
                logo_icon_name = "help-contents"
            };
            // GTK4 windows are only hidden on close: without an explicit
            // destroy every invocation leaked the dialog (review F21).
            about.close_request.connect (() => {
                about.destroy ();
                return false;
            });
            about.present ();
        }

        private void show_preferences (AppModel model) {
            var dialog = new Gtk.Dialog.with_buttons (
                _("Preferences"), this, Gtk.DialogFlags.MODAL,
                _("Close"), Gtk.ResponseType.CLOSE);
            dialog.set_default_size (420, 200);

            var content = (Gtk.Box) dialog.get_content_area ();
            var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
                margin_top = 12, margin_bottom = 12,
                margin_start = 12, margin_end = 12
            };

            var info = new Gtk.Label (
                _("Images are always loaded from the opened book. Remote content is blocked."));
            info.wrap = true;
            info.xalign = 0;
            vbox.append (info);

            // Proportional font picker (family + size) — GTK4 FontDialogButton
            var prop_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            prop_row.append (new Gtk.Label (_("Proportional font:")) { xalign = 0, hexpand = true });
            var prop_dialog = new Gtk.FontDialog ();
            var prop_btn = new Gtk.FontDialogButton (prop_dialog);
            prop_btn.tooltip_text = _("Choose proportional font");
            var prop_desc = Pango.FontDescription.from_string ("%s %d".printf (model.viewer.font_family, model.viewer.font_size));
            prop_btn.set_font_desc (prop_desc);
            prop_btn.notify["font-desc"].connect (() => {
                var desc = prop_btn.get_font_desc ();
                if (desc == null) return;
                string fam = desc.get_family () ?? model.viewer.font_family;
                int sz = desc.get_size () / Pango.SCALE;
                if (sz == 0) sz = model.viewer.font_size;
                if (sz < 6) sz = 6;
                if (sz > 72) sz = 72;
                dispatch (new ViewerFontChangedMessage (sz, fam, model.viewer.fixed_font_family));
            });
            prop_row.append (prop_btn);
            vbox.append (prop_row);

            // Fixed font picker
            var fixed_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            fixed_row.append (new Gtk.Label (_("Fixed font:")) { xalign = 0, hexpand = true });
            var fixed_dialog = new Gtk.FontDialog ();
            var fixed_btn = new Gtk.FontDialogButton (fixed_dialog);
            fixed_btn.tooltip_text = _("Choose fixed-width font");
            var fixed_desc = Pango.FontDescription.from_string ("%s %d".printf (model.viewer.fixed_font_family, model.viewer.font_size));
            fixed_btn.set_font_desc (fixed_desc);
            fixed_btn.notify["font-desc"].connect (() => {
                var desc = fixed_btn.get_font_desc ();
                if (desc == null) return;
                string fam = desc.get_family () ?? model.viewer.fixed_font_family;
                int sz = desc.get_size () / Pango.SCALE;
                if (sz == 0) sz = model.viewer.font_size;
                if (sz < 6) sz = 6;
                if (sz > 72) sz = 72;
                dispatch (new ViewerFontChangedMessage (sz, model.viewer.font_family, fam));
            });
            fixed_row.append (fixed_btn);
            vbox.append (fixed_row);

            content.append (vbox);

            dialog.response.connect ((rid) => {
                if (rid == Gtk.ResponseType.CLOSE || rid == Gtk.ResponseType.DELETE_EVENT) {
                    dialog.destroy ();
                }
            });

            dialog.present ();
        }

        // ── Tab lifecycle (U3) ──────────────────────────────────────────

        private DocumentTab create_tab (AppModel model) {
            var tab = new DocumentTab ();
            tab.view.build_ui (dispatch, model);

            var close_btn = new Gtk.Button.from_icon_name ("window-close-symbolic");
            close_btn.add_css_class ("flat");
            close_btn.tooltip_text = _("Close tab");
            close_btn.clicked.connect (() => close_tab (tab));

            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
            box.append (tab.title_label);
            box.append (close_btn);
            box.show ();

            tabs.add (tab);
            int idx = tabs.size - 1;
            viewer_notebook.append_page (tab.view, box);
            viewer_notebook.set_tab_reorderable (tab.view, true);
            viewer_notebook.show_tabs = tabs.size > 1;   // hidden for one book
            activate_tab_idx (idx, false);   // silent for construction
            return tab;
        }

        private DocumentTab? tab_for_book (string path) {
            foreach (var t in tabs) {
                if (t.book_path == path) return t;
            }
            return null;
        }

        // Bind a placeholder tab to a freshly opened book.
        private void attach_book_to_tab (DocumentTab tab, BookContext ctx,
                                          string path, bool sync_now) {
            // Full path: the serving registry and chm:// URIs are keyed by
            // it, and two books may share a basename (review F5).
            // H1: set active_book FIRST so proxied setters route to the
            // new book instead of corrupting the previous BookContext.
            held_model.active_book = ctx;
            tab.book_path = path;
            tab.view.book_path = tab.book_path;
            tab.history = ctx.history;
            // Keep tab's ViewerModel in sync with BookContext.viewer (M2/M3:
            // NAVIGATE_DONE routes via BookContext.viewer, so they must be
            // the same object). Placeholder's viewer is replaced.
            tab.viewer = ctx.viewer;
            // Per-book font override: prefer stored per-book size over global.
            int per_font = held_model.per_books.get_font_size (path, held_model.settings.font_size);
            if (per_font != held_model.viewer.font_size) {
                held_model.viewer.font_size = per_font;
                // Apply to WebKit immediately via existing viewer settings
                tab.view.get_settings ().default_font_size = per_font;
            }
            // Restore last_url if stored and different from home (user left
            // on a different page last session). Do not override when the
            // current navigation already set intended_url.
            string saved_url = held_model.per_books.get_last_url (path);
            string target_url = ctx.home;
            if (saved_url != "" && saved_url != ctx.home && held_model.chm_file.has_object (saved_url)) {
                target_url = saved_url;
                tab.url = target_url;
                if (sync_now) {
                    held_model.viewer.current_url = target_url;
                    held_model.viewer.intended_url = target_url;
                } else {
                    // The OPEN_FILE_DONE dispatch will NAVIGATE to home;
                    // override that by updating the pending navigation's target
                    // via per-book state — the view's OPEN_FILE_DONE already
                    // dispatched NAVIGATE(home) before we arrived here, so
                    // we dispatch an additional NAVIGATE to the saved page
                    // once the book is bound.
                    GLib.Idle.add (() => {
                        dispatch (new NavigateMessage (target_url, null, held_model.active_tab_index));
                        return GLib.Source.REMOVE;
                    });
                }
            } else {
                tab.title = ctx.title;
                tab.url = ctx.home;
            }
            tab.title = ctx.title;
            tab.title_label.set_text (ctx.title);
            if (sync_now && saved_url == "") {
                held_model.viewer.current_url = ctx.home;
                held_model.viewer.current_title = ctx.title;
                held_model.viewer.intended_url = ctx.home;
            }
        }

        private void close_tab (DocumentTab tab) {
            int idx = tabs.index_of (tab);
            if (idx < 0) return;

            // M1: persist scroll for the book being closed
            tab.view.save_scroll (held_model);

            if (tabs.size == 1) {
                // Last tab: drop its book and reset to an empty placeholder.
                dispatch (new CloseFileMessage ());
                return;
            }

            // Strict single-tab-per-file: every bound tab owns exactly
            // one BookContext. Closing it must remove that context and
            // close its handle.
            if (tab.book_path != "") {
                // Remove BookContext matching this tab
                for (int i = 0; i < held_model.books.size; i++) {
                    if (held_model.books[i].chm_file.filename () == tab.book_path) {
                        held_model.books.remove_at (i);
                        break;
                    }
                }
                var bk = CHMFile.by_path (tab.book_path);
                if (bk != null) bk.close ();      // unregisters too
                // If we closed the active book, clear file_open if no books remain
                if (held_model.books.size == 0) {
                    held_model.file_open = false;
                    held_model.active_book = null;
                    held_model.chm_file.close ();
                } else if (held_model.active_book != null &&
                           held_model.active_book.chm_file.filename () == tab.book_path) {
                    // Active book was closed but other books remain — will be
                    // rebound in activate_tab_idx below.
                    held_model.active_book = null;
                }
            }

            tabs.remove_at (idx);
            viewer_notebook.remove_page (idx);
            viewer_notebook.show_tabs = tabs.size > 1;
            if (idx == active_tab) {
                int next = idx < tabs.size ? idx : idx - 1;
                // Sentinel bypasses activate_tab_idx's num == active_tab
                // early-return so the incoming tab's state is restored.
                active_tab = -1;
                viewer_notebook.page = next;   // fires switch_page → activate
                activate_tab_idx (next, true);
            } else if (idx < active_tab) {
                active_tab--;
                if (held_model != null) held_model.active_tab_index = active_tab;
            }
        }

        private void activate_tab (int num) {
            activate_tab_idx (num, true);
        }

        private void activate_tab_idx (int num, bool sync_view) {
            if (num < 0 || num >= tabs.size) return;
            if (num == active_tab) {
                viewer_notebook.page = num;   // keep display in sync
                return;
            }

            // Outgoing tab state is NOT snapshotted here. Writing the shared
            // model.viewer.current_url into old.url was the F26 race hot
            // path: the shared slot already held the NEW book by the time
            // the snapshot ran, so old.url got corrupted with the new
            // book's URL. tab.url is updated only by NAVIGATE_DONE
            // (line ~843) and attach_book_to_tab, which is the correct
            // source of truth for "this tab's last URL".

            // M1: persist per-book scroll before leaving the tab; do it
            // while held_model still points at the outgoing book so the
            // async JS save targets the correct archive path.
            if (active_tab >= 0 && active_tab < tabs.size) {
                tabs[active_tab].view.save_scroll (held_model);
            }

            // Flush the shared viewer slot into the outgoing tab's
            // per-tab viewer (the slot has been the active tab's
            // viewer all along because every code path writes there).
            // Then pull the incoming tab's viewer back into the slot
            // so model.viewer reads in the update function see the
            // incoming tab's state.
            if (active_tab >= 0 && active_tab < tabs.size) {
                var old_tab = tabs[active_tab];
                if (old_tab.viewer == held_model.viewer) {
                    // Already the same reference; nothing to do.
                } else {
                    // Copy scratch state into the outgoing tab.
                    old_tab.viewer.current_url = held_model.viewer.current_url;
                    old_tab.viewer.current_title = held_model.viewer.current_title;
                    old_tab.viewer.intended_url = held_model.viewer.intended_url;
                    old_tab.viewer.loading = held_model.viewer.loading;
                    old_tab.viewer.error = held_model.viewer.error;
                    old_tab.viewer.pending_html = held_model.viewer.pending_html;
                    old_tab.viewer.find_text = held_model.viewer.find_text;
                    old_tab.viewer.find_case_sensitive = held_model.viewer.find_case_sensitive;
                }
            }

            active_tab = num;
            var tab = tabs[num];

            // Restore incoming tab's book (if bound) into shared model.
            // H1: active_book must be set before any proxied write so we
            // don't corrupt the outgoing book's context.
            if (tab.book_path != "") {
                var bk = CHMFile.by_path (tab.book_path);
                foreach (var bctx in held_model.books) {
                    if (bctx.chm_file == bk) {
                        held_model.active_book = bctx;
                        break;
                    }
                }
            }
            // tab.history is the per-tab history; it should already be
            // bctx.history if bound via attach_book_to_tab. Keep explicit
            // flush AFTER active_book so it targets the new context.
            if (tab.history != null)
                held_model.history = tab.history;

            // Swap the per-tab ViewerModel in for the shared slot so
            // model.viewer reads in the update function see the
            // incoming tab's viewer state.
            held_model.viewer = tab.viewer;
            // M6: sync WebView font to this tab's per-book viewer (other
            // tabs may have different font sizes/families).
            {
                var s = tab.view.get_settings ();
                s.default_font_size = tab.viewer.font_size;
                s.default_font_family = tab.viewer.font_family;
                s.monospace_font_family = tab.viewer.fixed_font_family;
            }

            // Tell the model which tab is now active so NAVIGATE
            // messages dispatched from updateModel carry the right
            // tab_index (the worker snapshot still uses the shared
            // model.chm_file which the proxy routes here, but the
            // tab_index lets NAVIGATE_DONE route its writes to the
            // right tab if the user switches mid-load).
            held_model.active_tab_index = num;

            tab.title_label.set_text (
                tab.title.length > 0 ? tab.title : _("New page"));
            held_model.status_text = tab.title.length > 0 ? tab.title : tab.url;

            // Notify the model + sidebar views that the active tab
            // changed so they can rebuild from the new active book.
            // Dispatched after the swap so updateModel.OPEN_FILE_DONE
            // can still use the previous active tab's state if needed.
            dispatch (new TabActivatedMessage (num, tab.book_path));

            if (sync_view)
                tab.view.sync_if_needed (held_model, true);
        }

        private void toggle_fullscreen () {
            var top = (Gtk.Window) get_root ();
            if (top == null) return;
            if (top.fullscreened) top.unfullscreen ();
            else top.fullscreen ();
        }

        // Mirror the panel state into the stateful toggle actions so
        // toolbar ToggleButtons and menu check-marks reflect whichever
        // panel is active+visible, no matter which path changed it.
        private void sync_panel_actions (AppModel model) {
            if (act_topics == null) return;
            bool visible = model.settings.show_topics ||
                           model.settings.show_index ||
                           model.settings.show_search ||
                           model.settings.show_bookmarks;
            int active = model.settings.active_side_panel;
            act_topics.set_state (visible && active == 0);
            act_index.set_state (visible && active == 1);
            act_search.set_state (visible && active == 2);
            if (act_bookmarks != null)
                act_bookmarks.set_state (visible && active == 3);
        }

        private void toggle_find_bar () {
            find_revealer.reveal_child = !find_revealer.reveal_child;
            if (find_revealer.reveal_child) {
                find_entry.grab_focus ();
            } else {
                // Bar closed: drop highlights and the match counter.
                find_count_label.set_text ("");
                dispatch (new ViewerFindMessage (""));
            }
        }

        // Strict single-tab-per-file: activate existing tab if the
        // file is already open (canonical path compare), otherwise
        // dispatch OPEN_FILE. Used by dialog, drag-drop, and any UI
        // entry point that has access to tabs.
        private void open_file_or_activate (string path) {
            string canon = GLib.File.new_for_path (path).get_path () ?? path;
            foreach (var t in tabs) {
                if (t.book_path == "") continue;
                string tb = GLib.File.new_for_path (t.book_path).get_path () ?? t.book_path;
                if (tb == canon) {
                    viewer_notebook.page = tabs.index_of (t);
                    return;
                }
            }
            dispatch (new OpenFileMessage (path));
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
            // Restore last folder from settings
            if (held_model != null && held_model.settings.last_opened_dir != null &&
                held_model.settings.last_opened_dir.length > 0) {
                dialog.initial_folder = GLib.File.new_for_path (held_model.settings.last_opened_dir);
            }
            
            dialog.open.begin (this, null, (obj, res) => {
                try {
                    var file = dialog.open.end (res);
                    var p = file.get_path ();
                    if (p != null) open_file_or_activate (p);
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

                    if (done_msg.ctx == null) break;

                    // Already open? Just activate its tab (match by full
                    // path — basenames can collide across books).
                    var existing = tab_for_book (done_msg.path);
                    if (existing != null) {
                        int idx = tabs.index_of (existing);
                        viewer_notebook.page = idx;   // fires activate
                        refresh_recent_menus ();
                        break;
                    }

                    // First book reuses the startup placeholder; every
                    // further book gets its own tab — deterministic even
                    // when bursts race.
                    DocumentTab target;
                    bool created;
                    if (tabs.size == 1 && tabs[0].book_path == "" &&
                        model.books.size == 1) {
                        target = tabs[0];
                        created = false;
                    } else {
                        target = create_tab (model);
                        created = true;
                    }
                    attach_book_to_tab (target, done_msg.ctx,
                                         done_msg.path, true);
                    viewer_notebook.show_tabs = tabs.size > 1;
                    viewer_notebook.page = tabs.index_of (target);
                    if (!created)
                        target.view.sync_if_needed (model);
                    refresh_recent_menus ();
                    break;
                }

                case AppMessageKind.OPEN_FILE_FAILED: {
                    // Error handled by toast
                    break;
                }

                case AppMessageKind.CLOSE_FILE: {
                    // Tear down all book tabs, leave one empty placeholder.
                    while (tabs.size > 1) {
                        tabs.remove_at (tabs.size - 1);
                        viewer_notebook.remove_page (tabs.size);
                    }
                    var first = tabs[0];
                    // Model pointers stay; the explicit Close already
                    // closed the chm file.
                    first.book_path = "";
                    first.url = "/";
                    first.title = _("New page");
                    first.title_label.set_text (first.title);
                    viewer_notebook.show_tabs = false;
                    set_title ("vCHM");
                    break;
                }

                case AppMessageKind.NAVIGATE_DONE: {
                    var done_msg = (NavigateDoneMessage) msg;
                    // Pages without their own <title> (metadata-poor
                    // books) must not blank the window title to
                    // "vCHM - " — keep the book title instead.
                    string win_title = done_msg.title != ""
                        ? done_msg.title
                        : (model.chm_file.title () != ""
                           ? model.chm_file.title ()
                           : done_msg.url);
                    set_title ("vCHM - %s".printf (win_title));

                    // Coalescing race guard: if the active book lost its
                    // OPEN_FILE_DONE attach, bind it to a tab now.
                    if (held_model.active_book != null && held_model.file_open) {
                        var apath = held_model.chm_file.filename ();
                        if (tab_for_book (apath) == null &&
                            tabs[active_tab].book_path == "") {
                            attach_book_to_tab (tabs[active_tab],
                                                held_model.active_book,
                                                apath,
                                                false);
                            viewer_notebook.show_tabs = tabs.size > 1;
                        }
                    }

                    // Use the tab_index from the message if present,
                    // otherwise fall back to the currently active tab.
                    // The user may have switched tabs between NAVIGATE
                    // dispatch and NAVIGATE_DONE; without tab_index the
                    // URL would land on the wrong tab.
                    int ti = done_msg.tab_index >= 0 ? done_msg.tab_index : active_tab;
                    if (ti >= 0 && ti < tabs.size) {
                        var tab = tabs[ti];
                        tab.url = model.viewer.current_url;
                        // Tab label: prefer the book title (set by
                        // attach_book_to_tab) over the page title so
                        // pages with empty <title> or generic titles
                        // like "Table of Contents" don't replace the
                        // book name. Only update the tab title if the
                        // page title is meaningful (non-empty and not
                        // equal to the book title).
                        if (done_msg.title != "" && done_msg.title != tab.title) {
                            tab.title = done_msg.title;
                        }
                        tab.title_label.set_text (tab.title);
                    }
                    break;
                }

                case AppMessageKind.TOGGLE_TOPICS_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search || model.settings.show_bookmarks;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.TOGGLE_INDEX_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search || model.settings.show_bookmarks;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.TOGGLE_SEARCH_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search || model.settings.show_bookmarks;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.TOGGLE_BOOKMARKS_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search || model.settings.show_bookmarks;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.SET_ACTIVE_SIDE_PANEL: {
                    sidebar_notebook.page = model.settings.active_side_panel;
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.SET_SASH_POSITION: {
                    sash_updating = true;
                    main_paned.position = model.settings.sash_position;
                    sash_updating = false;
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

                case AppMessageKind.ABOUT_DIALOG: {
                    show_about ();
                    break;
                }

                case AppMessageKind.PREFERENCES_DIALOG: {
                    show_preferences (model);
                    break;
                }

                case AppMessageKind.OPEN_IN_NEW_TAB: {
                    // Strict single-tab-per-file: internal chm:// links
                    // dispatched here (old target=_blank) now just navigate
                    // in the current tab. The dedicated "new tab clone"
                    // of the same book is removed (per-book persistence
                    // would otherwise clash). External links are handled
                    // via launch_external in ViewerView, not here.
                    var nt = (OpenInNewTabMessage) msg;
                    var target_path = normalize_chm_target (nt.url);
                    dispatch (new NavigateMessage (target_path, null, active_tab));
                    break;
                }

                case AppMessageKind.APP_QUIT: {
                    destroy ();
                    break;
                }

                case AppMessageKind.TAB_ACTIVATED: {
                    // The sidebar views are wired to update on
                    // NAVIGATE_DONE / OPEN_FILE_DONE, but those fire
                    // per-tab and may have been coalesced away. On
                    // an explicit tab switch we MUST rebuild the
                    // sidebar so it shows the new active book's TOC
                    // / index / search / bookmarks.
                    topics_view.update (msg, model);
                    index_view.update (msg, model);
                    search_view.update (msg, model);
                    bookmarks_view.update (msg, model);
                    // Skip the generic forward-to-subviews below
                    // for TAB_ACTIVATED: we just dispatched above.
                    return;
                }

                case AppMessageKind.VIEWER_FIND_COUNT: {
                    var fc = (ViewerFindCountMessage) msg;
                    find_count_label.set_text (
                        fc.match_count > 0 ? _("%u matches").printf (fc.match_count)
                                           : _("no matches"));
                    break;
                }

                default:
                    break;
            }

            // Forward to sub-views
            topics_view.update (msg, model);
            index_view.update (msg, model);
            search_view.update (msg, model);
            bookmarks_view.update (msg, model);
            viewer_view.update (msg, model);
            toolbar_view.update (msg, model);
            statusbar_view.update (msg, model);
        }
    }
}