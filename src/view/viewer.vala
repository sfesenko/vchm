// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Page rendering via WebKit. Pages are loaded through the chm:// scheme so
// WebKit resolves every relative URL (links, images, CSS, anchors)
// natively against the page URI — no HTML rewriting involved.

using WebKit;
using Gtk;
using GLib;
using Vchm.Model;

namespace Vchm.View {

    public class ViewerView : WebView {
        private Elmish.Dispatch<AppMessage> dispatch;
        private WebViewContextMenu context_menu;
        private GLib.SimpleAction? open_external_action = null;
        private string? loaded_url = null;
        private string? loaded_book = null;

        public ViewerView () {
            Object (web_context: WebContext.get_default ());
        }

        private static bool s_scheme_registered = false;

        // Which archive this tab renders (full path; set by the shell on
        // creation). Full path instead of basename: two open books may
        // share a basename and must not collide in the registry or URIs
        // (review F5).
        public string book_path { get; set; default = ""; }

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;

            var settings = get_settings ();
            settings.enable_javascript = false; // CHM files rarely need JS
            settings.enable_developer_extras = false;
            settings.enable_write_console_messages_to_stdout = false;
            settings.enable_page_cache = true;
            var v_init = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
            settings.default_font_size = v_init.font_size;
            settings.default_font_family = v_init.font_family;
            settings.monospace_font_family = v_init.fixed_font_family;
            // Images are always on; remote subresources are blocked by the
            // CSP injected in on_chm_uri_request (see HtmlTextUtils).
            settings.auto_load_images = true;

            var context = WebContext.get_default ();
            if (!s_scheme_registered) {
                context.register_uri_scheme ("chm", on_chm_uri_request);
                s_scheme_registered = true;
            }

            decide_policy.connect (on_decide_policy);
            load_changed.connect (on_load_changed);

            open_external_action = new GLib.SimpleAction (
                "open-external", GLib.VariantType.STRING);
            open_external_action.activate.connect ((parameter) => {
                if (parameter != null)
                    open_external (parameter.get_string ());
            });

            var group = new GLib.SimpleActionGroup ();
            group.add_action (open_external_action);
            insert_action_group ("viewer", group);

            var find = get_find_controller ();
            find.found_text.connect ((match_count) => {
                dispatch (new ViewerFindCountMessage (match_count));
            });
            find.failed_to_find_text.connect (() => {
                dispatch (new ViewerFindCountMessage (0));
            });

            // Hover link → status bar
            mouse_target_changed.connect ((hit, modifiers) => {
                var hover = hit.link_uri; // nullable
                dispatch (new LinkHoveredMessage (hover));
            });

            context_menu = new WebViewContextMenu (this, dispatch);
            context_menu.build_ui ();

            // Widget-level signal; the member field shadows it in scope.
            ((WebKit.WebView) this).context_menu.connect ((view, menu, hit) => {
                var link = hit.link_uri ?? "";
                bool external = link.has_prefix ("http://") ||
                                link.has_prefix ("https://") ||
                                link.has_prefix ("mailto:");
                if (!external) return false;

                // External links: single action — open in default browser.
                // Internal chm:// links just follow in the same tab (no
                // new-tab clone under strict single-tab-per-file).
                var ext_item = new WebKit.ContextMenuItem.from_gaction (
                    open_external_action,
                    _("Open Link in Browser"), link);
                menu.insert (ext_item, 0);

                menu.append (new WebKit.ContextMenuItem.separator ());
                return false;   // keep default items too
            });
        }

        // Full chm:// URI for a CHM-internal path like "/dir/page.htm".
        private string page_uri (string chm_path) {
            // The archive segment is the full path, percent-encoded
            // (allow_utf8=false → force percent-encoding; raw Cyrillic or
            // spaces in a URI make WebKit silently drop the load; the '/'
            // separators of the path must not leak into the URI structure).
            var esc = GLib.Uri.escape_string (book_path, null, false);
            string p = chm_path;
            if (!p.has_prefix ("/")) {
                p = "/" + p;
            }
            return "chm://" + esc + p;
        }

        private bool on_decide_policy (WebView view, PolicyDecision decision, PolicyDecisionType decision_type) {
            // target=_blank / window.open: no NEW_WINDOW_ACTION branch used
            // to leave these dying silently in a hidden WebView. Route CHM
            // targets into a new tab and externals to the desktop handler
            // (review F12).
            if (decision_type == PolicyDecisionType.NEW_WINDOW_ACTION) {
                var wnd_decision = (NavigationPolicyDecision) decision;
                var wnd_action = wnd_decision.get_navigation_action ();
                var wuri = wnd_action?.get_request ()?.get_uri ();
                decision.ignore ();
                if (wuri != null) {
                    if (wuri.has_prefix ("chm://")) {
                        // Strict single-tab-per-file: target=_blank inside
                        // the same book just follows the link in the same tab.
                        var wpath = chm_path_from_uri (wuri);
                        if (wpath != null && wpath.length > 1)
                            dispatch (new NavigateMessage (wpath));
                    } else if (wuri.has_prefix ("http://") || wuri.has_prefix ("https://") ||
                               wuri.has_prefix ("mailto:")) {
                        launch_external (wuri);
                    }
                }
                return true;
            }

            if (decision_type != PolicyDecisionType.NAVIGATION_ACTION) {
                return false;
            }

            var nav_decision = (NavigationPolicyDecision) decision;
            var nav_action = nav_decision.get_navigation_action ();
            if (nav_action == null) return false;

            var request = nav_action.get_request ();
            if (request == null) return false;

            var uri = request.get_uri ();
            if (uri == null) return false;

            // In-page anchors on the current page: let WebKit scroll.
            if (uri.has_prefix ("about:") || uri.has_prefix ("data:")) {
                return false;
            }

            if (uri.has_prefix ("chm://")) {
                // Our own model-driven load: let it proceed natively without
                // re-dispatching NAVIGATE (would loop / duplicate history).
                if (loaded_url != null && uri == page_uri (loaded_url)) {
                    return false;
                }

                // Same-document anchor (<a href="#sec">): stripping the
                // fragment yields the page we are already showing — hand
                // the jump to WebKit instead of redispatching NAVIGATE,
                // which was a no-op for the already-loaded URL and never
                // scrolled (review F3). Book segment must match too.
                int hash = uri.index_of ("#");
                if (hash >= 0 && loaded_url != null && loaded_url.length > 0 &&
                    uri.has_prefix ("chm://" +
                                    GLib.Uri.escape_string (book_path, null, false)) &&
                    chm_path_from_uri (uri) == loaded_url) {
                    return false;
                }

                var path = chm_path_from_uri (uri);
                if (path == null) {
                    nav_decision.ignore ();
                    return true;
                }
                // Ignore the native navigation: the model-driven load after
                // NAVIGATE_DONE is the only fetch (a use() here downloaded
                // the page twice).
                nav_decision.ignore ();
                dispatch (new NavigateMessage (path));
                return true;
            }

            if (uri.has_prefix ("ms-its:") || uri.has_prefix ("mk:@MSITStore:")) {
                nav_decision.ignore ();
                dispatch (new NavigateMessage (uri));
                return true;
            }

            if (uri.has_prefix ("http://") || uri.has_prefix ("https://") ||
                uri.has_prefix ("mailto:")) {
                // External target: hand to the desktop's default handler.
                nav_decision.ignore ();
                launch_external (uri);
                return true;
            }

            // Unknown schemes (file:, ftp:, …): never let them reach the
            // engine — the CSP restricts subresources, not top-level
            // navigation, so the default-use fallback rendered local
            // files from inside book content (review F11).
            nav_decision.ignore ();
            return true;
        }

        // Used by the context menu action (win.open-external).
        public void open_external (string uri) {
            launch_external (uri);
        }

        private void launch_external (string uri) {
            // fire-and-forget; failures surface as a toast
            GLib.AppInfo.launch_default_for_uri_async.begin (uri, null, null, (obj, res) => {
                try {
                    GLib.AppInfo.launch_default_for_uri_async.end (res);
                } catch (GLib.Error e) {
                    dispatch (new ShowToastMessage (
                        _("Cannot open %s: %s").printf (uri, e.message)));
                }
            });
        }

        private void on_load_changed (WebView view, LoadEvent load_event) {
            // Navigation truth lives in the model: NAVIGATE_DONE is dispatched
            // from the update function, not from WebKit load events, so that
            // history is pushed exactly once per navigation.
            // M1: restore per-book scroll only after the page has painted;
            // an Idle restore right after load_uri was overwritten by the
            // engine's own scroll reset.
            if (load_event == LoadEvent.FINISHED && pending_restore_y > 0) {
                restore_scroll (pending_restore_y);
                pending_restore_y = 0;
            }
        }

        // Extract "/path/page.htm" from "chm://<book-basename>/path/page.htm".
        private string? chm_path_from_uri (string uri) {
            const string prefix = "chm://";
            if (!uri.has_prefix (prefix)) return null;

            string rest = uri.substring (prefix.length);
            int slash = rest.index_of ("/");
            if (slash < 0) return null;

            string path = rest.substring (slash);
            int anchor = path.index_of ("#");
            if (anchor >= 0) path = path.substring (0, anchor);
            int query = path.index_of ("?");
            if (query >= 0) path = path.substring (0, query);

            var decoded = GLib.Uri.unescape_string (path, null);
            return decoded ?? path;
        }

        // ── Find-in-page (WebKit FindController)
        private void run_find (string text, bool case_sensitive) {
            if (text.length == 0) {
                get_find_controller ().search_finish ();
                return;
            }
            FindOptions opts = FindOptions.WRAP_AROUND;
            if (!case_sensitive) opts |= FindOptions.CASE_INSENSITIVE;
            get_find_controller ().search (text, (uint32) opts, uint.MAX);
        }

        // Print current page through the platform dialog.
        public void print_page () {
            var op = new WebKit.PrintOperation (this);
            op.run_dialog ((Gtk.Window?) get_root ());
        }

        // Scroll persistence: save/restore per-book scroll via JS.
        // pending_restore_y holds the y to restore once the page
        // finishes loading; restoring via Idle before FINISHED was
        // overwritten by WebKit's layout/scroll reset (M1).
        private int pending_restore_y = 0;

        public void restore_scroll (int y) {
            if (y <= 0) return;
            var js = "window.scrollTo(0, %d)".printf (y);
            evaluate_javascript.begin (js, -1, null, null, null, (obj, res) => {
                try { evaluate_javascript.end (res); } catch (Error e) {}
            });
        }

        // Book change needs a clean slate: WebKit keeps the previous
        // document's DOM, history and cached subresources. Reusing the
        // same WebView for a different archive without clearing leaves
        // stale state and, when the new URL has the same string as the
        // old one (re-opening the same file), the equality guard
        // `cur != loaded_url` skips the load and the view stays blank.
        // Call this before binding a new BookContext.
        public void invalidate_for_new_book () {
            loaded_url = null;
            loaded_book = null;
            pending_restore_y = 0;
            try { stop_loading (); } catch {}
        }

        public void reset_to_blank () {
            invalidate_for_new_book ();
            // Clear the previous document so a stale page is not flashed
            // while the new one loads; about:blank is allow-listed in
            // decide_policy and does not go through the chm: handler.
            load_uri ("about:blank");
        }

        // Load when the model's current URL differs from what we show.
        // Called from update() and on tab activation. The `force` flag
        // bypasses the cache-skip and always reloads — needed when a
        // tab is re-shown after being hidden, because WebKit may have
        // unloaded the page contents while the tab was off-screen.
        public void sync_if_needed (AppModel model, bool force = false) {
            var v_sync = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
            var cur = v_sync.current_url;
            string book;
            if (book_path != "") book = book_path;
            else if (model.current_book != null) book = model.current_book.chm_file.filename ();
            else book = model.placeholder.chm_file.filename ();
            if (model.file_open && cur.length > 0 &&
                (force || cur != loaded_url || book != loaded_book)) {
                loaded_url = cur;
                loaded_book = book;
                // Stash per-book scroll to restore once FINISHED fires (M1)
                int saved_y = model.per_books.get_scroll (book);
                pending_restore_y = saved_y;
                load_uri (page_uri (cur));
            }
        }

        public void update (AppMessage msg, AppModel model) {
            sync_if_needed (model);

            switch (msg.kind) {
                case AppMessageKind.VIEWER_FIND: {
                    var fm = (ViewerFindMessage) msg;
                    run_find (fm.text, fm.case_sensitive);
                    break;
                }

                case AppMessageKind.VIEWER_PRINT:
                    print_page ();
                    break;

                case AppMessageKind.VIEWER_COPY:
                    execute_editing_command ("Copy");
                    break;

                case AppMessageKind.VIEWER_FIND_NEXT:
                    get_find_controller ().search_next ();
                    break;

                case AppMessageKind.VIEWER_FIND_PREV:
                    get_find_controller ().search_previous ();
                    break;

                case AppMessageKind.VIEWER_FONT_INCREASE:
                case AppMessageKind.VIEWER_FONT_DECREASE:
                case AppMessageKind.VIEWER_FONT_RESET: {
                    var settings = get_settings ();
                    var v_f = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
                    settings.default_font_size = v_f.font_size;
                    break;
                }

                case AppMessageKind.VIEWER_FONT_CHANGED: {
                    var settings = get_settings ();
                    var v_fc = model.current_book != null ? model.current_book.viewer : model.placeholder.viewer;
                    settings.default_font_size = v_fc.font_size;
                    settings.default_font_family = v_fc.font_family;
                    settings.monospace_font_family = v_fc.fixed_font_family;
                    break;
                }

                default:
                    break;
            }
        }

        // Serve resources out of the archive. HTML is transcoded to UTF-8
        // using the per-file encoding detected from #SYSTEM/#WINDOWS.
        private void on_chm_uri_request (WebKit.URISchemeRequest request) {
            // "chm://<escaped-archive-path>/path" — resolve the owning archive.
            string uri = request.get_uri ();
            const string prefix = "chm://";
            if (!uri.has_prefix (prefix)) { finish_empty (request); return; }

            string rest = uri.substring (prefix.length);
            int slash = rest.index_of ("/");
            if (slash <= 0) { finish_empty (request); return; }

            var book_name_raw = rest.substring (0, slash);
            var book_name = GLib.Uri.unescape_string (book_name_raw, null)
                            ?? book_name_raw;
            var book = CHMFile.by_path (book_name);
            if (book == null || !book.is_open ()) { finish_empty (request); return; }

            string? path = chm_path_from_uri (uri);
            if (path == null || path.length <= 1) {
                finish_empty (request);
                return;
            }

            var bytes = book.get_bytes (path);
            if (bytes == null) {
                finish_empty (request);
                return;
            }

            string mime = Vchm.Model.CHMFile.mime_for_path (path);

            if (mime == "text/html") {
                var text = transcode_html (bytes, book.encoding ());
                // Some compilers store non-Latin text as Latin-1 entities of
                // the archive-encoded bytes ("&eth;" = CP1251 'р'). Decode
                // those back to real characters before serving.
                text = Vchm.Model.EntityByteDecoder.fixup (text, book.encoding ());
                // The stream we serve is always UTF-8. If the document keeps
                // its original <meta charset=windows-1251>, WebKit would
                // re-decode our UTF-8 bytes as CP1251 → mojibake.
                text = Vchm.Model.HtmlTextUtils.normalize_charset_decls (text);
                // Book content is self-contained: allow only chm:/data:
                // subresources, block the network at the engine level.
                text = Vchm.Model.HtmlTextUtils.inject_local_only_csp (text);
                var utf8_bytes = new GLib.Bytes (text.data);
                var stream = new GLib.MemoryInputStream.from_bytes (utf8_bytes);
                // Explicit charset: without it WebKit assumes windows-1252
                // and mojibakes legitimate UTF-8 (e.g. C2 A0 → "Â").
                request.finish (stream, utf8_bytes.get_size (),
                                "text/html; charset=utf-8");
                return;
            }

            var stream = new GLib.MemoryInputStream.from_bytes (bytes);
            request.finish (stream, bytes.get_size (), mime);
        }

        private string transcode_html (GLib.Bytes bytes, string encoding) {
            unowned uint8[] data = bytes.get_data ();

            // NUL-terminated copy so the cast below is safe.
            var buf = new uint8[data.length + 1];
            Memory.copy (buf, data, data.length);
            buf[data.length] = 0;

            var raw = (string) buf;
            if (raw.validate ()) return raw;

            try {
                return GLib.convert (raw, -1, "UTF-8", encoding);
            } catch (GLib.ConvertError e) {
                return raw;
            }
        }


        private void finish_empty (WebKit.URISchemeRequest request) {
            var empty = new GLib.Bytes (new uint8[0]);
            var stream = new GLib.MemoryInputStream.from_bytes (empty);
            request.finish (stream, 0, "text/plain");
        }

    }
}