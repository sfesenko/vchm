// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// CHM archive wrapper. Binary formats follow the published CHM layout:
// InfoFromSystem TLV records, 16-byte #TOPICS
// entries, #URLTBL indirection at +8 and #URLSTR strings at +8.

using ChmLib;
using GLib;
using Gee;

namespace Vchm.Model {

    // Little-endian readers
    public static uint32 UINT32_FROM_ARRAY (uint8[] array, int offset) {
        return (uint32) array[offset] | ((uint32) array[offset + 1] << 8) |
               ((uint32) array[offset + 2] << 16) | ((uint32) array[offset + 3] << 24);
    }

    public static uint16 UINT16_FROM_ARRAY (uint8[] array, int offset) {
        return (uint16) array[offset] | ((uint16) array[offset + 1] << 8);
    }

    // NUL-terminated string starting at `start` in `buf`, as raw bytes.
    public string? read_cstring (uint8[] buf, int start) {
        return read_cstring_bounded (buf, start, buf.length - start);
    }

    // Same, but never reads past `max_len` bytes — TLV records carry an
    // explicit length and may lack a terminator (malformed writers).
    public string? read_cstring_bounded (uint8[] buf, int start, int max_len) {
        if (start < 0 || start >= buf.length) return null;
        if (max_len < 0) max_len = 0;
        var sb = new StringBuilder ();
        int i = start;
        int end = start + max_len;
        while (i < buf.length && i < end && buf[i] != 0) {
            sb.append_c ((char) buf[i]);
            i++;
        }
        return sb.str;
    }

    // Convert raw bytes to UTF-8 using `enc` if not already valid UTF-8.
    public string to_utf8 (string raw, string enc) {
        if (raw.validate ()) return raw;
        try {
            return GLib.convert (raw, -1, "UTF-8", enc);
        } catch (GLib.ConvertError e) {
            return raw;
        }
    }

    // Name of TOC entry `index`: #STRINGS offset stored in #TOPICS entry +4.
    public string? btoc_item_name (uint8[] topics, uint8[] strings, uint32 index, string enc) {
        // Offsets come from hostile data: compute in 64-bit so a crafted
        // index wrapping mod 2^32 cannot pass the bounds check (review F22).
        uint64 tbase = (uint64) index * 16;
        if (tbase + 12 > (uint64) topics.length) return null;
        var off = UINT32_FROM_ARRAY (topics, (int) tbase + 4);
        if ((int32) off == -1) return null;
        var s = read_cstring (strings, (int) off);
        if (s == null || s.length == 0) return null;
        return to_utf8 (s, enc);
    }

    // URL of TOC entry `index`: #URLTBL index in entry +8, then u32 at
    // urltbl[idx+8] points into #URLSTR where the path starts at +8.
    public string? btoc_item_url (uint8[] topics, uint8[] strings, uint8[] urltbl,
                                    uint8[] urlstr, uint32 index) {
        uint64 tbase = (uint64) index * 16;
        if (tbase + 12 > (uint64) topics.length) return null;

        var ut_off = UINT32_FROM_ARRAY (topics, (int) tbase + 8);
        if ((uint64) ut_off + 12 > (uint64) urltbl.length) return null;

        var us_off = UINT32_FROM_ARRAY (urltbl, (int) ut_off + 8);
        if ((uint64) us_off + 9 > (uint64) urlstr.length) return null;

        var url = read_cstring (urlstr, (int) us_off + 8);
        if (url == null || url.length == 0) return null;
        if (url[0] != '/') url = "/" + url;
        return url;
    }

    // Depth-first walk of #TOCIDX returning the first entry that has a URL.
    public string? btoc_first_url (uint8[] topidx, uint8[] topics, uint8[] strings,
                                     uint8[] urltbl, uint8[] urlstr) {
        if (topidx.length < 4) return null;
        var root = UINT32_FROM_ARRAY (topidx, 0);
        return btoc_dfs (topidx, topics, strings, urltbl, urlstr, root, 0);
    }

    static string? btoc_dfs (uint8[] topidx, uint8[] topics, uint8[] strings,
                             uint8[] urltbl, uint8[] urlstr, uint32 offset, int depth) {
        if (depth > 128) return null; // guard against corrupt/cyclic data
        int hops = 0;
        while (offset != 0 && hops++ < 100000) {
            if (topidx.length < offset + 20) return null;

            var flags = UINT32_FROM_ARRAY (topidx, (int) (offset + 4));
            var index = UINT32_FROM_ARRAY (topidx, (int) (offset + 8));

            // GetItem(local = (flags & 0x8) == 0). Flag 0x8 = entry
            // carries a page reference resolved through #TOPICS/#URLTBL.
            if ((flags & 0x8) != 0) {
                var url = btoc_item_url (topics, strings, urltbl, urlstr, index);
                if (url != null) return url;
            }

            if ((flags & 0x4) != 0 && topidx.length >= offset + 24) { // book: descend
                var child = UINT32_FROM_ARRAY (topidx, (int) (offset + 20));
                if (child != 0) {
                    var found = btoc_dfs (topidx, topics, strings, urltbl, urlstr, child, depth + 1);
                    if (found != null) return found;
                }
            }

            offset = UINT32_FROM_ARRAY (topidx, (int) (offset + 0x10)); // next sibling
        }
        return null;
    }

    // Fallback when no #TOCIDX: scan #TOPICS entries in order.
    public string? topics_sequential_first_url (uint8[] topics, uint8[] strings,
                                                  uint8[] urltbl, uint8[] urlstr) {
        uint32 count = topics.length / 16;
        for (uint32 i = 0; i < count; i++) {
            var url = btoc_item_url (topics, strings, urltbl, urlstr, i);
            if (url != null) return url;
        }
        return null;
    }

    // Result object for content resolution
    public class CHMContent : Object {
        public string content { get; set; }
        public string mime_type { get; set; }
        public string path { get; set; }
        public bool success { get; set; }
        public string? error { get; set; }

        public CHMContent () {
            success = false;
            content = "";
            mime_type = "application/octet-stream";
            path = "";
            error = null;
        }

        public static CHMContent success_result (string content, string mime_type, string path) {
            var result = new CHMContent ();
            result.success = true;
            result.content = content;
            result.mime_type = mime_type;
            result.path = path;
            return result;
        }

        public static CHMContent error_result (string error) {
            var result = new CHMContent ();
            result.success = false;
            result.error = error;
            return result;
        }
    }

    // CHM File wrapper using chmlib
    public class CHMFile : Object {
        private const long MAX_UNIT_BYTES = 256 * 1024 * 1024; // sanity cap

        private ChmLib.File* _file;
        private ChmLib.File* _chi_file;   // optional .chi companion for /# units
        private string _filename;
        private string _title;
        private string _home;
        private string _topics_file;
        private string _index_file;
        private string _encoding;
        private string? _first_topic_url;

        // Raw (undecoded) metadata strings; converted after encoding detection.
        private string _raw_title;
        private string _raw_home;
        private bool _encoding_hinted = false;

        // Serializes chmlib handle access across threads (URI-scheme
        // workers, search/navigation Cmds) against close(). RecMutex:
        // entry points nest (load→close, detect_encoding→get_bytes…).
        private GLib.RecMutex _api_mutex = GLib.RecMutex ();

        public CHMFile () {
            _file = null;
            _chi_file = null;
            _filename = "";
            _title = "";
            _home = "/";
            _topics_file = "";
            _index_file = "";
            _encoding = "CP1252";
            _first_topic_url = null;
            _raw_title = "";
            _raw_home = "";
        }

        ~CHMFile () {
            close ();
        }

        public bool is_open () {
            _api_mutex.lock ();
            try {
                return _file != null;
            } finally {
                _api_mutex.unlock ();
            }
        }

        // Metadata handle: a .chi companion when present, else the archive
        // itself (_chmChiFile semantics).
        private ChmLib.File* meta_file () {
            return _chi_file != null ? _chi_file : _file;
        }

        // ── Open-book registry (multi-book serving) ─────────────────────
        // The URI scheme handler resolves "chm://<escaped-path>/..." against
        // this table, so every tab serves from its own archive. Keyed by
        // FULL PATH: two books may share a basename (/en/help.chm vs
        // /uk/help.chm) and must not collide (review F5).
        private static Gee.HashMap<string, weak CHMFile>? s_registry = null;

        private static void reg () {
            if (s_registry == null)
                s_registry = new Gee.HashMap<string, weak CHMFile> ();
        }

        private void register_self () {
            reg ();
            s_registry[_filename] = this;
        }

        private void unregister_self () {
            if (s_registry == null) return;
            s_registry.unset (_filename);
        }

        public static CHMFile? by_path (string path) {
            if (s_registry == null) return null;
            if (!s_registry.has_key (path)) return null;
            var v = s_registry[path];
            if (v == null) {
                s_registry.unset (path);
                return null;
            }
            return v;
        }

        // Re-key after a duplicate open displaced our registry entry
        // (the duplicate's load() overwrote it, its close() removed it).
        public void re_register () {
            register_self ();
        }

        public string filename () {
            return _filename;
        }

        public string title () {
            return _title;
        }

        public string home_page () {
            return _home;
        }

        public string topics_file () {
            return _topics_file;
        }

        public string index_file () {
            return _index_file;
        }

        public string encoding () {
            return _encoding;
        }

        public string get_first_topic_url () {
            return _first_topic_url ?? "";
        }

        // Manual charset selection (View ▸ Encoding). Re-decodes stored raw
        // metadata immediately; pages pick it up on next fetch.
        public void override_encoding (string encoding) {
            _api_mutex.lock ();
            try {
                if (_file == null) return;
                if (encoding == "auto") {
                    _encoding_hinted = false;
                    parse_system_info ();          // re-reads LCID/font hints
                    detect_encoding ();
                    finalize_metadata ();
                    return;
                }
                _encoding = encoding;
                _encoding_hinted = true;
                finalize_metadata ();
            } finally {
                _api_mutex.unlock ();
            }
        }

        // context ID -> archive path (leading '/'); port of _cidMap.
        private Gee.HashMap<uint32, string> cid_map = new Gee.HashMap<uint32, string> ();

        public bool load (string filename) {
            _api_mutex.lock ();
            try {
                close ();

                if (!GLib.FileUtils.test (filename, GLib.FileTest.EXISTS)) {
                    stderr.printf ("CHM file not found: %s\n", filename);
                    return false;
                }

                _file = chm_open (filename);

                if (_file == null) {
                    stderr.printf ("Failed to open CHM file: %s\n", filename);
                    return false;
                }

                // .chi companion: internal /#* units live there instead.
                var stem = filename.has_suffix (".chm")
                    ? filename.substring (0, filename.length - 4)
                    : filename;
                _chi_file = chm_open (stem + ".chi");
                if (_chi_file == null) {
                    _chi_file = chm_open (stem + ".CHI");
                }

                _filename = filename;
                register_self ();   // keyed by full path — AFTER _filename is set

                _title = "";
                _home = "/";
                _topics_file = "";
                _index_file = "";
                _encoding = "CP1252";
                _first_topic_url = null;
                _raw_title = "";
                _raw_home = "";
                _encoding_hinted = false;

                parse_system_info ();
                parse_windows_info ();
                detect_encoding ();
                finalize_metadata ();
                return true;
            } finally {
                _api_mutex.unlock ();
            }
        }

        public void close () {
            _api_mutex.lock ();
            try {
                unregister_self ();
                if (_chi_file != null) {
                    var tmp = _chi_file;
                    _chi_file = null;
                    chm_close (tmp);
                }
                if (_file != null) {
                    var tmp = _file;
                    _file = null;
                    chm_close (tmp);
                    _filename = "";
                    _first_topic_url = null;
                }
            } finally {
                _api_mutex.unlock ();
            }
        }

        // ── Metadata: /#SYSTEM ──────────────────────────────────────────
        // Layout: [u16 type][u16 length][data...] records after a 4-byte
        // version header. Types: 0=hhc 1=hhk 2=home 3=title 4=LCID 6=compiled
        // name 16=default font (InfoFromSystem).
        private void parse_system_info () {
            if (_file == null) return;

            ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct ();
            if (chm_resolve_object (meta_file (), "/#SYSTEM", out ui) != ChmLib.RESOLVE_SUCCESS) return;
            if (ui.length < 5 || ui.length > MAX_UNIT_BYTES) return;

            var buf = new uint8[(int) ui.length]; // zero-initialised

            // Skip the 4-byte version header.
            long size = chm_retrieve_object (meta_file (), &ui, buf, 4, (long) ui.length - 4);
            if (size <= 4) return;

            int index = 0;
            for (;;) {
                if (index + 4 > size) break;

                uint16 type = UINT16_FROM_ARRAY (buf, index);

                uint16 rlen = UINT16_FROM_ARRAY (buf, index + 2);
                if (index + 4 + rlen > size) break;   // corrupt tail

                switch (type) {
                    case 0: // topics (.hhc)
                        if (_topics_file.length == 0) {
                            var s = read_cstring_bounded (buf, index + 4, rlen);
                            if (s != null && s.length > 0) _topics_file = "/" + s;
                        }
                        break;

                    case 1: // index (.hhk)
                        if (_index_file.length == 0) {
                            var s = read_cstring_bounded (buf, index + 4, rlen);
                            if (s != null && s.length > 0) _index_file = "/" + s;
                        }
                        break;

                    case 2: // home page
                        if (_raw_home.length == 0) {
                            var s = read_cstring_bounded (buf, index + 4, rlen);
                            if (s != null && s.length > 0) _raw_home = s;
                        }
                        break;

                    case 3: // title
                        if (_raw_title.length == 0) {
                            var s = read_cstring_bounded (buf, index + 4, rlen);
                            if (s != null && s.length > 0) _raw_title = s;
                        }
                        break;

                    case 4: // LCID → encoding (trusted hint)
                        if (index + 8 <= size) {
                            uint32 lcid = UINT32_FROM_ARRAY (buf, index + 4);
                            _encoding = encoding_from_lcid (lcid);
                            _encoding_hinted = true;
                        }
                        break;

                    case 6: // compiled-file hint → try .hhc/.hhk siblings
                        if (_topics_file.length == 0) {
                            var s = read_cstring_bounded (buf, index + 4, rlen);
                            if (s != null && s.length > 0) {
                                if (has_object ("/" + s + ".hhc")) _topics_file = "/" + s + ".hhc";
                                if (has_object ("/" + s + ".hhk")) _index_file = "/" + s + ".hhk";
                            }
                        }
                        break;

                    case 16: // default font "name,size,charset"
                        var f = read_cstring_bounded (buf, index + 4, rlen);
                        if (f != null && f.length > 0 && !_encoding_hinted) {
                            int comma = f.last_index_of_char (',');
                            if (comma >= 0 && comma + 1 < f.length) {
                                int cs = 0;
                                if (int.try_parse (f.substring (comma + 1).strip (), out cs)) {
                                    _encoding = encoding_from_charset (cs);
                                    _encoding_hinted = true;
                                }
                            }
                        }
                        break;

                    default:
                        break;
                }

                index += rlen + 4;
            }
        }

        // Called after SYSTEM/WINDOWS parsing and encoding detection: decode
        // the raw metadata strings with the final charset.
        private void finalize_metadata () {
            _title = to_utf8 (_raw_title, _encoding);
            _home = _raw_home.length > 0 ? "/" + _raw_home : "/";
        }

        // ── Metadata: /#WINDOWS fallback ────────────────────────────────
        // Array of window entries after an 8-byte header. Relevant offsets
        // into each entry: title @0x14, hhc @0x60, hhk @0x64, home @0x68 —
        // all absolute offsets into #STRINGS. Port of InfoFromWindows().
        private void parse_windows_info () {
            if (_file == null) return;

            ChmLib.UnitInfoStruct wui = ChmLib.UnitInfoStruct ();
            if (chm_resolve_object (meta_file (), "/#WINDOWS", out wui) != ChmLib.RESOLVE_SUCCESS) return;
            if (wui.length < 8 || wui.length > MAX_UNIT_BYTES) return;

            var hdr = new uint8[8];
            if (chm_retrieve_object (meta_file (), &wui, hdr, 0, 8) != 8) return;

            uint32 entries = UINT32_FROM_ARRAY (hdr, 0);
            uint32 entry_size = UINT32_FROM_ARRAY (hdr, 4);

            if (entries == 0 || entry_size < 0x6C) return;
            if (entries > 1024) entries = 1024;

            uint64 total = (uint64) entries * entry_size;
            if (total > wui.length) return;

            var raw = new uint8[(int) total];
            if (chm_retrieve_object (meta_file (), &wui, raw, 8, (long) total) != (long) total) return;

            ChmLib.UnitInfoStruct sui = ChmLib.UnitInfoStruct ();
            if (chm_resolve_object (meta_file (), "/#STRINGS", out sui) != ChmLib.RESOLVE_SUCCESS) return;

            var strings = new uint8[(int) sui.length];
            if (chm_retrieve_object (meta_file (), &sui, strings, 0, (long) sui.length) != (long) sui.length) return;

            for (uint32 i = 0; i < entries; i++) {
                int base_i = (int) (i * entry_size);
                if (base_i + 0x6C > (int) total) break;

                var off_title = UINT32_FROM_ARRAY (raw, base_i + 0x14);
                var off_home = UINT32_FROM_ARRAY (raw, base_i + 0x68);
                var off_hhc = UINT32_FROM_ARRAY (raw, base_i + 0x60);
                var off_hhk = UINT32_FROM_ARRAY (raw, base_i + 0x64);

                if (_raw_title.length == 0 && off_title != 0 && off_title < strings.length) {
                    var s = read_cstring (strings, (int) off_title);
                    if (s != null && s.length > 0) _raw_title = s;
                }

                if (_raw_home.length == 0 && off_home != 0 && off_home < strings.length) {
                    var s = read_cstring (strings, (int) off_home);
                    if (s != null && s.length > 0) _raw_home = s;
                }

                if (_topics_file.length == 0 && off_hhc != 0 && off_hhc < strings.length) {
                    var s = read_cstring (strings, (int) off_hhc);
                    if (s != null && s.length > 0) _topics_file = "/" + s;
                }

                if (_index_file.length == 0 && off_hhk != 0 && off_hhk < strings.length) {
                    var s = read_cstring (strings, (int) off_hhk);
                    if (s != null && s.length > 0) _index_file = "/" + s;
                }
            }
        }

        // ── Encoding detection ──────────────────────────────────────────
        // 1. A <meta charset=...> in the home page is the document's own
        //    truth and overrides any hint (LCIDs in the wild often lie).
        // 2. Without a declaration: keep the LCID/font hint when present.
        // 3. Otherwise score Cyrillic-capable charsets on the sample and
        //    keep the one producing the most Cyrillic letters. KOI8-U is
        //    tried first and KOI8-R last: on equal scores the earlier
        //    candidate wins, so a Ukrainian reading outranks Russian.
        private void detect_encoding () {
            var bytes = sample_page_bytes ();
            if (bytes == null || bytes.get_size () == 0) return;

            unowned uint8[] data = bytes.get_data ();
            long n = long.min ((long) data.length, 8192);

            var buf = new uint8[n + 1];
            Memory.copy (buf, data, (size_t) n);
            buf[n] = 0;
            string raw = (string) buf;

            // 1) explicit charset declaration wins (manual scan — robust
            //    against odd quoting/spacing in the wild)
            var name = sniff_meta_charset (raw);
            if (name != null) {
                var mapped = normalize_charset_name (name.down ());
                if (mapped != null) {
                    _encoding = mapped;
                    _encoding_hinted = true;
                    return;
                }
            }

            // 2) trust the metadata hint when we have one
            if (_encoding_hinted) return;

            // 3) score candidates by produced-Cyrillic-letter count
            string best = "";
            int best_score = 0;
            foreach (var cand in new string[] { "KOI8-U", "CP1251", "CP866", "KOI8-R", "CP1252" }) {
                int score = cyrillic_score (buf[0:n], cand);
                if (score > best_score) {
                    best_score = score;
                    best = cand;
                }
            }
            if (best_score > 0 && best.length > 0) {
                _encoding = best;
            }
        }

        private bool _encoding_is_utf8 () {
            return _encoding.has_prefix ("UTF");
        }

        // Find the first charset=<name> declaration in an HTML head.
        private static string? sniff_meta_charset (string raw) {
            // ASCII-only lowering: offsets computed here index BOTH copies,
            // and full down() can resync UTF-8 ('İ') and desync them.
            var low = Vchm.Model.HtmlTextUtils.ascii_down (raw);
            int search_from = 0;
            for (;;) {
                int k = low.index_of ("charset", search_from);
                if (k < 0 || k + 7 >= low.length) return null;

                int j = k + 7;
                // skip spaces and one optional '=' separator variants
                while (j < low.length && (low[j] == ' ' || low[j] == '\t')) j++;
                if (j >= low.length || low[j] != '=') {
                    search_from = k + 7;
                    continue; // e.g. the word inside a comment; keep looking
                }
                j++;
                while (j < raw.length && (raw[j] == ' ' || raw[j] == '\t')) j++;
                if (j < raw.length && (raw[j] == '"' || raw[j] == '\'')) j++;

                var sb = new StringBuilder ();
                while (j < raw.length) {
                    char c = raw[j];
                    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_') {
                        sb.append_c (c);
                        j++;
                    } else {
                        break;
                    }
                }
                if (sb.len == 0) {
                    search_from = k + 7;
                    continue;
                }
                return sb.str;
            }
        }

        private GLib.Bytes? sample_page_bytes () {
            if (_raw_home.length > 0) {
                var b = get_bytes ("/" + _raw_home);
                if (b != null && b.get_size () > 0) return b;
            }
            foreach (var p in list_content_pages ()) {
                var b = get_bytes (p);
                if (b != null && b.get_size () > 0) return b;
            }
            return null;
        }

        private static string? normalize_charset_name (string name) {
            switch (name) {
                case "windows-1251": case "cp1251": case "win-1251": case "1251":
                    return "CP1251";
                case "koi8-u": case "koi8u": case "koi-u": case "cskoi8u":
                    return "KOI8-U";
                case "koi8-r": case "koi8": case "koi-r": case "cskoi8r":
                    return "KOI8-R";
                case "ibm866": case "cp866": case "866": case "alt":
                    return "CP866";
                case "utf-8": case "utf8":
                    return "UTF-8";
                case "windows-1252": case "cp1252": case "win-1252":
                case "iso-8859-1": case "latin1": case "l1": case "1252":
                    return "CP1252";
                case "windows-1250": case "cp1250": case "1250":
                    return "CP1250";
                case "windows-1253": case "cp1253": case "1253":
                    return "CP1253";
                case "windows-1254": case "cp1254": case "1254":
                    return "CP1254";
                case "windows-1255": case "cp1255": case "1255":
                    return "CP1255";
                case "windows-1256": case "cp1256": case "1256":
                    return "CP1256";
                case "windows-1257": case "cp1257": case "1257":
                    return "CP1257";
                default:
                    return null;
            }
        }

        // Cyrillic letter weights for charset scoring. Ukrainian letters
        // come first: і/ї/є/ґ appear only in a Ukrainian reading, so they
        // are the strongest evidence. Shared letters follow, and the
        // Russian-only ones score lowest — Russian stays supported, never
        // ahead of Ukrainian.
        private static int cyrillic_weight (unichar c) {
            switch (c) {
                // Ukrainian-only evidence (KOI8-U vs KOI8-R)
                case 'і': case 'ї': case 'є': case 'ґ': return 12;
                case 'І': case 'Ї': case 'Є': case 'Ґ': return 12;
                // Ukrainian frequency order
                case 'о': return 10;
                case 'а': case 'н': return 9;
                case 'и': case 'в': case 'т': return 7;
                case 'е': case 'р': case 'с': return 5;
                case 'к': case 'л': case 'у': case 'д': case 'м': return 3;
                case 'п': case 'з': case 'я': case 'б': case 'г':
                case 'ч': case 'х': case 'й': case 'ь': return 2;
                case 'О': case 'А': case 'Н': case 'И': case 'В':
                case 'Т': case 'Е': case 'Р': case 'С': return 2;
                // Russian-only letters: supported, lowest priority
                case 'ы': case 'э': case 'ъ': case 'ё':
                case 'Ы': case 'Э': case 'Ъ': case 'Ё': return 1;
                default:
                    if (c >= 0x0400 && c <= 0x04FF) return 1;
                    return 0;
            }
        }

        private static int cyrillic_score (uint8[] sample, string enc) {
            var buf = new uint8[sample.length + 1];
            Memory.copy (buf, sample, sample.length);
            buf[sample.length] = 0;

            string converted;
            try {
                converted = GLib.convert ((string) buf, sample.length, "UTF-8", enc);
            } catch (GLib.ConvertError e) {
                return -1; // hard failure: encoding cannot represent the bytes
            }

            int score = 0;
            int i = 0;
            while (i < converted.length) {
                unichar c;
                converted.get_next_char (ref i, out c);
                score += cyrillic_weight (c);
            }
            return score;
        }

        // ── Archive enumeration ─────────────────────────────────────────

        private static int enum_cb (ChmLib.File* h, ChmLib.UnitInfoStruct* ui, void* data) {
            var sink = (Gee.ArrayList<string>?) data;
            if (sink == null || ui == null) return ChmLib.ENUMERATOR_CONTINUE;

            var sb = new StringBuilder ();
            for (int k = 0; k < 513; k++) {
                uint8 ch = ui->path[k];
                if (ch == 0) break;
                sb.append_c ((char) ch);
            }
            var path = sb.str;
            if (path.length < 2) return ChmLib.ENUMERATOR_CONTINUE;

            // Skip internal streams ("/#…"), virtual storage ("::…") and
            // directory markers.
            if (path.has_prefix ("/#") || path.has_prefix ("::") || path.has_suffix ("/")) {
                return ChmLib.ENUMERATOR_CONTINUE;
            }
            if (!path.has_prefix ("/")) {
                path = "/" + path;
            }

            sink.add (path);
            return ChmLib.ENUMERATOR_CONTINUE;
        }

        public Gee.ArrayList<string> enumerate_files () {
            _api_mutex.lock ();
            try {
                var list = new Gee.ArrayList<string> ();
                if (_file == null) return list;

                // ALL covers category+type bits; filtering happens in the callback
                // because NORMAL/SPECIAL/META are category bits over FILES/DIRS.
                chm_enumerate (_file, ChmLib.ENUMERATE_ALL, enum_cb, (void*) list);
                return list;
            } finally {
                _api_mutex.unlock ();
            }
        }

        // Content-ish pages (.htm/.html/.txt), sorted — used as search space
        // and as a flat TOC fallback for archives without any TOC metadata.
        public Gee.ArrayList<string> list_content_pages () {
            var pages = new Gee.ArrayList<string> ();
            foreach (var p in enumerate_files ()) {
                var low = p.down ();
                if (low.has_suffix (".htm") || low.has_suffix (".html") || low.has_suffix (".txt")) {
                    pages.add (p);
                }
            }
            pages.sort ((a, b) => strcmp (a, b));
            return pages;
        }

        private string encoding_from_lcid (uint32 lcid) {
            switch (lcid) {
                case 0x0419: case 0x0422: case 0x0423: case 0x0402: case 0x0819:
                    return "CP1251"; // Ukrainian/Russian/Belarusian/Bulgarian
                case 0x0415: case 0x0405: case 0x040E: case 0x0418: case 0x041B: case 0x0424:
                    return "CP1250"; // Central European
                case 0x0408:
                    return "CP1253"; // Greek
                case 0x041F:
                    return "CP1254"; // Turkish
                case 0x040D:
                    return "CP1255"; // Hebrew
                case 0x0401: case 0x0801: case 0x0C01:
                    return "CP1256"; // Arabic
                case 0x0425: case 0x0426: case 0x0427:
                    return "CP1257"; // Baltic
                case 0x042A:
                    return "CP1258"; // Vietnamese
                case 0x041E:
                    return "CP874";  // Thai
                case 0x0411:
                    return "CP932";  // Japanese
                case 0x0412:
                    return "CP949";  // Korean
                case 0x0804:
                    return "CP936";  // Chinese Simplified
                case 0x0404: case 0x0C04:
                    return "CP950";  // Chinese Traditional (TW/HK)
                default:
                    return "CP1252"; // Western
            }
        }

        private string encoding_from_charset (int cs) {
            switch (cs) {
                case 204: return "CP1251";
                case 238: return "CP1250";
                case 161: return "CP1253";
                case 162: return "CP1254";
                case 177: return "CP1255";
                case 178: return "CP1256";
                case 186: return "CP1257";
                case 163: return "CP1258";
                case 128: return "CP932";
                case 129: return "CP949";
                case 134: return "CP936";
                case 136: return "CP950";
                case 255: return "CP850";
                default: return "CP1252";
            }
        }

        // Decode a retrieved unit to UTF-8 text. Validates properly instead
        // of relying on casts (review §4.9).
        private string decode_bytes (uint8[] buffer, long length) {
            if (length <= 0) return "";

            string raw = (string) buffer; // buffer is NUL-terminated (zero-initialised)
            if (raw.validate ()) return raw;

            try {
                return GLib.convert (raw, -1, "UTF-8", _encoding);
            } catch (GLib.ConvertError e) {
                var sb = new StringBuilder ();
                for (int i = 0; i < length && buffer[i] != 0; i++) {
                    sb.append_c ((char) buffer[i]);
                }
                return sb.str;
            }
        }

        // ── Content access ──────────────────────────────────────────────

        // Normalize a URL/path for chmlib lookup. CHMLIB stores entries with
        // a leading '/', so ensure it is present (review §4.1).
        // Anchors are stripped — except "/#NAME" which is an internal
        // metadata file (#SYSTEM, #TOPICS…), not a fragment.
        private string normalize_path (string path) {
            string norm = path;

            if (norm.has_prefix ("file://")) {
                var fp = GLib.File.new_for_uri (norm).get_path ();
                if (fp != null) norm = fp;
                int file_hash = norm.index_of ("#");
                if (file_hash > 1) norm = norm[0:file_hash];
            }

            int anchor = norm.index_of ("#");
            if (anchor > 1) norm = norm[0:anchor];

            var decoded = GLib.Uri.unescape_string (norm, null);
            if (decoded != null && decoded.length > 0) norm = decoded;

            if (norm.length == 0) return "/";
            if (norm[0] != '/') norm = "/" + norm;
            return norm;
        }

        public CHMContent get_content (string path) {
            _api_mutex.lock ();
            try {
                if (_file == null) {
                    return CHMContent.error_result ("No CHM file loaded");
                }

                string norm_path = normalize_path (path);

                ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct ();
                if (chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS &&
                    ui.length <= MAX_UNIT_BYTES) {
                    var buffer = new uint8[(int) ui.length + 1]; // +1 keeps the cast below NUL-terminated
                    long read = chm_retrieve_object (_file, &ui, buffer, 0, (long) ui.length);
                    if (read > 0) {
                        buffer[(int) read] = 0;
                        string content = decode_bytes (buffer, read);
                        return CHMContent.success_result (content, mime_for_path (norm_path), norm_path);
                    }
                }

                return CHMContent.error_result ("Failed to resolve: %s".printf (norm_path));
            } finally {
                _api_mutex.unlock ();
            }
        }

        public GLib.Bytes? get_bytes (string path) {
            _api_mutex.lock ();
            try {
                if (_file == null) return null;

                string norm_path = normalize_path (path);

                ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct ();
                if (chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS &&
                    ui.length <= MAX_UNIT_BYTES) {
                    var buffer = new uint8[(int) ui.length];
                    long read = chm_retrieve_object (_file, &ui, buffer, 0, (long) ui.length);
                    if (read > 0) {
                        return new GLib.Bytes (buffer[0:(int) read]);
                    }
                }

                return null;
            } finally {
                _api_mutex.unlock ();
            }
        }

        public bool has_object (string path) {
            _api_mutex.lock ();
            try {
                if (_file == null) return false;

                string norm_path = normalize_path (path);
                ChmLib.UnitInfoStruct ui = ChmLib.UnitInfoStruct ();
                return chm_resolve_object (_file, norm_path, out ui) == ChmLib.RESOLVE_SUCCESS;
            } finally {
                _api_mutex.unlock ();
            }
        }

        // ── TOC data for TopicsModel ────────────────────────────────────

        // Load raw units used by the binary TOC and compute the first topic
        // URL with the same shared parsers TopicsModel uses.
        public bool get_topics_data (out uint8[] topics, out uint8[] strings,
                                     out uint8[] urltbl, out uint8[] urlstr,
                                     out uint8[]? topidx) {
            topics = new uint8[0];
            strings = new uint8[0];
            urltbl = new uint8[0];
            urlstr = new uint8[0];
            topidx = null;

            _api_mutex.lock ();
            try {
                if (_file == null) return false;

                ChmLib.UnitInfoStruct ts_ui = ChmLib.UnitInfoStruct ();
                ChmLib.UnitInfoStruct st_ui = ChmLib.UnitInfoStruct ();
                ChmLib.UnitInfoStruct ut_ui = ChmLib.UnitInfoStruct ();
                ChmLib.UnitInfoStruct us_ui = ChmLib.UnitInfoStruct ();
                ChmLib.UnitInfoStruct ti_ui = ChmLib.UnitInfoStruct ();

                var mf = meta_file ();
                bool has_ti = chm_resolve_object (mf, "/#TOCIDX", out ti_ui) == ChmLib.RESOLVE_SUCCESS;
                if (chm_resolve_object (mf, "/#TOPICS", out ts_ui) != ChmLib.RESOLVE_SUCCESS ||
                    chm_resolve_object (mf, "/#STRINGS", out st_ui) != ChmLib.RESOLVE_SUCCESS ||
                    chm_resolve_object (mf, "/#URLTBL", out ut_ui) != ChmLib.RESOLVE_SUCCESS ||
                    chm_resolve_object (mf, "/#URLSTR", out us_ui) != ChmLib.RESOLVE_SUCCESS) {
                    return false;
                }

                if (ts_ui.length > MAX_UNIT_BYTES || st_ui.length > MAX_UNIT_BYTES ||
                    ut_ui.length > MAX_UNIT_BYTES || us_ui.length > MAX_UNIT_BYTES) {
                    return false;
                }

                topics = new uint8[(int) ts_ui.length];
                strings = new uint8[(int) st_ui.length];
                urltbl = new uint8[(int) ut_ui.length];
                urlstr = new uint8[(int) us_ui.length];

                if (chm_retrieve_object (mf, &ts_ui, topics, 0, (long) ts_ui.length) != (long) ts_ui.length ||
                    chm_retrieve_object (mf, &st_ui, strings, 0, (long) st_ui.length) != (long) st_ui.length ||
                    chm_retrieve_object (mf, &ut_ui, urltbl, 0, (long) ut_ui.length) != (long) ut_ui.length ||
                    chm_retrieve_object (mf, &us_ui, urlstr, 0, (long) us_ui.length) != (long) us_ui.length) {
                    return false;
                }

                if (has_ti && ti_ui.length >= 4 && ti_ui.length <= MAX_UNIT_BYTES) {
                    topidx = new uint8[(int) ti_ui.length];
                    if (chm_retrieve_object (mf, &ti_ui, topidx, 0, (long) ti_ui.length) != (long) ti_ui.length) {
                        topidx = null;
                    }
                }

                // First topic URL from the very data we just loaded.
                string? first_url = null;
                if (topidx != null) {
                    first_url = btoc_first_url (topidx, topics, strings, urltbl, urlstr);
                }
                if (first_url == null) {
                    first_url = topics_sequential_first_url (topics, strings, urltbl, urlstr);
                }
                if (first_url != null) {
                    _first_topic_url = first_url;
                }

                return true;
            } finally {
                _api_mutex.unlock ();
            }
        }

        // Kept for API compatibility; tree building lives in TopicsModel.
        public bool load_topics_tree (out Object model) {
            model = null;
            _api_mutex.lock ();
            try {
                if (_file == null) return false;
                uint8[] t, s, b, r;
                uint8[]? ti;
                return get_topics_data (out t, out s, out b, out r, out ti);
            } finally {
                _api_mutex.unlock ();
            }
        }

    
    // ── $FIftiMain bit-stream primitives ──────────────────────────────

    // Big-endian ENCint (cpp:128) — bounded.
    static uint64 be_encint_at (uint8[] buf, ref int pos) {
        uint64 result = 0;
        int shift = 0;
        while (true) {
            if (pos < 0 || pos >= buf.length) return uint64.MAX;
            uint8 b = buf[pos];
            result |= (uint64)(b & 0x7f) << shift;
            shift += 7;
            pos++;
            if ((b & 0x80) == 0) break;
            if (shift >= 64) return uint64.MAX;
            if (pos >= buf.length) return uint64.MAX;
        }
        return result;
    }

    // Count of set bits before first unset bit; advances byte/bit (cpp:149).
    // Bounded — returns bits counted so far if the buffer ends.
    static int ffus_at (uint8[] buf, ref int byte_off, ref int bit) {
        if (byte_off < 0 || byte_off >= buf.length || bit < 0 || bit > 7)
            return 0;
        int bits = 0;
        while (byte_off >= 0 && byte_off < buf.length &&
               (buf[byte_off] & (1 << bit)) != 0) {
            if (bit != 0) {
                bit--;
            } else {
                byte_off++;
                if (byte_off >= buf.length) break;
                bit = 7;
            }
            bits++;
            if (bits > buf.length * 8) break; // malformed guard
        }
        if (byte_off >= 0 && byte_off < buf.length && bit >= 0 && bit <= 7) {
            if ((buf[byte_off] & (1 << bit)) == 0) {
                if (bit != 0) {
                    bit--;
                } else {
                    byte_off++;
                    bit = 7;
                }
            }
        }
        return bits;
    }

    // SR-coded integer (cpp:176); s must be 2. Advances byte_off/bit,
    // sets total bytes consumed in `length`.
    static uint64 sr_int_at (uint8[] buf, ref int byte_off, ref int bit,
                             uint8 s, uint8 r, out int length) {
        uint64 ret = 0;
        length = 0;
        if (bit < 0 || bit > 7 || s != 2 ||
            byte_off < 0 || byte_off >= buf.length)
            return uint64.MAX;

        int count = ffus_at (buf, ref byte_off, ref bit);
        int bo = byte_off;

        int n_bits = r + (count > 0 ? count - 1 : 0);
        int n = n_bits;

        while (n > 0) {
            if (bo < 0 || bo >= buf.length) {
                byte_off = bo;
                return uint64.MAX;
            }
            int num_bits = n > bit ? bit : n - 1;
            int shift_base = n > bit ? 0 : bit - (n - 1);
            uint8 mask = (uint8)(((0xff >> (7 - num_bits)) << shift_base) & 0xff);
            ret = (ret << (num_bits + 1)) | (uint64)((buf[bo] & mask) >> shift_base);

            if (n > bit) {
                bo++;
                length++;
                n -= bit + 1;
                bit = 7;
            } else {
                bit -= n;
                n = 0;
            }
        }
        byte_off = bo;
        // The SR code omits the leading 1-bit: count leading ones encode
        // its position. Dropping this OR halved every non-small value and
        // made doc-index deltas point at wrong #TOPICS entries (0 search
        // results on real $FIftiMain books).
        if (count > 0) {
            if (n_bits >= 64) return uint64.MAX;
            ret |= (uint64) 1 << n_bits;
        }
        return ret;
    }


    // ── Full-text search: $FIftiMain B-tree ─────────────────────────

    private struct FtsParams {
        uint8 doc_index_s;
        uint8 doc_index_r;
        uint8 code_count_s;
        uint8 code_count_r;
        uint8 loc_codes_s;
        uint8 loc_codes_r;
    }

    // Reconstruct a word from a node record using prefix reuse (pos).
    // The index stores words in the ARCHIVE encoding; decode to UTF-8 so
    // comparisons against the user's needle work for non-Latin books
    // (CP1251/KOI8-U bytes never byte-match UTF-8 needles otherwise).
    private static void fts_word (uint8[] buffer, int chars_off, int char_len,
                                  int pos, string enc, ref string word) {
        // NUL-terminated copy: the (string) cast below reads until NUL,
        // and a zero-length piece must not produce a NULL string.
        var piece = new uint8[char_len + 1];
        for (int i = 0; i < char_len; i++) {
            piece[i] = buffer[chars_off + i];
        }
        piece[char_len] = 0;
        var decoded = to_utf8 ((string) piece, enc);
        if (pos == 0) {
            word = decoded;
        } else {
            // Prefix reuse pos counts characters of the DECODED word.
            // word.substring expects byte offset; Cyrillic decoded words
            // are 2 bytes/char, so convert char count to bytes.
            int w_chars = (int) word.char_count ();
            int keep_chars = pos < w_chars ? pos : w_chars;
            int keep_bytes = 0;
            int off = 0;
            for (int i = 0; i < keep_chars; i++) {
                unichar c;
                word.get_next_char (ref off, out c);
                keep_bytes = off;
            }
            word = word.substring (0, keep_bytes) + decoded;
        }
    }

    // Walk internal nodes to find the leaf that may contain `text`
    // (cpp:798). Returns 0 when not found.
    private uint32 get_leaf_node_offset (string text, uint32 initial_offset,
                                         uint32 buf_size, uint16 tree_depth,
                                         ChmLib.File* file, ChmLib.UnitInfoStruct* ui,
                                         string enc) {
        uint32 test_offset = 0;
        string word = "";

        if (buf_size == 0) return 0;

        var buffer = new uint8[buf_size];

        while (--tree_depth > 0) {
            if (initial_offset == test_offset) return 0;

            test_offset = initial_offset;
            if (chm_retrieve_object (file, ui, buffer, initial_offset, (long) buf_size) == 0)
                return 0;

            uint16 free_space = UINT16_FROM_ARRAY (buffer, 0);
            uint32 usable = free_space < buf_size ? buf_size - free_space : 0;
            uint32 i = 2;

            while (i < usable) {
                int word_len = buffer[i];
                if (word_len == 0 || i + 2 + word_len > usable)
                    break;

                int pos = buffer[i + 1];
                fts_word (buffer, (int) i + 2, word_len - 1, pos, enc, ref word);

                if (text.down () <= word.down ()) {
                    if (i + word_len + 1 + 4 <= usable) {
                        initial_offset = UINT32_FROM_ARRAY (buffer, (int)(i + word_len + 1));
                    }
                    break;
                }

                i += word_len + 1 + 4 + 2;
            }
        }

        return initial_offset == test_offset ? 0 : initial_offset;
    }


    // Decode one WLC stream: for each document referencing the word,
    // resolve topic title + URL and add to results (cpp:854).
    private bool process_wlc (uint64 wlc_count, uint64 wlc_size, uint32 wlc_offset,
                              FtsParams p,
                              ChmLib.File* f_main, ChmLib.UnitInfoStruct* ui_main,
                              ChmLib.File* f_topics, ChmLib.UnitInfoStruct* ui_topics,
                              ChmLib.File* f_strings, ChmLib.UnitInfoStruct* ui_strings,
                              ChmLib.File* f_urltbl, ChmLib.UnitInfoStruct* ui_urltbl,
                              ChmLib.File* f_urlstr, ChmLib.UnitInfoStruct* ui_urlstr,
                              Gee.ArrayList<SearchResult> results) {
        const int TOPICS_ENTRY_LEN = 16;
        const int COMBUF_LEN = 1024;

        if (wlc_count > 1000000 || wlc_size == uint64.MAX ||
            wlc_size > (uint64) ui_main->length ||
            wlc_size > (uint64) MAX_UNIT_BYTES) {
            return false;
        }

        int bit = 7;
        uint64 index = 0;
        int off = 0;
        int length;

        var buffer = new uint8[wlc_size];
        if (chm_retrieve_object (f_main, ui_main, buffer, (ulong) wlc_offset, (long) wlc_size) != (long) wlc_size) {
            return false;
        }

        var entry = new uint8[TOPICS_ENTRY_LEN];
        var combuf = new uint8[COMBUF_LEN];
        // De-dup set: scanning `results` per document is quadratic on
        // hit-heavy words (review F23).
        var seen_urls = new Gee.HashSet<string> ();

        for (uint64 i = 0; i < wlc_count; ++i) {
            if (bit != 7) {
                off++;
                bit = 7;
            }

            uint64 step = sr_int_at (buffer, ref off, ref bit, p.doc_index_s, p.doc_index_r, out length);
            if (step == uint64.MAX) break;
            index += step;
            if (off >= wlc_size) break;
            if (chm_retrieve_object (f_topics, ui_topics, entry, (ulong)(index * 16), TOPICS_ENTRY_LEN) != TOPICS_ENTRY_LEN) {
                return false;
            }

            uint32 stroff = UINT32_FROM_ARRAY (entry, 4);
            string topic;
            long got = chm_retrieve_object (f_strings, ui_strings, combuf, stroff, COMBUF_LEN - 1);
            if (got <= 0) {
                topic = "Untitled in index";
            } else {
                combuf[(int) got] = 0;
                topic = to_utf8 ((string) combuf, _encoding);
            }

            uint32 urloff = UINT32_FROM_ARRAY (entry, 8);
            if (chm_retrieve_object (f_urltbl, ui_urltbl, combuf, urloff, 12) != 12) {
                return false;
            }

            urloff = UINT32_FROM_ARRAY (combuf, 8);
            got = chm_retrieve_object (f_urlstr, ui_urlstr, combuf, urloff + 8, COMBUF_LEN - 1);
            if (got <= 0) {
                return false;
            }

            combuf[(int) got] = 0;
            string url = (string) combuf;
            if (url.length > 0 && url[0] != '/') url = "/" + url;

            if (topic.length > 0 && url.length > 0 &&
                results.size < MAX_SEARCH_RESULTS && !seen_urls.contains (url)) {
                seen_urls.add (url);
                results.add (new SearchResult (topic, url, 1));
            }

            uint64 count = sr_int_at (buffer, ref off, ref bit, p.code_count_s, p.code_count_r, out length);
            if (count == uint64.MAX || count > 1000000) break;

            for (uint64 j = 0; j < count && off < wlc_size; ++j) {
                uint64 skip = sr_int_at (buffer, ref off, ref bit, p.loc_codes_s, p.loc_codes_r, out length);
                if (skip == uint64.MAX) break;
            }
        }

        return true;
    }

    // Driver (cpp:657). True when the FTS index was usable — even with
    // zero hits — so the caller must not fall back to brute force.
    // words_seen / words_non_ascii report the index vocabulary mix so
    // the caller can detect a degenerate ASCII-only index for non-Latin
    // queries (see search()).
    private bool fts_search (string text, bool whole_words, bool titles_only,
                             out Gee.ArrayList<SearchResult> results,
                             out int words_seen, out int words_non_ascii) {
        results = new Gee.ArrayList<SearchResult> ();
        words_seen = 0;
        words_non_ascii = 0;
        if (_file == null) return false;
        if (text.length == 0) return false;

        var f_main = _file;
        var mf = meta_file ();

        ChmLib.UnitInfoStruct ui_main = ChmLib.UnitInfoStruct ();
        ChmLib.UnitInfoStruct ui_topics = ChmLib.UnitInfoStruct ();
        ChmLib.UnitInfoStruct ui_strings = ChmLib.UnitInfoStruct ();
        ChmLib.UnitInfoStruct ui_urltbl = ChmLib.UnitInfoStruct ();
        ChmLib.UnitInfoStruct ui_urlstr = ChmLib.UnitInfoStruct ();

        if (chm_resolve_object (f_main, "/$FIftiMain", out ui_main) != ChmLib.RESOLVE_SUCCESS ||
            chm_resolve_object (mf, "/#TOPICS", out ui_topics) != ChmLib.RESOLVE_SUCCESS ||
            chm_resolve_object (mf, "/#STRINGS", out ui_strings) != ChmLib.RESOLVE_SUCCESS ||
            chm_resolve_object (mf, "/#URLTBL", out ui_urltbl) != ChmLib.RESOLVE_SUCCESS ||
            chm_resolve_object (mf, "/#URLSTR", out ui_urlstr) != ChmLib.RESOLVE_SUCCESS) {
            return false;
        }

        const int FTS_HEADER_LEN = 0x32;
        var header = new uint8[FTS_HEADER_LEN];
        if (chm_retrieve_object (f_main, &ui_main, header, 0, FTS_HEADER_LEN) == 0)
            return false;

        var p = FtsParams () {
            doc_index_s = header[0x1E], doc_index_r = header[0x1F],
            code_count_s = header[0x20], code_count_r = header[0x21],
            loc_codes_s = header[0x22], loc_codes_r = header[0x23]
        };

        if (p.doc_index_s != 2 || p.code_count_s != 2 || p.loc_codes_s != 2)
            return false;

        uint32 node_offset = UINT32_FROM_ARRAY (header, 0x14);
        uint32 node_len = UINT32_FROM_ARRAY (header, 0x2E);
        uint16 tree_depth = UINT16_FROM_ARRAY (header, 0x18);

        if (node_len == 0 || node_len > MAX_UNIT_BYTES) return false;

        string word = "";
        var buffer = new uint8[node_len];

        node_offset = get_leaf_node_offset (text, node_offset, node_len,
                                            tree_depth, f_main, &ui_main,
                                            _encoding);
        if (node_offset == 0)
            return false;

        string needle = text.down ();
        bool partial = false;

        bool leaf_ok = false;
        do {
            if (chm_retrieve_object (f_main, &ui_main, buffer, node_offset, (long) node_len) == 0) {
                break;
            }
            leaf_ok = true;
            uint16 free_space = UINT16_FROM_ARRAY (buffer, 6);
            uint32 usable = free_space < node_len ? node_len - free_space : 0;
            uint32 i = 4 + 2 + 2;

            // Next leaf pointer rides at buffer[0..3]; it is position-
            // independent, so read it before parsing records: any abort
            // below must not leave a stale offset for the do/while walk.
            node_offset = UINT32_FROM_ARRAY (buffer, 0);

            while (i < usable) {
                int word_len = buffer[i];

                if (word_len == 0 || i + 2 + word_len > usable)
                    break;

                int pos = buffer[i + 1];
                fts_word (buffer, (int) i + 2, word_len - 1, pos, _encoding, ref word);
                words_seen++;
                for (int k = 0; k < word.length; k++) {
                    if ((uint8) word[k] >= 0x80) {
                        words_non_ascii++;
                        break;
                    }
                }

                i += 2 + word_len;

                uint8 title_flag = buffer[i - 1];
                int encsz = 0;

                int ipos = (int) i;
                uint64 wlc_count = be_encint_at (buffer, ref ipos);
                i = (uint32) ipos;

                if (i + 4 > usable)
                    break;

                uint32 wlc_offset = UINT32_FROM_ARRAY (buffer, (int) i);

                i += 4 + 2;
                if (i >= usable)
                    break;
                ipos = (int) i;
                uint64 wlc_size = be_encint_at (buffer, ref ipos);
                i = (uint32) ipos;

                if (wlc_count > 1000000 || wlc_size == uint64.MAX ||
                    wlc_size > (uint64) ui_main.length ||
                    wlc_size > (uint64) MAX_UNIT_BYTES)
                    continue;

                if (title_flag == 0 && titles_only)
                    continue;

                bool is_match = word.down () == needle;

                if (whole_words) {
                    if (is_match) {
                        process_wlc (wlc_count, wlc_size, wlc_offset, p,
                                     f_main, &ui_main, mf, &ui_topics, mf, &ui_strings,
                                     mf, &ui_urltbl, mf, &ui_urlstr, results);
                        break;
                    }
                } else {
                    var wlow = word.down ();
                    if (wlow.has_prefix (needle)) {
                        partial = true;
                        process_wlc (wlc_count, wlc_size, wlc_offset, p,
                                     f_main, &ui_main, mf, &ui_topics, mf, &ui_strings,
                                     mf, &ui_urltbl, mf, &ui_urlstr, results);
                    }
                    // No early break here: the original only breaks on
                    // `CmpNoCase(...) < -1`, which is never true, and a
                    // byte-order break stopped the walk before the first
                    // word whose prefix could match (0 results on real
                    // books). Leaves are small; scanning them whole is
                    // cheap.
                }

                if (results.size >= MAX_SEARCH_RESULTS)
                    break;
            }
        } while (!whole_words && word.down ().has_prefix (needle) && node_offset != 0);

        // Once an index leaf was walked the result is authoritative —
        // zero hits must NOT trigger the brute-force fallback.
        return leaf_ok;
    }

    // ── Text/HHC/HHK access ─────────────────────────────────────────

// Load a text-ish unit (e.g. .hhc/.hhk) decoded to UTF-8.
public string load_text (string path) {
    var bytes = get_bytes (path);
    if (bytes == null || bytes.get_size () == 0) return "";

    unowned uint8[] data = bytes.get_data ();
    var buf = new uint8[data.length + 1];
    Memory.copy (buf, data, data.length);
    buf[data.length] = 0;

    var raw = (string) buf;
    if (raw.validate ()) return raw;
    try {
        return GLib.convert (raw, -1, "UTF-8", _encoding);
    } catch (GLib.ConvertError e) {
        return raw;
    }
}

// Table of contents from the .hhc file (when no #TOCIDX exists).
        public Gee.ArrayList<HhcEntry>? load_hhc_tree () {
            if (_topics_file.length == 0) return null;
            var text = load_text (_topics_file);
            if (text.length == 0) return null;
            return HhcParser.parse_toc (text, _encoding);
        }

// Keyword index: prefer the binary $WWKeywordLinks/BTree, fall back to
        // the .hhk file. Rows are SearchResult(title=keyword, url, rank=0).
        public bool load_index_entries (out Gee.ArrayList<SearchResult> entries) {
            entries = new Gee.ArrayList<SearchResult> ();

            _api_mutex.lock ();
            try {
                if (_file == null) return false;

                if (load_binary_index (out entries)) {
                    return true;
                }

                if (_index_file.length == 0) return false;

                var text = load_text (_index_file);
                if (text.length == 0) return false;

                var parsed_rows = HhcParser.collect_index (text, _encoding);
                foreach (var r in parsed_rows) {
                    string? url = normalize_index_target (r.url);
                    if (url != null && url.length > 0) {
                        entries.add (new SearchResult (r.title, url, r.rank));
                    } else if (url == null) {
                        // external/cross-book target: drop entirely
                    } else if (r.url.length == 0 && r.title.length > 0) {
                        // target-less keyword stays for the filter list
                        entries.add (new SearchResult (r.title, "", r.rank));
                    }
                }
                return entries.size > 0;
            } finally {
                _api_mutex.unlock ();
            }
        }

        // BinaryIndex: UTF-16 keyword records in
        // /$WWKeywordLinks/BTree, topic targets resolved via #TOPICS.
        private bool load_binary_index (out Gee.ArrayList<SearchResult> entries) {
            entries = new Gee.ArrayList<SearchResult> ();
            if (_file == null) return false;
            var mf = meta_file ();

            ChmLib.UnitInfoStruct bt_ui = ChmLib.UnitInfoStruct ();
            ChmLib.UnitInfoStruct ts_ui = ChmLib.UnitInfoStruct ();
            ChmLib.UnitInfoStruct st_ui = ChmLib.UnitInfoStruct ();
            ChmLib.UnitInfoStruct ut_ui = ChmLib.UnitInfoStruct ();
            ChmLib.UnitInfoStruct us_ui = ChmLib.UnitInfoStruct ();

            if (chm_resolve_object (mf, "/$WWKeywordLinks/BTree", out bt_ui) != ChmLib.RESOLVE_SUCCESS ||
                chm_resolve_object (mf, "/#TOPICS", out ts_ui) != ChmLib.RESOLVE_SUCCESS ||
                chm_resolve_object (mf, "/#STRINGS", out st_ui) != ChmLib.RESOLVE_SUCCESS ||
                chm_resolve_object (mf, "/#URLTBL", out ut_ui) != ChmLib.RESOLVE_SUCCESS ||
                chm_resolve_object (mf, "/#URLSTR", out us_ui) != ChmLib.RESOLVE_SUCCESS) {
                return false;
            }

            uint8[] btree = new uint8[0];
            uint8[] topics = new uint8[0];
            uint8[] strings = new uint8[0];
            uint8[] urltbl = new uint8[0];
            uint8[] urlstr = new uint8[0];
            if (!retrieve_unit (mf, bt_ui, out btree) ||
                !retrieve_unit (mf, ts_ui, out topics) ||
                !retrieve_unit (mf, st_ui, out strings) ||
                !retrieve_unit (mf, ut_ui, out urltbl) ||
                !retrieve_unit (mf, us_ui, out urlstr)) {
                return false;
            }

            if (btree.length < 0x4C + 12) return false;

            const uint16 BLOCK_SIZE = 2048;
            int offset = 0x4C;
            int next = -1;

            do {
                if (btree.length < offset + 12) return entries.size != 0;

                uint16 free_space = UINT16_FROM_ARRAY (btree, offset);
                next = (int32) UINT32_FROM_ARRAY (btree, offset + 8);
                int space_left = BLOCK_SIZE - 12;
                offset += 12;

                while (space_left > free_space) {
                    // keyword name: UTF-16 chars until NUL
                    var name = new StringBuilder ();
                    for (;;) {
                        if (btree.length < offset + 2) return entries.size != 0;
                        uint16 ch = UINT16_FROM_ARRAY (btree, offset);
                        offset += 2;
                        space_left -= 2;
                        if (ch == 0) break;
                        append_utf16_char (name, ch);
                    }

                    if (btree.length < offset + 16) return entries.size != 0;
                    uint16 see_also = UINT16_FROM_ARRAY (btree, offset);
                    uint32 num_topics = UINT32_FROM_ARRAY (btree, offset + 0xC);
                    offset += 16;
                    space_left -= 16;

                    if (see_also != 0) {
                        // "see also" pointer: skip its unicode string
                        for (;;) {
                            if (btree.length < offset + 2) return entries.size != 0;
                            uint16 ch = UINT16_FROM_ARRAY (btree, offset);
                            offset += 2;
                            space_left -= 2;
                            if (ch == 0) break;
                        }
                    } else {
                        for (uint32 i = 0; i < num_topics && space_left > free_space; i++) {
                            if (btree.length < offset + 4) return entries.size != 0;
                            uint32 index = UINT32_FROM_ARRAY (btree, offset);
                            offset += 4;
                            space_left -= 4;

                            var url = btoc_item_url (topics, strings, urltbl, urlstr, index);
                            if (url != null && url.length > 0) {
                                entries.add (new SearchResult (name.str, url, 0));
                            }
                        }
                    }

                    if (btree.length < offset + 8) return entries.size != 0;
                    offset += 8;
                    space_left -= 8;
                }

                offset += space_left;   // skip block padding
            } while (next != -1);

            return entries.size != 0;
        }

        static void append_utf16_char (StringBuilder sb, uint16 unit) {
            sb.append_unichar ((unichar) unit);
        }

        static bool retrieve_unit (ChmLib.File* f, ChmLib.UnitInfoStruct ui, out uint8[] data) {
            data = new uint8[0];
            if (ui.length == 0 || ui.length > MAX_UNIT_BYTES) return false;
            var buf = new uint8[(int) ui.length];
            if (chm_retrieve_object (f, &ui, buf, 0, (long) ui.length) != (long) ui.length) {
                return false;
            }
            data = buf;
            return true;
        }

static string? normalize_index_target (string target) {
    var t = target.strip ();
    if (t.length == 0) return "";
    var low = t.down ();
    if (low.has_prefix ("http://") || low.has_prefix ("https://") ||
        low.has_prefix ("mailto:") || low.has_prefix ("ms-its:") ||
        low.has_prefix ("ftp://")) {
        return null; // not an internal page
    }
    // Strip archive prefix of cross-book links
    int marker = low.index_of (".chm/");
    if (low.has_prefix ("mk:@msitstore:") && marker >= 0) {
        return t.substring (marker + 4);
    }
    if (t[0] != '/') return "/" + t;
    return t;
}

// All topic URLs known to the archive (from #TOPICS), de-duplicated,
// TOC order. Also fills a url→title map for search results.
public Gee.ArrayList<string> enumerate_topic_urls (out Gee.HashMap<string, string> titles) {
    titles = new Gee.HashMap<string, string> ();
    var urls = new Gee.ArrayList<string> ();

    uint8[] topics, strings, urltbl, urlstr;
    uint8[]? topidx;
    if (!get_topics_data (out topics, out strings, out urltbl, out urlstr, out topidx)) {
        return urls;
    }

    var enc = _encoding;
    var seen = new Gee.HashSet<string> ();
    uint32 count = topics.length / 16;
    for (uint32 i = 0; i < count; i++) {
        var url = btoc_item_url (topics, strings, urltbl, urlstr, i);
        if (url == null || seen.contains (url)) continue;
        seen.add (url);
        urls.add (url);

        if (!titles.has_key (url)) {
            var name = btoc_item_name (topics, strings, i, enc);
            if (name != null && name.length > 0) {
                titles[url] = name;
            }
        }
    }
    return urls;
}

// ── Full-text search (v1: scan pages; $FIftiMain port pending) ────

public bool search (string query, bool whole_words, bool titles_only,
                    out Gee.ArrayList<SearchResult> results) {
    results = new Gee.ArrayList<SearchResult> ();

    var needle = query.down ().strip ();
    if (needle.length == 0) return false;

    // Fast path under the API lock: $FIftiMain walks raw chmlib handles
    // that close() would free, and a compiled-index walk is short.
    _api_mutex.lock ();
    bool indexed;
    int fts_words_seen = 0;
    int fts_words_non_ascii = 0;
    try {
        indexed = _file != null && fts_search (needle, whole_words, titles_only,
                                               out results, out fts_words_seen,
                                               out fts_words_non_ascii);
    } finally {
        _api_mutex.unlock ();
    }
    bool needle_non_ascii = false;
    for (int i = 0; i < needle.length; i++) {
        if ((uint8) needle[i] >= 0x80) { needle_non_ascii = true; break; }
    }
    // Trust an authoritative FTS zero UNLESS the needle cannot possibly
    // be in the index: HHW compilers built on non-Ukrainian locales index
    // only ASCII fragments of scanned books (stray high-byte OCR noise
    // aside), so non-Latin queries never match there and a full scan is
    // the only honest answer. A healthy native-language index is mostly
    // non-ASCII words; a degenerate one is almost pure ASCII.
    if (indexed && (results.size > 0 ||
                    !(needle_non_ascii && fts_words_non_ascii * 20 < fts_words_seen))) {
        return true;
    }
    results = new Gee.ArrayList<SearchResult> ();

    // Brute force — potentially minutes long. Snapshot the URL list under
    // the lock, then fetch each page in its own short locked section:
    // the chm:// scheme handler runs on the main loop, so holding the
    // mutex for the whole scan froze link clicks, lazy images and tab
    // closes until it finished (review F2). After close() mid-scan,
    // get_content fails cleanly and the loop drains without hits.
    Gee.HashMap<string, string> titles = new Gee.HashMap<string, string> ();
    var urls = new Gee.ArrayList<string> ();
    var seen = new Gee.HashSet<string> ();

    _api_mutex.lock ();
    try {
        if (_file != null) {
            urls = enumerate_topic_urls (out titles);
            foreach (var u in urls) seen.add (u);
            foreach (var p in list_content_pages ()) {
                if (!seen.contains (p)) {
                    seen.add (p);
                    urls.add (p);
                }
            }
        }
    } finally {
        _api_mutex.unlock ();
    }

    // Matching pass: rank pages, and remember each page's <title> and
    // first heading so result labels stay distinguishable.
    var page_titles = new Gee.HashMap<string, string> ();
    var page_headings = new Gee.HashMap<string, string> ();
    var hits = new Gee.ArrayList<SearchResult> ();

    for (int idx = 0; idx < urls.size && hits.size < MAX_SEARCH_RESULTS; idx++) {
        var url = urls[idx];
        bool have_title = titles.has_key (url) && titles[url].length > 0;
        string title = have_title
            ? titles[url]
            : url.substring (url.last_index_of ("/") + 1);

        string haystack;
        if (titles_only) {
            haystack = title.down ();
        } else {
            var c = get_content (url);   // short lock per page
            if (!c.success) continue;
            haystack = to_utf8 (c.content.down (), _encoding);
            // Archives without #TOPICS names would list raw file names
            // as result titles — remember the page <title>/heading for
            // the label pass below.
            if (!have_title) {
                page_titles[url] = page_title_of (c.content, _encoding);
                page_headings[url] = page_heading_of (c.content, _encoding);
            }
        }

        int hits_n = count_matches (haystack, needle, whole_words);
        if (hits_n > 0) {
            hits.add (new SearchResult (title, url, hits_n));
        }
    }

    // Label pass: HHW books often title every page with the book name
    // ("Національний університет" ×17) — identical labels are useless.
    // Prefer unique <title>s, then unique first headings, then the
    // file name.
    var label_counts = new Gee.HashMap<string, int> ();
    foreach (var h in hits) {
        string cand = h.title;
        if (!titles.has_key (h.url) || titles[h.url].length == 0) {
            cand = page_titles.has_key (h.url) ? page_titles[h.url] : "";
        }
        if (cand.length == 0)
            cand = h.url.substring (h.url.last_index_of ("/") + 1);
        label_counts[cand] = (label_counts.has_key (cand) ? label_counts[cand] : 0) + 1;
    }
    foreach (var h in hits) {
        string label = h.title;
        if (!titles.has_key (h.url) || titles[h.url].length == 0) {
            label = page_titles.has_key (h.url) ? page_titles[h.url] : "";
        }
        if (label.length == 0 || label_counts[label] > 1) {
            string head = page_headings.has_key (h.url)
                ? page_headings[h.url] : "";
            if (head.length > 0 && head != label &&
                (!label_counts.has_key (head) || label_counts[head] == 0)) {
                label = head;
            } else {
                label = h.url.substring (h.url.last_index_of ("/") + 1);
            }
        }
        results.add (new SearchResult (label, h.url, h.rank));
    }
    return results.size > 0;
}

// <title> text of a served page (already UTF-8), tags/entities resolved.
private static string page_title_of (string html, string enc) {
    var low = HtmlTextUtils.ascii_down (html);
    int open = low.index_of ("<title");
    if (open < 0) return "";
    int gt = html.index_of (">", open);
    int close = low.index_of ("</title", gt);
    if (gt < 0 || close < 0 || close <= gt + 1) return "";
    var raw = html.substring (gt + 1, close - gt - 1).strip ();
    if (raw.length == 0) return "";
    var decoded = EntityByteDecoder.fixup (raw, enc);
    return HhcParser.decode_entities (decoded).strip ();
}

// First <h1>/<h2> heading of a served page — a per-page label when the
// <title> is duplicated across the book.
private static string page_heading_of (string html, string enc) {
    var low = HtmlTextUtils.ascii_down (html);
    foreach (string tag in new string[] { "<h1", "<h2" }) {
        int open = low.index_of (tag);
        if (open < 0) continue;
        int gt = html.index_of (">", open);
        if (gt < 0) continue;
        string close_tag = "</" + tag.substring (1);
        int close = low.index_of (close_tag, gt);
        if (close < 0 || close <= gt + 1) continue;
        var raw = html.substring (gt + 1, close - gt - 1);
        var decoded = EntityByteDecoder.fixup (raw, enc);
        // Drop nested markup (e.g. <a name=…> inside headings) and
        // collapse whitespace runs.
        var sb = new StringBuilder ();
        bool in_tag = false;
        for (int i = 0; i < decoded.length; i++) {
            char ch = decoded[i];
            if (ch == '<') { in_tag = true; continue; }
            if (ch == '>') { in_tag = false; continue; }
            if (!in_tag) {
                bool ws = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
                if (ws && sb.len > 0 && sb.str[sb.len - 1] == ' ') continue;
                sb.append_c (ws ? ' ' : ch);
            }
        }
        var text = HhcParser.decode_entities (sb.str).strip ();
        if (text.length > 0) return text;
    }
    return "";
}

private const int MAX_SEARCH_RESULTS = 512;

static int count_matches (string haystack_down, string needle_down, bool whole_words) {
    int nlen = needle_down.length;
    if (nlen == 0) return 0;

    if (!whole_words) {
        int count = 0;
        int pos = 0;
        while ((pos = haystack_down.index_of (needle_down, pos)) >= 0) {
            count++;
            pos += nlen;
        }
        return count;
    }

    // Whole-word mode: map match offsets to character boundaries. The
    // offset table is built once per haystack — the previous version
    // allocated the whole prefix substring PER MATCH, which is
    // quadratic on hit-heavy pages (review F23).
    int nchars = haystack_down.char_count ();
    if (nchars == 0) return 0;
    var starts = new int[nchars];
    int bi = 0;
    int ci = 0;
    unichar ch;
    while (bi < haystack_down.length && ci < nchars) {
        starts[ci++] = bi;
        haystack_down.get_next_char (ref bi, out ch);
    }

    int count = 0;
    int pos = 0;
    while ((pos = haystack_down.index_of (needle_down, pos)) >= 0) {
        unichar prev = ' ';
        unichar next = ' ';

        // Character immediately before the match (ends exactly at pos).
        int pi = char_index_at_or_after (starts, pos) - 1;
        if (pi >= 0) {
            int tmp = starts[pi];
            haystack_down.get_next_char (ref tmp, out prev);
        }

        // Character immediately after the match.
        int ni = char_index_at_or_after (starts, pos + nlen);
        if (ni < nchars) {
            int tmp = starts[ni];
            haystack_down.get_next_char (ref tmp, out next);
        }

        if (!prev.isalnum () && !next.isalnum ()) count++;
        pos += nlen;
    }
    return count;
}

// Binary search: index of the first character whose byte offset is >=
// `byte_off` in the sorted `starts` table.
static int char_index_at_or_after (int[] starts, int byte_off) {
    int lo = 0;
    int hi = starts.length - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (starts[mid] >= byte_off) {
            hi = mid - 1;
        } else {
            lo = mid + 1;
        }
    }
    return lo;
}

// LoadContextIDs: /#IVB holds
        // [u32 skipped][u32 cid][u32 #STRINGS-offset] triplets; names resolve
        // through the metadata handle's #STRINGS.
        public void load_context_ids () {
            _api_mutex.lock ();
            try {
                cid_map.clear ();
                if (_file == null) return;

                ChmLib.UnitInfoStruct ivb_ui = ChmLib.UnitInfoStruct ();
                ChmLib.UnitInfoStruct strs_ui = ChmLib.UnitInfoStruct ();

                // #IVB sits beside the other internal units — companion when
                // present, else the archive itself.
                int rivb = chm_resolve_object (meta_file (), "/#IVB", out ivb_ui);
                int rstr = chm_resolve_object (meta_file (), "/#STRINGS", out strs_ui);
                if (rivb != ChmLib.RESOLVE_SUCCESS || rstr != ChmLib.RESOLVE_SUCCESS) {
                    return;
                }

                uint8[] ivb;
                if (!retrieve_unit (meta_file (), ivb_ui, out ivb)) return;

                if (ivb.length < 12) return;   // 4-byte skip + at least one cid pair

                size_t n = ivb.length / 4 - 1;          // skip leading dword
                if (n % 2 != 0) return;

                uint8[] strings;
                if (!retrieve_unit (meta_file (), strs_ui, out strings)) return;

                for (size_t i = 0; i + 1 < n; i += 2) {
                    uint32 cid = UINT32_FROM_ARRAY (ivb, (int) ((i + 1) * 4));
                    uint32 soff = UINT32_FROM_ARRAY (ivb, (int) ((i + 2) * 4));
                    var s = read_cstring (strings, (int) soff);
                    if (s != null && s.length > 0 && !cid_map.has_key (cid)) {
                        cid_map[cid] = "/" + s;
                    }
                }
            } finally {
                _api_mutex.unlock ();
            }
        }

        public bool is_valid_cid (int context_id) {
            return cid_map.has_key ((uint32) context_id);
        }

        public string get_page_by_cid (int context_id) {
            var v = cid_map[(uint32) context_id];
            return v ?? "";
        }

// Single source of truth for extension→MIME mapping.
        public static string mime_for_path (string path) {
            string low = path.down ();
            if (low.has_suffix (".html") || low.has_suffix (".htm"))
                return "text/html";
            else if (low.has_suffix (".css"))
                return "text/css";
            else if (low.has_suffix (".js"))
                return "application/javascript";
            else if (low.has_suffix (".png"))
                return "image/png";
            else if (low.has_suffix (".jpg") || low.has_suffix (".jpeg"))
                return "image/jpeg";
            else if (low.has_suffix (".gif"))
                return "image/gif";
            else if (low.has_suffix (".svg"))
                return "image/svg+xml";
            else if (low.has_suffix (".ico"))
                return "image/x-icon";
            else if (low.has_suffix (".pdf"))
                return "application/pdf";
            else if (low.has_suffix (".txt"))
                return "text/plain";
            else if (low.has_suffix (".xml"))
                return "application/xml";
            else
                return "application/octet-stream";
        }
    }
}