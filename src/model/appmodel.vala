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
        public SearchModel search = new SearchModel ();
        public ViewerModel viewer = new ViewerModel ();
        public string title = "";
        public string home = "/";
        public bool history_navigation_in_progress = false;
    }

    public class AppModel : Object {
        // Sub-models. These were shared pointer-swapped slots; Phase 2
        // makes them proxy to whichever tab is currently active. The
        // active tab is owned by AppView (a GTK layer), so we go
        // through a delegate that AppView sets in build_ui.
        //
        // Proxy accessors (chm_file, topics, index, history, viewer,
        // search) read from the active tab; writes go to a scratch
        // slot that the view flushes on tab activation. The scratch
        // pattern keeps the existing view/update code working while
        // the real per-tab state lives in DocumentTab.
        private BookContext? _active_ctx = null;
        public CHMFile chm_file {
            get { return _active_ctx != null ? _active_ctx.chm_file : _scratch_chm; }
            set { if (_active_ctx != null) _active_ctx.chm_file = value; else _scratch_chm = value; }
        }
        public TopicsModel topics {
            get { return _active_ctx != null ? _active_ctx.topics : _scratch_topics; }
            set { if (_active_ctx != null) _active_ctx.topics = value; else _scratch_topics = value; }
        }
        public IndexModel index {
            get { return _active_ctx != null ? _active_ctx.index : _scratch_index; }
            set { if (_active_ctx != null) _active_ctx.index = value; else _scratch_index = value; }
        }
        public HistoryModel history {
            get { return _active_ctx != null ? _active_ctx.history : _scratch_history; }
            set { if (_active_ctx != null) _active_ctx.history = value; else _scratch_history = value; }
        }
        public SearchModel search {
            get { return _active_ctx != null ? _active_ctx.search : _scratch_search; }
            private set { if (_active_ctx != null) _active_ctx.search = value; else _scratch_search = value; }
        }
        private SearchModel _scratch_search = new SearchModel ();
        // Per-tab viewer (per BookContext). Proxy so NAVIGATE/NAVIGATE_DONE
        // writes target the correct book even if the user switches tabs
        // mid-load (M2/M3). Scratch holds the placeholder tab's viewer.
        public ViewerModel viewer {
            get { return _active_ctx != null ? _active_ctx.viewer : _scratch_viewer; }
            set { if (_active_ctx != null) _active_ctx.viewer = value; else _scratch_viewer = value; }
        }
        private ViewerModel _scratch_viewer = new ViewerModel ();
        public SettingsModel settings { get; private set; }
        public BookmarkStore bookmarks { get; private set; }
        public PerBookStore per_books { get; private set; }

        // Scratch slots used during a model update; the view flushes
        // them into the active tab on tab activation. Keeping the
        // scratch makes the existing chm_file/topics/index/history
        // pointer-swap pattern in OPEN_FILE_DONE transparent.
        private CHMFile _scratch_chm = new CHMFile ();
        private TopicsModel _scratch_topics = new TopicsModel ();
        private IndexModel _scratch_index = new IndexModel ();
        private HistoryModel _scratch_history = new HistoryModel ();

        // All opened books; [0] mirrors the "active" pointers below.
        public Gee.ArrayList<BookContext> books =
            new Gee.ArrayList<BookContext> ();
        public BookContext? active_book {
            get { return _active_ctx; }
            set { _active_ctx = value; }
        }

        // Index of the currently active tab in AppView.tabs[]. Set
        // by AppView.activate_tab_idx. Read by app-update when
        // dispatching NAVIGATE so the resulting NavigateMessage
        // carries the correct tab_index — the worker snapshot still
        // uses the shared model.chm_file (which the proxy routes to
        // the active tab), but the tab_index lets NAVIGATE_DONE
        // route its writes to the right tab even if the user has
        // switched tabs in the meantime.
        public int active_tab_index { get; set; }

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
            get { return _active_ctx != null ? _active_ctx.history_navigation_in_progress : _scratch_history_in_progress; }
            set { if (_active_ctx != null) _active_ctx.history_navigation_in_progress = value; else _scratch_history_in_progress = value; }
        }
        private bool _scratch_history_in_progress = false;

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
            chm_file = _scratch_chm;
            topics = _scratch_topics;
            index = _scratch_index;
            search = new SearchModel ();
            history = _scratch_history;
            viewer = _scratch_viewer;
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
            status_text = "Ready";
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