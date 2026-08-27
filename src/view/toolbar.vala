// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class ToolbarView : Box {
        private Elmish.Dispatch<AppMessage> dispatch;

        public ToolbarView () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 6);
            margin_top = 4;
            margin_bottom = 4;
            margin_start = 6;
            margin_end = 6;
        }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            // Navigation buttons
            var back_btn = new Button.from_icon_name ("go-previous-symbolic") {
                tooltip_text = _("Back"),
                action_name = "win." + AppView.ACTION_BACK
            };
            append (back_btn);

            var forward_btn = new Button.from_icon_name ("go-next-symbolic") {
                tooltip_text = _("Forward"),
                action_name = "win." + AppView.ACTION_FORWARD
            };
            append (forward_btn);

            var home_btn = new Button.from_icon_name ("go-home-symbolic") {
                tooltip_text = _("Home"),
                action_name = "win." + AppView.ACTION_HOME
            };
            append (home_btn);

            var separator1 = new Separator (Orientation.VERTICAL);
            append (separator1);

            // File buttons
            var open_btn = new Button.from_icon_name ("document-open-symbolic") {
                tooltip_text = _("Open"),
                action_name = "win." + AppView.ACTION_OPEN
            };
            append (open_btn);

            var close_btn = new Button.from_icon_name ("window-close-symbolic") {
                tooltip_text = _("Close"),
                action_name = "win." + AppView.ACTION_CLOSE
            };
            append (close_btn);

            var copy_btn = new Button.from_icon_name ("edit-copy-symbolic") {
                tooltip_text = _("Copy selection")
            };
            copy_btn.clicked.connect (() => dispatch (new ViewerCopyMessage ()));
            append (copy_btn);

            var separator2 = new Separator (Orientation.VERTICAL);
            append (separator2);

            // View buttons — ToggleButtons mirror the stateful
            // win.toggle_* actions, so check-state stays in sync.
            var topics_btn = new ToggleButton () {
                icon_name = "sidebar-show-symbolic",
                tooltip_text = _("Contents"),
                action_name = "win." + AppView.ACTION_TOGGLE_TOPICS
            };
            append (topics_btn);

            var index_btn = new ToggleButton () {
                icon_name = "view-list-symbolic",
                tooltip_text = _("Index"),
                action_name = "win." + AppView.ACTION_TOGGLE_INDEX
            };
            append (index_btn);

            var search_btn = new ToggleButton () {
                icon_name = "edit-find-symbolic",
                tooltip_text = _("Search"),
                action_name = "win." + AppView.ACTION_TOGGLE_SEARCH
            };
            append (search_btn);

            var separator3 = new Separator (Orientation.VERTICAL);
            append (separator3);

            // Font controls. zoom-in/out exist in every theme; the
            // previous text-size-*-symbolic names are in no icon set and
            // rendered as blank boxes.
            var font_decrease_btn = new Button.from_icon_name ("zoom-out-symbolic") {
                tooltip_text = _("Decrease Font Size"),
                action_name = "win." + AppView.ACTION_FONT_DECREASE
            };
            append (font_decrease_btn);

            var font_increase_btn = new Button.from_icon_name ("zoom-in-symbolic") {
                tooltip_text = _("Increase Font Size"),
                action_name = "win." + AppView.ACTION_FONT_INCREASE
            };
            append (font_increase_btn);

            var font_reset_btn = new Button.from_icon_name ("view-refresh-symbolic") {
                tooltip_text = _("Reset Font Size"),
                action_name = "win." + AppView.ACTION_FONT_RESET
            };
            append (font_reset_btn);

            var separator4 = new Separator (Orientation.VERTICAL);
            append (separator4);

            // Find
            var find_btn = new Button.from_icon_name ("edit-find-symbolic") {
                tooltip_text = _("Find in Page"),
                action_name = "win." + AppView.ACTION_FIND
            };
            append (find_btn);

            // Spacer
            var spacer = new Box (Orientation.HORIZONTAL, 0) { hexpand = true };
            append (spacer);

            // Print
            var print_btn = new Button.from_icon_name ("document-print-symbolic") {
                tooltip_text = _("Print")
            };
            print_btn.clicked.connect (() =>
                dispatch (new ViewerPrintMessage ()));
            append (print_btn);
        }

        public void update (AppMessage msg, AppModel model) {
            // Update button states based on model
        }
    }
}