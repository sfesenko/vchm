void test_error_domain () {
    var e = new Itsf.Error.INTERNAL ("boom");
    assert (e.code == Itsf.Error.INTERNAL);
    // valac 0.56 generates no Itsf.Error.quark() binding; compare against
    // the C quark string registered by itsf_error_quark() instead.
    assert (e.domain == GLib.Quark.from_string ("itsf-error-quark"));
}

private delegate void ArchiveAction (Itsf.Archive arc) throws Error;

private string fixture_dir () {
    return GLib.Environment.get_variable ("FIXTURES_DIR") ?? "builddir/tests";
}

// Runs `action` with an opened archive, driving the async open to completion.
private void with_fixture (string name, ArchiveAction action) {
    var loop = new GLib.MainLoop ();
    Itsf.Archive.open.begin (GLib.File.new_for_path (
        Path.build_filename (fixture_dir (), name)), (o, r) => {
        try {
            action (Itsf.Archive.open.end (r));
        } catch (Error e) {
            Test.message ("open threw: %s", e.message);
            Test.fail ();
        }
        loop.quit ();
    });
    loop.run ();
}

private bool array_has (string[] arr, string needle) {
    foreach (var s in arr) if (s == needle) return true;
    return false;
}

void test_open_fixture_and_list () {
    with_fixture ("basic.chm", (arc) => {
        var entries = arc.list ();
        assert (entries.length > 0);
        // Public content pages (see tools/mkfixtures.py basic.chm recipe).
        assert_true (arc.contains ("/toc.hhc"));
        assert_true (arc.contains ("/index.hhk"));
        assert_true (arc.contains ("/guide.htm"));
        assert_true (arc.contains ("/intro.html"));
        // Internal streams excluded from list() but still resolvable.
        assert_false (array_has (entries, "/#SYSTEM"));
        assert_false (array_has (entries, "/::DataSpace/Storage/MSCompressed/Content"));
        assert_false (array_has (entries, "::DataSpace/Storage/MSCompressed/Content"));
        assert_true (arc.contains ("/#SYSTEM"));
        assert_true (arc.contains ("::DataSpace/Storage/MSCompressed/Content"));
        // Missing paths resolve cleanly, not via throw.
        assert_false (arc.contains ("/nope-missing.htm"));
        assert (arc.uncompressed_size ("/nope-missing.htm") == 0);
        assert (arc.uncompressed_size ("/intro.html") > 0);
        arc.close ();
    });
}

void test_multiblock_index_walk () {
    // big.chm uses a PMGI root (depth 2); every leaf must be reachable.
    with_fixture ("big.chm", (arc) => {
        var entries = arc.list ();
        assert (entries.length == 601);
        assert_true (arc.contains ("/p0000.htm"));
        assert_true (arc.contains ("/p0600.htm"));
        assert (arc.uncompressed_size ("/p0600.htm") > 0);
        arc.close ();
    });
}

private void expect_open_throws (string path) {
    var loop = new GLib.MainLoop ();
    bool threw = false;
    Itsf.Archive.open.begin (GLib.File.new_for_path (path), (o, r) => {
        try {
            Itsf.Archive.open.end (r).close ();
        } catch (Itsf.Error e) {
            threw = true;
        }
        loop.quit ();
    });
    loop.run ();
    assert_true (threw);
}

void test_open_rejects_non_chm () {
    try {
        var junk = Path.build_filename (GLib.DirUtils.make_tmp ("itsf-XXXXXX"), "junk.chm");
        FileUtils.set_contents (junk, "this is not a chm archive");
        expect_open_throws (junk);                                  // Review Focus 5
    } catch (Error e) {
        Test.message ("setup threw: %s", e.message);
        Test.fail ();
    }
}

void test_truncated_header () {
    try {
        var short_f = Path.build_filename (GLib.DirUtils.make_tmp ("itsf-XXXXXX"), "short.chm");
        FileUtils.set_contents (short_f, "ITSF\x03\x00\x00\x00");   // magic + version only
        expect_open_throws (short_f);                               // Review Focus 5
    } catch (Error e) {
        Test.message ("setup threw: %s", e.message);
        Test.fail ();
    }
}

void test_cyclic_directory () {
    // cyc.chm cycles /#TOCIDX *content* nodes (mkfixtures.py main_malformed):
    // the directory itself is valid, so open succeeds and terminates.
    with_fixture ("cyc.chm", (arc) => {
        assert (arc.list ().length > 0);
        arc.close ();
    });
}

// Open must throw precisely Itsf.Error.INVALID_INDEX (nothing else passes).
private void expect_invalid_index (string name) {
    var loop = new GLib.MainLoop ();
    bool ok = false;
    Itsf.Archive.open.begin (GLib.File.new_for_path (
        Path.build_filename (fixture_dir (), name)), (o, r) => {
        try {
            Itsf.Archive.open.end (r).close ();
            Test.message ("%s opened; expected INVALID_INDEX", name);
            Test.fail ();
        } catch (Itsf.Error e) {
            if (e.code == Itsf.Error.INVALID_INDEX)
                ok = true;
            else {
                Test.message ("%s threw %s, expected INVALID_INDEX", name, e.message);
                Test.fail ();
            }
        }
        loop.quit ();
    });
    loop.run ();
    assert_true (ok);
}

void test_dir_cword_overflow () {
    // 11 continuation bytes in the first name-length cword.
    expect_invalid_index ("dir_cword_overflow.chm");
}

void test_dir_truncated_name () {
    // Name length claims bytes past the entry body.
    expect_invalid_index ("dir_trunc.chm");
}

void test_dir_bad_free_space () {
    // PMGL free-space field exceeds the block.
    expect_invalid_index ("dir_badfree.chm");
}

void test_dir_offset_past_eof () {
    // ITSF dir_offset points outside the file.
    expect_invalid_index ("dir_badoff.chm");
}

void test_dir_self_cycle_terminates () {
    // PMGL leaf whose next pointer is itself: the visited-set must
    // terminate the walk; open succeeds with the entries.
    with_fixture ("dir_selfcycle.chm", (arc) => {
        assert (arc.list ().length > 0);
        arc.close ();
    });
}

void test_malformed_directory () {
    // malformed.chm corrupts the /#SYSTEM *TLV body*, not the directory,
    // so open must succeed (directory-level corruption is dir_* above).
    with_fixture ("malformed.chm", (arc) => {
        assert (arc.list ().length > 0);
        arc.close ();
    });
}

void test_read_home () {
    with_fixture ("basic.chm", (arc) => {
        var bytes = arc.read ("/intro.html");
        assert (bytes.get_size () == arc.uncompressed_size ("/intro.html"));
        assert (bytes.get_size () > 0);
        arc.close ();
    });
}

void test_read_range_system_skip () {
    // Mirrors chmfile.vala:419: skip the 4-byte /#SYSTEM version header.
    with_fixture ("basic.chm", (arc) => {
        var full = arc.read ("/#SYSTEM");
        var size = arc.uncompressed_size ("/#SYSTEM");
        var part = arc.read_range ("/#SYSTEM", 4, size - 4);
        assert (part.get_size () == size - 4);
        unowned uint8[] fdata = full.get_data ();
        unowned uint8[] pdata = part.get_data ();
        for (uint64 i = 0; i + 4 < size; i++)
            assert (pdata[i] == fdata[i + 4]);
        arc.close ();
    });
}

void test_read_range_past_end () {
    with_fixture ("basic.chm", (arc) => {                   // Review Focus 4
        var size = arc.uncompressed_size ("/intro.html");
        var empty = arc.read_range ("/intro.html", size + 100, 10);
        assert (empty.get_size () == 0);
        var zero = arc.read_range ("/intro.html", 0, 0);
        assert (zero.get_size () == 0);
        arc.close ();
    });
}

void test_read_missing_throws () {
    with_fixture ("basic.chm", (arc) => {
        bool threw = false;
        try { arc.read ("/no-such-page.htm"); }
        catch (Itsf.Error e) { threw = true; }
        assert_true (threw);
        arc.close ();
    });
}

// --- LZX bit reader + Huffman tables (MS-PATCH 2.1.1: 16-bit LE words,
// MSB first). Vectors machine-generated by tools/mklzx.py.

private uint32 must_read (Itsf.Lzx.BitReader br, int n) {
    try {
        return br.read_bits (n);
    } catch (Error e) {
        Test.message ("unexpected bit-read error: %s", e.message);
        Test.fail ();
        return 0;
    }
}

private uint32 must_decode (Itsf.Lzx.HuffmanTable t, Itsf.Lzx.BitReader br) {
    try {
        return t.decode_symbol (br);
    } catch (Error e) {
        Test.message ("unexpected huffman-decode error: %s", e.message);
        Test.fail ();
        return 0;
    }
}

private void must_build (Itsf.Lzx.HuffmanTable t, uint8[] lens) {
    try {
        t.build_from_lengths (lens);
    } catch (Error e) {
        Test.message ("unexpected table-build error: %s", e.message);
        Test.fail ();
    }
}

private uint8[] must_pretree (Itsf.Lzx.BitReader br, int count, uint8[]? prev = null) {
    try {
        return Itsf.Lzx.Pretree.decode_lengths (br, count, prev);
    } catch (Error e) {
        Test.message ("unexpected pretree error: %s", e.message);
        Test.fail ();
        return new uint8[0];
    }
}

void test_bitreader_msb_first () {
    // First LE word is 0xA000: bits are 1,0,1,0,0,0,0,0,...
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0xA0, 0x34, 0x12 });
    assert (must_read (br, 1) == 1);
    assert (must_read (br, 1) == 0);
    assert (must_read (br, 1) == 1);
    assert (must_read (br, 3) == 0);
    assert (must_read (br, 10) == 0);       // rest of first word
    assert (must_read (br, 16) == 0x1234);  // whole second word == its value
}

void test_bitreader_overread_throws () {
    var br = new Itsf.Lzx.BitReader ({ 0xFF, 0xFF });
    must_read (br, 16);
    bool threw = false;
    try { br.read_bits (1); } catch (Itsf.Error e) { threw = true; }
    assert_true (threw);
}

void test_bitreader_odd_tail_throws () {
    // Streams are word-aligned (MS-PATCH 2.1.1); a trailing odd byte
    // carries no readable bits.
    var br = new Itsf.Lzx.BitReader ({ 0xFF });
    bool threw = false;
    try { br.read_bits (1); } catch (Itsf.Error e) { threw = true; }
    assert_true (threw);
}

void test_bitreader_align () {
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0xA0 });
    must_read (br, 3);
    assert_false (br.is_aligned_to_byte ());
    br.align_to_byte ();
    assert_true (br.is_aligned_to_byte ());
    assert (must_read (br, 8) == 0x00);
}

void test_bitreader_word_align () {
    // align_to_word discards to the next 16-bit boundary for the
    // CHM 0x8000 realignment and type-3 raw reads.
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0xA0, 0x34, 0x12 });
    assert (must_read (br, 3) == 0x05);   // bits 1,0,1
    br.align_to_word ();
    assert (must_read (br, 16) == 0x1234);
}

void test_bitreader_raw_bytes () {
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0xA0, 0x12, 0x34 });
    must_read (br, 3);
    br.align_to_word ();
    uint8[] raw;
    try {
        raw = br.read_raw_bytes (2);
    } catch (Error e) {
        Test.message ("unexpected raw-read error: %s", e.message);
        Test.fail ();
        return;
    }
    assert (raw.length == 2);
    assert (raw[0] == 0x12 && raw[1] == 0x34);
}

void test_pretree_all_zeros () {
    // 20 nibbles of 0 => all code lengths 0.
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00, 0x00, 0x00 });
    var lens = must_pretree (br, 256);
    assert (lens.length == 256);
    foreach (var l in lens) assert (l == 0);
}

void test_pretree_runs () {
    // Tree-delta vector from tools/mklzx.py: 19-run emits 5x16,
    // 17-run 4x0, 18-run 20x0.
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0x22, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x33, 0x02, 0x0C, 0xF6,
                                       0x00, 0x00 });
    var lens = must_pretree (br, 29);
    assert (lens.length == 29);
    for (int i = 0; i < 5; i++) assert (lens[i] == 16);
    for (int i = 5; i < 29; i++) assert (lens[i] == 0);
}

void test_pretree_prev () {
    // Same bits, but delta against a nonzero previous tree: every direct
    // code resolves against prev[x] instead of zero. With prev all 3s,
    // the 19-run value is (3-1)%17 = 2; the 17/18 zero-runs stay zero.
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0x22, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x33, 0x02, 0x0C, 0xF6,
                                       0x00, 0x00 });
    var prev = new uint8[29];
    for (int i = 0; i < 29; i++) prev[i] = 3;
    var lens = must_pretree (br, 29, prev);
    assert (lens.length == 29);
    for (int i = 0; i < 5; i++) assert (lens[i] == 2);
    for (int i = 5; i < 29; i++) assert (lens[i] == 0);
}

void test_huffman_single_symbol () {
    // Lengths [1, 0, 0, ...]: symbol 0 gets code "0".
    var lens = new uint8[4];
    lens[0] = 1;
    var t = new Itsf.Lzx.HuffmanTable ();
    must_build (t, lens);
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0x00 });
    assert (must_decode (t, br) == 0);
    assert (must_decode (t, br) == 0);
}

void test_huffman_two_symbols () {
    // Lengths [1, 1]: symbol 0 -> "0", symbol 1 -> "1".
    var lens = new uint8[2];
    lens[0] = 1; lens[1] = 1;
    var t = new Itsf.Lzx.HuffmanTable ();
    must_build (t, lens);
    var br = new Itsf.Lzx.BitReader ({ 0x00, 0x40 });   // bits 0,1,...
    assert (must_decode (t, br) == 0);
    assert (must_decode (t, br) == 1);
}

// --- LZX block decoder + compressed sections (vectors in
// tests/itsfdata/*.lzx, machine-generated by tools/mklzx.py).

private string? find_vector (string name) {
    string[] cands = {};
    string? r = GLib.Environment.get_variable ("MESON_SOURCE_ROOT");
    if (r == null)
        r = GLib.Environment.get_variable ("MESON_PROJECT_SOURCE_ROOT");
    if (r != null)
        cands += Path.build_filename (r, "tests", "itsfdata", name);
    cands += Path.build_filename ("tests", "itsfdata", name);
    cands += Path.build_filename ("..", "tests", "itsfdata", name);
    // Walk up from the test binary: covers the in-tree builddir layout
    // (builddir/tests/test_itsf -> <root>/tests/itsfdata).
    try {
        string dir = Path.get_dirname (FileUtils.read_link ("/proc/self/exe"));
        for (int i = 0; i < 6; i++) {
            cands += Path.build_filename (dir, "tests", "itsfdata", name);
            dir = Path.get_dirname (dir);
        }
    } catch (Error e) {
    }
    foreach (var p in cands) {
        if (FileUtils.test (p, FileTest.EXISTS))
            return p;
    }
    return null;
}

private uint8[] load_vector (string name) {
    string? path = find_vector (name);
    if (path == null) {
        Test.message ("vector not found: %s", name);
        Test.fail ();
        return new uint8[0];
    }
    uint8[] data = new uint8[0];
    try {
        GLib.FileUtils.get_data (path, out data);
    } catch (Error e) {
        Test.message ("cannot load vector %s: %s", path, e.message);
        Test.fail ();
    }
    return data;
}

private GLib.Bytes must_lzx_decode (uint8[] compressed, int window_bits,
        uint64 expected_out) {
    try {
        return Itsf.Lzx.Decoder.decode (compressed, window_bits, expected_out);
    } catch (Error e) {
        Test.message ("unexpected decode error: %s", e.message);
        Test.fail ();
        return new GLib.Bytes (new uint8[0]);
    }
}

void test_type3_roundtrip () {
    var compressed = load_vector ("type3_hello.lzx");
    var decoded = must_lzx_decode (compressed, 15, 1024);
    assert (decoded.get_size () == 1024);
    unowned uint8[] got = decoded.get_data ();
    string unit = "hello lzx world\n";
    for (int i = 0; i < 1024; i++)
        assert (got[i] == (uint8) unit[i % unit.length]);
}

void test_verbatim_block () {
    // Literal-only verbatim block ("abcd" x 4).
    var compressed = load_vector ("verbatim_abcd.lzx");
    var decoded = must_lzx_decode (compressed, 15, 16);
    assert (decoded.get_size () == 16);
    unowned uint8[] got = decoded.get_data ();
    string want = "abcdabcdabcdabcd";
    for (int i = 0; i < 16; i++)
        assert (got[i] == (uint8) want[i]);
}

void test_verbatim_match () {
    // Literals plus one (offset 2, length 198) match: exercises match
    // lengths, offsets and the repeated-offset queue.
    var compressed = load_vector ("verbatim_match.lzx");
    var decoded = must_lzx_decode (compressed, 15, 200);
    assert (decoded.get_size () == 200);
    unowned uint8[] got = decoded.get_data ();
    assert (got[0] == (uint8) 'a' && got[1] == (uint8) 'b');
    for (int i = 2; i < 200; i++)
        assert (got[i] == (uint8) ((i % 2 == 0) ? 'a' : 'b'));
}

void test_e8_postpass () {
    // E8 flag set on a type-3 block: the byte at 5 is 0xE8 followed by
    // LE value 10; with filesize 16 it becomes 10 - 5 = 5.
    var compressed = load_vector ("e8code.lzx");
    var decoded = must_lzx_decode (compressed, 15, 16);
    assert (decoded.get_size () == 16);
    unowned uint8[] got = decoded.get_data ();
    uint8[] want = { 0, 0, 0, 0, 0, 0xE8, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (int i = 0; i < 16; i++)
        assert (got[i] == want[i]);
}

void test_truncated_block_throws () {
    var full = load_vector ("verbatim_abcd.lzx");
    bool threw = false;
    try {
        Itsf.Lzx.Decoder.decode (full[0:full.length / 2], 15, 16);
    } catch (Itsf.Error e) { threw = true; }
    assert_true (threw);
}

void test_verbatim_chained () {
    // Two chained verbatim blocks (prev threading), R0/R1/R2 reuse,
    // long (>257, encoder-split into <=257 chunks) lengths and a 0x8000
    // realignment crossing.
    var compressed = load_vector ("verbatim_big.lzx");
    var want = load_vector ("verbatim_big.exp");
    var decoded = must_lzx_decode (compressed, 16, (uint64) want.length);
    assert (decoded.get_size () == (uint64) want.length);
    unowned uint8[] got = decoded.get_data ();
    for (int i = 0; i < want.length; i++)
        assert (got[i] == want[i]);
}

void test_aligned_block () {
    // Aligned-offset block: split footer (verbatim + aligned tree bits)
    // plus an R0 repeat.
    var compressed = load_vector ("aligned_foo.lzx");
    var want = load_vector ("aligned_foo.exp");
    var decoded = must_lzx_decode (compressed, 15, (uint64) want.length);
    assert (decoded.get_size () == (uint64) want.length);
    unowned uint8[] got = decoded.get_data ();
    for (int i = 0; i < want.length; i++)
        assert (got[i] == want[i]);
}

void test_compressed_fixture_reads () {
    // Fixtures are uncompressed, so this asserts the section path is a
    // no-op for them: every read still matches uncompressed_size.
    with_fixture ("big.chm", (arc) => {
        foreach (var p in arc.list ()) {
            var b = arc.read (p);
            assert (b.get_size () == arc.uncompressed_size (p));
        }
        arc.close ();
    });
}

// --- Hermetic compressed-section test: space-1 entry over 2 reset
// intervals (0x8000 + partial 1000); sha256 ground truth, no CORPUS_DIR.
private const uint64 COMPRESSED_LEN = 0x8000u + 1000u;
private const string COMPRESSED_SHA256 = "04b81117e4f991e557ff0f67b37df9ae9d61cdbcab02623144df1f32f2b4cb15";

void test_compressed_section_hermetic () {
    with_fixture ("compressed.chm", (arc) => {
        assert (arc.uncompressed_size ("/comp.html") == COMPRESSED_LEN);
        var full = arc.read ("/comp.html");
        assert (full.get_size () == COMPRESSED_LEN);
        unowned uint8[] fdata = full.get_data ();
        var sum = new GLib.Checksum (GLib.ChecksumType.SHA256);
        sum.update (fdata, fdata.length);
        assert_cmpstr (sum.get_string (), CompareOperator.EQ, COMPRESSED_SHA256);
        // Slice straddling the 0x8000 interval boundary.
        var span = arc.read_range ("/comp.html", 0x8000u - 16u, 32u);
        assert (span.get_size () == 32u);
        unowned uint8[] sdata = span.get_data ();
        for (uint64 i = 0; i < 32u; i++)
            assert (sdata[i] == fdata[0x8000u - 16u + i]);
        // Second-interval head.
        var head2 = arc.read_range ("/comp.html", 0x8000u, 64u);
        assert (head2.get_size () == 64u);
        unowned uint8[] hdata = head2.get_data ();
        for (uint64 i = 0; i < 64u; i++)
            assert (hdata[i] == fdata[0x8000u + i]);
        // Cache hit: second full read is identical.
        var full2 = arc.read ("/comp.html");
        assert (full2.get_size () == COMPRESSED_LEN);
        unowned uint8[] f2data = full2.get_data ();
        for (uint64 i = 0; i < COMPRESSED_LEN; i++)
            assert (f2data[i] == fdata[i]);
        arc.close ();
    });
}

// --- Async reads: byte-identical to sync, yielding per reset interval.

private async void check_entry_async_parity (Itsf.Archive arc, string path) throws Error {
    var a = yield arc.read_async (path);
    var s = arc.read (path);
    assert (a.get_size () == s.get_size ());
    unowned uint8[] ad = a.get_data ();
    unowned uint8[] sd = s.get_data ();
    for (uint64 i = 0; i < s.get_size (); i++)
        assert (ad[i] == sd[i]);
    uint64 len = s.get_size ();
    uint64 off = len / 2u;
    var ar = yield arc.read_range_async (path, off, 64);
    var sr = arc.read_range (path, off, 64);
    assert (ar.get_size () == sr.get_size ());
    unowned uint8[] ard = ar.get_data ();
    unowned uint8[] srd = sr.get_data ();
    for (uint64 i = 0; i < sr.get_size (); i++)
        assert (ard[i] == srd[i]);
}

private async void check_archive_async_parity (Itsf.Archive arc) throws Error {
    foreach (var p in arc.list ())
        yield check_entry_async_parity (arc, p);
}

private async void run_async_parity (string path, GLib.MainLoop loop) {
    try {
        var arc = yield Itsf.Archive.open (GLib.File.new_for_path (path));
        yield check_archive_async_parity (arc);
        // Error parity: both spellings throw INVALID_PATH on a miss.
        bool sync_threw = false;
        try { arc.read ("/no-such-page.htm"); } catch (Itsf.Error e) { sync_threw = true; }
        assert_true (sync_threw);
        bool async_threw = false;
        try { yield arc.read_async ("/no-such-page.htm"); } catch (Itsf.Error e) { async_threw = true; }
        assert_true (async_threw);
        arc.close ();
    } catch (Error e) {
        Test.message ("async parity failed for %s: %s", path, e.message);
        Test.fail ();
    }
    loop.quit ();
}

private void drive_async_parity (string path) {
    var loop = new GLib.MainLoop ();
    run_async_parity.begin (path, loop);
    loop.run ();
}

void test_read_async_matches_sync () {
    drive_async_parity (Path.build_filename (fixture_dir (), "basic.chm"));
    drive_async_parity (Path.build_filename (fixture_dir (), "big.chm"));
    drive_async_parity (Path.build_filename (fixture_dir (), "compressed.chm"));
}

private string[] collect_chm (string dir) {
    string[] acc = {};
    GLib.Dir? d = null;
    try {
        d = GLib.Dir.open (dir);
    } catch (Error e) {
        Test.message ("cannot list %s: %s", dir, e.message);
        Test.fail ();
        return acc;
    }
    if (d == null) return acc;
    string? name;
    while ((name = d.read_name ()) != null) {
        var p = Path.build_filename (dir, name);
        if (GLib.FileUtils.test (p, GLib.FileTest.IS_DIR)) {
            foreach (var q in collect_chm (p))
                acc += q;
        } else if (name.has_suffix (".chm")) {
            acc += p;
        }
    }
    return acc;
}

void test_read_async_corpus_parity () {
    // Corpus objects must read byte-identical through the async spelling,
    // exercising decode_section_async including multi-interval sections.
    var corpus = GLib.Environment.get_variable ("CORPUS_DIR");
    if (corpus == null || corpus == "") {
        Test.skip ("no corpus; set CORPUS_DIR=/path/to/books");
        return;
    }
    string[] books = collect_chm (corpus);
    if (books.length == 0) {
        Test.skip ("no *.chm under CORPUS_DIR");
        return;
    }
    foreach (var b in books) {
        Test.message ("parity: %s", b);
        drive_async_parity (b);
    }
}

public int main (string[] args) {
    GLib.Test.init (ref args, null);
    GLib.Test.add_func ("/itsf/error_domain", test_error_domain);
    GLib.Test.add_func ("/itsf/open_fixture_and_list", test_open_fixture_and_list);
    GLib.Test.add_func ("/itsf/multiblock_index_walk", test_multiblock_index_walk);
    GLib.Test.add_func ("/itsf/open_rejects_non_chm", test_open_rejects_non_chm);
    GLib.Test.add_func ("/itsf/truncated_header", test_truncated_header);
    GLib.Test.add_func ("/itsf/cyclic_directory", test_cyclic_directory);
    GLib.Test.add_func ("/itsf/dir_cword_overflow", test_dir_cword_overflow);
    GLib.Test.add_func ("/itsf/dir_truncated_name", test_dir_truncated_name);
    GLib.Test.add_func ("/itsf/dir_bad_free_space", test_dir_bad_free_space);
    GLib.Test.add_func ("/itsf/dir_offset_past_eof", test_dir_offset_past_eof);
    GLib.Test.add_func ("/itsf/dir_self_cycle_terminates", test_dir_self_cycle_terminates);
    GLib.Test.add_func ("/itsf/malformed_directory", test_malformed_directory);
    GLib.Test.add_func ("/itsf/read_home", test_read_home);
    GLib.Test.add_func ("/itsf/read_range_system_skip", test_read_range_system_skip);
    GLib.Test.add_func ("/itsf/read_range_past_end", test_read_range_past_end);
    GLib.Test.add_func ("/itsf/read_missing_throws", test_read_missing_throws);
    GLib.Test.add_func ("/itsf/bitreader_msb_first", test_bitreader_msb_first);
    GLib.Test.add_func ("/itsf/bitreader_overread_throws", test_bitreader_overread_throws);
    GLib.Test.add_func ("/itsf/bitreader_odd_tail_throws", test_bitreader_odd_tail_throws);
    GLib.Test.add_func ("/itsf/bitreader_align", test_bitreader_align);
    GLib.Test.add_func ("/itsf/pretree_all_zeros", test_pretree_all_zeros);
    GLib.Test.add_func ("/itsf/pretree_runs", test_pretree_runs);
    GLib.Test.add_func ("/itsf/huffman_single_symbol", test_huffman_single_symbol);
    GLib.Test.add_func ("/itsf/huffman_two_symbols", test_huffman_two_symbols);
    GLib.Test.add_func ("/itsf/pretree_prev", test_pretree_prev);
    GLib.Test.add_func ("/itsf/bitreader_word_align", test_bitreader_word_align);
    GLib.Test.add_func ("/itsf/bitreader_raw_bytes", test_bitreader_raw_bytes);
    GLib.Test.add_func ("/itsf/type3_roundtrip", test_type3_roundtrip);
    GLib.Test.add_func ("/itsf/verbatim_block", test_verbatim_block);
    GLib.Test.add_func ("/itsf/verbatim_match", test_verbatim_match);
    GLib.Test.add_func ("/itsf/e8_postpass", test_e8_postpass);
    GLib.Test.add_func ("/itsf/truncated_block_throws", test_truncated_block_throws);
    GLib.Test.add_func ("/itsf/verbatim_chained", test_verbatim_chained);
    GLib.Test.add_func ("/itsf/aligned_block", test_aligned_block);
    GLib.Test.add_func ("/itsf/compressed_fixture_reads", test_compressed_fixture_reads);
    GLib.Test.add_func ("/itsf/compressed_section_hermetic", test_compressed_section_hermetic);
    GLib.Test.add_func ("/itsf/read_async_matches_sync", test_read_async_matches_sync);
    GLib.Test.add_func ("/itsf/read_async_corpus_parity", test_read_async_corpus_parity);
    return GLib.Test.run ();
}
