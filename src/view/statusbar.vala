// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class StatusBarView : Box {
        private unowned Elmish.Dispatch<AppMessage> dispatch;
        private Label status_label;
        private Revealer toast_revealer;
        private Label toast_label;
        private uint toast_timeout_id = 0;

        public StatusBarView () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 6);
            margin_top = 2;
            margin_bottom = 2;
            margin_start = 6;
            margin_end = 6;
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            status_label = new Label ("Ready") {
                halign = Align.START,
                hexpand = true,
                ellipsize = Pango.EllipsizeMode.END
            };
            append (status_label);

            // Toast notification
            toast_label = new Label ("") {
                margin_top = 4,
                margin_bottom = 4,
                margin_start = 12,
                margin_end = 12
            };
            toast_label.add_css_class ("toast");
            
            toast_revealer = new Revealer () {
                transition_type = RevealerTransitionType.SLIDE_UP,
                reveal_child = false,
                child = toast_label
            };
            append (toast_revealer);
        }

        public void show_toast (string message) {
            toast_label.label = message;
            toast_revealer.reveal_child = true;
            
            // Cancel existing timeout
            if (toast_timeout_id != 0) {
                GLib.Source.remove (toast_timeout_id);
            }
            
            // Auto-hide after 3 seconds
            toast_timeout_id = GLib.Timeout.add (3000, () => {
                toast_revealer.reveal_child = false;
                toast_timeout_id = 0;
                return false;
            });
        }

        public void update (AppMessage msg, AppModel model) {
            switch (msg.kind) {
                case AppMessageKind.OPEN_FILE_DONE:
                case AppMessageKind.NAVIGATE_DONE: {
                    status_label.label = model.status_text;
                    break;
                }
                case AppMessageKind.LINK_HOVERED: {
                    var hm = (LinkHoveredMessage) msg;
                    if (hm.url != null && hm.url.length > 0) {
                        status_label.label = hm.url;
                    } else {
                        // Restore last status (page title or Ready)
                        status_label.label = model.status_text;
                    }
                    break;
                }
                default:
                    break;
            }
        }
    }
}