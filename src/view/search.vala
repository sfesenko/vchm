// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    private class SearchRow : Object {
        public string title { get; set; }
        public string url { get; set; }
        public int rank { get; set; }

        public SearchRow (string title, string url, int rank) {
            this.title = title;
            this.url = url;
            this.rank = rank;
        }
    }

    public class SearchView : Box {
        private unowned Elmish.Dispatch<AppMessage> dispatch;
        private ColumnView column_view;
        private GLib.ListStore store;
        private SingleSelection selection;
        private Entry query_entry;
        private CheckButton whole_words_check;
        private CheckButton titles_only_check;
        private Button search_button;
        private ScrolledWindow scrolled;
        private Label status_label;
        // Guards against programmatic set_text re-entering ::changed
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

            store = new GLib.ListStore (typeof (SearchRow));
            selection = new SingleSelection (store) {
                autoselect = false,
                can_unselect = true
            };
            column_view = new ColumnView (selection) {
                hexpand = true,
                vexpand = true,
                show_column_separators = false,
                show_row_separators = false
            };

            // Title column
            var title_factory = new SignalListItemFactory ();
            title_factory.setup.connect ((item) => {
                var li = (ListItem) item;
                var label = new Label (null) {
                    xalign = 0,
                    hexpand = true,
                    ellipsize = Pango.EllipsizeMode.END
                };
                li.set_child (label);
            });
            title_factory.bind.connect ((item) => {
                var li = (ListItem) item;
                var label = (Label) li.get_child ();
                var row = (SearchRow) li.get_item ();
                label.label = row.title;
            });
            var title_column = new ColumnViewColumn (_("Title"), title_factory) {
                expand = true
            };
            column_view.append_column (title_column);

            // Rank column
            var rank_factory = new SignalListItemFactory ();
            rank_factory.setup.connect ((item) => {
                var li = (ListItem) item;
                var label = new Label (null) { xalign = 1 };
                li.set_child (label);
            });
            rank_factory.bind.connect ((item) => {
                var li = (ListItem) item;
                var label = (Label) li.get_child ();
                var row = (SearchRow) li.get_item ();
                label.label = row.rank.to_string ();
            });
            var rank_column = new ColumnViewColumn (_("Rank"), rank_factory) {
                fixed_width = 50
            };
            column_view.append_column (rank_column);

            column_view.activate.connect ((pos) => {
                var row = (SearchRow?) store.get_item (pos);
                if (row != null && row.url != null && row.url != "") {
                    dispatch (new SearchSelectionChangedMessage (row.url));
                }
            });

            // Loads a result as soon as it is selected (single
            // click — chmsearchpanel EVT_LIST_ITEM_SELECTED parity).
            selection.selection_changed.connect (() => {
                if (syncing) return;
                var row = (SearchRow?) selection.selected_item;
                if (row == null) return;
                if (row.url != null && row.url != "") {
                    dispatch (new SearchSelectionChangedMessage (row.url));
                }
            });

            scrolled.child = column_view;
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

        public void notify_active_changed (AppModel model) {
            var s_na = model.current_book != null ? model.current_book.search : model.placeholder.search;
            populating = true;
            query_entry.text = s_na.query;
            populating = false;
            rebuild_results (model);
        }

        public void update (AppMessage msg, AppModel model) {
            var s_up = model.current_book != null ? model.current_book.search : model.placeholder.search;
            switch (msg.kind) {
                case AppMessageKind.SEARCH_QUERY_CHANGED: {
                    // GTK4 set_text re-emits ::changed even for the same
                    // value — without the same-value guard + populating
                    // flag every programmatic set re-dispatched the
                    // message forever.
                    if (query_entry.text != s_up.query) {
                        populating = true;
                        query_entry.text = s_up.query;
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
                    var s_op = model.current_book != null ? model.current_book.search : model.placeholder.search;
                    whole_words_check.active = s_op.whole_words;
                    titles_only_check.active = s_op.titles_only;
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_results (AppModel model) {
            var s_rb = model.current_book != null ? model.current_book.search : model.placeholder.search;
            syncing = true;
            store.remove_all ();
            foreach (var result in s_rb.results) {
                store.append (new SearchRow (result.title, result.url, result.rank));
            }

            if (store.get_n_items () > 0) {
                selection.select_item (0, true);
                column_view.scroll_to (0, null, ListScrollFlags.NONE, null);
                status_label.visible = false;
                status_label.label = "";
            } else {
                status_label.label = _("No results for '%s'").printf (s_rb.query);
                status_label.visible = true;
            }
            syncing = false;
        }
    }
}
