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
        private TopicsItem? built_root = null;   // change-detection guard
        // Guards against programmatic cursor moves (selection sync,
        // rebuilds) re-entering the navigate-on-select handler.
        private bool syncing = false;

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

            // Navigates on selection (single click), not only on
            // double-click (chmtoc EVT_TREE_SEL_CHANGED parity).
            tree_view.cursor_changed.connect (() => {
                if (syncing) return;
                TreePath? path;
                TreeViewColumn? col;
                tree_view.get_cursor (out path, out col);
                if (path == null) return;
                TreeIter iter;
                if (!store.get_iter (out iter, path)) return;
                Value val;
                store.get_value (iter, 1, out val);
                string? url = val.get_string ();
                if (url != null && url != "") {
                    dispatch (new TopicsSelectionChangedMessage (url));
                }
            });

            tree_view.row_expanded.connect ((iter, path) => {
                if (syncing) return;
                Value val;
                store.get_value (iter, 1, out val);
                string? url = val.get_string ();
                if (url != null && url != "") {
                    dispatch (new TopicsItemExpandedMessage (url));
                }
            });

            tree_view.row_collapsed.connect ((iter, path) => {
                if (syncing) return;
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

        // B+hybrid: called via AppModel.notify["active-book"] (freeze/thaw batched) instead of via TAB_ACTIVATED
        public void notify_active_changed (AppModel model) {
            built_root = null;
            rebuild_tree (model);
            var t_sel = model.active_book != null ? model.active_book.topics : model.placeholder.topics;
            select_url (t_sel.selected_url);
        }

        public void update (AppMessage msg, AppModel model) {
            var t_up = model.active_book != null ? model.active_book.topics : model.placeholder.topics;
            switch (msg.kind) {

                case AppMessageKind.CLOSE_FILE: {
                    built_root = null;
                    store.clear ();
                    break;
                }

                case AppMessageKind.TAB_ACTIVATED: {
                    // Legacy path: still handled via Elmish for incremental migration
                    built_root = null;
                    rebuild_tree (model);
                    select_url (t_up.selected_url);
                    break;
                }

                case AppMessageKind.TOPICS_SELECTION_CHANGED: {
                    // Selection initiated here already moved the cursor.
                    break;
                }

                case AppMessageKind.TOPICS_ITEM_EXPANDED: {
                    var em = (TopicsItemExpandedMessage) msg;
                    expand_url (em.url);
                    break;
                }

                case AppMessageKind.TOPICS_ITEM_COLLAPSED: {
                    var cm = (TopicsItemCollapsedMessage) msg;
                    collapse_url (cm.url);
                    break;
                }

                case AppMessageKind.NAVIGATE_DONE:
                case AppMessageKind.PANELS_REBUILT: {
                    // Coalescing guard + follow page changes: rebuild when
                    // the root instance changed (PANELS_REBUILT swaps it
                    // wholesale), then highlight current topic.
                    if (t_up.root != built_root) {
                        built_root = t_up.root;
                        rebuild_tree (model);
                    }
                    select_url (t_up.selected_url);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_tree (AppModel model) {
            syncing = true;
            store.clear ();
            var t_rb = model.active_book != null ? model.active_book.topics : model.placeholder.topics;
            if (t_rb.root != null) {
                add_items_recursive (null, t_rb.root);
            }
            tree_view.expand_all ();
            syncing = false;
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
            if (url == null || url.length == 0) return;
            TreeIter iter;
            if (store.get_iter_first (out iter)) {
                TreeIter found_iter;
                if (find_iter_by_url (iter, url, out found_iter)) {
                    var path = store.get_path (found_iter);
                    syncing = true;
                    tree_view.expand_to_path (path);
                    tree_view.set_cursor (path, null, false);
                    syncing = false;
                    tree_view.scroll_to_cell (path, null, true, 0.3f, 0f);
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