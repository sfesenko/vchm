// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    // Bookmarks side panel: combo of saved pages for the current book
    // plus Add/Remove buttons.
    public class BookmarksView : Box {
        private unowned Elmish.Dispatch<AppMessage> dispatch;
        private DropDown combo;
        private StringList combo_items;
        private AppModel model;
        private bool populating = false;
        private string populated_for = "";

        public BookmarksView () {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            margin_top = 6;
            margin_bottom = 6;
            margin_start = 6;
            margin_end = 6;
        }

        public void build_ui (Elmish.Dispatch<AppMessage> d, AppModel m) {
            dispatch = d;
            model = m;

            combo_items = new StringList (null);
            combo = new DropDown (combo_items, null) {
                hexpand = true
            };
            var factory = new SignalListItemFactory ();
            factory.setup.connect ((item) => {
                var li = (ListItem) item;
                li.set_child (new Label (null) { xalign = 0 });
            });
            factory.bind.connect ((item) => {
                var li = (ListItem) item;
                var label = (Label) li.get_child ();
                var str_obj = (StringObject) li.get_item ();
                label.label = str_obj.string;
            });
            combo.factory = factory;
            combo.list_factory = factory;
            combo.notify["selected"].connect (() => {
                if (populating) return;
                uint idx = combo.selected;
                var list = current_list ();
                if (list != null && idx != Gtk.INVALID_LIST_POSITION && (int) idx < list.size)
                    dispatch (new BookmarkJumpMessage (list[(int) idx].url));
            });
            append (combo);

            var btns = new Box (Orientation.HORIZONTAL, 6);
            var add_btn = new Button.with_label (_("Add"));
            add_btn.clicked.connect (() => {
                var v_add = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
                if (v_add.current_url.length > 0 && model.file_open)
                    dispatch (new BookmarkAddMessage ());
            });
            btns.append (add_btn);

            var remove_btn = new Button.with_label (_("Remove"));
            remove_btn.clicked.connect (() => {
                uint idx = combo.selected;
                var list = current_list ();
                if (list != null && idx != Gtk.INVALID_LIST_POSITION && (int) idx < list.size)
                    dispatch (new BookmarkRemoveMessage (list[(int) idx].title, list[(int) idx].url));
            });
            btns.append (remove_btn);

            var rename_btn = new Button.with_label (_("Rename"));
            rename_btn.clicked.connect (() => {
                uint idx = combo.selected;
                var list = current_list ();
                if (list == null || idx == Gtk.INVALID_LIST_POSITION || (int) idx >= list.size) return;
                var bm = list[(int) idx];
                var dialog = new Gtk.Window () {
                    title = _("Rename Bookmark"),
                    transient_for = (Window) get_root (),
                    modal = true,
                    default_width = 350,
                    default_height = 100
                };
                var box = new Box (Orientation.VERTICAL, 6) {
                    margin_top = 12, margin_bottom = 12, margin_start = 12, margin_end = 12
                };
                var label = new Label (_("New title:"));
                label.halign = Align.START;
                var entry = new Entry () { text = bm.title, hexpand = true };
                box.append (label);
                box.append (entry);
                var btn_row = new Box (Orientation.HORIZONTAL, 6) {
                    halign = Align.END
                };
                var cancel_btn = new Button.with_label (_("_Cancel")) { use_underline = true };
                cancel_btn.clicked.connect (() => dialog.destroy ());
                var rename_action = new Button.with_label (_("_Rename")) { use_underline = true };
                rename_action.add_css_class ("suggested-action");
                rename_action.clicked.connect (() => {
                    var nt = entry.text.strip ();
                    if (nt.length > 0 && nt != bm.title)
                        dispatch (new BookmarkRenameMessage (bm.url, nt));
                    dialog.destroy ();
                });
                btn_row.append (cancel_btn);
                btn_row.append (rename_action);
                box.append (btn_row);
                dialog.child = box;
                dialog.default_widget = rename_action;
                entry.activates_default = true;
                // Escape-close parity with Gtk.Dialog.
                var esc = new EventControllerKey ();
                ((Gtk.Widget) dialog).add_controller (esc);
                esc.key_pressed.connect ((keyval, keycode, state) => {
                    if (keyval == Gdk.Key.Escape) {
                        dialog.destroy ();
                        return true;
                    }
                    return false;
                });
                dialog.present ();
                entry.grab_focus ();
            });
            btns.append (rename_btn);
            append (btns);

            repopulate ();
        }

        private Gee.ArrayList<Bookmark>? current_list () {
            var c_cur = model.current_book != null ? model.current_book : model.placeholder;
            if (!c_cur.chm_file.is_open ()) return null;
            return model.bookmarks.for_book (c_cur.chm_file.filename ());
        }

        public void notify_active_changed (AppModel model) {
            populated_for = "";
            repopulate ();
            var c_not = model.current_book != null ? model.current_book : model.placeholder;
            populated_for = c_not.chm_file.is_open () ? c_not.chm_file.filename () : "";
        }

        public void update (AppMessage msg, AppModel model) {
            var c_up = model.current_book != null ? model.current_book : model.placeholder;
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE:
                case AppMessageKind.BOOKMARKS_CHANGED:
                case AppMessageKind.NAVIGATE_DONE: {
                    var book = c_up.chm_file.is_open ()
                        ? c_up.chm_file.filename () : "";
                    if (book != populated_for ||
                        msg.kind == AppMessageKind.BOOKMARKS_CHANGED) {
                        populated_for = book;
                        repopulate ();
                    }
                    break;
                }
                default:
                    break;
            }
        }

        private void repopulate () {
            populating = true;
            combo_items.splice (0, combo_items.get_n_items (), null);
            var list = current_list ();
            if (list != null)
                foreach (var b in list) combo_items.append (b.title);
            combo.selected = list != null && list.size > 0 ? 0 : Gtk.INVALID_LIST_POSITION;
            populating = false;
        }
    }
}
