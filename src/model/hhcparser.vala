// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Parser for .hhc (table of contents) and .hhk (keyword index) files.
// These are HTML-ish documents built from nested <ul>/<li> lists whose
// items carry <object type="text/sitemap"> blocks with <param> pairs.
//
// Two quirks handled:
//  - HHK objects may hold a keyword followed by (Name=title, Local=url)
//    target pairs; each pair becomes its own result row.
//  - Names may be stored as Latin-1 named entities of *archive-encoded*
//    bytes ("&Ntilde;&icirc;" = bytes D1 EE = "Си" in CP1251). After entity
//    decoding such names are re-encoded via the archive charset.

using GLib;
using Gee;

namespace Vchm.Model {

    public class HhcEntry : Object {
        public string name { get; set; }
        public string local { get; set; } // primary target as stored (no leading '/')
        public Gee.ArrayList<string> targets { get; private set; } // all Local/Url params
        public Gee.ArrayList<HhcEntry> children { get; private set; }

        public HhcEntry (string name, string local) {
            this.name = name;
            this.local = local;
            targets = new Gee.ArrayList<string> ();
            children = new Gee.ArrayList<HhcEntry> ();
        }
    }

    public class HhcParser : Object {

        // Parse a TOC document into a forest of entries.
        public static Gee.ArrayList<HhcEntry>? parse_toc (string text, string enc) {
            var roots = new Gee.ArrayList<HhcEntry> ();

            // Frames track the entry list of each open <ul> level plus the
            // newest entry there, which owns the next nested <ul>.
            var frames = new Gee.ArrayList<Frame> ();
            frames.add (new Frame (roots));
            int obj_start = -1;

            int i = 0;
            int n = text.length;
            while (i < n) {
                int lt = text.index_of ("<", i);
                if (lt < 0) break;
                int gt = text.index_of (">", lt);
                if (gt < 0) break;

                string tag = text.substring (lt + 1, gt - lt - 1).down ().strip ();

                if (tag.has_prefix ("ul")) {
                    frames.add (new Frame ());
                } else if (tag.has_prefix ("/ul")) {
                    if (frames.size > 1) {
                        var closed = frames[frames.size - 1];
                        frames.remove_at (frames.size - 1);
                        var parent_frame = frames[frames.size - 1];
                        if (parent_frame.last != null) {
                            // Nested list: children belong to the newest entry.
                            foreach (var c in closed.list) {
                                parent_frame.last.children.add (c);
                            }
                        } else {
                            // Top-level list: promote its items to our level.
                            foreach (var c in closed.list) {
                                parent_frame.list.add (c);
                            }
                            if (closed.list.size > 0) {
                                parent_frame.last = closed.list[closed.list.size - 1];
                            }
                        }
                    }
                } else if (tag.has_prefix ("object")) {
                    obj_start = gt + 1;
                } else if (tag.has_prefix ("/object")) {
                    if (obj_start >= 0) {
                        var block = text.substring (obj_start, lt - obj_start);
                        obj_start = -1;

                        SitemapParams p;
                        collect_params (block, enc, out p);
                        if (p.keyword != null && p.keyword.length > 0) {
                            var frame = frames[frames.size - 1];
                            var e = new HhcEntry (
                                p.keyword,
                                p.targets.size > 0 ? p.targets[0].url : "");
                            foreach (var t in p.targets) {
                                e.targets.add (t.url);
                            }
                            frame.list.add (e);
                            frame.last = e;
                        }
                    }
                }

                i = gt + 1;
            }

            return roots.size > 0 ? roots : null;
        }

        // Flat keyword list from an .hhk document. A keyword followed by
// (Name=title, Local=url) pairs yields one row per target titled by the
// paired Name (or the keyword when absent); keyword-only objects yield
// url-less rows so the filter list still shows them.
        public static Gee.ArrayList<SearchResult> collect_index (string text, string enc) {
            var out_list = new Gee.ArrayList<SearchResult> ();

            var low = text.down ();
            int pos = 0;
            for (;;) {
                int obj = low.index_of ("<object", pos);
                if (obj < 0) break;
                int obj_gt = text.index_of (">", obj);
                if (obj_gt < 0) break;
                int end = low.index_of ("</object>", obj_gt);
                if (end < 0) break;

                SitemapParams p;
                collect_params (text.substring (obj_gt + 1, end - obj_gt - 1), enc, out p);

                if (p.keyword != null && p.keyword.length > 0) {
                    var keyword = p.keyword;
                    if (p.targets.size == 0) {
                        out_list.add (new SearchResult (keyword, "", 0));
                    } else {
                        foreach (var t in p.targets) {
                            string title = t.title.length > 0 ? t.title : keyword;
                            out_list.add (new SearchResult (title, t.url, 0));
                        }
                    }
                }

                pos = end;
            }
            return out_list;
        }

        // ── Object body parsing ─────────────────────────────────────────

        private class TargetParam : Object {
            public string title; // paired Name or "" when absent
            public string url;
        }

        private class SitemapParams : Object {
            public string? keyword = null;
            public Gee.ArrayList<TargetParam> targets = new Gee.ArrayList<TargetParam> ();
        }

        // Walk <param> tags in order: first Name is the keyword; every
        // subsequent Name starts a pending title that the next Local/Url
        // completes.
        static void collect_params (string block, string enc, out SitemapParams p) {
            p = new SitemapParams ();
            string pending_title = null;

            int pos = 0;
            for (;;) {
                pos = block.index_of ("<param", pos);
                if (pos < 0) break;
                int tag_end = block.index_of (">", pos);
                if (tag_end < 0) break;
                var tag = block.substring (pos, tag_end - pos);

                string nm = read_attr (tag, "name");
                string vl = read_attr (tag, "value");
                if (nm != null && vl != null) {
                    switch (nm.down ()) {
                        case "name":
                            var decoded = fixup_name (decode_entities (vl), enc);
                            if (p.keyword == null) {
                                p.keyword = decoded;
                            } else {
                                pending_title = decoded;
                            }
                            break;
                        case "local":
                        case "url":
                            var tp = new TargetParam () {
                                title = pending_title ?? "",
                                url = vl.strip ()
                            };
                            pending_title = null;
                            p.targets.add (tp);
                            break;
                        default:
                            break;
                    }
                }
                pos = tag_end + 1;
            }
        }

        static string? read_attr (string tag, string attr_name) {
            var low = tag.down ();
            int k = low.index_of (attr_name + "=");
            while (k > 0) {
                unichar prev = low[k - 1];
                if (!prev.isalnum () && prev != '-' && prev != '_') break;
                k = low.index_of (attr_name + "=", k + 1);
            }
            if (k < 0) return null;

            int eq = k + attr_name.length + 1;
            while (eq < tag.length && tag[eq] == ' ') eq++;
            if (eq >= tag.length) return null;

            char quote = tag[eq];
            if (quote == '"' || quote == '\'') {
                int end = tag.index_of_char (quote, eq + 1);
                if (end < 0) return null;
                return tag.substring (eq + 1, end - eq - 1);
            }
            int end = eq;
            while (end < tag.length && tag[end] != ' ' && tag[end] != '\t' && tag[end] != '/') end++;
            return tag.substring (eq, end - eq);
        }

        // ── Text fixes ──────────────────────────────────────────────────

        // If the decoded name consists of Latin-1-range characters only it
        // likely represents archive-encoded bytes written as named entities;
        // convert those bytes to UTF-8 using `enc`. Real Unicode passes through.
        // Convert Latin-1-range runs through the archive charset while
        // passing real-Unicode characters through untouched — names may mix
        // entity-encoded bytes with already-decoded Cyrillic.
        public static string fixup_name (string s, string enc = "") {
            if (enc.length == 0 || enc.has_prefix ("UTF")) return s;
            if (!s.validate ()) return s;

            var out_sb = new StringBuilder ();
            var run = new uint8[s.length];      // pending high-byte run
            int ri = 0;
            bool any_high = false;

            int i = 0;
            while (i < s.length) {
                unichar c;
                s.get_next_char (ref i, out c);
                if (c >= 0x80 && c <= 0xFF) {
                    run[ri++] = (uint8) c;
                    any_high = true;
                } else {
                    flush_run (out_sb, run, ref ri, enc);
                    sb_append_unichar (out_sb, c);
                }
            }
            flush_run (out_sb, run, ref ri, enc);
            return any_high ? out_sb.str : s;
        }

        private static void sb_append_unichar (StringBuilder sb, unichar c) {
            sb.append_unichar (c);
        }

        private static void flush_run (StringBuilder sb, uint8[] run, ref int ri, string enc) {
            if (ri == 0) return;
            var buf = new uint8[ri + 1];
            Memory.copy (buf, run, ri);
            buf[ri] = 0;
            try {
                sb.append (GLib.convert ((string) buf, ri, "UTF-8", enc));
            } catch (GLib.ConvertError e) {
                for (int k = 0; k < ri; k++) sb.append_c ((char) run[k]);
            }
            ri = 0;
        }

        public static string decode_entities (string s) {
            if (!s.contains ("&")) return s;

            var sb = new StringBuilder ();
            int i = 0;
            int n = s.length;
            while (i < n) {
                int amp = s.index_of ("&", i);
                if (amp < 0) {
                    sb.append (s.substring (i));
                    break;
                }
                sb.append (s.substring (i, amp - i));

                int semi = s.index_of (";", amp);
                if (semi < 0 || semi - amp > 12) {
                    sb.append_c ('&');
                    i = amp + 1;
                    continue;
                }

                var ent_low = s.substring (amp + 1, semi - amp - 1).down ();
                var ent = ent_low;
                switch (ent) {
                    case "amp": sb.append_c ('&'); break;
                    case "lt": sb.append_c ('<'); break;
                    case "gt": sb.append_c ('>'); break;
                    case "quot": sb.append_c ('"'); break;
                    case "apos": sb.append_c ('\''); break;
                    case "nbsp": sb.append_c (' '); break;
                    default:
                        if (ent.has_prefix ("#")) {
                            int code = ent.has_prefix ("#x")
                                ? (int) long.parse (ent.substring (2), 16)
                                : int.parse (ent.substring (1));
                            sb.append_unichar ((unichar) code);
                        } else {
                            unichar mapped = entity_by_name (
                                s.substring (amp + 1, semi - amp - 1));
                            if (mapped > 0) {
                                sb.append_unichar (mapped);
                            } else {
                                // Unknown entity: keep the original text.
                                sb.append (s.substring (amp, semi - amp + 1));
                            }
                        }
                        break;
                }
                i = semi + 1;
            }
            return sb.str;
        }

        // HTML4 Latin-1 named entities → code point.
        // Resolution is case-aware but not case-exclusive: the exact
        // spelling decides (&ETH; 208 ≠ &eth; 240, &Dagger; 8225), and
        // names that miss both exact tables fall back through the
        // capitalized-form table (routing on the first
        // letter's case left "&Dagger;"/"&Prime;" unresolvable).
        public static unichar entity_by_name (string raw_name) {
            if (raw_name.length == 0) return 0;
            var mapped = latin1_entity (raw_name);
            if (mapped > 0) return mapped;
            if (raw_name.length < 2) return 0;
            return upper_latin1 (raw_name.down ());
        }

        public static unichar latin1_entity (string e) {
            switch (e) {
                case "quot": return 34; case "amp": return 38; case "apos": return 39;
                case "lt": return 60; case "gt": return 62;
                case "nbsp": return 160; case "iexcl": return 161; case "cent": return 162;
                case "pound": return 163; case "curren": return 164; case "yen": return 165;
                case "brvbar": return 166; case "sect": return 167; case "uml": return 168;
                case "copy": return 169; case "ordf": return 170; case "laquo": return 171;
                case "not": return 172; case "shy": return 173; case "reg": return 174;
                case "macr": return 175; case "deg": return 176; case "plusmn": return 177;
                case "sup2": return 178; case "sup3": return 179; case "acute": return 180;
                case "micro": return 181; case "para": return 182; case "middot": return 183;
                case "cedil": return 184; case "sup1": return 185; case "ordm": return 186;
                case "raquo": return 187; case "frac14": return 188; case "frac12": return 189;
                case "frac34": return 190; case "iquest": return 191; case "agrave": return 224;
                case "aacute": return 225; case "acirc": return 226; case "atilde": return 227;
                case "auml": return 228; case "aring": return 229; case "aelig": return 230;
                case "ccedil": return 231; case "egrave": return 232; case "eacute": return 233;
                case "ecirc": return 234; case "euml": return 235; case "igrave": return 236;
                case "iacute": return 237; case "icirc": return 238; case "iuml": return 239;
                case "eth": return 240; case "ntilde": return 241; case "ograve": return 242;
                case "oacute": return 243; case "ocirc": return 244; case "otilde": return 245;
                case "ouml": return 246; case "divide": return 247; case "oslash": return 248;
                case "ugrave": return 249; case "uacute": return 250; case "ucirc": return 251;
                case "uuml": return 252; case "yacute": return 253; case "thorn": return 254;
                case "szlig": return 223; case "yuml": return 255;
                case "times": return 215;
                case "ensp": return 8194; case "emsp": return 8195;
                case "thinsp": return 8201; case "zwnj": return 8204;
                case "zwj": return 8205; case "lrm": return 8206;
                case "rlm": return 8207; case "ndash": return 8211;
                case "mdash": return 8212; case "lsquo": return 8216;
                case "rsquo": return 8217; case "sbquo": return 8218;
                case "ldquo": return 8220; case "rdquo": return 8221;
                case "bdquo": return 8222; case "dagger": return 8224;
                case "Dagger": return 8225; case "bull": return 8226;
                case "hellip": return 8230; case "permil": return 8240;
                case "prime": return 8242; case "Prime": return 8243;
                case "lsaquo": return 8249; case "rsaquo": return 8250;
                case "oline": return 8254; case "frasl": return 8260;
                case "euro": return 8364;
                default: break;
            }
            // Uppercase forms start with a capital letter.
            if (e.length >= 2) {
                var lower = e.down ();
                var upper_map = upper_latin1 (lower);
                if (upper_map > 0) return upper_map;
            }
            return 0;
        }

        static unichar upper_latin1 (string lower) {
            switch (lower) {
                case "agrave": return 192; case "aacute": return 193; case "acirc": return 194;
                case "atilde": return 195; case "auml": return 196; case "aring": return 197;
                case "aelig": return 198; case "ccedil": return 199; case "egrave": return 200;
                case "eacute": return 201; case "ecirc": return 202; case "euml": return 203;
                case "igrave": return 204; case "iacute": return 205; case "icirc": return 206;
                case "iuml": return 207; case "eth": return 208; case "ntilde": return 209;
                case "ograve": return 210; case "oacute": return 211; case "ocirc": return 212;
                case "otilde": return 213; case "ouml": return 214; case "oslash": return 216;
                case "ugrave": return 217; case "uacute": return 218; case "ucirc": return 219;
                case "uuml": return 220; case "yacute": return 221; case "thorn": return 222;
                default: return 0;
            }
        }
    }

    // Internal parse-frame: the open <ul>'s entry list and its newest entry.
    private class Frame : Object {
        public Gee.ArrayList<HhcEntry> list;
        public HhcEntry? last;

        public Frame (Gee.ArrayList<HhcEntry>? initial = null) {
            list = initial ?? new Gee.ArrayList<HhcEntry> ();
            last = null;
        }
    }
}