// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

namespace Vchm.Model {

    // Pure HTML string helpers kept GTK-free for headless testing.
    public class HtmlTextUtils : Object {

        // Lowercase ASCII letters only. Unlike string.down() this preserves
        // byte length 1:1, so offsets computed on the lowered copy stay
        // valid in the original — full down() can resync UTF-8 (e.g. 'İ'
        // lowers to a two-char sequence) and desync paired indexes
        // (review F24).
        public static string ascii_down (string s) {
            var buf = new uint8[s.length + 1];
            Memory.copy (buf, s.data, s.length);
            buf[s.length] = 0;
            for (int i = 0; i < s.length; i++) {
                if (buf[i] >= 'A' && buf[i] <= 'Z') buf[i] += 'a' - 'A';
            }
            return (string) buf;
        }

        // Rewrite every charset= declaration to utf-8. Covers
        // <meta http-equiv="Content-Type" content="...; charset=X"> and
        // <meta charset="X"> forms, in single/double/unquoted styles.
        public static string normalize_charset_decls (string html) {
            var low = ascii_down (html);
            var sb = new StringBuilder ();
            int i = 0;
            int n = html.length;
            bool replaced_any = false;

            while (i < n) {
                int k = low.index_of ("charset", i);
                if (k < 0) {
                    sb.append (html.substring (i));
                    break;
                }
                // word boundary: preceding char must not be alphanumeric
                if (k > 0) {
                    unichar prev = low[k - 1];
                    if (prev.isalnum () || prev == '-' || prev == '_') {
                        // not our keyword; copy through this occurrence
                        sb.append (html.substring (i, k - i + 7));
                        i = k + 7;
                        continue;
                    }
                }

                int j = k + 7;
                while (j < n && (html[j] == ' ' || html[j] == '\t')) j++;
                if (j >= n || html[j] != '=') {
                    sb.append (html.substring (i, k - i + 7));
                    i = k + 7;
                    continue;
                }
                j++;                                    // past '='
                while (j < n && (html[j] == ' ' || html[j] == '\t')) j++;

                char quote = j < n ? html[j] : '\0';
                int value_start = j;
                if (quote == '"' || quote == '\'') value_start = j + 1;

                int v = value_start;
                while (v < n) {
                    char c = html[v];
                    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_' ||
                        c == '.' || c == ':') {
                        v++;
                    } else {
                        break;
                    }
                }
                if (v == value_start) {
                    // no charset value here; keep original text
                    sb.append (html.substring (i, k - i + 7));
                    i = k + 7;
                    continue;
                }

                // emit up to and including any opening quote, then utf-8
                sb.append (html.substring (i, value_start - i));
                sb.append ("utf-8");
                replaced_any = true;
                i = v;
            }

            return replaced_any ? sb.str : html;
        }

        // Content-Security-Policy restricting every subresource load to the
        // local archives (chm:) and inline data: URLs. CHM pages must never
        // reach the network: remote images, styles, fonts and frames are
        // blocked at the engine level, not just unresolved.
        public static string local_only_csp_meta () {
            return "<meta http-equiv=\"Content-Security-Policy\" " +
                "content=\"default-src chm: data:; img-src chm: data:; " +
                "style-src chm: data: 'unsafe-inline'; font-src chm: data:; " +
                "script-src 'none'; object-src 'none'; " +
                "frame-src chm: data:; form-action 'none'\">";
        }

        // Insert the local-only CSP meta right after <head> (case-insensitive,
        // <header> not confused for <head>). Falls back to a synthetic head
        // after <html>, then to prepending — WebKit honours the first CSP
        // declaration it sees.
        public static string inject_local_only_csp (string html) {
            var meta = local_only_csp_meta ();
            // ascii_down keeps offsets paired with `html` for the splices.
            var low = ascii_down (html);

            int i = index_of_tag (low, "<head");
            if (i >= 0) {
                int gt = low.index_of (">", i);
                if (gt >= 0) {
                    return html.substring (0, gt + 1) + meta +
                           html.substring (gt + 1);
                }
            }

            i = index_of_tag (low, "<html");
            if (i >= 0) {
                int gt = low.index_of (">", i);
                if (gt >= 0) {
                    return html.substring (0, gt + 1) + "<head>" + meta +
                           "</head>" + html.substring (gt + 1);
                }
            }

            return meta + html;
        }

        // Find "<tag" whose next char is not a letter (so "<head" does not
        // match "<header"). Returns the offset in `low` or -1.
        private static int index_of_tag (string low, string tag) {
            int i = low.index_of (tag);
            while (i >= 0) {
                unichar c = i + tag.length < low.length ? low[i + tag.length] : ' ';
                if (c.isalnum ()) {
                    i = low.index_of (tag, i + 1);
                    continue;
                }
                break;
            }
            return i;
        }
    }

    public class EntityByteDecoder : Object {

        // Entities that MUST survive as-is (markup semantics).
        private static bool is_reserved (string name) {
            return name == "amp" || name == "lt" || name == "gt" ||
                   name == "quot" || name == "apos";
        }

        // True when the document uses Latin-1 named entities of encoded
        // bytes ("&eth;" for CP1251 0xF0 = 'р'). One hit anywhere is enough.
        private static bool has_encoded_byte_entities (string low) {
            int i = 0;
            while ((i = low.index_of ("&", i)) >= 0) {
                int semi = low.index_of (";", i);
                if (semi < 0 || semi - i > 12) { i++; continue; }
                var name = low.substring (i + 1, semi - i - 1);
                if (name.has_prefix ("#")) return true;          // numeric ref
                if (!is_reserved (name) && Vchm.Model.HhcParser.entity_by_name (name) > 0)
                    return true;
                i = semi;
            }
            return false;
        }

        // Decode named/numeric byte-entities ("&eth;" = CP1251 0xF0) into
        // raw bytes and convert ONLY those runs through the archive
        // charset (fixup_name approach, review F10). Literal non-ASCII
        // text is genuine Unicode already — re-converting the whole
        // buffer mangled it whenever the archive hint was legacy but the
        // document real UTF-8. Reserved markup entities are preserved.
        // Returns input unchanged when no such entities exist.
        public static string fixup (string html, string encoding) {
            if (encoding.has_prefix ("UTF")) return html;
            var low = HtmlTextUtils.ascii_down (html);
            if (!has_encoded_byte_entities (low)) return html;

            var sb = new StringBuilder ();
            var run = new uint8[html.length + 1];   // pending encoded-byte run
            int rl = 0;
            int i = 0;
            int n = html.length;

            while (i < n) {
                int amp = html.index_of ("&", i);
                int stop = amp < 0 ? n : amp;

                // Literal text up to the entity candidate: ASCII bytes join
                // the pending run (same bytes in every single-byte
                // charset); non-ASCII bytes are real Unicode — flush the
                // run and pass them through untouched.
                while (i < stop) {
                    if (((uint8) html[i]) < 0x80) {
                        run[rl++] = (uint8) html[i];
                        i++;
                        continue;
                    }
                    flush_run (sb, run, rl, encoding);
                    rl = 0;
                    int cstart = i;
                    i++;
                    while (i < n && (((uint8) html[i]) & 0xC0) == 0x80) i++;
                    sb.append (html.substring (cstart, i - cstart));
                }

                if (amp < 0) break;

                int semi = html.index_of (";", amp);
                string name = "";
                if (semi >= 0 && semi - amp > 1)
                    name = html.substring (amp + 1, semi - amp - 1);

                uint32 code = 0;
                bool known = false;

                if (!is_reserved (name)) {
                    if (name.has_prefix ("#")) {
                        bool is_hex = name.has_prefix ("#x") || name.has_prefix ("#X");
                        string digits = is_hex ? name.substring (2) : name.substring (1);
                        int base_ = is_hex ? 16 : 10;
                        int64 v = 0;
                        bool ok = digits.length > 0;
                        for (int k = 0; k < digits.length; k++) {
                            int dv = hex_val (digits[k]);
                            if (dv < 0 || dv >= base_) { ok = false; break; }
                            v = v * base_ + dv;
                            if (v > 0x10FFFF) { ok = false; break; }
                        }
                        if (ok && v <= 0xFF) {
                            code = (uint32) v; known = true;
                        }
                        // refs above 0xFF are real Unicode: browser
                        // renders them, so emit verbatim (known=false)
                    } else {
                        var mapped = Vchm.Model.HhcParser.entity_by_name (name);
                        if (mapped > 0) { code = mapped; known = true; }
                    }
                }

                if (!(known && code <= 0xFF)) {
                    // Unknown/reserved/non-byte/malformed: markup — flush
                    // the byte-run, emit verbatim, resume after it.
                    flush_run (sb, run, rl, encoding);
                    rl = 0;
                    int upto = semi >= 0 ? semi + 1 : n;
                    sb.append (html.substring (amp, upto - amp));
                    i = upto;
                    continue;
                }

                run[rl++] = (uint8) code;
                i = semi + 1;
            }

            flush_run (sb, run, rl, encoding);
            return sb.str;
        }

        // Charset-convert one accumulated byte-run to UTF-8. Runs hold only
        // ASCII plus entity-derived bytes, which every supported legacy
        // codepage can represent; a stray undefined byte degrades to '?'
        // instead of losing the whole run.
        private static void flush_run (StringBuilder sb, uint8[] run, int len, string encoding) {
            if (len == 0) return;
            run[len] = 0;
            try {
                sb.append ((string) GLib.convert ((string) run, len,
                                                  "UTF-8", encoding));
            } catch (GLib.ConvertError e) {
                for (int k = 0; k < len; k++) {
                    sb.append_c (run[k] < 0x80 ? (char) run[k] : '?');
                }
            }
        }

        private static int hex_val (char c) {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }
    }

}
