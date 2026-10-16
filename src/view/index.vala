// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    private class IndexRow : Object {
        public string name { get; set; }
        public string url { get; set; }

        public IndexRow (string name, string url) {
            this.name = name;
            this.url = url;
        }
    }

    public class IndexView : Box {
        private unowned Elmish.Dispatch<AppMessage> dispatch;
        private ListView list_view;
        private GLib.ListStore store;
        private SingleSelection selection;
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

            store = new GLib.ListStore (typeof (IndexRow));
            selection = new SingleSelection (store) {
                autoselect = false,
                can_unselect = true
            };
            var factory = new SignalListItemFactory ();
            factory.setup.connect ((item) => {
                var li = (ListItem) item;
                var label = new Label (null) {
                    xalign = 0,
                    hexpand = true,
                    ellipsize = Pango.EllipsizeMode.END
                };
                li.set_child (label);
            });
            factory.bind.connect ((item) => {
                var li = (ListItem) item;
                var label = (Label) li.get_child ();
                var row = (IndexRow) li.get_item ();
                label.label = row.name;
            });
            list_view = new ListView (selection, factory) {
                hexpand = true,
                vexpand = true
            };

            list_view.activate.connect ((pos) => {
                var row = (IndexRow?) store.get_item (pos);
                if (row != null && row.url != null && row.url != "") {
                    dispatch (new IndexSelectionChangedMessage (row.url));
                }
            });

            // Navigates when an index entry is selected (single
            // click — chmindexpanel EVT_LIST_ITEM_SELECTED parity).
            selection.selection_changed.connect (() => {
                if (syncing) return;
                var row = (IndexRow?) selection.selected_item;
                if (row == null) return;
                if (row.url != null && row.url != "") {
                    dispatch (new IndexSelectionChangedMessage (row.url));
                }
            });

            scrolled.child = list_view;
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
                    // typed.
                    if (model.file_open) {
                        rebuild_list (model);
                    }
                    break;
                }

                case AppMessageKind.INDEX_FILTER_CHANGED: {
                    apply_filter (model);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_list (AppModel model) {
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
            update_status (model);
            // Programmatic repopulation + cursor set must not look like
            // a user selection.
            syncing = true;
            store.remove_all ();
            foreach (var entry in idx_af.filtered_entries ()) {
                store.append (new IndexRow (entry.name, entry.url));
            }

            if (store.get_n_items () > 0) {
                selection.select_item (0, true);
                list_view.scroll_to (0, ListScrollFlags.NONE, null);
            }
            syncing = false;
        }
    }
}
