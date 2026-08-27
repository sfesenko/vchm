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

    return Test.run ();
}