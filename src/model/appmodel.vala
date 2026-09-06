// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

namespace Vchm.Model {

    public class BookContext : Object {
        public CHMFile chm_file { get; set; default = new CHMFile (); }
        public TopicsModel topics { get; set; default = new TopicsModel (); }
        public IndexModel index { get; set; default = new IndexModel (); }
        public HistoryModel history { get; set; default = new HistoryModel (); }
        public SearchModel search { get; set; default = new SearchModel (); }
        public ViewerModel viewer { get; set; default = new ViewerModel (); }
        public string title { get; set; default = ""; }
        public string home { get; set; default = "/"; }
        public bool history_navigation_in_progress { get; set; default = false; }
    }

    public class AppModel : Object {
        private BookContext? _active_ctx = null;
        private BookContext _empty_book = new BookContext ();
        // Deprecated aliases for one-commit migration — new code uses current_book/_empty_book
        public BookContext placeholder { get { return _empty_book; } }
        public BookContext current_ctx { get { return _active_ctx ?? _empty_book; } }
        public CHMFile chm_file {
            get { return current_ctx.chm_file; }
            set { current_ctx.chm_file = value; notify_property ("chm-file"); }
        }
        public TopicsModel topics {
            get { return current_ctx.topics; }
            set { current_ctx.topics = value; notify_property ("topics"); }
        }
        public IndexModel index {
            get { return current_ctx.index; }
            set { current_ctx.index = value; notify_property ("index"); }
        }
        public HistoryModel history {
            get { return current_ctx.history; }
            set { current_ctx.history = value; notify_property ("history"); }
        }
        public SearchModel search {
            get { return current_ctx.search; }
            private set { current_ctx.search = value; notify_property ("search"); }
        }
        public ViewerModel viewer {
            get { return current_ctx.viewer; }
            set { current_ctx.viewer = value; notify_property ("viewer"); }
        }
        public SettingsModel settings { get; private set; }
        public BookmarkStore bookmarks { get; private set; }
        public PerBookStore per_books { get; private set; }

        // Single-book: exactly one active context
        public BookContext? current_book {
            get { return _active_ctx; }
            set { set_active (value); }
        }
        // Alias for migration
        public BookContext? active_book {
            get { return current_book; }
            set { current_book = value; }
        }

        // Deprecated tabs/books shim — single-book has no tabs. Kept to keep old tests compiling one commit; will be removed.
        private Gee.ArrayList<BookContext> _books_compat = new Gee.ArrayList<BookContext> ();
        public Gee.ArrayList<BookContext> books {
            get { return _books_compat; }
            set { _books_compat = value; notify_property ("books"); notify_property ("tabs"); }
        }
        public Gee.ArrayList<BookContext> tabs {
            get { return _books_compat; }
        }
        public BookContext? current_tab {
            owned get { return _active_ctx; }
        }
        private int _active_tab_index = -1;
        public int active_tab_index {
            get { return _active_tab_index; }
            set {
                if (_active_tab_index == value) return;
                _active_tab_index = value;
                notify_property ("active-tab-index");
                notify_property ("current-tab");
            }
        }
        public void add_book (BookContext ctx) { _books_compat.add (ctx); notify_property ("books"); notify_property ("tabs"); }
        public void insert_book (int idx, BookContext ctx) { _books_compat.insert (idx, ctx); notify_property ("books"); notify_property ("tabs"); }
        public void remove_book_at (int idx) { _books_compat.remove_at (idx); notify_property ("books"); notify_property ("tabs"); }
        public void clear_books () { _books_compat.clear (); notify_property ("books"); notify_property ("tabs"); }
        public void reorder_books (int from, int to) {
            if (from < 0 || from >= _books_compat.size || to < 0 || to > _books_compat.size) return;
            var tmp = _books_compat[from];
            _books_compat.remove_at (from);
            if (to > from) to--;
            _books_compat.insert (to, tmp);
            notify_property ("books"); notify_property ("tabs");
        }

        public bool file_open { get; set; }
        public string status_text { get; set; }
        public string? toast_message { get; set; }

        public bool history_navigation_in_progress {
            get { return current_ctx.history_navigation_in_progress; }
            set { current_ctx.history_navigation_in_progress = value; notify_property ("history-navigation-in-progress"); }
        }

        public uint open_generation { get; set; default = 0; }

        public void set_active (BookContext? ctx) {
            if (_active_ctx != null && _active_ctx != ctx) {
                _active_ctx.chm_file.close ();
            }
            _active_ctx = ctx;
            file_open = (ctx != null);
            notify_property ("active-book");
            notify_property ("current-book");
            notify_property ("chm-file");
            notify_property ("topics");
            notify_property ("index");
            notify_property ("history");
            notify_property ("search");
            notify_property ("viewer");
            notify_property ("history-navigation-in-progress");
            notify_property ("current-tab");
        }

        public void clear_active () {
            set_active (null);
        }

        public static string canon_open_key (string path) {
            return GLib.File.new_for_path (path).get_path () ?? path;
        }

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
            settings = new SettingsModel ();
            bookmarks = new BookmarkStore ();
            bookmarks.load (settings.bookmark_rows);
            if (bookmarks.prune (settings.bookmarks_expire_days)) settings.bookmark_rows = bookmarks.save ();
            per_books = new PerBookStore ();
            per_books.load (settings.per_book_rows);
            if (per_books.prune (settings.per_book_expire_days)) settings.per_book_rows = per_books.save ();

            viewer.font_size = settings.font_size;
            viewer.font_family = settings.font_family;
            viewer.fixed_font_family = settings.fixed_font_family;

            file_open = false;
            status_text = _("Ready");
        }

        public void bind_to (BookContext ctx) {
            _active_ctx = ctx;
        }

        public AppMessage to_app_message (AppMessage msg) {
            return msg;
        }

        public void show_toast (string message) {
            parent_dispatch (new ShowToastMessage (message));
        }
    }
}
