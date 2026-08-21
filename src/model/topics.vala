// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
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

    // Model for the topics tree panel
    public class TopicsModel : Object {
        public TopicsItem? root { get; private set; }
        public string? selected_url { get; set; }
        public bool loading { get; set; }
        public string? error { get; set; }
        public Gtk.TreeStore? tree_store { get; private set; }

        public TopicsModel () {
            loading = false;
        }

        public void clear () {
            root = null;
            selected_url = null;
            error = null;
            tree_store = null;
        }

        public void build_from_chm (CHMFile chm_file) {
            clear ();
            loading = true;
            error = null;
            
            uint8[] topics;
            uint8[] strings;
            uint8[] urltbl;
            uint8[] urlstr;
            uint8[]? topidx;
            
            if (!chm_file.get_topics_data (out topics, out strings, out urltbl, out urlstr, out topidx)) {
                error = "Failed to read topics data from CHM";
                loading = false;
                return;
            }
            
            // Build the full tree from CHM
            tree_store = build_topics_tree_store (topics, strings, urltbl, urlstr, topidx);
            
            // Also build internal structure for compatibility
            if (tree_store != null) {
                root = build_tree_from_store (tree_store);
            } else {
                // Fallback: create dummy root
                root = new TopicsItem ("Loading...", "/");
            }
            
            loading = false;
        }
        
        private Gtk.TreeStore build_topics_tree_store (uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr, uint8[]? topidx) {
            var store = new Gtk.TreeStore (2, typeof(string), typeof(string)); // name, url
            
            if (topidx != null && topidx.length >= 4) {
                // Use binary TOC tree
                var nodes = new Gee.HashMap<uint32, NodeInfo> ();
                uint32 root_offset = UINT32_FROM_ARRAY (topidx, 0);
                uint32 offset = root_offset;
                while (offset != 0 && offset + 24 <= topidx.length) {
                    uint32 flags = UINT32_FROM_ARRAY (topidx, (int)offset + 4);
                    uint32 index = UINT32_FROM_ARRAY (topidx, (int)offset + 8);
                    uint32 next = UINT32_FROM_ARRAY (topidx, (int)offset + 16);
                    uint32 child = UINT32_FROM_ARRAY (topidx, (int)offset + 20);
                    
                    nodes[offset] = new NodeInfo (offset, flags, index, next, child);
                    offset = next;
                }
                
                if (nodes.has_key (root_offset)) {
                    TreeIter iter = TreeIter();
                    build_tree_from_binary_toc (store, null, nodes, root_offset, topics, strings, urltbl, urlstr);
                }
            } else {
                // Fallback: parse #TOPICS sequentially
                int num_entries = topics.length / 16;
                for (int i = 0; i < num_entries; i++) {
                    int topic_offset = i * 16;
                    if (topics.length < topic_offset + 12) break;
                    
                    string? name = get_item_name (topics, strings, (uint32)i, false);
                    string? url = get_item_url (topics, strings, urltbl, urlstr, (uint32)i, false);
                    
                    if (name != null) {
                        TreeIter iter = TreeIter();
                        store.append (out iter, null);
                        store.set (iter, 0, name, 1, url ?? "");
                    }
                }
            }
            
            return store;
        }
        
        private void build_tree_from_binary_toc (Gtk.TreeStore store, TreeIter? parent, 
                                                  Gee.HashMap<uint32, NodeInfo> nodes, uint32 offset,
                                                  uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr) {
            NodeInfo? node = nodes[offset];
            if (node == null) return;
            
            string? name = get_item_name (topics, strings, node.index, (node.flags & 0x8) != 0);
            string? url = get_item_url (topics, strings, urltbl, urlstr, node.index, (node.flags & 0x8) != 0);
            
            if (name != null) {
                TreeIter iter = TreeIter();
                store.append (out iter, parent);
                store.set (iter, 0, name, 1, url ?? "");
                
                // Process children
                if ((node.flags & 0x4) != 0 && node.child != 0) {
                    uint32 child_offset = node.child;
                    while (child_offset != 0 && nodes.has_key (child_offset)) {
                        build_tree_from_binary_toc (store, iter, nodes, child_offset, topics, strings, urltbl, urlstr);
                        NodeInfo? child_node = nodes[child_offset];
                        if (child_node != null) {
                            child_offset = child_node.next;
                        } else {
                            break;
                        }
                    }
                }
            }
            
            // Process next sibling
            if (node.next != 0 && nodes.has_key (node.next)) {
                build_tree_from_binary_toc (store, parent, nodes, node.next, topics, strings, urltbl, urlstr);
            }
        }
        
        private TopicsItem? build_tree_from_store (Gtk.TreeStore store) {
            TreeIter iter = TreeIter();
            if (!store.get_iter_first (out iter)) {
                return null;
            }
            
            root = convert_iter_to_item (store, iter, null);
            return root;
        }
        
        private TopicsItem? convert_iter_to_item (Gtk.TreeStore store, TreeIter iter, TopicsItem? parent) {
            GLib.Value name_val = new GLib.Value (typeof(string));
            GLib.Value url_val = new GLib.Value (typeof(string));
            store.get_value (iter, 0, out name_val);
            store.get_value (iter, 1, out url_val);
            string name = name_val.get_string ();
            string url = url_val.get_string ();
            
            var item = new TopicsItem (name, url);
            item.parent = parent;
            
            // Process children
            TreeIter child_iter = TreeIter();
            if (store.iter_children (out child_iter, iter)) {
                do {
                    var child = convert_iter_to_item (store, child_iter, item);
                    if (child != null) {
                        item.add_child (child);
                    }
                } while (store.iter_next (ref child_iter));
            }
            
            return item;
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
        
        // Helper functions (copied from CHMFile)
        static uint32 UINT32_FROM_ARRAY (uint8[] array, int offset) {
            return (uint32) array[offset] | ((uint32) array[offset + 1] << 8) | 
                   ((uint32) array[offset + 2] << 16) | ((uint32) array[offset + 3] << 24);
        }
        
        private string? get_item_name (uint8[] topics, uint8[] strings, uint32 index, bool local) {
            if (local) {
                if (strings.length <= index) return null;
                int len = 0;
                while (index + len < strings.length && strings[index + len] != 0) len++;
                if (len == 0) return null;
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[index + i]);
                return sb.str;
            } else {
                int topic_offset = (int)(index * 16);
                if (topics.length < topic_offset + 4) return null;
                
                uint32 str_offset = UINT32_FROM_ARRAY (topics, topic_offset + 4);
                int32 test = (int32)str_offset;
                if (test == -1) return null;
                if (strings.length <= str_offset) return null;
                
                int len = 0;
                while (str_offset + len < strings.length && strings[str_offset + len] != 0) len++;
                if (len == 0) return null;
                
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[str_offset + i]);
                return sb.str;
            }
        }
        
        private string? get_item_url (uint8[] topics, uint8[] strings, uint8[] urltbl, uint8[] urlstr, uint32 index, bool local) {
            if (local) {
                if (strings.length <= index) return null;
                int len = 0;
                while (index + len < strings.length && strings[index + len] != 0) len++;
                if (len == 0) return null;
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)strings[index + i]);
                return null;
            } else {
                int topic_offset = (int)(index * 16);
                if (topics.length < topic_offset + 12) return null;
                
                uint32 str_offset = UINT32_FROM_ARRAY (topics, topic_offset + 4);
                int32 test = (int32)str_offset;
                if (test == -1) return null;
                if (strings.length <= str_offset) return null;
                
                uint32 urltbl_offset = UINT32_FROM_ARRAY (topics, topic_offset + 8);
                if (urltbl.length < urltbl_offset + 12) return null;
                
                uint32 urlstr_offset = UINT32_FROM_ARRAY (urltbl, (int)urltbl_offset + 8);
                if (urlstr.length <= urlstr_offset) return null;
                
                int url_start = (int)(urlstr_offset + 8);
                if (urlstr.length <= url_start) return null;
                
                int len = 0;
                while (url_start + len < urlstr.length && urlstr[url_start + len] != 0) len++;
                if (len == 0) return null;
                
                var sb = new StringBuilder ();
                for (int i = 0; i < len; i++) sb.append_c ((char)urlstr[url_start + i]);
                string? url = sb.str;
                
                if (url != null && !url.has_prefix ("/")) {
                    url = "/" + url;
                }
                
                return url;
            }
        }
        
        private class NodeInfo {
            public uint32 offset;
            public uint32 flags;
            public uint32 index;
            public uint32 next;
            public uint32 child;
            
            public NodeInfo (uint32 offset, uint32 flags, uint32 index, uint32 next, uint32 child) {
                this.offset = offset;
                this.flags = flags;
                this.index = index;
                this.next = next;
                this.child = child;
            }
        }
    }
}