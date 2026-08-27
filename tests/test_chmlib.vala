// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

// Regression coverage for the chmlib wrapper layer: asserts the load /
// metadata / content pipeline against tests/fixtures/basic.chm (review
// F17 — the previous version only printed diagnostics and returned 0).

using ChmLib;
using GLib;
using Vchm.Model;

string fixture_path;

void test_load () {
    var chm = new CHMFile ();
    assert_true (chm.load (fixture_path));
    assert_true (chm.is_open ());
    assert_true (chm.filename () == fixture_path);
}

void test_metadata () {
    var chm = new CHMFile ();
    assert_true (chm.load (fixture_path));
    // basic.chm carries #SYSTEM records: title "Test Book", home intro.html.
    assert_cmpstr (chm.title (), EQ, "Test Book");
    assert_cmpstr (chm.home_page (), EQ, "/intro.html");
}

void test_resolve_content () {
    var chm = new CHMFile ();
    assert_true (chm.load (fixture_path));
    assert_true (chm.has_object ("/intro.html"));
    assert_false (chm.has_object ("/no-such-page.htm"));

    var bytes = chm.get_bytes ("/intro.html");
    assert_true (bytes != null);
    assert_true (bytes.get_size () > 0);
    assert_true (((string) bytes.get_data ()).contains ("Intro"));

    var content = chm.get_content ("/guide.htm");
    assert_true (content.success);
    assert_cmpstr (content.mime_type, EQ, "text/html");

    assert_null (chm.get_bytes ("/no-such-page.htm"));
    assert_false (chm.get_content ("/no-such-page.htm").success);
}

void test_topics_data () {
    var chm = new CHMFile ();
    assert_true (chm.load (fixture_path));

    uint8[] topics, strings, urltbl, urlstr;
    uint8[]? topidx;
    assert_true (chm.get_topics_data (out topics, out strings,
                                      out urltbl, out urlstr, out topidx));
    // Two #TOPICS entries of 16 bytes each.
    assert_cmpuint ((uint) topics.length, GE, 32);
    assert_true (strings.length > 0);
    assert_true (urltbl.length > 0);
    assert_true (urlstr.length > 0);
    assert_true (topidx != null);
    // get_topics_data() computes the first topic URL from the same data.
    assert_cmpstr (chm.get_first_topic_url (), EQ, "/intro.html");

    // Internal metadata units resolve through raw chmlib too.
    var file = chm_open (fixture_path);
    assert_true (file != null);
    UnitInfoStruct ui;
    assert_cmpint (chm_resolve_object (file, "/#SYSTEM", out ui), EQ,
                   ChmLib.RESOLVE_SUCCESS);
    assert_cmpuint ((uint) ui.length, GE, 5);
    uint8[] buf = new uint8[ui.length];
    assert_cmpint ((int) chm_retrieve_object (file, &ui, buf, 0, (long) ui.length),
                   GT, 0);
    chm_close (file);
}

void test_close_is_idempotent () {
    var chm = new CHMFile ();
    assert_true (chm.load (fixture_path));
    chm.close ();
    assert_false (chm.is_open ());
    assert_false (chm.has_object ("/intro.html"));
    chm.close ();   // double-close must not crash
    assert_false (chm.is_open ());
}

int main (string[] args) {
    Test.init (ref args);
    fixture_path = args.length > 1 ? args[1]
                                   : Path.build_filename ("tests", "fixtures", "basic.chm");

    Test.add_func ("/chmlib/load", test_load);
    Test.add_func ("/chmlib/metadata", test_metadata);
    Test.add_func ("/chmlib/resolve_content", test_resolve_content);
    Test.add_func ("/chmlib/topics_data", test_topics_data);
    Test.add_func ("/chmlib/close_is_idempotent", test_close_is_idempotent);

    return Test.run ();
}
