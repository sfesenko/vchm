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
        private Label status_label;
        private string index_loaded_for = "";   // archive basename guard
        // Guards against programmatic cursor moves (filter re-set,
        // rebuilds) re-entering the navigate-on-select handler.
        private bool syncing = false;

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

            // Navigates when an index entry is selected (single
            // click — chmindexpanel EVT_LIST_ITEM_SELECTED parity).
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
                    dispatch (new IndexSelectionChangedMessage (url));
                }
            });

            scrolled.child = tree_view;
            append (scrolled);

            // Empty-state hint (books without a keyword index).
            status_label = new Label (null) {
                wrap = true,
                margin_top = 12,
                margin_bottom = 12,
                margin_start = 12,
                margin_end = 12,
                visible = false
            };
            status_label.add_css_class ("dim-label");
            append (status_label);
        }

        public void notify_active_changed (AppModel model) {
            if (model.file_open) {
                index_loaded_for = "";
                rebuild_list (model);
                var cur = model.current_book != null ? model.current_book : model.placeholder;
                index_loaded_for = cur.chm_file.filename ();
            }
        }

        public void update (AppMessage msg, AppModel model) {
            var idx_cur = model.current_book != null ? model.current_book : model.placeholder;
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE:
                case AppMessageKind.NAVIGATE_DONE: {
                    var book = idx_cur.chm_file.filename ();
                    if (model.file_open && book != index_loaded_for) {
                        index_loaded_for = book;
                        rebuild_list (model);
                    }
                    break;
                }

                case AppMessageKind.PANELS_REBUILT: {
                    // Encoding change swaps model.index wholesale while the
                    // filename stays the same — the filename guard above
                    // would keep the stale keyword list until the user
                    // typed (review F9).
                    if (model.file_open) {
                        rebuild_list (model);
                    }
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
            var idx_rb = model.current_book != null ? model.current_book.index : model.placeholder.index;
            foreach (var entry in idx_rb.entries) {
                TreeIter iter;
                store.append (out iter);
                store.set (iter, 0, entry.name, 1, entry.url);
            }
            apply_filter (model);
        }

        private void update_status (AppModel model) {
            var idx_st = model.current_book != null ? model.current_book.index : model.placeholder.index;
            if (idx_st.entries.size > 0) {
                status_label.visible = false;
                status_label.label = "";
            } else {
                status_label.label = idx_st.error ?? _("Index is empty");
                status_label.visible = true;
            }
        }

        private void apply_filter (AppModel model) {
            var idx_af = model.current_book != null ? model.current_book.index : model.placeholder.index;
            var filter = idx_af.filter_text.down ();
            update_status (model);
            // Programmatic repopulation + cursor set must not look like
            // a user selection.
            syncing = true;
            store.clear ();
            foreach (var entry in idx_af.filtered_entries ()) {
                TreeIter iter;
                store.append (out iter);
                store.set (iter, 0, entry.name, 1, entry.url);
            }

            if (store.iter_n_children (null) > 0) {
                var path = new TreePath.first ();
                tree_view.set_cursor (path, null, false);
            }
            syncing = false;
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