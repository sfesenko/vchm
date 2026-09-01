// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    // Bookmarks side panel: combo of saved pages for the current book
    // plus Add/Remove buttons.
    public class BookmarksView : Box {
        private Elmish.Dispatch<AppMessage> dispatch;
        private ComboBoxText combo;
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

            combo = new ComboBoxText ();
            combo.hexpand = true;
            combo.changed.connect (() => {
                if (populating) return;
                int idx = combo.active;
                var list = current_list ();
                if (idx >= 0 && list != null && idx < list.size)
                    dispatch (new BookmarkJumpMessage (list[idx].url));
            });
            append (combo);

            var btns = new Box (Orientation.HORIZONTAL, 6);
            var add_btn = new Button.with_label (_("Add"));
            add_btn.clicked.connect (() => {
                var v_add = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
                if (v_add.current_url.length > 0 && model.file_open)
                    dispatch (new BookmarkAddMessage ());
            });
            btns.append (add_btn);

            var remove_btn = new Button.with_label (_("Remove"));
            remove_btn.clicked.connect (() => {
                int idx = combo.active;
                var list = current_list ();
                if (idx >= 0 && list != null && idx < list.size)
                    dispatch (new BookmarkRemoveMessage (list[idx].title, list[idx].url));
            });
            btns.append (remove_btn);

            var rename_btn = new Button.with_label (_("Rename"));
            rename_btn.clicked.connect (() => {
                int idx = combo.active;
                var list = current_list ();
                if (idx < 0 || list == null || idx >= list.size) return;
                var bm = list[idx];
                var dialog = new Dialog.with_buttons (_("Rename Bookmark"), (Window) get_root (),
                    DialogFlags.MODAL, _("_Cancel"), ResponseType.CANCEL, _("_Rename"), ResponseType.ACCEPT);
                dialog.set_default_size (350, 100);
                var content = dialog.get_content_area ();
                var box = new Box (Orientation.VERTICAL, 6) {
                    margin_top = 12, margin_bottom = 12, margin_start = 12, margin_end = 12
                };
                var label = new Label (_("New title:"));
                label.halign = Align.START;
                var entry = new Entry () { text = bm.title, hexpand = true };
                entry.activates_default = true;
                dialog.set_default_response (ResponseType.ACCEPT);
                box.append (label);
                box.append (entry);
                content.append (box);
                dialog.present ();
                entry.grab_focus ();
                dialog.response.connect ((resp) => {
                    if (resp == ResponseType.ACCEPT) {
                        var nt = entry.text.strip ();
                        if (nt.length > 0 && nt != bm.title)
                            dispatch (new BookmarkRenameMessage (bm.url, nt));
                    }
                    dialog.destroy ();
                });
            });
            btns.append (rename_btn);
            append (btns);

            repopulate ();
        }

        private Gee.ArrayList<Bookmark>? current_list () {
            var c_cur = model.active_book != null ? model.active_book : model.placeholder;
            if (!c_cur.chm_file.is_open ()) return null;
            return model.bookmarks.for_book (c_cur.chm_file.filename ());
        }

        public void notify_active_changed (AppModel model) {
            populated_for = "";
            repopulate ();
            var c_not = model.active_book != null ? model.active_book : model.placeholder;
            populated_for = c_not.chm_file.is_open () ? c_not.chm_file.filename () : "";
        }

        public void update (AppMessage msg, AppModel model) {
            var c_up = model.active_book != null ? model.active_book : model.placeholder;
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

                case AppMessageKind.TAB_ACTIVATED: {
                    // Legacy via Elmish; also via notify_active_changed
                    populated_for = "";   // bypass the guard
                    repopulate ();
                    populated_for = c_up.chm_file.is_open ()
                        ? c_up.chm_file.filename () : "";
                    break;
                }

                default:
                    break;
            }
        }

        private void repopulate () {
            populating = true;
            combo.remove_all ();
            var list = current_list ();
            if (list != null)
                foreach (var b in list) combo.append_text (b.title);
            combo.active = list != null && list.size > 0 ? 0 : -1;
            populating = false;
        }
    }
}
