// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Pure-data topics tree (A1): no GTK types. Sources in priority order:
// #TOCIDX binary TOC -> .hhc file -> flat enumeration. Binary walking uses
// an explicit frame stack (A2) mirroring RecurseLoadBTOC ordering.

using GLib;
using Gee;

namespace Vchm.Model {

    // Topics tree item
    public class TopicsItem : Object {
        public string name { get; set; }
        public string url { get; set; }
        public Gee.ArrayList<TopicsItem> children { get; private set; }
        public bool expanded { get; set; }
        public TopicsItem? parent { get; set; }

        public TopicsItem (string name, string url) {
            this.name = name;
            this.url = url;
            children = new Gee.ArrayList<TopicsItem> ();
            expanded = false;
        }

        public void add_child (TopicsItem child) {
            child.parent = this;
            children.add (child);
        }
    }

    // Model for the topics tree panel.
    public class TopicsModel : Object {
        public TopicsItem? root { get; private set; }
        public string? selected_url { get; set; }
        public bool loading { get; set; }
        public string? error { get; set; }

        public TopicsModel () {
            loading = false;
        }

        public void clear () {
            root = null;
            selected_url = null;
            error = null;
        }

        public void build_from_chm (CHMFile chm_file) {
            clear ();
            loading = true;
            error = null;

            uint8[] topics, strings, urltbl, urlstr;
            uint8[]? topidx;
            bool has_topics = chm_file.get_topics_data (out topics, out strings,
                                                        out urltbl, out urlstr, out topidx);

            if (has_topics && topidx != null && topidx.length >= 4) {
                root = build_binary_root (topidx, topics, strings, urltbl, urlstr,
                                          chm_file.encoding ());
            }
            if (root == null) {
                var hhc = chm_file.load_hhc_tree ();
                if (hhc != null && hhc.size > 0) {
                    root = new TopicsItem (_("Contents"), "");
                    foreach (var e in hhc) {
                        root.add_child (hhc_to_item (e));
                    }
                }
            }

            // Last resort for metadata-poor archives.
            if (root == null) {
                root = build_flat_pages (chm_file);
            }
            if (root == null) {
                error = _("Failed to read topics data from CHM");
            }

            loading = false;
        }

        // Iterative DFS over #TOCIDX nodes. Frames hold each level's
        // sibling-chain cursor and its parent item; children complete
        // before the parent's next sibling.
        private TopicsItem? build_binary_root (uint8[] topidx, uint8[] topics,
                                               uint8[] strings, uint8[] urltbl,
                                               uint8[] urlstr, string enc) {
            var contents = new TopicsItem (_("Contents"), "");
            if (topidx.length < 4) return null;

            var frames = new Gee.ArrayList<uint32?> ();
            var parents = new Gee.ArrayList<TopicsItem?> ();
            frames.add (UINT32_FROM_ARRAY (topidx, 0));
            parents.add (contents);
            int level = 0;
            int guard = 0;

            while (level >= 0 && guard++ < 100000) {
                uint32 offset = frames[level];

                if (offset == 0) {                       // chain done: pop
                    frames.remove_at (level);
                    parents.remove_at (level);
                    level--;
                    continue;
                }

                if (topidx.length < offset + 20) break;

                var flags = UINT32_FROM_ARRAY (topidx, (int) (offset + 4));
                var index = UINT32_FROM_ARRAY (topidx, (int) (offset + 8));
                var next = UINT32_FROM_ARRAY (topidx, (int) (offset + 0x10));

                string? name = null;
                string? url = null;

                if ((flags & 0x8) != 0) {
                    name = btoc_item_name (topics, strings, index, enc);
                    url = btoc_item_url (topics, strings, urltbl, urlstr, index);
                    if (name != null) {
                        name = Vchm.Model.EntityByteDecoder.fixup (name, enc);
                        name = strip_unknown_entities (name);
                    }
                } else if ((flags & 0x4) != 0) {
                    var raw = read_cstring (strings, (int) index);
                    if (raw != null && raw.length > 0)
                        name = strip_unknown_entities (to_utf8 (raw, enc));
                }

                TopicsItem? item = null;
                if (name != null) {
                    item = new TopicsItem (name, url ?? "");
                    parents[level].add_child (item);
                }

                uint32 child = 0;
                if ((flags & 0x4) != 0 && topidx.length >= offset + 24) {
                    child = UINT32_FROM_ARRAY (topidx, (int) (offset + 20));
                }

                if (child != 0 && level < 127) {
                    frames[level] = next;                 // resume after children
                    frames.add (child);
                    parents.add (item != null ? item : parents[level]);
                    level++;
                } else {
                    frames[level] = next;
                    while (frames[level] == 0 && level > 0) {
                        frames.remove_at (level);
                        parents.remove_at (level);
                        level--;
                    }
                }
            }

            return contents.children.size > 0 ? contents : null;
        }

        // Replace entities the decoder does not know (HHW lookalike names
        // like &Dstrok; with no byte meaning) so labels stay readable.
        private static string strip_unknown_entities (string s) {
            if (!s.contains ("&")) return s;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < s.length) {
                int amp = s.index_of ("&", i);
                if (amp < 0) { sb.append (s.substring (i)); break; }
                sb.append (s.substring (i, amp - i));
                int semi = s.index_of (";", amp);
                if (semi < 0 || semi - amp > 12) { sb.append_c ('&'); i = amp + 1; continue; }
                var nm = s.substring (amp + 1, semi - amp - 1).down ();
                bool known = nm.has_prefix ("#") ||
                             nm == "amp" || nm == "lt" || nm == "gt" ||
                             nm == "quot" || nm == "apos" ||
                             HhcParser.entity_by_name (nm) > 0;
                if (known) sb.append (s.substring (amp, semi - amp + 1));
                i = semi + 1;
            }
            return sb.str;
        }

        private TopicsItem hhc_to_item (HhcEntry e) {
            string url = e.local.length > 0 ? normalize_hhc_local (e.local) : "";
            var item = new TopicsItem (strip_unknown_entities (e.name), url);
            foreach (var c in e.children) {
                item.add_child (hhc_to_item (c));
            }
            return item;
        }

        private static string normalize_hhc_local (string local) {
            var t = local.strip ().split ("#")[0];
            if (t.length == 0 || t.down ().has_prefix ("http")) return "";
            if (t[0] != '/') return "/" + t;
            return t;
        }

        // Flat TOC from enumerated content pages. Labels: the page
        // <title>, then the first <h1>/<h2> heading, then the file
        // name — HHW books often title every page with the book name,
        // and raw file names read as broken content in the sidebar.
        private TopicsItem build_flat_pages (CHMFile chm_file) {
            var root_item = new TopicsItem (_("Contents"), "");
            var enc = chm_file.encoding ();
            int budget = 300;                       // bound work on huge archives

            // First pass: collect candidate labels.
            var pages = chm_file.list_content_pages ();
            var titles = new string[pages.size];
            for (int i = 0; i < pages.size; i++) {
                string base_name = pages[i].substring (pages[i].last_index_of ("/") + 1);
                titles[i] = base_name;
                if (budget-- <= 0) continue;
                var c = chm_file.get_content (pages[i]);
                if (!c.success) continue;
                string fixed = Vchm.Model.EntityByteDecoder.fixup (c.content, enc);
                string t = extract_title (fixed, enc);
                if (t.length > 0) titles[i] = t;
            }

            // Duplicate <title>s (book-name-per-page HHW style): prefer
            // the first heading so entries stay distinguishable.
            var counts = new Gee.HashMap<string, int> ();
            foreach (var t in titles) counts[t] = (counts.has_key (t) ? counts[t] : 0) + 1;

            budget = 300;
            for (int i = 0; i < pages.size; i++) {
                string label = titles[i];
                if (counts[label] > 1 && budget-- > 0) {
                    var c = chm_file.get_content (pages[i]);
                    if (c.success) {
                        string h = extract_heading (
                            Vchm.Model.EntityByteDecoder.fixup (c.content, enc), enc);
                        if (h.length > 0 && counts[h] == 0) {
                            label = h;
                        }
                    }
                }
                if (counts[label] > 1)
                    label = pages[i].substring (pages[i].last_index_of ("/") + 1);
                root_item.add_child (new TopicsItem (label, pages[i]));
            }
            return root_item;
        }

        public static string extract_title (string html, string enc) {
            var low = Vchm.Model.HtmlTextUtils.ascii_down (html);
            int open = low.index_of ("<title");
            if (open < 0) return "";
            int gt = html.index_of (">", open);
            int close = low.index_of ("</title", gt);
            if (gt < 0 || close < 0 || close <= gt + 1) return "";
            var raw = html.substring (gt + 1, close - gt - 1).strip ();
            if (raw.length == 0) return "";
            // Titles may be Latin-1 entity encodings of archive bytes.
            var decoded = Vchm.Model.EntityByteDecoder.fixup (raw, enc);
            return HhcParser.decode_entities (decoded).strip ();
        }

        // First <h1>/<h2> heading text — a per-page label when the
        // <title> is duplicated across the book.
        public static string extract_heading (string html, string enc) {
            var low = Vchm.Model.HtmlTextUtils.ascii_down (html);
            foreach (string tag in new string[] { "<h1", "<h2" }) {
                int open = low.index_of (tag);
                if (open < 0) continue;
                int gt = html.index_of (">", open);
                if (gt < 0) continue;
                string close_tag = "</" + tag.substring (1);
                int close = low.index_of (close_tag, gt);
                if (close < 0 || close <= gt + 1) continue;
                var raw = html.substring (gt + 1, close - gt - 1).strip ();
                if (raw.length == 0) continue;
                var decoded = Vchm.Model.EntityByteDecoder.fixup (raw, enc);
                // Drop nested markup (e.g. <a name=…> inside headings).
                var sb = new StringBuilder ();
                int i = 0;
                bool in_tag = false;
                for (i = 0; i < decoded.length; i++) {
                    char ch = decoded[i];
                    if (ch == '<') { in_tag = true; continue; }
                    if (ch == '>') { in_tag = false; continue; }
                    if (!in_tag) sb.append_c (ch);
                }
                var text = HhcParser.decode_entities (sb.str).strip ();
                // Collapse internal whitespace runs.
                var outb = new StringBuilder ();
                bool ws = false;
                for (i = 0; i < text.length; i++) {
                    char ch = text[i];
                    bool is_ws = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
                    if (is_ws) {
                        if (!ws) outb.append_c (' ');
                    } else {
                        outb.append_c (ch);
                    }
                    ws = is_ws;
                }
                return outb.str.strip ();
            }
            return "";
        }

        public TopicsItem? find_item_by_url (string url) {
            if (root == null) return null;
            return find_recursive (root, url);
        }

        private TopicsItem? find_recursive (TopicsItem item, string url) {
            if (item.url == url) return item;
            foreach (var child in item.children) {
                var found = find_recursive (child, url);
                if (found != null) return found;
            }
            return null;
        }

        public void expand_path (string url) {
            var item = find_item_by_url (url);
            while (item != null) {
                item.expanded = true;
                item = item.parent;
            }
        }

        public Gee.HashSet<string> collect_expanded () {
            var acc = new Gee.HashSet<string> ();
            if (root != null) collect_expanded_rec (root, acc);
            return acc;
        }

        private void collect_expanded_rec (TopicsItem item, Gee.HashSet<string> acc) {
            if (item.expanded && item.url != null && item.url.length > 0) acc.add (item.url);
            foreach (var c in item.children) collect_expanded_rec (c, acc);
        }

        public void apply_expanded (Gee.HashSet<string> set) {
            if (root == null) return;
            apply_expanded_rec (root, set);
        }

        private void apply_expanded_rec (TopicsItem item, Gee.HashSet<string> set) {
            if (item.url != null && item.url.length > 0) item.expanded = set.contains (item.url);
            foreach (var c in item.children) apply_expanded_rec (c, set);
        }
    }
}
