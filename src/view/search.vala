// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class SearchView : Box {
        private Elmish.Dispatch<AppMessage> dispatch;
        private TreeView tree_view;
        private Gtk.ListStore store;
        private Entry query_entry;
        private CheckButton whole_words_check;
        private CheckButton titles_only_check;
        private Button search_button;
        private ScrolledWindow scrolled;
        private Label status_label;
        // Guards against programmatic set_text re-entering ::changed
        // (review F1).
        private bool populating = false;
        // Guards against programmatic cursor moves (results rebuild)
        // re-entering the navigate-on-select handler.
        private bool syncing = false;

        public SearchView () {
            Object (orientation: Orientation.VERTICAL);
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            // Search controls
            var controls_box = new Box (Orientation.VERTICAL, 6) {
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 6,
                margin_end = 6
            };

            // Query entry with search button
            var query_box = new Box (Orientation.HORIZONTAL, 6);
            query_entry = new Entry () {
                placeholder_text = _("Search for..."),
                hexpand = true
            };
            query_entry.activate.connect (() => dispatch (new SearchExecuteMessage ()));
            query_entry.changed.connect (() => {
                if (populating) return;
                dispatch (new SearchQueryChangedMessage (query_entry.text));
            });
            query_box.append (query_entry);

            search_button = new Button.with_label (_("Search"));
            search_button.clicked.connect (() => dispatch (new SearchExecuteMessage ()));
            query_box.append (search_button);

            controls_box.append (query_box);

            // Options
            var options_box = new Box (Orientation.HORIZONTAL, 12);
            whole_words_check = new CheckButton ();
            whole_words_check.label = _("Whole words");
            whole_words_check.toggled.connect (() => 
                dispatch (new SearchOptionsChangedMessage (whole_words_check.active, titles_only_check.active)));
            options_box.append (whole_words_check);

            titles_only_check = new CheckButton ();
            titles_only_check.label = _("Titles only");
            titles_only_check.toggled.connect (() => 
                dispatch (new SearchOptionsChangedMessage (whole_words_check.active, titles_only_check.active)));
            options_box.append (titles_only_check);

            controls_box.append (options_box);
            append (controls_box);

            scrolled = new ScrolledWindow () {
                hexpand = true,
                vexpand = true
            };
            scrolled.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);

            store = new Gtk.ListStore (3, typeof(string), typeof(string), typeof(int)); // title, url, rank
            tree_view = new TreeView () {
                model = store,
                headers_visible = true,
                hexpand = true,
                vexpand = true
            };

            // Title column
            var renderer = new CellRendererText () {
                ellipsize = Pango.EllipsizeMode.END
            };
            var title_column = new TreeViewColumn ();
            title_column.title = _("Title");
            title_column.pack_start (renderer, true);
            title_column.add_attribute (renderer, "text", 0);
            title_column.expand = true;
            tree_view.append_column (title_column);

            // Rank column
            var rank_renderer = new CellRendererText ();
            var rank_column = new TreeViewColumn ();
            rank_column.title = _("Rank");
            rank_column.pack_start (rank_renderer, false);
            rank_column.add_attribute (rank_renderer, "text", 2);
            rank_column.fixed_width = 50;
            tree_view.append_column (rank_column);

            tree_view.row_activated.connect ((path, column) => {
                TreeIter iter;
                if (store.get_iter (out iter, path)) {
                    Value val;
                    store.get_value (iter, 1, out val);
                    string? url = val.get_string ();
                    if (url != null && url != "") {
                        dispatch (new SearchSelectionChangedMessage (url));
                    }
                }
            });

            // Loads a result as soon as it is selected (single
            // click — chmsearchpanel EVT_LIST_ITEM_SELECTED parity).
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
                    dispatch (new SearchSelectionChangedMessage (url));
                }
            });

            scrolled.child = tree_view;
            append (scrolled);

            // Empty-state hint (no hits / nothing searched yet).
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

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.SEARCH_QUERY_CHANGED: {
                    // GTK4 set_text re-emits ::changed even for the same
                    // value — without the same-value guard + populating
                    // flag every programmatic set re-dispatched the
                    // message forever (review F1).
                    if (query_entry.text != model.search.query) {
                        populating = true;
                        query_entry.text = model.search.query;
                        populating = false;
                    }
                    break;
                }

                case AppMessageKind.SEARCH_EXECUTE: {
                    // Triggered by button or Enter
                    break;
                }

                case AppMessageKind.SEARCH_DONE: {
                    rebuild_results (model);
                    break;
                }

                case AppMessageKind.SEARCH_OPTIONS_CHANGED: {
                    whole_words_check.active = model.search.whole_words;
                    titles_only_check.active = model.search.titles_only;
                    break;
                }

                case AppMessageKind.SEARCH_NEXT: {
                    select_relative (model, 1);
                    break;
                }

                case AppMessageKind.SEARCH_PREV: {
                    select_relative (model, -1);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_results (AppModel model) {
            syncing = true;
            store.clear ();
            foreach (var result in model.search.results) {
                TreeIter iter;
                store.append (out iter);
                store.set (iter, 0, result.title, 1, result.url, 2, result.rank);
            }

            if (store.iter_n_children (null) > 0) {
                var path = new TreePath.first ();
                tree_view.set_cursor (path, null, false);
                status_label.visible = false;
                status_label.label = "";
            } else {
                status_label.label = _("No results for '%s'").printf (model.search.query);
                status_label.visible = true;
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