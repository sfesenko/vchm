// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class IndexView : Box {
        private Elmish.Dispatch<AppMessage> dispatch;
        private TreeView tree_view;
        private Gtk.ListStore store;
        private Entry filter_entry;
        private ScrolledWindow scrolled;

        public IndexView () {
            Object (orientation: Orientation.VERTICAL);
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            // Filter entry
            filter_entry = new Entry () {
                placeholder_text = _("Filter index..."),
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 6,
                margin_end = 6
            };
            filter_entry.changed.connect (() => {
                dispatch (new IndexFilterChangedMessage (filter_entry.text));
            });
            append (filter_entry);

            scrolled = new ScrolledWindow () {
                hexpand = true,
                vexpand = true
            };
            scrolled.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);

            store = new Gtk.ListStore (2, typeof(string), typeof(string)); // name, url
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
            column.title = _("Index");
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
                        dispatch (new IndexSelectionChangedMessage (url));
                    }
                }
            });

            tree_view.cursor_changed.connect (() => {
                TreePath? path;
                TreeViewColumn? tv_column;
                tree_view.get_cursor (out path, out tv_column);
                if (path != null) {
                    TreeIter iter;
                    if (store.get_iter (out iter, path)) {
                        Value val;
                        store.get_value (iter, 1, out val);
                        string? url = val.get_string ();
                        if (url != null && url != "") {
                            dispatch (new IndexSelectionChangedMessage (url));
                        }
                    }
                }
            });

            scrolled.child = tree_view;
            append (scrolled);
        }

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE: {
                    rebuild_list (model);
                    break;
                }

                case AppMessageKind.CLOSE_FILE: {
                    store.clear ();
                    break;
                }

                case AppMessageKind.INDEX_FILTER_CHANGED: {
                    apply_filter (model);
                    break;
                }

                case AppMessageKind.INDEX_NEXT: {
                    select_relative (model, 1);
                    break;
                }

                case AppMessageKind.INDEX_PREV: {
                    select_relative (model, -1);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_list (AppModel model) {
            store.clear ();
            foreach (var entry in model.index.entries) {
                TreeIter iter;
                store.append (out iter);
                store.set (iter, 0, entry.name, 1, entry.url);
            }
            apply_filter (model);
        }

        private void apply_filter (AppModel model) {
            var filter = model.index.filter_text.down ();
            // We'll use a TreeModelFilter for proper filtering
            // For now, just rebuild with filtered entries
            store.clear ();
            foreach (var entry in model.index.filtered_entries ()) {
                TreeIter iter;
                store.append (out iter);
                store.set (iter, 0, entry.name, 1, entry.url);
            }
            
            if (store.iter_n_children (null) > 0) {
                var path = new TreePath.first ();
                tree_view.set_cursor (path, null, false);
            }
        }

        private void select_relative (AppModel model, int delta) {
            var n = store.iter_n_children (null);
            if (n == 0) return;
            
            TreePath? path;
            TreeViewColumn? column;
            tree_view.get_cursor (out path, out column);
            
            int current = 0;
            if (path != null) {
                current = path.get_indices ()[0];
            }
            
            int next = (current + delta + n) % n;
            var new_path = new TreePath.from_indices (next);
            tree_view.set_cursor (new_path, null, false);
        }
    }
}