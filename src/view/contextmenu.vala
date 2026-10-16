// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using WebKit;
using Gtk;
using Vchm.Model;

namespace Vchm.View {

    public class WebViewContextMenu : Object {
        private WebView web_view;
        private unowned Elmish.Dispatch<AppMessage> dispatch;

        public WebViewContextMenu (WebView web_view, Elmish.Dispatch<AppMessage> dispatch) {
            this.web_view = web_view;
            this.dispatch = dispatch;
        }

        public void build_ui () {
            // Context menu is handled by WebKit automatically
            // We can connect to context-menu signal if needed
            web_view.context_menu.connect ((view, menu, hit_test_result) => {
                // Add custom menu items if needed
                return false;
            });
        }
    }
}