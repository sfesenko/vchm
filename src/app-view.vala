// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;
using Vchm.View;
using GLib;

namespace Vchm {

    // One document tab: its own WebView + history; the shared archive
    // model supplies content for whichever tab is active.
    public class DocumentTab : Object {
        public Vchm.View.ViewerView view;
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
        private ToolbarView toolbar_view;
        private StatusBarView statusbar_view;
        private BookmarksView bookmarks_view;

        // Stateful panel-toggle actions (checked = panel visible+active);
        // kept as members so the shell can re-sync their state whenever
        // the active panel changes from any path.
        private GLib.SimpleAction act_topics;
        private GLib.SimpleAction act_index;
        private GLib.SimpleAction act_search;

        // Guards against notify->dispatch->set->notify feedback loops.
        private bool sash_updating = false;

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
            // dispatch() is synchronous here — the flag is already flipped
            // when we mirror it into the action state.
            act_topics = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_TOPICS, null, held_model != null ? held_model.settings.show_topics : true);
            act_topics.activate.connect (() => {
                dispatch (new ToggleTopicsPanelMessage ());
                sync_panel_actions (held_model);
            });
            add_action (act_topics);

            act_index = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_INDEX, null, held_model != null ? held_model.settings.show_index : true);
            act_index.activate.connect (() => {
                dispatch (new ToggleIndexPanelMessage ());
                sync_panel_actions (held_model);
            });
            add_action (act_index);

            act_search = new GLib.SimpleAction.stateful (
                ACTION_TOGGLE_SEARCH, null, held_model != null ? held_model.settings.show_search : false);
            act_search.activate.connect (() => {
                dispatch (new ToggleSearchPanelMessage ());
                sync_panel_actions (held_model);
            });
            add_action (act_search);

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
            file_section.append (_("Print..."), "win.print");
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

                if (was_active != null)
                    active_tab = tabs.index_of (was_active);
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
                                  model.settings.show_search;
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
                dispatch (new OpenFileMessage (chosen.get_path ()));
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
            dialog.set_default_size (380, 100);

            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                margin_top = 12, margin_bottom = 12,
                margin_start = 12, margin_end = 12
            };
            row.append (new Gtk.Label (
                _("Images are always loaded from the opened book. Remote content is blocked.")));
            dialog.get_content_area ().append (row);

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
            tab.book_path = path;
            tab.view.book_path = tab.book_path;
            tab.history = ctx.history;
            held_model.history = ctx.history;
            held_model.chm_file = ctx.chm_file;
            held_model.topics = ctx.topics;
            held_model.index = ctx.index;
            held_model.active_book = ctx;
            tab.title = ctx.title;
            tab.url = ctx.home;
            tab.title_label.set_text (ctx.title);
            if (sync_now) {
                held_model.viewer.current_url = ctx.home;
                held_model.viewer.current_title = ctx.title;
                held_model.viewer.intended_url = ctx.home;
            }
        }

        private void close_tab (DocumentTab tab) {
            int idx = tabs.index_of (tab);
            if (idx < 0) return;

            if (tabs.size == 1) {
                // Last tab: drop its book and reset to an empty placeholder.
                dispatch (new CloseFileMessage ());
                return;
            }

            // Closing a book-bound tab closes that book for real, but only
            // when no other tab still uses it (shared-book tabs from
            // OPEN_IN_NEW_TAB keep the archive alive).
            if (tab.book_path != "") {
                bool last_for_book = true;
                foreach (var t in tabs) {
                    if (t != tab && t.book_path == tab.book_path) {
                        last_for_book = false;
                        break;
                    }
                }
                if (last_for_book) {
                    var bk = CHMFile.by_path (tab.book_path);
                    if (bk != null) bk.close ();      // unregisters too
                    if (held_model.active_book != null &&
                        held_model.chm_file.filename () == tab.book_path) {
                        held_model.file_open = false;
                    }
                }
            }

            tabs.remove_at (idx);
            viewer_notebook.remove_page (idx);
            if (idx == active_tab) {
                int next = idx < tabs.size ? idx : idx - 1;
                // Sentinel bypasses activate_tab_idx's num == active_tab
                // early-return so the incoming tab's state is restored.
                active_tab = -1;
                viewer_notebook.page = next;   // fires switch_page → activate
                activate_tab_idx (next, true);
            } else if (idx < active_tab) {
                active_tab--;
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

            // Snapshot outgoing tab state.
            if (active_tab >= 0 && active_tab < tabs.size) {
                var old = tabs[active_tab];
                old.url = held_model.viewer.current_url;
                old.title = held_model.viewer.current_title;
            }

            active_tab = num;
            var tab = tabs[num];

            // Restore incoming tab's book (if bound) into shared model.
            if (tab.book_path != "") {
                var bk = CHMFile.by_path (tab.book_path);
                foreach (var bctx in held_model.books) {
                    if (bctx.chm_file == bk) {
                        held_model.chm_file = bctx.chm_file;
                        held_model.topics = bctx.topics;
                        held_model.index = bctx.index;
                        held_model.active_book = bctx;
                        break;
                    }
                }
            }
            if (tab.history != null)
                held_model.history = tab.history;

            held_model.viewer.current_url = tab.url;
            held_model.viewer.current_title = tab.title;
            held_model.viewer.intended_url = tab.url;
            held_model.viewer.loading = false;

            tab.title_label.set_text (
                tab.title.length > 0 ? tab.title : _("New page"));
            held_model.status_text = tab.title.length > 0 ? tab.title : tab.url;

            if (sync_view)
                tab.view.sync_if_needed (held_model);
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
                           model.settings.show_search;
            int active = model.settings.active_side_panel;
            act_topics.set_state (visible && active == 0);
            act_index.set_state (visible && active == 1);
            act_search.set_state (visible && active == 2);
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

                    if (done_msg.ctx == null) break;

                    // Already open? Just activate its tab (match by full
                    // path — basenames can collide across books).
                    var existing = tab_for_book (done_msg.path);
                    if (existing != null) {
                        int idx = tabs.index_of (existing);
                        viewer_notebook.page = idx;   // fires activate
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

                    if (active_tab >= 0 && active_tab < tabs.size) {
                        var tab = tabs[active_tab];
                        tab.url = model.viewer.current_url;
                        tab.title = done_msg.title != "" ? done_msg.title : tab.url;
                        tab.title_label.set_text (tab.title);
                    }
                    break;
                }

                case AppMessageKind.TOGGLE_TOPICS_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.TOGGLE_INDEX_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
                    if (sidebar_box.visible)
                        sidebar_notebook.page = model.settings.active_side_panel.clamp (0, 3);
                    sync_panel_actions (model);
                    break;
                }

                case AppMessageKind.TOGGLE_SEARCH_PANEL: {
                    sidebar_box.visible = model.settings.show_topics || model.settings.show_index || model.settings.show_search;
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
                    var nt = (OpenInNewTabMessage) msg;
                    var target_path = normalize_chm_target (nt.url);

                    // New tab within the SAME book; fresh history for it.
                    var tab = create_tab (model);
                    tab.book_path = model.chm_file.filename ();
                    tab.view.book_path = tab.book_path;
                    tab.history = new HistoryModel ();
                    tab.url = target_path;

                    // Snapshot current tab, activate the new one silently,
                    // point shared model at it, and navigate.
                    int new_idx = tabs.size - 1;
                    if (active_tab >= 0 && active_tab < tabs.size) {
                        var old_t = tabs[active_tab];
                        old_t.url = model.viewer.current_url;
                        old_t.title = model.viewer.current_title;
                    }
                    active_tab = new_idx;
                    held_model.history = tab.history;
                    held_model.viewer.current_url = target_path;
                    held_model.viewer.current_title = "";
                    held_model.viewer.intended_url = target_path;
                    dispatch (new NavigateMessage (target_path));
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