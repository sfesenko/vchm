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
                if (model.viewer.current_url.length > 0 && model.file_open)
                    dispatch (new BookmarkAddMessage ());
            });
            btns.append (add_btn);

            var remove_btn = new Button.with_label (_("Remove"));
            remove_btn.clicked.connect (() => {
                int idx = combo.active;
                var list = current_list ();
                if (idx >= 0 && list != null && idx < list.size)
                    dispatch (new BookmarkRemoveMessage (list[idx].title));
            });
            btns.append (remove_btn);
            append (btns);

            repopulate ();
        }

        private Gee.ArrayList<Bookmark>? current_list () {
            if (!model.chm_file.is_open ()) return null;
            return model.bookmarks.for_book (model.chm_file.filename ());
        }

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE:
                case AppMessageKind.BOOKMARKS_CHANGED:
                case AppMessageKind.NAVIGATE_DONE: {
                    var book = model.chm_file.is_open ()
                        ? model.chm_file.filename () : "";
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
            combo.remove_all ();
            var list = current_list ();
            if (list != null)
                foreach (var b in list) combo.append_text (b.title);
            combo.active = list != null && list.size > 0 ? 0 : -1;
            populating = false;
        }
    }
}
