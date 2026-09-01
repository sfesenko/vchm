// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

namespace Vchm.Model {

    // Main application model containing all sub-models
    // One opened archive with everything derived from it. Lives at
    // namespace scope so messages can carry it between worker and UI.
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
        // B+hybrid TabModel: each BookContext owns its sub-models (chm_file,
        // topics, index, history, search, viewer). AppModel owns the list
        // of tabs and the active_book pointer. A single placeholder
        // BookContext backs the proxy getters when no book is open (initial
        // window, last tab closed). This replaces the old separate
        // _scratch_* slots and makes TabModel the owner; proxy getters just
        // delegate to current_ctx for compat during migration (new code
        // should use model.active_book.* explicitly).
        private BookContext? _active_ctx = null;
        private BookContext _placeholder = new BookContext ();
        public BookContext placeholder { get { return _placeholder; } }
        public BookContext current_ctx { get { return _active_ctx ?? _placeholder; } }
        public CHMFile chm_file {
            get { return current_ctx.chm_file; }
            set { current_ctx.chm_file = value; }
        }
        public TopicsModel topics {
            get { return current_ctx.topics; }
            set { current_ctx.topics = value; }
        }
        public IndexModel index {
            get { return current_ctx.index; }
            set { current_ctx.index = value; }
        }
        public HistoryModel history {
            get { return current_ctx.history; }
            set { current_ctx.history = value; }
        }
        public SearchModel search {
            get { return current_ctx.search; }
            private set { current_ctx.search = value; }
        }
        // Per-tab viewer (per BookContext). Proxy delegates to current_ctx.
        public ViewerModel viewer {
            get { return current_ctx.viewer; }
            set { current_ctx.viewer = value; }
        }
        public SettingsModel settings { get; private set; }
        public BookmarkStore bookmarks { get; private set; }
        public PerBookStore per_books { get; private set; }

        // All opened books; [0] mirrors the "active" pointers below.
        // B+hybrid: tabs is the hierarchical collection; books kept as alias for compat.
        private Gee.ArrayList<BookContext> _books = new Gee.ArrayList<BookContext> ();
        public Gee.ArrayList<BookContext> books {
            get { return _books; }
            set { _books = value; notify_property ("books"); notify_property ("tabs"); }
        }
        public Gee.ArrayList<BookContext> tabs {
            get { return _books; }
        }
        public BookContext? active_book {
            get { return _active_ctx; }
            set {
                if (_active_ctx == value) return;
                _active_ctx = value;
                // Keep active_tab_index in sync with active_book
                if (value != null) {
                    int idx = _books.index_of (value);
                    if (idx >= 0 && idx != _active_tab_index) {
                        _active_tab_index = idx;
                        notify_property ("active-tab-index");
                    }
                }
                // Notify proxy properties whose getter changes with active_book
                notify_property ("active-book");
                notify_property ("chm-file");
                notify_property ("topics");
                notify_property ("index");
                notify_property ("history");
                notify_property ("search");
                notify_property ("viewer");
                notify_property ("history-navigation-in-progress");
                notify_property ("current-tab");
            }
        }
        public BookContext? current_tab {
            owned get {
                if (_active_tab_index >= 0 && _active_tab_index < _books.size) return _books[_active_tab_index];
                return _active_ctx;
            }
        }
        private int _active_tab_index = -1;
        // Index of the currently active tab in AppView.tabs[]. Set
        // by AppView.activate_tab_idx. Read by app-update when
        // dispatching NAVIGATE so the resulting NavigateMessage
        // carries the correct tab_index — the worker snapshot still
        // uses the shared model.chm_file (which the proxy routes to
        // the active tab), but the tab_index lets NAVIGATE_DONE
        // route its writes to the right tab even if the user has
        // switched tabs in the meantime.
        public int active_tab_index {
            get { return _active_tab_index; }
            set {
                if (_active_tab_index == value) return;
                _active_tab_index = value;
                // Sync active_book to match index without recursion
                if (value >= 0 && value < _books.size) {
                    var b = _books[value];
                    if (_active_ctx != b) {
                        _active_ctx = b;
                        notify_property ("active-book");
                        notify_property ("chm-file");
                        notify_property ("topics");
                        notify_property ("index");
                        notify_property ("history");
                        notify_property ("search");
                        notify_property ("viewer");
                        notify_property ("history-navigation-in-progress");
                        notify_property ("current-tab");
                    }
                }
                notify_property ("active-tab-index");
                notify_property ("current-tab");
            }
        }

        // B+hybrid helpers that keep notify in sync
        public void add_book (BookContext ctx) {
            _books.add (ctx);
            notify_property ("books");
            notify_property ("tabs");
        }
        public void insert_book (int idx, BookContext ctx) {
            _books.insert (idx, ctx);
            notify_property ("books");
            notify_property ("tabs");
        }
        public void remove_book_at (int idx) {
            _books.remove_at (idx);
            notify_property ("books");
            notify_property ("tabs");
        }
        public void clear_books () {
            _books.clear ();
            notify_property ("books");
            notify_property ("tabs");
        }
        public void reorder_books (int from, int to) {
            if (from < 0 || from >= _books.size || to < 0 || to > _books.size) return;
            var tmp = _books[from];
            _books.remove_at (from);
            if (to > from) to--;
            _books.insert (to, tmp);
            notify_property ("books");
            notify_property ("tabs");
        }

    // BookContext lives inside AppModel scope for message carrying.

        // UI state
        public bool file_open { get; set; }
        public string status_text { get; set; }
        public string? toast_message { get; set; }

        // Set while a back/forward navigation is in flight so NAVIGATE_DONE
        // does not push a duplicate entry and truncate forward history.
        // Proxied to active BookContext; with strict single-tab-per-file
        // global would work, but per-book is correct for clones.
        public bool history_navigation_in_progress {
            get { return current_ctx.history_navigation_in_progress; }
            set { current_ctx.history_navigation_in_progress = value; }
        }

        // OPEN_FILE serialization (F26 follow-up): two concurrent open
        // workers raced on model.books / model.viewer / tabs[].url and
        // left the first tab blank. We now run at most one OPEN_FILE
        // worker at a time across all paths; further opens are deferred
        // to a Timeout that re-dispatches once the current worker calls
        // release_open. Keyed by path so duplicate OPEN_FILE messages
        // for the same book coalesce (a user double-clicking in the file
        // dialog should not open the same book twice).
        private GLib.Mutex _open_mutex = GLib.Mutex ();
        // Set of paths with an open currently in flight (worker running
        // or OPEN_FILE message queued). Single worker is enforced by
        // checking against _any_in_flight, but the per-path set lets us
        // coalesce duplicate messages for the same book.
        private Gee.HashSet<string> _open_in_flight =
            new Gee.HashSet<string> ();
        private bool _any_open_in_flight = false;

        private string canon_open_key (string path) {
            return GLib.File.new_for_path (path).get_path () ?? path;
        }

        private Gee.ArrayQueue<string> _open_queue = new Gee.ArrayQueue<string> ();

        // Returns true if no other OPEN_FILE is running and no other
        // OPEN_FILE is queued for the same path. Marks both flags so
        // the next OPEN_FILE for any path is deferred.
        public bool try_acquire_open (string path) {
            string k = canon_open_key (path);
            _open_mutex.lock ();
            try {
                if (_any_open_in_flight) return false;
                if (_open_in_flight.contains (k)) return false;
                _open_in_flight.add (k);
                _any_open_in_flight = true;
                return true;
            } finally {
                _open_mutex.unlock ();
            }
        }

        public void enqueue_open (string path) {
            string k = canon_open_key (path);
            _open_mutex.lock ();
            try {
                if (_open_in_flight.contains (k)) return;
                if (_open_queue.contains (k)) return;
                _open_queue.offer (k);
            } finally {
                _open_mutex.unlock ();
            }
        }

        public void release_open (string path) {
            string k = canon_open_key (path);
            _open_mutex.lock ();
            try {
                _open_in_flight.remove (k);
                _any_open_in_flight = false;
            } finally {
                _open_mutex.unlock ();
            }
        }

        // Release current slot and if queued paths remain, acquire the next
        // one atomically and return it (caller should dispatch it).
        public bool release_and_dequeue_next (string path, out string? next) {
            string k = canon_open_key (path);
            _open_mutex.lock ();
            try {
                _open_in_flight.remove (k);
                if (!_open_queue.is_empty) {
                    next = _open_queue.poll ();
                    _open_in_flight.add (next);
                    _any_open_in_flight = true;
                    return true;
                }
                _any_open_in_flight = false;
                next = null;
                return false;
            } finally {
                _open_mutex.unlock ();
            }
        }

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
            // placeholder already has defaults; no separate scratch init needed
            settings = new SettingsModel ();
            bookmarks = new BookmarkStore ();
            bookmarks.load (settings.bookmark_rows);
            if (bookmarks.prune (settings.bookmarks_expire_days)) settings.bookmark_rows = bookmarks.save ();
            per_books = new PerBookStore ();
            per_books.load (settings.per_book_rows);
            if (per_books.prune (settings.per_book_expire_days)) settings.per_book_rows = per_books.save ();

            // Apply saved viewer settings
            viewer.font_size = settings.font_size;
            viewer.font_family = settings.font_family;
            viewer.fixed_font_family = settings.fixed_font_family;

            file_open = false;
            status_text = _("Ready");
        }

        // Flush the scratch sub-models into a BookContext (called by
        // AppView when binding a book to a tab). Idempotent.
        public void bind_to (BookContext ctx) {
            _active_ctx = ctx;
            // The scratch slots are kept in sync via the proxy
            // accessors; explicit flush is a no-op now.
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