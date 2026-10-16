// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    private class TopicsFlatRow : Object {
        public TopicsItem item { get; private set; }
        public int depth { get; private set; }
        public bool has_children { get; private set; }

        public TopicsFlatRow (TopicsItem item, int depth, bool has_children) {
            this.item = item;
            this.depth = depth;
            this.has_children = has_children;
        }
    }

    public class TopicsView : Box {
        private unowned Elmish.Dispatch<AppMessage> dispatch;
        private ListView list_view;
        private GLib.ListStore store;
        private SingleSelection selection;
        private ScrolledWindow scrolled;
        private AppModel? held_model = null;
        private TopicsItem? built_root = null;   // change-detection guard
        // Collapsed nodes (by identity); everything else renders expanded.
        private Gee.HashSet<TopicsItem> collapsed;
        private double pending_scroll_restore = 0;
        // Guards against programmatic cursor moves (selection sync,
        // rebuilds) re-entering the navigate-on-select handler.
        private bool syncing = false;

        public TopicsView () {
            Object (orientation: Orientation.VERTICAL);
            collapsed = new Gee.HashSet<TopicsItem> ();
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;
            held_model = model;

            scrolled = new ScrolledWindow () {
                hexpand = true,
                vexpand = true
            };
            scrolled.set_policy (PolicyType.NEVER, PolicyType.AUTOMATIC);

            store = new GLib.ListStore (typeof (TopicsFlatRow));
            selection = new SingleSelection (store) {
                autoselect = false,
                can_unselect = true
            };
            var factory = new SignalListItemFactory ();
            factory.setup.connect ((list_item) => {
                var li = (ListItem) list_item;
                var row_box = new Box (Orientation.HORIZONTAL, 2);
                var expander = new Button () {
                    has_frame = false,
                    width_request = 24
                };
                expander.clicked.connect (() => {
                    var r = (TopicsFlatRow?) li.get_item ();
                    if (r != null) toggle_item (r.item);
                });
                var label = new Label (null) {
                    xalign = 0,
                    hexpand = true,
                    ellipsize = Pango.EllipsizeMode.END
                };
                row_box.append (expander);
                row_box.append (label);
                li.set_child (row_box);
            });
            factory.bind.connect ((list_item) => {
                var li = (ListItem) list_item;
                var row_box = (Box) li.get_child ();
                var expander = (Button) row_box.get_first_child ();
                var label = (Label) row_box.get_last_child ();
                var r = (TopicsFlatRow) li.get_item ();
                row_box.margin_start = r.depth * 16;
                label.label = r.item.name;
                if (r.has_children) {
                    expander.visible = true;
                    expander.label = is_expanded (r.item) ? "▾" : "▸";
                } else {
                    expander.visible = false;
                }
            });
            list_view = new ListView (selection, factory) {
                hexpand = true,
                vexpand = true
            };

            // Left/Right toggles; capture phase beats GtkListBase's move bindings.
            var keys = new EventControllerKey ();
            keys.set_propagation_phase (PropagationPhase.CAPTURE);
            keys.key_pressed.connect ((keyval, keycode, state) => {
                var r = (TopicsFlatRow?) selection.selected_item;
                if (r == null || !r.has_children) return false;
                if (keyval == Gdk.Key.Left && is_expanded (r.item)) {
                    toggle_item (r.item);
                    return true;
                }
                if (keyval == Gdk.Key.Right && !is_expanded (r.item)) {
                    toggle_item (r.item);
                    return true;
                }
                return false;
            });
            list_view.add_controller (keys);

            list_view.activate.connect ((pos) => {
                var r = (TopicsFlatRow?) store.get_item (pos);
                if (r != null && r.item.url != null && r.item.url != "") {
                    dispatch (new TopicsSelectionChangedMessage (r.item.url));
                }
            });

            // Navigates on selection (single click), not only on
            // double-click (chmtoc EVT_TREE_SEL_CHANGED parity).
            selection.selection_changed.connect (() => {
                if (syncing) return;
                var r = (TopicsFlatRow?) selection.selected_item;
                if (r == null) return;
                if (r.item.url != null && r.item.url != "") {
                    dispatch (new TopicsSelectionChangedMessage (r.item.url));
                }
            });

            scrolled.child = list_view;
            append (scrolled);
        }

        private bool is_expanded (TopicsItem item) {
            return !collapsed.contains (item);
        }

        private void toggle_item (TopicsItem item) {
            var m = held_model;
            if (m == null) return;
            bool had_selection = selection.selected_item != null;
            if (collapsed.contains (item)) collapsed.remove (item);
            else collapsed.add (item);
            rebuild_flat (m, true);
            // Keep a visible highlight when collapse hid the selected row.
            if (had_selection && selection.selected_item == null) {
                syncing = true;
                select_item_position (item, false);
                syncing = false;
            }
            // Persist; URL-less group nodes are view-only.
            if (item.url != null && item.url != "") {
                if (collapsed.contains (item))
                    dispatch (new TopicsItemCollapsedMessage (item.url));
                else
                    dispatch (new TopicsItemExpandedMessage (item.url));
            }
        }

        // B+hybrid: called via AppModel.notify["current-book"] (freeze/thaw batched) instead of via TAB_ACTIVATED
        public void notify_active_changed (AppModel model) {
            held_model = model;
            built_root = null;
            rebuild_tree (model);
            var t_sel = model.current_book != null ? model.current_book.topics : model.placeholder.topics;
            select_url (model, t_sel.selected_url);
        }

        public void update (AppMessage msg, AppModel model) {
            held_model = model;
            var t_up = model.current_book != null ? model.current_book.topics : model.placeholder.topics;
            switch (msg.kind) {
                case AppMessageKind.TOPICS_SELECTION_CHANGED: {
                    // Selection initiated here already moved the cursor.
                    break;
                }

                case AppMessageKind.TOPICS_ITEM_EXPANDED:
                case AppMessageKind.TOPICS_ITEM_COLLAPSED: {
                    // Applied in toggle_item; the messages only persist.
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
                    select_url (model, t_up.selected_url);
                    break;
                }

                default:
                    break;
            }
        }

        private void rebuild_tree (AppModel model) {
            collapsed.clear ();
            rebuild_flat (model, false);
        }

        private void rebuild_flat (AppModel model, bool preserve_scroll) {
            var prev_row = (TopicsFlatRow?) selection.selected_item;
            var prev_item = prev_row != null ? prev_row.item : null;
            double saved_scroll = 0;
            if (preserve_scroll) {
                var vadj = scrolled.get_vadjustment ();
                if (vadj != null) saved_scroll = vadj.get_value ();
            }

            syncing = true;
            store.remove_all ();
            var t_rb = model.current_book != null ? model.current_book.topics : model.placeholder.topics;
            if (t_rb.root != null) {
                add_visible_recursive (t_rb.root, 0);
            }
            if (prev_item != null) {
                select_item_position (prev_item, false);
            }
            syncing = false;

            if (preserve_scroll && saved_scroll > 0) {
                pending_scroll_restore = saved_scroll;
                GLib.Idle.add (restore_scroll_idle);
            }
        }

        private bool restore_scroll_idle () {
            if (pending_scroll_restore > 0) {
                var vadj = scrolled.get_vadjustment ();
                if (vadj != null) vadj.set_value (pending_scroll_restore);
                pending_scroll_restore = 0;
            }
            return false;
        }

        private void add_visible_recursive (TopicsItem item, int depth) {
            bool has_kids = item.children.size > 0;
            store.append (new TopicsFlatRow (item, depth, has_kids));
            if (has_kids && is_expanded (item)) {
                foreach (var child in item.children) {
                    add_visible_recursive (child, depth + 1);
                }
            }
        }

        private void select_url (AppModel model, string? url) {
            if (url == null || url.length == 0) return;
            var t = model.current_book != null ? model.current_book.topics : model.placeholder.topics;
            var item = t.find_item_by_url (url);
            if (item == null) return;
            ensure_ancestors_visible (model, item);
            syncing = true;
            select_item_position (item, true);
            syncing = false;
        }

        private void ensure_ancestors_visible (AppModel model, TopicsItem item) {
            // Visual expand_to_path parity; persistence untouched.
            bool changed = false;
            var p = item.parent;
            while (p != null) {
                if (collapsed.contains (p)) {
                    collapsed.remove (p);
                    changed = true;
                }
                p = p.parent;
            }
            if (changed) rebuild_flat (model, false);
        }

        private bool select_item_position (TopicsItem item, bool scroll) {
            for (uint i = 0; i < store.get_n_items (); i++) {
                var r = (TopicsFlatRow) store.get_item (i);
                if (r.item == item) {
                    selection.select_item (i, true);
                    if (scroll) list_view.scroll_to (i, ListScrollFlags.SELECT, null);
                    return true;
                }
            }
            return false;
        }
    }
}
