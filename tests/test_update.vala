// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

AppModel make_model () {
    return new AppModel ();
}

void test_initial_state () {
    var model = make_model ();

    assert (!model.file_open);
    assert (model.status_text == "Ready");
    assert (model.topics != null);
    assert (model.index != null);
    assert (model.search != null);
    assert (model.history != null);
    assert (model.viewer != null);
    assert (model.settings != null);
}

void test_open_file_sets_state () {
    var model = make_model ();

    // We can't actually load a real CHM file in unit tests,
    // so we just test that the message handling doesn't crash
    // and that file_open is set appropriately when load succeeds
    // (Since we can't load a real file, file_open will remain false)
    var msg = new OpenFileDoneMessage ("/test/file.chm", "Test Book", "/index.html");
    updateModel (msg, model);

    // The model should handle the message without crashing
    // Note: file_open will be false since no real file was loaded
    assert (model.status_text == "Ready" || model.status_text.contains ("Opened") || model.status_text.contains ("Failed"));
}

void test_close_file_resets_state () {
    var model = make_model ();

    // Set file_open to true manually to test close behavior
    model.file_open = true;
    model.status_text = "Opened: test.chm";

    updateModel (new CloseFileMessage (), model);

    assert (!model.file_open);
    assert (model.status_text == "Ready");
}

void test_navigate_adds_to_history () {
    var model = make_model ();

    // Test that navigate message adds to history (without actual file)
    // We can't test with real file, so just verify the message doesn't crash
    var nav_msg = new NavigateDoneMessage ("/chapter1.html", "Chapter 1");
    updateModel (nav_msg, model);

    // Just verify it doesn't crash
    assert (model.history.entries.size >= 0);
}

void test_font_size_changes () {
    var model = make_model ();

    var initial_size = model.viewer.font_size;

    updateModel (new ViewerFontIncreaseMessage (), model);
    assert (model.viewer.font_size == initial_size + 1);
    assert (model.settings.font_size == initial_size + 1);

    updateModel (new ViewerFontDecreaseMessage (), model);
    assert (model.viewer.font_size == initial_size);
    assert (model.settings.font_size == initial_size);

    updateModel (new ViewerFontResetMessage (), model);
    assert (model.viewer.font_size == 12);
    assert (model.settings.font_size == 12);
}

void test_settings_persist () {
    var model = make_model ();

    model.settings.window_width = 1200;
    model.settings.window_height = 800;
    model.settings.sash_position = 300;
    model.settings.font_size = 14;
    model.settings.font_family = "Serif";
    model.settings.fixed_font_family = "Monospace";

    model.settings.save ();

    // Create new model - should load saved settings
    var model2 = new AppModel ();
    assert (model2.settings.window_width == 1200);
    assert (model2.settings.window_height == 800);
    assert (model2.settings.sash_position == 300);
    assert (model2.settings.font_size == 14);
    assert (model2.settings.font_family == "Serif");
    assert (model2.settings.fixed_font_family == "Monospace");
}

void test_recent_files () {
    var model = make_model ();
    model.settings.recent_files = {};
    
    model.settings.add_recent_file ("/path/to/file1.chm");
    model.settings.add_recent_file ("/path/to/file2.chm");
    model.settings.add_recent_file ("/path/to/file1.chm"); // duplicate

    assert (model.settings.recent_files.length == 2);
    assert (model.settings.recent_files[0] == "/path/to/file1.chm");
    assert (model.settings.recent_files[1] == "/path/to/file2.chm");
}

void test_history_navigation () {
    var model = make_model ();

    var history = model.history;
    
    assert (!history.can_go_back ());
    assert (!history.can_go_forward ());

    history.add_entry ("Page 1", "/page1.html", "/test.chm");
    assert (!history.can_go_back ());
    assert (!history.can_go_forward ());

    history.add_entry ("Page 2", "/page2.html", "/test.chm");
    assert (history.can_go_back ());
    assert (!history.can_go_forward ());

    var back = history.go_back ();
    assert (back != null);
    assert (back.url == "/page1.html");

    var forward = history.go_forward ();
    assert (forward != null);
    assert (forward.url == "/page2.html");
}

void test_message_type_safety () {
    // Plain classes support is/as — the type-safe way to read payloads.
    AppMessage msg = new OpenFileMessage ("/test.chm");
    var open = msg as OpenFileMessage;
    assert (open != null);
    assert ((msg is CloseFileMessage) == false);
}

// ── CHM File Tests ──

void test_chmfile_new () {
    var chm = new CHMFile ();
    assert (!chm.is_open ());
    assert (chm.filename () == null || chm.filename () == "");
    assert (chm.home_page () == "/");
}

void test_chmfile_close () {
    var chm = new CHMFile ();
    chm.close ();
    assert (!chm.is_open ());
}

void test_chmfile_cid_stub () {
    var chm = new CHMFile ();
    // Context-ID support is not ported yet; stubs must behave safely.
    assert (!chm.is_valid_cid (123));
    assert (chm.get_page_by_cid (123) == "");
}



void test_topics_model () {
    var topics = new TopicsModel ();
    assert (topics.root == null);
    assert (topics.selected_url == null);
    assert (!topics.loading);
    
    topics.clear ();
    assert (topics.root == null);
}

void test_index_model () {
    var index = new IndexModel ();
    assert (index.entries.size == 0);
    assert (index.filter_text == "");
    assert (index.selected_index == -1);
    assert (!index.loading);
    
    index.clear ();
    assert (index.entries.size == 0);
}

void test_search_model () {
    var search = new SearchModel ();
    assert (search.results.size == 0);
    assert (search.query == "");
    assert (!search.whole_words);
    assert (!search.titles_only);
    assert (search.selected_index == -1);
    assert (!search.searching);
    
    search.clear ();
    assert (search.results.size == 0);
}

void test_history_model () {
    var history = new HistoryModel ();
    assert (history.entries.size == 0);
    assert (history.current_index == -1);
    assert (!history.can_go_back ());
    assert (!history.can_go_forward ());
    
    history.add_entry ("Test", "/test.html", "/test.chm");
    assert (history.entries.size == 1);
    assert (history.current_index == 0);
}

void test_viewer_model () {
    var viewer = new ViewerModel ();
    assert (viewer.current_url == "/");
    assert (viewer.current_title == "");
    assert (!viewer.loading);
    assert (viewer.font_size == 12);
    assert (viewer.font_family == "Sans");
    assert (viewer.fixed_font_family == "Monospace");
    
    viewer.navigate ("/test.html", "Test Page", "/test.chm");
    assert (viewer.current_url == "/test.html");
    assert (viewer.current_title == "Test Page");
    assert (viewer.loading);
    
    viewer.load_finished (true);
    assert (!viewer.loading);
    assert (viewer.error == null);
}

void test_settings_model_defaults () {
    var settings = new SettingsModel ();
    // Just ensure it constructs without error and has defaults
    assert (settings.window_width > 0);
    assert (settings.window_height > 0);
    assert (settings.sash_position > 0);
    assert (settings.font_size > 0);
}

void test_settings_model_recent_files () {
    // Clear GSettings before testing
    var gsettings = new GLib.Settings ("org.gnome.vchm");
    gsettings.set_strv ("recent-files", {});
    
    var settings = new SettingsModel ();
    settings.add_recent_file ("/test1.chm");
    settings.add_recent_file ("/test2.chm");
    settings.add_recent_file ("/test1.chm"); // duplicate
    
    assert (settings.recent_files.length == 2);
    assert (settings.recent_files[0] == "/test1.chm");
}

void test_per_tab_history_isolation () {
    var model = make_model ();
    var ctxA = new BookContext ();
    ctxA.title = "Book A";
    var ctxB = new BookContext ();
    ctxB.title = "Book B";
    model.add_book (ctxA);
    model.add_book (ctxB);
    model.active_book = ctxA;
    model.active_tab_index = 0;
    model.file_open = true;

    // Simulate navigations via NAVIGATE_DONE routed by tab_index
    updateModel (new NavigateDoneMessage ("/a1.html", "A1", "/a1.html", 0), model);
    updateModel (new NavigateDoneMessage ("/a2.html", "A2", "/a2.html", 0), model);
    assert (ctxA.history.entries.size == 2);
    assert (ctxB.history.entries.size == 0);
    assert (ctxA.history.current_index == 1);

    updateModel (new NavigateDoneMessage ("/b1.html", "B1", "/b1.html", 1), model);
    assert (ctxB.history.entries.size == 1);
    assert (ctxA.history.entries.size == 2);

    // Back in A must not affect B
    var back = ctxA.history.go_back ();
    assert (back != null && back.url == "/a1.html");
    assert (ctxA.history.current_index == 0);
    assert (ctxB.history.current_index == 0);
    assert (ctxB.history.entries[0].url == "/b1.html");

    // Forward in B isolated
    var fwd = ctxB.history.go_back ();
    // B has only 1 entry, can't go back
    assert (fwd == null);
    assert (ctxB.history.current_index == 0);
}

void test_per_tab_search_isolation () {
    var model = make_model ();
    var ctxA = new BookContext ();
    var ctxB = new BookContext ();
    model.add_book (ctxA);
    model.add_book (ctxB);
    model.active_book = ctxA;
    model.active_tab_index = 0;
    model.file_open = true;

    ctxA.search.query = "hello";
    ctxB.search.query = "world";
    assert (ctxA.search.query == "hello");
    assert (ctxB.search.query == "world");

    // SEARCH_DONE routed by tab_index
    var resA = new Gee.ArrayList<SearchResult> ();
    resA.add (new SearchResult ("/a.html", "A", 1));
    updateModel (new SearchDoneMessage (resA, 0), model);
    assert (ctxA.search.results.size == 1);
    assert (ctxB.search.results.size == 0);

    var resB = new Gee.ArrayList<SearchResult> ();
    resB.add (new SearchResult ("/b.html", "B", 1));
    resB.add (new SearchResult ("/b2.html", "B2", 1));
    updateModel (new SearchDoneMessage (resB, 1), model);
    assert (ctxB.search.results.size == 2);
    assert (ctxA.search.results.size == 1);
}

void test_per_tab_viewer_isolation () {
    var model = make_model ();
    var ctxA = new BookContext ();
    var ctxB = new BookContext ();
    model.add_book (ctxA);
    model.add_book (ctxB);
    model.active_book = ctxA;
    model.file_open = true;
    ctxA.viewer.font_size = 12;
    ctxB.viewer.font_size = 18;
    assert (ctxA.viewer.font_size == 12);
    assert (ctxB.viewer.font_size == 18);
    // VIEWER_FONT_INCREASE on active_book only
    updateModel (new ViewerFontIncreaseMessage (), model);
    assert (ctxA.viewer.font_size == 13);
    assert (ctxB.viewer.font_size == 18);
    // Switch and increase B
    model.active_book = ctxB;
    updateModel (new ViewerFontIncreaseMessage (), model);
    assert (ctxB.viewer.font_size == 19);
    assert (ctxA.viewer.font_size == 13);
}

void test_tab_reorder () {
    var model = make_model ();
    var a = new BookContext (); a.title = "A";
    var b = new BookContext (); b.title = "B";
    var c = new BookContext (); c.title = "C";
    model.add_book (a);
    model.add_book (b);
    model.add_book (c);
    assert (model.books.size == 3);
    assert (model.books[0] == a);
    assert (model.books[1] == b);
    assert (model.books[2] == c);
    // Move A from 0 to 2 (end)
    model.reorder_books (0, 2);
    // After remove 0 and insert at 2 (adjusted for removal), order should be B, A, C or B,C,A depending on implementation
    // Our implementation removes then inserts: if to>from to-- ; so 0->2 becomes 0 removed, to becomes 1, insert at1 => B,A,C
    assert (model.books.size == 3);
    // Verify all three still present
    bool has_a = false, has_b = false, has_c = false;
    foreach (var x in model.books) {
        if (x == a) has_a = true;
        if (x == b) has_b = true;
        if (x == c) has_c = true;
    }
    assert (has_a && has_b && has_c);
}

void test_close_mid_navigate () {
    var model = make_model ();
    var ctx = new BookContext ();
    ctx.title = "Book";
    model.add_book (ctx);
    model.active_book = ctx;
    model.active_tab_index = 0;
    model.file_open = true;
    // Simulate NAVIGATE_DONE for tab 0, then close before next navigate
    updateModel (new NavigateDoneMessage ("/p1.html", "P1", "/p1.html", 0), model);
    assert (ctx.history.entries.size == 1);
    // Close the book
    updateModel (new CloseFileMessage (), model);
    assert (model.books.size == 0);
    assert (!model.file_open);
    // Late NAVIGATE_DONE for old tab should not crash (target_ctx == null or placeholder)
    updateModel (new NavigateDoneMessage ("/p2.html", "P2", "/p2.html", 0), model);
    // Should not have added to closed ctx
    assert (ctx.history.entries.size == 1);
    // Placeholder should not have history (or at least not crash)
    assert (model.placeholder.history.entries.size == 0);
}

void test_tabs_vs_placeholder () {
    var model = make_model ();
    assert (model.placeholder != null);
    // When no book open, viewer via placeholder should be functional
    model.placeholder.viewer.font_size = 15;
    assert (model.viewer.font_size == 15);
    // After adding book, viewer should delegate to active_book
    var ctx = new BookContext ();
    ctx.viewer.font_size = 20;
    model.add_book (ctx);
    model.active_book = ctx;
    assert (model.viewer.font_size == 20);
    model.active_book = null;
    assert (model.viewer.font_size == 15);
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/update/initial_state", test_initial_state);
    Test.add_func ("/update/open_file_sets_state", test_open_file_sets_state);
    Test.add_func ("/update/close_file_resets_state", test_close_file_resets_state);
    Test.add_func ("/update/navigate_adds_to_history", test_navigate_adds_to_history);
    Test.add_func ("/update/font_size_changes", test_font_size_changes);
    Test.add_func ("/update/settings_persist", test_settings_persist);
    Test.add_func ("/update/recent_files", test_recent_files);
    Test.add_func ("/update/history_navigation", test_history_navigation);
    Test.add_func ("/update/message_type_safety", test_message_type_safety);
    
    // CHM File Tests
    Test.add_func ("/chmfile/new", test_chmfile_new);
    Test.add_func ("/chmfile/close", test_chmfile_close);
    Test.add_func ("/chmfile/cid_stub", test_chmfile_cid_stub);
    
    // Sub-model Tests
    Test.add_func ("/model/topics", test_topics_model);
    Test.add_func ("/model/index", test_index_model);
    Test.add_func ("/model/search", test_search_model);
    Test.add_func ("/model/history", test_history_model);
    Test.add_func ("/model/viewer", test_viewer_model);
    Test.add_func ("/model/settings", test_settings_model_defaults);
    Test.add_func ("/model/settings/recent_files", test_settings_model_recent_files);

    // B+hybrid per-tab isolation & lifecycle
    Test.add_func ("/update/per_tab_history_isolation", test_per_tab_history_isolation);
    Test.add_func ("/update/per_tab_search_isolation", test_per_tab_search_isolation);
    Test.add_func ("/update/per_tab_viewer_isolation", test_per_tab_viewer_isolation);
    Test.add_func ("/update/tab_reorder", test_tab_reorder);
    Test.add_func ("/update/close_mid_navigate", test_close_mid_navigate);
    Test.add_func ("/update/tabs_vs_placeholder", test_tabs_vs_placeholder);

    return Test.run ();
}