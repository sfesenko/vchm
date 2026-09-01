// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // ── Discriminator enum (drives the switch dispatch) ──
    // Keep the enum entries in sync with the message classes below.
    public enum AppMessageKind {
        // File operations
        OPEN_FILE,
        OPEN_FILE_DONE,
        OPEN_FILE_FAILED,
        CLOSE_FILE,
        RECENT_FILE_ACTIVATED,

        // Navigation
        NAVIGATE,
        NAVIGATE_DONE,
        NAVIGATE_FAILED,
        GO_BACK,
        GO_FORWARD,
        GO_HOME,
        CONTEXT_ID_NAVIGATE,

        // UI - Side panels
        TOGGLE_TOPICS_PANEL,
        TOGGLE_INDEX_PANEL,
        TOGGLE_SEARCH_PANEL,
        TOGGLE_BOOKMARKS_PANEL,
        SET_ACTIVE_SIDE_PANEL,
        SET_SASH_POSITION,

        // Topics tree
        TOPICS_SELECTION_CHANGED,
        TOPICS_ITEM_EXPANDED,
        TOPICS_ITEM_COLLAPSED,

        // Index
        INDEX_FILTER_CHANGED,
        INDEX_SELECTION_CHANGED,
        INDEX_NEXT,
        INDEX_PREV,

        // Panels
        PANELS_REBUILT,

        // Search
        SEARCH_QUERY_CHANGED,
        SEARCH_EXECUTE,
        SEARCH_DONE,
        SEARCH_SELECTION_CHANGED,
        SEARCH_NEXT,
        SEARCH_PREV,
        SEARCH_OPTIONS_CHANGED,

        // Viewer
        VIEWER_FONT_INCREASE,
        VIEWER_FONT_DECREASE,
        VIEWER_FONT_RESET,
        VIEWER_FONT_CHANGED,
        VIEWER_FIND,
        VIEWER_FIND_NEXT,
        VIEWER_FIND_PREV,
        VIEWER_FIND_COUNT,
        VIEWER_PRINT,
        VIEWER_COPY,

        // History
        HISTORY_CLEAR,
        SET_ENCODING,
        BOOKMARK_ADD,
        BOOKMARK_REMOVE,
        BOOKMARK_RENAME,
        BOOKMARK_JUMP,
        BOOKMARKS_CHANGED,
        OPEN_IN_NEW_TAB,

        // Tab lifecycle
        TAB_ACTIVATED,
        NEXT_TAB,
        PREV_TAB,

        // Link hover
        LINK_HOVERED,

        // Window
        WINDOW_STATE_CHANGED,
        WINDOW_MAXIMIZED_CHANGED,

        // Toast/Notifications
        SHOW_TOAST,

        // Application
        APP_QUIT,
        APP_QUIT_INTERNAL,
        ABOUT_DIALOG,
        PREFERENCES_DIALOG,

        SET_PER_BOOK_EXPIRE,
        SET_BOOKMARKS_EXPIRE,
    }

    // ── Base class ──
    public abstract class AppMessage {
        public abstract AppMessageKind kind { get; }
    }

    // ── File operations ──
    public class OpenFileMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.OPEN_FILE; } }
        public string path { get; private set; }
        public int? context_id { get; private set; }
        public OpenFileMessage (string path, int? context_id = null) {
            this.path = path;
            this.context_id = context_id;
        }
    }

    public class OpenFileDoneMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.OPEN_FILE_DONE; } }
        public string path { get; private set; }
        public string title { get; private set; }
        public string home_page { get; private set; }
        public BookContext ctx { get; private set; }
        public OpenFileDoneMessage (string path, string title, string home_page, BookContext? ctx = null) {
            this.path = path;
            this.title = title;
            this.home_page = home_page;
            this.ctx = ctx;
        }
    }

    public class OpenFileFailedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.OPEN_FILE_FAILED; } }
        public string path { get; private set; }
        public string error { get; private set; }
        public OpenFileFailedMessage (string path, string error) {
            this.path = path;
            this.error = error;
        }
    }

    public class CloseFileMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.CLOSE_FILE; } }
    }

    public class RecentFileActivatedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.RECENT_FILE_ACTIVATED; } }
        public string path { get; private set; }
        public RecentFileActivatedMessage (string path) { this.path = path; }
    }

    // ── Navigation ──
    public class NavigateMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.NAVIGATE; } }
        public string url { get; private set; }
        public string? title { get; private set; }
        // Which tab this navigation belongs to. The worker runs off
        // the main thread; without tab_index the NAVIGATE_DONE
        // handler writes to whichever tab is currently active in
        // the shared model, which may be a different one if the user
        // switched tabs mid-load (F26 follow-up).
        public int tab_index { get; private set; }
        public NavigateMessage (string url, string? title = null, int tab_index = -1) {
            this.url = url;
            this.title = title;
            this.tab_index = tab_index;
        }
    }

    public class NavigateDoneMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.NAVIGATE_DONE; } }
        public string url { get; private set; }
        public string title { get; private set; }
        // Original NAVIGATE target this result belongs to. The single
        // model.intended_url slot races when a second navigation starts
        // before the first worker reports back (review F7).
        public string intended_url { get; private set; }
        public int tab_index { get; private set; }
        public NavigateDoneMessage (string url, string title, string? intended_url = null, int tab_index = -1) {
            this.url = url;
            this.title = title;
            this.intended_url = intended_url ?? url;
            this.tab_index = tab_index;
        }
    }

    public class NavigateFailedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.NAVIGATE_FAILED; } }
        public string url { get; private set; }
        public string error { get; private set; }
        public NavigateFailedMessage (string url, string error) {
            this.url = url;
            this.error = error;
        }
    }

    public class GoBackMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.GO_BACK; } }
    }

    public class GoForwardMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.GO_FORWARD; } }
    }

    public class GoHomeMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.GO_HOME; } }
    }

    public class ContextIdNavigateMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.CONTEXT_ID_NAVIGATE; } }
        public int context_id { get; private set; }
        public ContextIdNavigateMessage (int context_id) { this.context_id = context_id; }
    }

    // ── Side panels ──
    public class ToggleTopicsPanelMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOGGLE_TOPICS_PANEL; } }
    }

    public class ToggleIndexPanelMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOGGLE_INDEX_PANEL; } }
    }

    public class ToggleSearchPanelMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOGGLE_SEARCH_PANEL; } }
    }

    public class ToggleBookmarksPanelMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOGGLE_BOOKMARKS_PANEL; } }
    }

    public class SetActiveSidePanelMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SET_ACTIVE_SIDE_PANEL; } }
        public int panel { get; private set; } // 0=topics, 1=index, 2=search
        public SetActiveSidePanelMessage (int panel) { this.panel = panel; }
    }

    public class SetSashPositionMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SET_SASH_POSITION; } }
        public int position { get; private set; }
        public SetSashPositionMessage (int position) { this.position = position; }
    }

    // ── Topics tree ──
    public class TopicsSelectionChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOPICS_SELECTION_CHANGED; } }
        public string url { get; private set; }
        public TopicsSelectionChangedMessage (string url) { this.url = url; }
    }

    public class TopicsItemExpandedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOPICS_ITEM_EXPANDED; } }
        public string url { get; private set; }
        public TopicsItemExpandedMessage (string url) { this.url = url; }
    }

    public class TopicsItemCollapsedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TOPICS_ITEM_COLLAPSED; } }
        public string url { get; private set; }
        public TopicsItemCollapsedMessage (string url) { this.url = url; }
    }

    // ── Index ──
    public class IndexFilterChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.INDEX_FILTER_CHANGED; } }
        public string filter { get; private set; }
        public IndexFilterChangedMessage (string filter) { this.filter = filter; }
    }

    public class IndexSelectionChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.INDEX_SELECTION_CHANGED; } }
        public string url { get; private set; }
        public IndexSelectionChangedMessage (string url) { this.url = url; }
    }

    public class IndexNextMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.INDEX_NEXT; } }
    }

    public class IndexPrevMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.INDEX_PREV; } }
    }

    // ── Panels ──
    public class PanelsRebuiltMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.PANELS_REBUILT; } }
        public TopicsModel topics { get; private set; }
        public IndexModel index { get; private set; }
        public int tab_index { get; private set; }
        public PanelsRebuiltMessage (TopicsModel topics, IndexModel index, int tab_index = -1) {
            this.topics = topics;
            this.index = index;
            this.tab_index = tab_index;
        }
    }

    // ── Search ──
    public class SearchQueryChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_QUERY_CHANGED; } }
        public string query { get; private set; }
        public SearchQueryChangedMessage (string query) { this.query = query; }
    }

    public class SearchExecuteMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_EXECUTE; } }
    }

    public class SearchDoneMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_DONE; } }
        public Gee.ArrayList<SearchResult> results { get; private set; }
        public int tab_index { get; private set; }
        public SearchDoneMessage (Gee.ArrayList<SearchResult> results, int tab_index = -1) {
            this.results = results;
            this.tab_index = tab_index;
        }
    }

    public class SearchSelectionChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_SELECTION_CHANGED; } }
        public string url { get; private set; }
        public SearchSelectionChangedMessage (string url) { this.url = url; }
    }

    public class SearchNextMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_NEXT; } }
    }

    public class SearchPrevMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_PREV; } }
    }

    public class SearchOptionsChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SEARCH_OPTIONS_CHANGED; } }
        public bool whole_words { get; private set; }
        public bool titles_only { get; private set; }
        public SearchOptionsChangedMessage (bool whole_words, bool titles_only) {
            this.whole_words = whole_words;
            this.titles_only = titles_only;
        }
    }

    // ── Viewer ──
    public class ViewerFontIncreaseMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FONT_INCREASE; } }
    }

    public class ViewerFontDecreaseMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FONT_DECREASE; } }
    }

    public class ViewerFontResetMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FONT_RESET; } }
    }

    public class ViewerFontChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FONT_CHANGED; } }
        public int size { get; private set; }
        public string family { get; private set; }
        public string fixed_family { get; private set; }
        public ViewerFontChangedMessage (int size, string family, string fixed_family) {
            this.size = size;
            this.family = family;
            this.fixed_family = fixed_family;
        }
    }

    public class ViewerFindMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FIND; } }
        public string text { get; private set; }
        public bool case_sensitive { get; private set; }
        public ViewerFindMessage (string text, bool case_sensitive = false) {
            this.text = text;
            this.case_sensitive = case_sensitive;
        }
    }

    public class ViewerFindNextMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FIND_NEXT; } }
    }

    public class ViewerFindPrevMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FIND_PREV; } }
    }

    public class BookmarkAddMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.BOOKMARK_ADD; } }
    }

    public class BookmarkRemoveMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.BOOKMARK_REMOVE; } }
        public string title { get; private set; }
        public string url { get; private set; }
        public BookmarkRemoveMessage (string title, string? url = null) {
            this.title = title;
            this.url = url ?? "";
        }
    }

    public class BookmarkRenameMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.BOOKMARK_RENAME; } }
        public string url { get; private set; }
        public string new_title { get; private set; }
        public BookmarkRenameMessage (string url, string new_title) {
            this.url = url;
            this.new_title = new_title;
        }
    }

    public class BookmarksChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.BOOKMARKS_CHANGED; } }
    }

    public class BookmarkJumpMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.BOOKMARK_JUMP; } }
        public string url { get; private set; }
        public BookmarkJumpMessage (string url) { this.url = url; }
    }

    public class OpenInNewTabMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.OPEN_IN_NEW_TAB; } }
        public string url { get; private set; }
        public OpenInNewTabMessage (string url) { this.url = url; }
    }

    public class TabActivatedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.TAB_ACTIVATED; } }
        public int tab_index { get; private set; }
        public string book_path { get; private set; }
        public TabActivatedMessage (int tab_index, string book_path) {
            this.tab_index = tab_index;
            this.book_path = book_path;
        }
    }

    public class NextTabMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.NEXT_TAB; } }
    }

    public class PrevTabMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.PREV_TAB; } }
    }

    public class LinkHoveredMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.LINK_HOVERED; } }
        public string? url { get; private set; }
        public LinkHoveredMessage (string? url) { this.url = url; }
    }

    public class SetEncodingMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SET_ENCODING; } }
        public string encoding { get; private set; }
        public SetEncodingMessage (string encoding) { this.encoding = encoding; }
    }

    public class ViewerCopyMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_COPY; } }
    }

    public class ViewerPrintMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_PRINT; } }
    }

    public class ViewerFindCountMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.VIEWER_FIND_COUNT; } }
        public uint match_count { get; private set; }
        public ViewerFindCountMessage (uint match_count) { this.match_count = match_count; }
    }

    // ── History ──
    public class HistoryClearMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.HISTORY_CLEAR; } }
    }

    // ── Window ──
    public class WindowStateChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.WINDOW_STATE_CHANGED; } }
        public int width { get; private set; }
        public int height { get; private set; }
        public WindowStateChangedMessage (int width, int height) {
            this.width = width; this.height = height;
        }
    }

    public class WindowMaximizedChangedMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.WINDOW_MAXIMIZED_CHANGED; } }
        public bool maximized { get; private set; }
        public WindowMaximizedChangedMessage (bool maximized) { this.maximized = maximized; }
    }

    // ── Application ──
    public class QuitMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.APP_QUIT_INTERNAL; } }
        public int width { get; private set; }
        public int height { get; private set; }
        public bool maximized { get; private set; }
        public QuitMessage (int width, int height, bool maximized) {
            this.width = width; this.height = height; this.maximized = maximized;
        }
    }

    public class AboutDialogMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.ABOUT_DIALOG; } }
    }

    public class PreferencesDialogMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.PREFERENCES_DIALOG; } }
    }

    public class ShowToastMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SHOW_TOAST; } }
        public string message { get; private set; }
        public ShowToastMessage (string message) { this.message = message; }
    }

    public class SetPerBookExpireMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SET_PER_BOOK_EXPIRE; } }
        public int days { get; private set; }
        public SetPerBookExpireMessage (int days) { this.days = days; }
    }

    public class SetBookmarksExpireMessage : AppMessage {
        public override AppMessageKind kind { get { return AppMessageKind.SET_BOOKMARKS_EXPIRE; } }
        public int days { get; private set; }
        public SetBookmarksExpireMessage (int days) { this.days = days; }
    }
}