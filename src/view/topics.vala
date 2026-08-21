// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class TopicsView : Box {
        private Elmish.Dispatch<AppMessage> dispatch;
        private TreeView tree_view;
        private TreeStore store;
        private ScrolledWindow scrolled;

        public TopicsView () {
            Object (orientation: Orientation.VERTICAL);
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            scrolled = new ScrolledWindow () {
                hexpand = true,
                vexpand = true
            };
            scrolled.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);

            store = new TreeStore (2, typeof(string), typeof(string)); // name, url
            tree_view = new TreeView () {
                model = store,
                headers_visible = false,
                hexpand = true,
                vexpand = true
            };

            var renderer = new CellRendererText () {
                ellipsize = Pango.EllipsizeMode.END
            };
            var column = new TreeViewColumn ();
            column.title = _("Topics");
            column.pack_start (renderer, true);
            column.add_attribute (renderer, "text", 0);
            tree_view.append_column (column);

            tree_view.row_activated.connect ((path, column) => {
                TreeIter iter;
                if (store.get_iter (out iter, path)) {
                    Value val;
                    store.get_value (iter, 1, out val);
                    string? url = val.get_string ();
                    if (url != null && url != "") {
                        dispatch (new TopicsSelectionChangedMessage (url));
                    }
                }
            });

            tree_view.row_expanded.connect ((iter, path) => {
                Value val;
                store.get_value (iter, 1, out val);
                string? url = val.get_string ();
                if (url != null && url != "") {
                    dispatch (new TopicsItemExpandedMessage (url));
                }
            });

            tree_view.row_collapsed.connect ((iter, path) => {
                Value val;
                store.get_value (iter, 1, out val);
                string? url = val.get_string ();
                if (url != null && url != "") {
                    dispatch (new TopicsItemCollapsedMessage (url));
                }
            });

            scrolled.child = tree_view;
            append (scrolled);
        }

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE: {
                    rebuild_tree (model);
                    break;
                }

                case AppMessageKind.CLOSE_FILE: {
                    store.clear ();
                    break;
                }

                case AppMessageKind.TOPICS_SELECTION_CHANGED: {
                    select_url (model.topics.selected_url);
                    break;
                }

                case AppMessageKind.TOPICS_ITEM_EXPANDED: {
                    expand_url (model.topics.selected_url);
                    break;
                }

                case AppMessageKind.TOPICS_ITEM_COLLAPSED: {
                    collapse_url (model.topics.selected_url);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_tree (AppModel model) {
            store.clear ();
            if (model.topics.root != null) {
                add_items_recursive (null, model.topics.root);
            }
            tree_view.expand_all ();
        }

        private void add_items_recursive (TreeIter? parent, TopicsItem item) {
            TreeIter iter;
            store.append (out iter, parent);
            store.set (iter, 0, item.name, 1, item.url);
            foreach (var child in item.children) {
                add_items_recursive (iter, child);
            }
        }

        private void select_url (string? url) {
            if (url == null) return;
            // Find and select the row with matching URL
            TreeIter iter;
            if (store.get_iter_first (out iter)) {
                TreeIter found_iter;
                if (find_iter_by_url (iter, url, out found_iter)) {
                    var path = store.get_path (found_iter);
                    tree_view.set_cursor (path, null, false);
                }
            }
        }

        private bool find_iter_by_url (TreeIter iter, string url, out TreeIter result) {
            while (true) {
                Value val;
                store.get_value (iter, 1, out val);
                string? item_url = val.get_string ();
                if (item_url == url) {
                    result = iter;
                    return true;
                }
                
                // Check children
                TreeIter child_iter;
                if (store.iter_children (out child_iter, iter)) {
                    if (find_iter_by_url (child_iter, url, out result)) return true;
                }
                
                if (!store.iter_next (ref iter)) {
                    return false;
                }
            }
        }

        private void expand_url (string? url) {
            if (url == null) return;
            TreeIter iter;
            if (store.get_iter_first (out iter)) {
                TreeIter found_iter;
                if (find_iter_by_url (iter, url, out found_iter)) {
                    var path = store.get_path (found_iter);
                    tree_view.expand_row (path, false);
                }
            }
        }

        private void collapse_url (string? url) {
            if (url == null) return;
            TreeIter iter;
            if (store.get_iter_first (out iter)) {
                TreeIter found_iter;
                if (find_iter_by_url (iter, url, out found_iter)) {
                    var path = store.get_path (found_iter);
                    tree_view.collapse_row (path);
                }
            }
        }
    }
}