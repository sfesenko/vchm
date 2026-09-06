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
        public const string ACTION_BACK = "back";
        public const string ACTION_FORWARD = "forward";
        public const string ACTION_HOME = "home";
        public const string ACTION_FONT_INCREASE = "font_increase";
        public const string ACTION_FONT_DECREASE = "font_decrease";
        public const string ACTION_FONT_RESET = "font_reset";
        public const string ACTION_COPY = "copy";
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
        // Single-book: one WebView, recreated on book change (design §6)
        private ViewerView view;
        private uint scroll_coalesce_id = 0;
        private int pending_scroll = 0;
        private string pending_scroll_book = "";
        private bool pending_scroll_dirty = false;
        
        // Sub-views
        private TopicsView topics_view;
        private IndexView index_view;
        private SearchView search_view;

        public ViewerView viewer_view {
            get {
                assert (view != null);
                return view;
            }
        }
        // Per-tab ViewerModel via BookContext (B+hybrid): active tab's viewer lives in AppModel.current_book.viewer
        public ViewerModel? active_viewer {
            get {
                if (held_model == null) return null;
                if (held_model.current_book != null) return held_model.current_book.viewer;
                return held_model.placeholder.viewer;
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
            setup_notify_handlers (model);
        }

        private void setup_notify_handlers (AppModel model) {
            // B+hybrid: sync UI via GObject notify (batched via freeze/thaw in ElmishProgram.process)
            // instead of via queue_view_update single-slot. Keeps uni-direct: view -> ModelMsg -> model mutated -> notify -> view.
            model.settings.notify["show-topics"].connect (() => { update_sidebar_visibility (model); sync_panel_actions (model); });
            model.settings.notify["show-index"].connect (() => { update_sidebar_visibility (model); sync_panel_actions (model); });
            model.settings.notify["show-search"].connect (() => { update_sidebar_visibility (model); sync_panel_actions (model); });
            model.settings.notify["show-bookmarks"].connect (() => { update_sidebar_visibility (model); sync_panel_actions (model); });
            model.settings.notify["active-side-panel"].connect (() => { update_sidebar_visibility (model); sync_panel_actions (model); });
            model.notify["active-book"].connect (() => {
                // Single-book: recreate viewer when active book changes (design §6)
                // Delay to ensure held_model is set; recreate handles null (blank) case
                recreate_viewer_for_new_book (model.current_book);
                // Rebuild sub-views from new BookContext
                if (model.current_book != null) {
                    topics_view.notify_active_changed (model);
                    index_view.notify_active_changed (model);
                    search_view.notify_active_changed (model);
                    bookmarks_view.notify_active_changed (model);
                } else {
                    // No book — clear topics/index/search/bookmarks views
                    topics_view.notify_active_changed (model);
                    index_view.notify_active_changed (model);
                    search_view.notify_active_changed (model);
                    bookmarks_view.notify_active_changed (model);
                }
                update_sidebar_visibility (model);
                sync_panel_actions (model);
            });
            model.notify["books"].connect (() => {
                refresh_recent_menus ();
            });
            // Sash position: sync UI without queue_view_update Idle
            model.settings.notify["sash-position"].connect (() => {
                if (main_paned == null) return;
                sash_updating = true;
                main_paned.position = model.settings.sash_position;
                sash_updating = false;
            });
            model.settings.notify["window-maximized"].connect (() => {
                if (model.settings.window_maximized) maximize ();
                else unmaximize ();
            });
        }

        private void update_sidebar_visibility (AppModel model) {
            if (sidebar_box == null || sidebar_notebook == null) return;
            bool visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search || model.settings.show_bookmarks;
            sidebar_box.visible = visible;
            if (visible) {
                int p = model.settings.active_side_panel.clamp (0, 3);
                if (sidebar_notebook.page != p) sidebar_notebook.page = p;
            }
        }

        private void setup_actions () {
            ActionEntry[] action_entries = {
                { ACTION_QUIT, () => app.quit (), null, null },
                { ACTION_OPEN, () => on_open_file (), null, null },
                { ACTION_BACK, () => dispatch (new GoBackMessage ()), null, null },
                { ACTION_FORWARD, () => dispatch (new GoForwardMessage ()), null, null },
                { ACTION_HOME, () => dispatch (new GoHomeMessage ()), null, null },
                { ACTION_FONT_INCREASE, () => dispatch (new ViewerFontIncreaseMessage ()), null, null },
                { ACTION_FONT_DECREASE, () => dispatch (new ViewerFontDecreaseMessage ()), null, null },
                { ACTION_FONT_RESET, () => dispatch (new ViewerFontResetMessage ()), null, null },
                { ACTION_COPY, () => dispatch (new ViewerCopyMessage ()), null, null },
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
            application.set_accels_for_action (ACTION_PREFIX + ACTION_BACK, {"<Alt>Left"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FORWARD, {"<Alt>Right"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_HOME, {"<Alt>Home"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_COPY, {"<Control>c"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_INCREASE, {"<Control>plus", "<Control>equal"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_DECREASE, {"<Control>minus"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FONT_RESET, {"<Control>0"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FIND, {"<Control>f"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_PRINT, {"<Control>p"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_FULLSCREEN, {"F11", "F11"});
            application.set_accels_for_action (ACTION_PREFIX + ACTION_ABOUT, {"F1"});
            application.set_accels_for_action (ACTION_PREFIX + "set-encoding", {});
        }

        private void setup_window (AppModel model) {
            set_title ("vCHM");
            set_default_size (model.settings.window_width, model.settings.window_height);

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
                flush_pending_scroll (held_model ?? model);
                // Flush geometry so a quit right after a resize still
                // restores the final size.
                save_geometry (model);
                if (held_model != null) {
                    held_model.settings.per_book_rows = held_model.per_books.save ();
                } else {
                    model.settings.per_book_rows = model.per_books.save ();
                }
                (held_model ?? model).settings.save ();
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
                default_width, default_height));
        }

        private void flush_pending_scroll (AppModel? model = null) {
            var m = model ?? held_model;
            if (m == null || !pending_scroll_dirty) return;
            if (scroll_coalesce_id != 0) {
                Source.remove (scroll_coalesce_id);
                scroll_coalesce_id = 0;
            }
            m.per_books.set_scroll (pending_scroll_book, pending_scroll);
            m.settings.per_book_rows = m.per_books.save ();
            pending_scroll_dirty = false;
        }

        private void recreate_viewer_for_new_book (BookContext? ctx) {
            // Drop old view — unparent is enough; do NOT call destroy() (deprecated in GTK4, double-frees WebContext.get_default())
            if (viewer_scrolled != null && viewer_scrolled.child != null) viewer_scrolled.child = null;
            if (scroll_coalesce_id != 0) {
                Source.remove (scroll_coalesce_id);
                scroll_coalesce_id = 0;
            }
            pending_scroll_dirty = false;
            view = null; // let GC finalize old WebView
            // Create new
            view = new ViewerView ();
            view.book_path = ctx != null ? ctx.chm_file.filename () : "";
            view.build_ui (dispatch, held_model ?? new AppModel ());
            // Add to scrolled
            if (viewer_scrolled != null) {
                viewer_scrolled.child = view;
                // Wire continuous scroll tracking — MUST happen after parenting, when vadjustment is realized
                var vadj = viewer_scrolled.get_vadjustment ();
                if (vadj != null) {
                    vadj.value_changed.connect (() => {
                        if (view == null || view.book_path == "" || held_model == null) return;
                        pending_scroll = (int) vadj.get_value ();
                        pending_scroll_book = view.book_path;
                        pending_scroll_dirty = true;
                        if (scroll_coalesce_id == 0) {
                            scroll_coalesce_id = Timeout.add (1500, () => {
                                flush_pending_scroll ();
                                scroll_coalesce_id = 0;
                                return false;
                            });
                        }
                    });
                }
            }
            // Sync immediately
            if (held_model != null) view.sync_if_needed (held_model, true);
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
            file_section.append (_("Quit"), "win.quit");
            menu.append_section (_("File"), file_section);

            // Edit section (Copy, Find)
            var edit_section = new GLib.Menu ();
            edit_section.append (_("Copy"), "win.copy");
            edit_section.append (_("Find in Page..."), "win.find");
            menu.append_section (_("Edit"), edit_section);

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

            // History section (Back/Forward/Home)
            var history_section = new GLib.Menu ();
            history_section.append (_("Back"), "win.back");
            history_section.append (_("Forward"), "win.forward");
            history_section.append (_("Home"), "win.home");
            menu.append_section (_("History"), history_section);

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

            // Viewer area — single WebView (design §6)
            view = new ViewerView ();
            view.book_path = "";
            view.build_ui (dispatch, model);
            viewer_scrolled = new Gtk.ScrolledWindow () {
                hexpand = true,
                vexpand = true,
                child = view
            };
            // Wire continuous scroll tracking — MUST happen after parenting, when vadjustment is realized
            var vadj = viewer_scrolled.get_vadjustment ();
            if (vadj != null) {
                vadj.value_changed.connect (() => {
                    if (view == null || view.book_path == "" || held_model == null) return;
                    pending_scroll = (int) vadj.get_value ();
                    pending_scroll_book = view.book_path;
                    pending_scroll_dirty = true;
                    if (scroll_coalesce_id == 0) {
                        scroll_coalesce_id = Timeout.add (1500, () => {
                            flush_pending_scroll ();
                            scroll_coalesce_id = 0;
                            return false;
                        });
                    }
                });
            }

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
            var pref_v = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
            var prop_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            prop_row.append (new Gtk.Label (_("Proportional font:")) { xalign = 0, hexpand = true });
            var prop_dialog = new Gtk.FontDialog ();
            var prop_btn = new Gtk.FontDialogButton (prop_dialog);
            prop_btn.tooltip_text = _("Choose proportional font");
            var prop_desc = Pango.FontDescription.from_string ("%s %d".printf (pref_v.font_family, pref_v.font_size));
            prop_btn.set_font_desc (prop_desc);
            prop_btn.notify["font-desc"].connect (() => {
                var desc = prop_btn.get_font_desc ();
                if (desc == null) return;
                var v_cur = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
                string fam = desc.get_family () ?? v_cur.font_family;
                int sz = desc.get_size () / Pango.SCALE;
                if (sz == 0) sz = v_cur.font_size;
                if (sz < 6) sz = 6;
                if (sz > 72) sz = 72;
                dispatch (new ViewerFontChangedMessage (sz, fam, v_cur.fixed_font_family));
            });
            prop_row.append (prop_btn);
            vbox.append (prop_row);

            // Fixed font picker
            var fixed_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            fixed_row.append (new Gtk.Label (_("Fixed font:")) { xalign = 0, hexpand = true });
            var fixed_dialog = new Gtk.FontDialog ();
            var fixed_btn = new Gtk.FontDialogButton (fixed_dialog);
            fixed_btn.tooltip_text = _("Choose fixed-width font");
            var fixed_desc = Pango.FontDescription.from_string ("%s %d".printf (pref_v.fixed_font_family, pref_v.font_size));
            fixed_btn.set_font_desc (fixed_desc);
            fixed_btn.notify["font-desc"].connect (() => {
                var desc = fixed_btn.get_font_desc ();
                if (desc == null) return;
                var v_cur2 = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
                string fam = desc.get_family () ?? v_cur2.fixed_font_family;
                int sz = desc.get_size () / Pango.SCALE;
                if (sz == 0) sz = v_cur2.font_size;
                if (sz < 6) sz = 6;
                if (sz > 72) sz = 72;
                dispatch (new ViewerFontChangedMessage (sz, v_cur2.font_family, fam));
            });
            fixed_row.append (fixed_btn);
            vbox.append (fixed_row);

            // TTL for per-book state (position/history/expanded)
            var per_exp_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            per_exp_row.append (new Gtk.Label (_("Per-book history expiry (days, 0=keep):")) { xalign = 0, hexpand = true });
            var per_exp_spin = new Gtk.SpinButton.with_range (0, 3650, 1);
            per_exp_spin.value = model.settings.per_book_expire_days;
            per_exp_spin.tooltip_text = _("Days after last access to keep per-book position, expanded sections and navigation history");
            per_exp_spin.value_changed.connect (() => {
                dispatch (new SetPerBookExpireMessage ((int) per_exp_spin.value));
            });
            per_exp_row.append (per_exp_spin);
            vbox.append (per_exp_row);

            var bm_exp_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            bm_exp_row.append (new Gtk.Label (_("Bookmarks expiry (days, 0=keep):")) { xalign = 0, hexpand = true });
            var bm_exp_spin = new Gtk.SpinButton.with_range (0, 3650, 1);
            bm_exp_spin.value = model.settings.bookmarks_expire_days;
            bm_exp_spin.tooltip_text = _("Days after creation to keep bookmarks");
            bm_exp_spin.value_changed.connect (() => {
                dispatch (new SetBookmarksExpireMessage ((int) bm_exp_spin.value));
            });
            bm_exp_row.append (bm_exp_spin);
            vbox.append (bm_exp_row);

            content.append (vbox);

            dialog.response.connect ((rid) => {
                if (rid == Gtk.ResponseType.CLOSE || rid == Gtk.ResponseType.DELETE_EVENT) {
                    dialog.destroy ();
                }
            });

            dialog.present ();
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

        private void open_file_or_activate (string path) {
            string canon = AppModel.canon_open_key (path);
            if (held_model != null && held_model.current_book != null) {
                string cur = AppModel.canon_open_key (held_model.current_book.chm_file.filename ());
                if (canon == cur) {
                    present ();
                    if (view != null) view.sync_if_needed (held_model, true);
                    return;
                }
            }
            flush_pending_scroll ();
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

                    // Single-book: current_book already set by updateModel; notify["active-book"] recreated viewer.
                    refresh_recent_menus ();
                    break;
                }

                case AppMessageKind.OPEN_FILE_FAILED: {
                    // Error handled by toast
                    break;
                }

                case AppMessageKind.NAVIGATE_DONE: {
                    var done_msg = (NavigateDoneMessage) msg;
                    var title_src = model.current_book != null ? model.current_book : model.placeholder;
                    string win_title = done_msg.title != ""
                        ? done_msg.title
                        : (title_src.chm_file.title () != ""
                            ? title_src.chm_file.title ()
                            : done_msg.url);
                    set_title ("vCHM - %s".printf (win_title));
                    break;
                }

                case AppMessageKind.TOGGLE_TOPICS_PANEL:
                case AppMessageKind.TOGGLE_INDEX_PANEL:
                case AppMessageKind.TOGGLE_SEARCH_PANEL:
                case AppMessageKind.TOGGLE_BOOKMARKS_PANEL:
                case AppMessageKind.SET_ACTIVE_SIDE_PANEL:
                case AppMessageKind.SET_SASH_POSITION:
                    // B+hybrid: handled via GObject notify (freeze/thaw batched) in setup_notify_handlers,
                    // not via queue_view_update Idle. Keeping updateView for these would be 1 frame late.
                    break;

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
case AppMessageKind.PRESENT_WINDOW: {
                    present ();
                    break;
                }

                case AppMessageKind.TEST_REOPEN: {
                    // Model already cleared via set_active(null); view blank is handled via notify["active-book"] -> recreate_viewer_for_new_book(null)
                    break;
                }

                case AppMessageKind.APP_QUIT: {
                    destroy ();
                    break;
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