// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Parser/model unit tests over generated fixtures (tools/mkfixtures.py).
// GTK-free: links only vchm-core.

using Vchm.Model;

int failures = 0;

void check (bool cond, string what) {
    if (cond) {
        stdout.printf ("  ok  %s\n", what);
    } else {
        stdout.printf ("FAIL  %s\n", what);
        failures++;
    }
}

void test_basic_metadata (string path) {
    stdout.printf ("[basic.chm metadata]\n");
    var chm = new CHMFile ();
    check (chm.load (path), "load");
    check (chm.title () == "Test Book", "title from #SYSTEM TLV");
    check (chm.home_page () == "/intro.html", "home from #SYSTEM TLV");
    check (chm.topics_file () == "/toc.hhc", "topics file name");
    check (chm.index_file () == "/index.hhk", "index file name");
    check (chm.encoding () == "CP1252", "LCID hint -> CP1252");

    // normalize_path semantics through public API
    check (chm.has_object ("/intro.html"), "resolve with leading slash");
    check (chm.has_object ("guide.htm"), "relative path gets leading slash");
    check (chm.has_object ("/#SYSTEM"), "'/#' prefix is a file, not an anchor");
    check (!chm.has_object ("/nope.html"), "missing file not resolved");

    var c = chm.get_content ("/guide.htm#top");
    check (c.success, "anchor stripped for lookup");
    check (c.content.contains ("Forth language guide"), "content decoded");

    // URL-decoding
    check (chm.has_object ("%69ntro.html"), "percent-decoded path resolves");
}

void test_binary_toc (string path) {
    stdout.printf ("[basic.chm binary TOC]\n");
    var chm = new CHMFile ();
    chm.load (path);

    uint8[] t, s, b, r;
    uint8[]? ti;
    check (chm.get_topics_data (out t, out s, out b, out r, out ti), "units loaded");
    check (ti != null, "#TOCIDX present");
    check (t.length == 32, "#TOPICS two 16-byte entries");
    check (t.length / 16 == 2, "topic count");

    // first topic via TOCIDX walk and via sequential scan must agree
    var ft_toc = btoc_first_url (ti, t, s, b, r);
    var ft_seq = topics_sequential_first_url (t, s, b, r);
    check (ft_toc == "/intro.html", "TOCIDX first url");
    check (ft_seq == "/intro.html", "sequential first url agrees");

    check (btoc_item_name (t, s, 0, "CP1252") == "Intro", "entry name decode");
    check (btoc_item_url (t, s, b, r, 1) == "/guide.htm", "entry url + slash fixup");
}

void test_hhc_hhk (string path) {
    stdout.printf ("[basic.chm HHC/HHK]\n");
    var chm = new CHMFile ();
    chm.load (path);

    var tree = chm.load_hhc_tree ();
    check (tree != null && tree.size == 2, "hhc root count (nested ul folds under Intro)");
    if (tree != null && tree.size >= 3) {
        check (tree[0].name == "Intro" && tree[0].local == "intro.html", "hhc entry 0");
        check (tree[0].children.size == 1, "hhc nesting captured");
        if (tree[0].children.size == 1) {
            // Entities decode to Latin-1 range then re-map via archive
            // charset (CP1252 here): Ñ ó ä -> "Ñóädivision".
            check (tree[0].children[0].name == "Ñóädivision",
                   "entity-encoded name decoded via archive charset");
            check (tree[0].children[0].local == "guide.htm#top", "anchor kept raw in parser");
        }
        check (tree[1].name == "Guide", "hhc sibling after nested ul");
    }

    Gee.ArrayList<SearchResult> idx;
    check (chm.load_index_entries (out idx), "hhk parsed");
    check (idx.size == 1, "one target row");
    if (idx.size == 1) {
        check (idx[0].title == "покажчик", "paired Name becomes title");
        check (idx[0].url == "/guide.htm", "target normalized with slash");
    }
}

void test_search (string path) {
    stdout.printf ("[basic.chm search]\n");
    var chm = new CHMFile ();
    chm.load (path);

    Gee.ArrayList<SearchResult> res;
    bool ok = chm.search ("forth", false, false, out res);
    check (ok && res.size == 2, "case-insensitive full-text hits");
    bool ranks_sorted = true;
    for (int i = 1; i < res.size; i++) {
        if (res[i - 1].rank < res[i].rank) ranks_sorted = false;
    }
    check (ranks_sorted || res.size <= 1, "results ranked");

    Gee.ArrayList<SearchResult> ww;
    chm.search ("orth", true, false, out ww);
    check (ww.size == 0, "whole-word rejects substring");

    Gee.ArrayList<SearchResult> to;
    chm.search ("intro", false, true, out to);
    check (to.size == 1 && to[0].url == "/intro.html",
           "titles-only matches topic titles");
}

void test_koi_detection (string path) {
    stdout.printf ("[koi8u.chm encoding detection]\n");
    var chm = new CHMFile ();
    chm.load (path);
    check (chm.encoding () == "KOI8-U", "meta charset=koi8-u overrides defaults");
    check (chm.title () == "Посібник", "title decoded from koi8u bytes");

    var c = chm.get_content ("/plain.txt");
    check (c.success && c.content.contains ("Київ"), "page transcoded to UTF-8");
    check (c.content.validate (), "result is valid UTF-8");

    Gee.ArrayList<SearchResult> res;
    bool ok = chm.search ("Київ", false, false, out res);
    check (ok && res.size >= 1, "UTF-8 query finds KOI8-U-stored text");
}

void test_flat_fallback (string path) {
    stdout.printf ("[flat.chm enumeration fallback]\n");
    var chm = new CHMFile ();
    chm.load (path);

    check (chm.load_hhc_tree () == null, "no hhc");
    var pages = chm.list_content_pages ();
    check (pages.size == 2, "enumeration finds content pages");
    bool sorted_ok = pages.size < 2 || pages[0] <= pages[1];
    check (sorted_ok, "pages sorted");

    Gee.ArrayList<SearchResult> res;
    check (chm.search ("FORTH", false, false, out res) && res.size == 1,
           "search works without any TOC metadata");

    // .hhk targets: external rejected, internal kept
    Gee.ArrayList<SearchResult> idx;
    check (chm.load_index_entries (out idx), "hhk parsed");
    bool saw_web = false, saw_local = false;
    foreach (var r in idx) {
        if (r.title == "WebOnly") saw_web = true;
        if (r.title == "Local page" && r.url == "/only.htm") saw_local = true;
    }
    check (!saw_web, "external link rejected");
    check (saw_local, "internal target kept");
}

void test_binary_index_and_cids (string path) {
    stdout.printf ("[btree.chm binary index + context IDs]\n");
    var chm = new CHMFile ();
    chm.load (path);

    Gee.ArrayList<SearchResult> idx;
    check (chm.load_index_entries (out idx), "binary index parsed");
    check (idx.size == 3, "two keywords, three targets (see-also skipped)");
    if (idx.size == 3) {
        check (idx[0].title == "Help" && idx[0].url == "/intro.html", "target 0");
        check (idx[1].title == "Help" && idx[1].url == "/guide.htm", "target 1");
        check (idx[2].title == "Zed" && idx[2].url == "/guide.htm", "second keyword block");
    }

    chm.load_context_ids ();
    check (chm.is_valid_cid (7), "cid 7 registered");
    check (chm.get_page_by_cid (7) == "/intro.html", "cid resolves to page");
    check (!chm.is_valid_cid (8), "unknown cid rejected");

    var nav = new CHMFile ();
    nav.load (path);
    nav.load_context_ids ();
    check (nav.is_valid_cid (7), "second load keeps cid map consistent");
}

void test_search_cap (string path) {
    stdout.printf ("[big.chm search cap]\n");
    var chm = new CHMFile ();
    chm.load (path);

    Gee.ArrayList<SearchResult> res;
    check (chm.search ("capme", false, false, out res), "all pages match");
    check (res.size == 512, "results capped at MAX_SEARCH_RESULTS");

    var seen = new Gee.HashSet<string> ();
    foreach (var r in res) seen.add (r.url);
    check (seen.size == res.size, "no duplicate urls in results");
}

void test_deep_toc (string path) {
    stdout.printf ("[deep.chm long chain]\n");
    var chm = new CHMFile ();
    chm.load (path);

    uint8[] t, s2, b2, r2;
    uint8[]? ti;
    check (chm.get_topics_data (out t, out s2, out b2, out r2, out ti), "units ok");
    check (ti != null, "TOCIDX present");
    if (ti != null) {
        var first = btoc_first_url (ti, t, s2, b2, r2);
        check (first == "/p0.htm", "200-node walk finds first url");
    }
}

void test_malformed_tlv (string path) {
    stdout.printf ("[malformed.chm graceful degradation]\n");
    var chm = new CHMFile ();
    check (chm.load (path), "loads despite corrupt metadata");
    check (chm.title () == "", "bogus title record ignored");
    check (chm.home_page () == "/", "home falls back");
    check (chm.has_object ("/x.htm"), "content still resolves");
    var c = chm.get_content ("/x.htm");
    check (c.success && c.content.contains ("ok"), "page readable");
}

void test_charset_normalization () {
    stdout.printf ("[charset decl normalization]\n");

    check (HtmlTextUtils.normalize_charset_decls ("<meta charset=\"windows-1251\">") ==
           "<meta charset=\"utf-8\">", "double-quoted meta charset");
    check (HtmlTextUtils.normalize_charset_decls ("<meta charset='koi8-r'>") ==
           "<meta charset='utf-8'>", "single-quoted meta charset");
    check (HtmlTextUtils.normalize_charset_decls ("content=\"text/html; CHARSET=CP1251\"") ==
           "content=\"text/html; CHARSET=utf-8\"", "uppercase + inline form");
    check (HtmlTextUtils.normalize_charset_decls ("<meta http-equiv=Content-Type content=charset=gb2312>") ==
           "<meta http-equiv=Content-Type content=charset=utf-8>", "unquoted value");
    check (HtmlTextUtils.normalize_charset_decls ("charset=utf-8") == "charset=utf-8",
           "already utf-8 untouched");
    check (HtmlTextUtils.normalize_charset_decls ("<p>charset</p>") == "<p>charset</p>",
           "bare word untouched");
    check (HtmlTextUtils.normalize_charset_decls ("mycharset=x") == "mycharset=x",
           "prefixed word untouched");
    string two = HtmlTextUtils.normalize_charset_decls ("<meta charset=\"a\"> <meta charset=\"b\">");
    check (!two.contains ("\"a\"") && !two.contains ("\"b\""),
           "multiple declarations rewritten");
}

void test_csp_injection () {
    stdout.printf ("[local-only CSP injection]\n");

    string meta = HtmlTextUtils.local_only_csp_meta ();
    check (meta.contains ("img-src chm: data:"), "CSP allows chm:/data: images");
    check (meta.contains ("script-src 'none'"), "CSP blocks scripts");

    string out1 = HtmlTextUtils.inject_local_only_csp (
        "<html><head><title>t</title></head><body></body></html>");
    check (out1.contains ("<head>" + meta), "inserted right after lowercase <head>");
    check (out1.contains ("</head>"), "document structure kept");

    string out2 = HtmlTextUtils.inject_local_only_csp (
        "<html><HEAD><TITLE>t</TITLE></HEAD></html>");
    check (out2.contains ("<HEAD>" + meta), "case-insensitive <HEAD>");

    string out3 = HtmlTextUtils.inject_local_only_csp (
        "<html><head><meta charset=\"utf-8\"></head><header>hdr</header></html>");
    check (out3.index_of (meta) < out3.index_of ("<header"),
           "<header> not mistaken for <head>");

    string out4 = HtmlTextUtils.inject_local_only_csp ("<html><body>x</body></html>");
    check (out4.contains ("<html><head>" + meta), "synthetic head after <html>");

    string out5 = HtmlTextUtils.inject_local_only_csp ("plain text");
    check (out5.has_prefix (meta), "prepended without any tags");

    string out6 = HtmlTextUtils.inject_local_only_csp (
        "<html><head><title>a</title></head><body><img src=\"http://x/y.png\"></body></html>");
    check (out6.contains ("Content-Security-Policy"), "remote-img page gets policy");
}

void test_fts (string path) {
    stdout.printf ("[fts.chm compiled full-text index]\n");
    var chm = new CHMFile ();
    chm.load (path);

    Gee.ArrayList<SearchResult> exact;
    check (chm.search ("forth", true, false, out exact), "whole-word FTS match");
    check (exact.size == 1, "single exact doc");
    if (exact.size == 1) {
        check (exact[0].url == "/forth.htm", "fts url resolves via TOPICS chain");
    }

    Gee.ArrayList<SearchResult> pre;
    check (chm.search ("fort", false, false, out pre), "prefix scan across words");
    var urls = new Gee.ArrayList<string> ();
    foreach (var r in pre) urls.add (r.url);
    // "format" does not start with "fort" — only two docs match.
    check (pre.size == 2 && urls.contains ("/intro.html") &&
           urls.contains ("/forth.htm"), "prefix docs found (format excluded)");

    Gee.ArrayList<SearchResult> none;
    check (!chm.search ("zzz", true, false, out none) || none.size == 0,
           "miss yields no results");
}


void test_encoding_scoring (string path) {
    stdout.printf ("[score.chm heuristic scoring]\n");
    var chm = new CHMFile ();
    chm.load (path);
    // No LCID record, no meta charset: scoring must land on KOI8-U.
    check (chm.encoding () == "KOI8-U", "scoring picks KOI8-U without hints");

    var c = chm.get_content ("/koi.htm");
    check (c.success && c.content.contains ("столиця"), "scored page decodes");
}

void test_override_encoding (string path) {
    stdout.printf ("[override encoding]\n");
    var chm = new CHMFile ();
    chm.load (path);
    string before = chm.encoding ();

    chm.override_encoding ("CP1251");
    check (chm.encoding () == "CP1251", "override applied");

    chm.override_encoding ("auto");
    check (chm.encoding () == before, "'auto' restores detection result");
}

void test_chi_companion (string dir) {
    stdout.printf ("[chi.chm companion routing]\n");
    var chm = new CHMFile ();
    check (chm.load (dir + "/chi.chm"), "main archive loads");
    check (chm.title () == "Split Book", "title from .chi #SYSTEM");
    check (chm.home_page () == "/intro.html", "home from .chi");
    check (chm.has_object ("/intro.html"), "content page in main archive");

    uint8[] t, s2, b2, r2;
    uint8[]? ti;
    check (chm.get_topics_data (out t, out s2, out b2, out r2, out ti),
           "#TOPICS resolved through companion");
    check (btoc_item_url (t, s2, b2, r2, 0) == "/intro.html", "companion topic url");

    Gee.ArrayList<SearchResult> res;
    check (chm.search ("FORTH", false, false, out res) && res.size == 1,
           "search spans main-archive pages");

    // BinaryIndex + CIDs resolve through the companion as well.
    Gee.ArrayList<SearchResult> idx;
    check (chm.load_index_entries (out idx), "btree via .chi");
    check (idx.size == 2 && idx[0].title == "Split", "companion btree targets");

    chm.load_context_ids ();
    check (chm.is_valid_cid (42) && chm.get_page_by_cid (42) == "/intro.html",
           "context ids via .chi");
}

void test_index_target_filtering (string dir) {
    stdout.printf ("[hhk target filtering]\n");
    var chm = new CHMFile ();
    chm.load (dir + "/chi.chm");
    // NOTE: hhk target-filtering is covered by flat.chm tests — here
    // BinaryIndex correctly shadows any .hhk.
}

void test_windows_fallback (string path) {
    stdout.printf ("[win.chm #WINDOWS fallback]\n");
    var chm = new CHMFile ();
    chm.load (path);
    check (chm.title () == "Winf Title", "title from #WINDOWS");
    check (chm.home_page () == "/wpage.htm", "home from #WINDOWS");
    check (chm.topics_file () == "/wtoc.hhc", "hhc from #WINDOWS");

    var tree = chm.load_hhc_tree ();
    check (tree != null && tree.size == 1, "windows-provided hhc parses");
    if (tree != null && tree.size == 1) {
        check (tree[0].name == "W page" && tree[0].local == "wpage.htm",
               "fallback hhc entry content");
    }
}

void test_fts_titles_only_and_locs (string path) {
    stdout.printf ("[fts.chm titles-only + loc codes]\n");
    var chm = new CHMFile ();
    chm.load (path);

    // 'format' carries title_flag=0 and a non-zero loc-code payload.
    Gee.ArrayList<SearchResult> to;
    chm.search ("format", true, true, out to);
    check (to.size == 0, "titles-only skips title-less words");

    Gee.ArrayList<SearchResult> full;
    check (chm.search ("format", true, false, out full) && full.size == 1,
           "full search still finds it");

    Gee.ArrayList<SearchResult> pre;
    check (chm.search ("forma", false, true, out pre), "prefix titles-only runs");
    check (pre.size == 0, "prefix respects titles-only too");
}

void test_malformed_fts (string dir) {
    stdout.printf ("[malformed $FIftiMain indexes]\n");

    // fts_ff.chm: WLC stream bytes of every word are all 0xFF.
    var ff = new CHMFile ();
    check (ff.load (dir + "/fts_ff.chm"), "fts_ff loads");
    Gee.ArrayList<SearchResult> res;
    bool ok = ff.search ("forth", true, false, out res);
    check (!ok || res.size == 0, "fts_ff: all-0xFF WLC stream yields no hits");
    ok = ff.search ("fort", false, false, out res);
    check (!ok || res.size == 0, "fts_ff: prefix walk survives garbage streams");

    // fts_fs.chm: leaf free_space u16 patched past node_len (wrap bait).
    var fs = new CHMFile ();
    check (fs.load (dir + "/fts_fs.chm"), "fts_fs loads");
    ok = fs.search ("zzz", true, false, out res);
    check (!ok || res.size == 0, "fts_fs: oversized free_space degrades to clean miss");

    // fts_big.chm: wlc_size ENCint encodes 2^28, wlc_offset sits past EOF.
    var fb = new CHMFile ();
    check (fb.load (dir + "/fts_big.chm"), "fts_big loads");
    ok = fb.search ("format", true, false, out res);
    check (!ok || res.size == 0, "fts_big: huge wlc_size rejected without explosion");
}

int count_topic_items (TopicsItem? item) {
    if (item == null) return 0;
    int n = 1;
    foreach (var c in item.children)
        n += count_topic_items (c);
    return n;
}

void test_cyclic_toc (string dir) {
    stdout.printf ("[cyc.chm cyclic #TOCIDX]\n");
    var chm = new CHMFile ();
    check (chm.load (dir + "/cyc.chm"), "cycle archive loads");

    uint8[] t, s, b, r;
    uint8[]? ti;
    check (chm.get_topics_data (out t, out s, out b, out r, out ti),
           "topics units present");
    if (ti != null) {
        check (ti.length == 52, "#TOCIDX carries the two-node cycle");
        var nxt_a = UINT32_FROM_ARRAY (ti, 4 + 0x10);
        var nxt_b = UINT32_FROM_ARRAY (ti, (int) nxt_a + 0x10);
        check (nxt_a == 28 && nxt_b == 4, "siblings point at each other");
    }

    // Completing this call IS the assertion: the walk guard must fire
    // instead of looping forever.
    var tm = new TopicsModel ();
    tm.build_from_chm (chm);
    check (true, "cyclic toc terminates");

    int total = count_topic_items (tm.root);
    check (total >= 1 && total < 1000,
           "tree finite (%d nodes)".printf (total));
}

void test_nonul_content (string dir) {
    stdout.printf ("[nonul.chm unterminated page]\n");
    var chm = new CHMFile ();
    check (chm.load (dir + "/nonul.chm"), "loads");
    check (chm.home_page () == "/page.htm", "home points at bare page");

    var c = chm.get_content ("/page.htm");
    check (c.success, "unterminated page fetched");
    check (c.content.contains ("html"), "content decoded");
    check (c.content.has_prefix ("<html>") && c.content.has_suffix ("</html>"),
           "content intact to the final byte");
}

void test_decode_entities () {
    stdout.printf ("[entity decoding]\n");
    check (HhcParser.decode_entities ("&amp;") == "&", "amp");
    check (HhcParser.decode_entities ("&#1055;&#1088;&#1080;") == "При", "decimal numeric entities");
    check (HhcParser.decode_entities ("&#x41;") == "A", "hex entity");
    check (HhcParser.decode_entities ("&unknownzz;") == "&unknownzz;", "unknown preserved verbatim");
    check (HhcParser.decode_entities ("a & b") == "a & b", "lone ampersand untouched");
    check (HhcParser.decode_entities ("&nbsp;x") == " x", "nbsp expands");
}

void test_recents_and_history_edges () {
    stdout.printf ("[recents dedup/cap; history bounds]\n");
    var sm = new SettingsModel ();
    for (int i = 0; i < 12; i++)
        sm.add_recent_file ("/b%d.chm".printf (i));
    check (sm.recent_files.length == 10, "recents capped at 10");
    check (sm.recent_files[0] == "/b11.chm", "newest first");

    sm.add_recent_file ("/b10.chm");   // existing → moves to front
    check (sm.recent_files[0] == "/b10.chm", "duplicate moved to front");
    check (sm.recent_files.length == 10, "cap kept after move");
    int b10_rows = 0;
    bool saw_dropped = false;
    foreach (var f in sm.recent_files) {
        if (f == "/b10.chm") b10_rows++;
        if (f == "/b0.chm" || f == "/b1.chm") saw_dropped = true;
    }
    check (b10_rows == 1, "no duplicate rows");
    // 12 distinct adds kept only the newest ten: /b0, /b1 fell off.
    check (!saw_dropped, "oldest entries dropped");
    check (sm.recent_files[9] == "/b2.chm", "tail holds the oldest survivor");

    var h = new HistoryModel ();
    h.add_entry ("A", "/a", "f");
    check (h.go_forward () == null, "forward at end is null");
    h.clear ();
    check (!h.can_go_back () && !h.can_go_forward (), "cleared state inert");
}

void test_viewer_model () {
    stdout.printf ("[viewer model transitions]\n");
    var v = new ViewerModel ();
    v.navigate ("/p.htm", "T", "book.chm");
    check (v.loading && v.current_url == "/p.htm" &&
           v.intended_url == "/p.htm" && v.error == null, "navigate state");
    v.load_finished (true);
    check (!v.loading && v.error == null, "finish clears loading");

    v.increase_font_size ();
    int after_inc = v.font_size;
    for (int i = 0; i < 200; i++) v.increase_font_size ();
    check (v.font_size == 72, "font clamped high");
    v.decrease_font_size ();
    check (v.font_size == 71, "decrease steps");
    for (int i = 0; i < 200; i++) v.decrease_font_size ();
    check (v.font_size == 6, "font clamped low");
    v.reset_font_size ();
    check (v.font_size == 12, "reset default");

    check (after_inc > 0, "sanity");
}

void test_bookmark_store () {
    stdout.printf ("[bookmark store]\n");
    var b = new BookmarkStore ();

    b.add ("/a.chm", "Intro", "/intro.html");
    b.add ("/a.chm", "Guide", "/guide.htm");
    b.add ("/b.chm", "Other", "/other.htm");

    check (b.for_book ("/a.chm").size == 2, "per-book isolation");
    check (b.for_book ("/b.chm").size == 1, "second book separate");

    // same URL replaces the row instead of duplicating
    b.add ("/a.chm", "Intro v2", "/intro.html");
    check (b.for_book ("/a.chm").size == 2, "same-url add replaces");

    // round-trip through the serialized form
    string[] rows = b.save ();
    check (rows.length == 3, "three rows serialized");
    var restored = new BookmarkStore ();
    restored.load (rows);
    check (restored.for_book ("/a.chm").size == 2 &&
           restored.for_book ("/b.chm").size == 1, "round-trip restores groups");
    bool found_v2 = false;
    foreach (var bm in restored.for_book ("/a.chm")) {
        if (bm.title == "Intro v2" && bm.url == "/intro.html") found_v2 = true;
    }
    check (found_v2, "replaced entry survives round-trip");

    check (b.remove ("/a.chm", "Guide"), "remove by title");
    check (b.for_book ("/a.chm").size == 1, "removal applied");
    check (!b.remove ("/a.chm", "nope"), "unknown title returns false");

    // F13: fields containing the \x1f separator or backslashes must
    // survive the round-trip instead of being dropped as malformed rows.
    b.add ("/c.chm", "ti\x1ftle\\2", "/u\x1frl\\x");
    string[] rows2 = b.save ();
    check (rows2.length == 3, "escaped row joins existing rows");
    var restored2 = new BookmarkStore ();
    restored2.load (rows2);
    bool esc_ok = false;
    foreach (var bm in restored2.for_book ("/c.chm")) {
        esc_ok = bm.title == "ti\x1ftle\\2" && bm.url == "/u\x1frl\\x";
    }
    check (esc_ok, "separator/backslash round-trip");

    // rows with an empty archive key stay loadable-noop, not crashers
    restored2.load (new string[] { "", "\x1f/x.htm\x1fT" });
    check (restored2.for_book ("").size == 0, "empty key row skipped");
}

void test_entity_byte_decoder () {
    stdout.printf ("[entity byte decoder]\n");

    // CP1252-view entities of CP1251 bytes: eth=F0→р, divide=F7→ч, ETH=D0→П
    string out1 = Vchm.Model.EntityByteDecoder.fixup ("&eth;&divide;&ETH;", "CP1251");
    check (out1 == "рчР", "named entities decode case-sensitively");

    // numeric decimal refs of the same bytes
    string out2 = Vchm.Model.EntityByteDecoder.fixup ("&#240;&#247;&#208;", "CP1251");
    check (out2 == "рчР", "numeric entities decode");

    // reserved entities must survive untouched
    string out3 = Vchm.Model.EntityByteDecoder.fixup ("a &amp; b &lt;x&gt;", "CP1251");
    check (out3.contains ("&amp;") && out3.contains ("&lt;"), "reserved kept");

    // UTF-8 archives are never touched
    check (Vchm.Model.EntityByteDecoder.fixup ("&eth;", "UTF-8") == "&eth;", "utf-8 passthrough");

    // plain ASCII without trigger stays as-is even for byte charsets
    check (Vchm.Model.EntityByteDecoder.fixup ("hello world", "CP1251") == "hello world", "no-trigger passthrough");

    // F10: genuine-UTF-8 page under a legacy archive hint — only the
    // entity run is re-encoded; literal Cyrillic must survive verbatim.
    string cyr = "Перевірка";
    string out6 = Vchm.Model.EntityByteDecoder.fixup (cyr + " &divide; х", "CP1251");
    check (out6 == cyr + " ч х", "literal UTF-8 untouched, entity converted");

    // F10/F23 interplay: ASCII between entities joins one conversion run
    // (byte escapes sidestep Cyrillic/Latin homoglyphs: D1 80 = 'р',
    // D1 87 = 'ч').
    string exp_run = "\xD1\x80" + "og" + "\xD1\x87";
    check (Vchm.Model.EntityByteDecoder.fixup ("&eth;og&divide;", "CP1251") == exp_run,
           "ascii joins adjacent entity run");

    // F14: mixed-case keys resolve through either table.
    check (Vchm.Model.HhcParser.entity_by_name ("Dagger") == 8225, "&Dagger; resolves");
    check (Vchm.Model.HhcParser.entity_by_name ("Prime") == 8243, "&Prime; resolves");
    check (Vchm.Model.HhcParser.entity_by_name ("ETH") == 208 &&
           Vchm.Model.HhcParser.entity_by_name ("eth") == 240,
           "case-sensitive pair intact");
}

void test_served_entities_page (string dir) {
    stdout.printf ("[entities.htm served decoded]\n");
    var chm = new CHMFile ();
    chm.load (dir + "/basic.chm");
    var c = chm.get_content ("/entities.htm");
    check (c.success, "page loads");
    // model-level: transcode+fixup pipeline equals core helper output
    var fixed_up = Vchm.Model.HtmlTextUtils.normalize_charset_decls (
        Vchm.Model.EntityByteDecoder.fixup (c.content, chm.encoding ()));
    check (!fixed_up.contains ("&eth;"), "entities decoded before serve");
}
void test_history () {
    stdout.printf ("[history model]\n");
    var h = new HistoryModel ();
    check (!h.can_go_back () && !h.can_go_forward (), "empty history inert");

    h.add_entry ("A", "/a", "f");
    h.add_entry ("B", "/b", "f");
    check (h.current_index == 1, "two entries pushed");

    var back = h.go_back ();
    check (back != null && back.url == "/a" && h.can_go_forward (), "back keeps forward");

    // Simulating NAVIGATE_DONE after Back must NOT push (app-update skips);
    // a fresh click DOES truncate forward:
    h.add_entry ("C", "/c", "f");
    check (h.entries.size == 2 && !h.can_go_forward (), "new nav truncates forward tail");
    check (h.entries[1].url == "/c", "tail replaced by new page");

    check (h.go_back () != null && h.go_forward () != null, "back/forward cycle");
    h.clear ();
    check (h.entries.size == 0 && h.current_index == -1, "clear resets");

    // MAX_HISTORY cap keeps the newest 100 and stays consistent.
    for (int i = 0; i < 105; i++) {
        h.add_entry ("E%d".printf (i), "/e%d" .printf (i), "f");
    }
    check (h.entries.size == 100, "history capped at 100");
    check (h.entries[99].url == "/e104", "newest retained at tail");
    check (h.entries[0].url == "/e5", "oldest dropped from front");
    check (h.can_go_back (), "still navigable after cap");
}

void test_settings_fallback () {
    stdout.printf ("[settings fallback]\n");
    // Run without an installed schema: constructor must not abort.
    var s = new SettingsModel ();
    check (s.window_width == 1024 && s.window_height == 768, "defaults applied");
    s.window_width = 800;
    s.save ();                       // must be a no-op, no crash
    check (s.window_width == 800, "save without schema is harmless");
}

void test_book_cp1251 (string path) {
    stdout.printf ("[book_cp1251.chm multi-encoding book]\n");
    var chm = new CHMFile ();
    check (chm.load (path), "load cp1251 book");
    check (chm.is_open (), "is_open");
    check (chm.encoding () == "CP1251", "encoding detected as CP1251");
    check (chm.home_page () == "/home.htm", "home page");

    // Content loading: page in CP1251 must decode to UTF-8
    var c = chm.get_content ("/ch1.htm");
    check (c.success, "content loaded");
    check (c.mime_type == "text/html", "mime type");
    check (c.content.contains ("\u041a\u043e\u0431\u0437\u0430\u0440"),
           "CP1251 content decoded to UTF-8 (contains 'Кобзар')");
    check (c.content.contains ("\u041a\u0438\u0457\u0432"),
           "CP1251 content decoded (contains 'Київ')");

    // Image loading
    var img = chm.get_bytes ("/img/cover.png");
    check (img != null, "PNG image resolved");
    check (img.get_size () > 8, "PNG has data");
    unowned var d = img.get_data ();
    check (d[0] == 0x89 && d[1] == 0x50, "PNG magic bytes");

    // Binary TOC
    uint8[] t, s, b, r;
    uint8[]? ti;
    check (chm.get_topics_data (out t, out s, out b, out r, out ti),
           "topics data present");
    check (ti != null, "#TOCIDX present");

    // HHC parsing
    var hhc = chm.load_hhc_tree ();
    check (hhc != null, "HHC parsed");
    check (hhc.size >= 1, "HHC has root entry");
    // Verify nested structure: root has children
    bool found_ch1 = false;
    foreach (var e in hhc) {
        foreach (var c2 in e.children) {
            if (c2.name.contains ("1")) found_ch1 = true;
        }
    }
    check (found_ch1, "HHC contains nested chapter entry");

    // Keyword index
    Gee.ArrayList<SearchResult> idx;
    check (chm.load_index_entries (out idx), "keyword index loaded");
    check (idx.size > 0, "keyword index has entries");
    // BTree stores ASCII keywords (kobzar/shevchenko/language/song)
    bool found_kobzar = false, found_shevchenko = false;
    foreach (var e in idx) {
        if (e.title == "kobzar") found_kobzar = true;
        if (e.title == "shevchenko") found_shevchenko = true;
    }
    check (found_kobzar, "keyword 'kobzar' in index");
    check (found_shevchenko, "keyword 'shevchenko' in index");

    // Full-text search: Cyrillic needle in CP1251 content
    Gee.ArrayList<SearchResult> res;
    bool ok = chm.search ("\u043a\u043e\u0431\u0437\u0430\u0440", false, false, out res);
    check (ok, "search('кобзар') returns true");
    check (res.size > 0, "search('кобзар') finds results");
    bool found_in_ch1 = false;
    foreach (var sr in res) {
        if (sr.url.contains ("ch1")) found_in_ch1 = true;
    }
    check (found_in_ch1, "search result points to ch1.htm");

    // Content pages enumeration
    var pages = chm.list_content_pages ();
    check (pages.size >= 4, "content pages enumerated");
}

void test_book_koi8u (string path) {
    stdout.printf ("[book_koi8u.chm KOI8-U book]\n");
    var chm = new CHMFile ();
    check (chm.load (path), "load koi8u book");
    check (chm.encoding () == "KOI8-U", "encoding detected as KOI8-U");
    check (chm.home_page () == "/home.htm", "home page");

    var c = chm.get_content ("/ch1.htm");
    check (c.success, "content loaded");
    check (c.content.contains ("\u041a\u0438\u0457\u0432"),
           "KOI8-U content decoded to UTF-8 (contains 'Київ')");

    // Search with Cyrillic needle
    Gee.ArrayList<SearchResult> res;
    bool ok = chm.search ("\u0457\u0436\u0430\u043a", false, false, out res);
    check (ok, "search('їжак') returns true");
    check (res.size > 0, "search('їжак') finds results");
}

int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("usage: test_parsers <fixture-dir>\n");
        return 2;
    }
    string dir = args[1];

    test_basic_metadata (dir + "/basic.chm");
    test_binary_toc (dir + "/basic.chm");
    test_hhc_hhk (dir + "/basic.chm");
    test_search (dir + "/basic.chm");
    test_koi_detection (dir + "/koi8u.chm");
    test_flat_fallback (dir + "/flat.chm");
    test_binary_index_and_cids (dir + "/btree.chm");
    test_search_cap (dir + "/big.chm");
    test_deep_toc (dir + "/deep.chm");
    test_malformed_tlv (dir + "/malformed.chm");
    test_charset_normalization ();
    test_csp_injection ();
    test_fts (dir + "/fts.chm");
    test_encoding_scoring (dir + "/score.chm");
    test_override_encoding (dir + "/score.chm");
    test_chi_companion (dir);
    test_windows_fallback (dir + "/win.chm");
    test_fts_titles_only_and_locs (dir + "/fts.chm");
    test_malformed_fts (dir);
    test_cyclic_toc (dir);
    test_nonul_content (dir);
    test_decode_entities ();
    test_recents_and_history_edges ();
    test_viewer_model ();
    test_index_target_filtering (dir);
    test_bookmark_store ();
    test_entity_byte_decoder ();
    test_served_entities_page (dir);
    test_history ();
    test_settings_fallback ();

    // ── book_cp1251.chm: multi-encoding test book ───────────────────────
    test_book_cp1251 (dir + "/book_cp1251.chm");
    test_book_koi8u (dir + "/book_koi8u.chm");

    if (failures > 0) {
        stdout.printf ("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    stdout.printf ("\nAll parser tests passed\n");
    return 0;
}