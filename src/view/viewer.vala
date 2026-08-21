// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using WebKit;
using Gtk;
using GLib;
using Vchm.Model;

namespace Vchm.View {

    public class ViewerView : WebView {
        private Elmish.Dispatch<AppMessage> dispatch;
        private WebViewContextMenu context_menu;
        private string? pending_html = null;

        public ViewerView () {
            Object (web_context: WebContext.get_default ());
            // Connect to realize signal to load pending HTML when widget is realized
            realize.connect (() => {
                if (pending_html != null) {
                    load_html (pending_html, "about:blank");
                    pending_html = null;
                }
            });
        }

        // Static reference to current model for URI scheme handler
        private static AppModel? s_current_model = null;

        public void build_ui (Elmish.Dispatch<AppMessage> dispatch, AppModel model) {
            this.dispatch = dispatch;
            s_current_model = model;

            // Configure WebView settings
            var settings = get_settings ();
            settings.enable_javascript = false; // CHM files typically don't need JS
            settings.enable_developer_extras = false;
            settings.enable_write_console_messages_to_stdout = false;
            settings.enable_page_cache = true;
            settings.default_font_size = model.viewer.font_size;
            settings.default_font_family = model.viewer.font_family;
            settings.monospace_font_family = model.viewer.fixed_font_family;
            settings.auto_load_images = model.viewer.show_images;

            // Register chm:// URI scheme handler for images, CSS, JS
            var context = WebContext.get_default ();
            context.register_uri_scheme ("chm", on_chm_uri_request);

            // Handle navigation requests
            decide_policy.connect (on_decide_policy);

            // Handle load changes
            load_changed.connect (on_load_changed);

            // Context menu
            context_menu = new WebViewContextMenu (this, dispatch);
            context_menu.build_ui ();
        }

        private bool on_decide_policy (WebView view, PolicyDecision decision, PolicyDecisionType decision_type) {
            if (decision_type != PolicyDecisionType.NAVIGATION_ACTION) {
                return false;
            }

            var nav_decision = (NavigationPolicyDecision) decision;
            var nav_action = nav_decision.get_navigation_action ();
            if (nav_action == null) {
                return false;
            }

            var request = nav_action.get_request ();
            if (request == null) {
                return false;
            }

            var uri = request.get_uri ();
            if (uri == null) {
                return false;
            }

            if (uri.has_prefix ("ms-its:")) {
                // Handle ms-its: links (cross-CHM links)
                nav_decision.use ();
                dispatch (new NavigateMessage (uri));
                return true;
            } else if (uri.has_prefix ("chm://")) {
                // Handle internal CHM links
                nav_decision.use ();
                // Extract path from chm:// URL
                var path = uri.substring ("chm://".length);
                // Find first / which separates filename from path
                int slash_pos = path.index_of ("/");
                if (slash_pos > 0) {
                    path = path.substring (slash_pos);
                    dispatch (new NavigateMessage (path));
                }
                return true;
            } else if (uri.has_prefix ("http://") || uri.has_prefix ("https://")) {
                // Allow external links to load normally
                return false;
            } else if (uri.has_prefix ("/") || uri.has_prefix ("#")) {
                // Relative link within CHM
                nav_decision.use ();
                dispatch (new NavigateMessage (uri));
                return true;
            } else if (uri == "about:blank" || uri.has_prefix ("data:")) {
                // Ignore about:blank and data: URI navigation
                return false;
            }

            return false;
        }

        private void on_load_changed (WebView view, LoadEvent load_event) {
            switch (load_event) {
                case LoadEvent.STARTED:
                    var uri_start = get_uri () ?? "";
                    if (uri_start != "" && uri_start != "about:blank" && !uri_start.has_prefix ("data:")) {
                        dispatch (new NavigateMessage (uri_start));
                    }
                    break;
                case LoadEvent.COMMITTED:
                    break;
                case LoadEvent.REDIRECTED:
                    break;
                case LoadEvent.FINISHED:
                    var title = get_title () ?? "";
                    var uri = get_uri () ?? "/";
                    
                    // Don't dispatch for data: URIs or about:blank - we handle navigation via decide_policy
                    if (!uri.has_prefix ("data:") && uri != "about:blank") {
                        dispatch (new NavigateDoneMessage (uri, title));
                    }
                    break;
            }
        }

        public void update (AppMessage msg, AppModel model) {
            // Load pending HTML if available (regardless of message type)
            if (model.viewer.pending_html != null) {
                // Rewrite relative links in HTML to use chm:// scheme
                var html = rewrite_links (model.viewer.pending_html, model.chm_file.filename ());
                // Store HTML and let realize signal load it
                pending_html = html;
                // If already realized, load immediately
                if (get_realized ()) {
                    load_html (pending_html, "about:blank");
                    pending_html = null;
                }
            }
            
            switch (msg.kind) {
                case AppMessageKind.NAVIGATE_DONE: {
                    // NAVIGATE_DONE specific handling if needed
                    break;
                }

                case AppMessageKind.VIEWER_FONT_INCREASE:
                case AppMessageKind.VIEWER_FONT_DECREASE:
                case AppMessageKind.VIEWER_FONT_RESET: {
                    var settings = get_settings ();
                    settings.default_font_size = model.viewer.font_size;
                    break;
                }

                case AppMessageKind.VIEWER_FONT_CHANGED: {
                    var settings = get_settings ();
                    settings.default_font_size = model.viewer.font_size;
                    settings.default_font_family = model.viewer.font_family;
                    settings.monospace_font_family = model.viewer.fixed_font_family;
                    break;
                }

                case AppMessageKind.VIEWER_TOGGLE_IMAGES: {
                    var settings = get_settings ();
                    settings.auto_load_images = model.viewer.show_images;
                    reload ();
                    break;
                }

                case AppMessageKind.VIEWER_FIND: {
                    // TODO: Implement find in page for WebKitGTK 6.0
                    break;
                }

                case AppMessageKind.VIEWER_FIND_NEXT: {
                    break;
                }

                case AppMessageKind.VIEWER_FIND_PREV: {
                    break;
                }

                default:
                    break;
            }
        }

        // Rewrite relative links in HTML to use chm:// scheme for proper resource loading
        private string rewrite_links (string html, string chm_filename) {
            var basename = GLib.Path.get_basename (chm_filename);
            var chm_prefix = "chm://%s/".printf (basename);
            
            // Use a simple manual replacement to avoid regex issues
            var result = new StringBuilder ();
            int i = 0;
            while (i < html.length) {
                // Check for href="/...
                if (i + 6 <= html.length && html.substring (i, 6) == "href=\"/") {
                    result.append ("href=\\\"");
                    result.append (chm_prefix);
                    i += 6;
                }
                // Check for href='#...
                else if (i + 6 <= html.length && html.substring (i, 6) == "href='#") {
                    result.append ("href='");
                    result.append (chm_prefix);
                    i += 6;
                }
                // Check for href="#...
                else if (i + 6 <= html.length && html.substring (i, 6) == "href=\\\"#") {
                    result.append ("href=\\\"");
                    result.append (chm_prefix);
                    i += 6;
                }
                // Check for href='#...
                else if (i + 6 <= html.length && html.substring (i, 6) == "href='#") {
                    result.append ("href='");
                    result.append (chm_prefix);
                    i += 6;
                }
                // Fix src attributes (images, scripts, css)
                else if (i + 5 <= html.length && html.substring (i, 5) == "src=\"/") {
                    result.append ("src=\\\"");
                    result.append (chm_prefix);
                    i += 5;
                }
                else if (i + 5 <= html.length && html.substring (i, 5) == "src='/") {
                    result.append ("src='");
                    result.append (chm_prefix);
                    i += 5;
                }
                else {
                    result.append_c (html[i]);
                    i++;
                }
            }
            return result.str;
        }

        // Handle chm:// URI scheme requests
        private void on_chm_uri_request (WebKit.URISchemeRequest request) {
            if (s_current_model == null) {
                var error_stream = new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (new uint8[0]));
                request.finish (error_stream, 0, "text/plain");
                return;
            }

            string uri = request.get_uri ();
            stderr.printf ("DEBUG VIEWER: chm:// request: %s\n", uri);
            
            if (!uri.has_prefix ("chm://")) {
                var error_stream = new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (new uint8[0]));
                request.finish (error_stream, 0, "text/plain");
                return;
            }

            // Parse chm://filename/path
            string path = uri.substring ("chm://".length);
            int slash_pos = path.index_of ("/");
            string chm_filename;
            string resource_path;
            
            if (slash_pos > 0) {
                chm_filename = path.substring (0, slash_pos);
                resource_path = path.substring (slash_pos);
            } else {
                var error_stream = new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (new uint8[0]));
                request.finish (error_stream, 0, "text/plain");
                return;
            }

            // Verify filename matches
            string expected_basename = GLib.Path.get_basename (s_current_model.chm_file.filename ());
            if (chm_filename != expected_basename) {
                stderr.printf ("DEBUG VIEWER: CHM filename mismatch: expected %s, got %s\n", expected_basename, chm_filename);
                var error_stream = new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (new uint8[0]));
                request.finish (error_stream, 0, "text/plain");
                return;
            }

            // Resolve and read the resource from CHM using new API
            var bytes = s_current_model.chm_file.get_bytes (resource_path);
            if (bytes != null) {
                string mime = get_mime_type (resource_path);
                var stream = new GLib.MemoryInputStream.from_bytes (bytes);
                request.finish (stream, bytes.get_size (), mime);
                return;
            }

            var error_stream = new GLib.MemoryInputStream.from_bytes (new GLib.Bytes (new uint8[0]));
            request.finish (error_stream, 0, "text/plain");
        }

        // Get MIME type from file extension
        private string get_mime_type (string path) {
            if (path.has_suffix (".html") || path.has_suffix (".htm"))
                return "text/html";
            else if (path.has_suffix (".css"))
                return "text/css";
            else if (path.has_suffix (".js"))
                return "application/javascript";
            else if (path.has_suffix (".png"))
                return "image/png";
            else if (path.has_suffix (".jpg") || path.has_suffix (".jpeg"))
                return "image/jpeg";
            else if (path.has_suffix (".gif"))
                return "image/gif";
            else if (path.has_suffix (".svg"))
                return "image/svg+xml";
            else if (path.has_suffix (".ico"))
                return "image/x-icon";
            else if (path.has_suffix (".pdf"))
                return "application/pdf";
            else if (path.has_suffix (".txt"))
                return "text/plain";
            else if (path.has_suffix (".xml"))
                return "application/xml";
            else
                return "application/octet-stream";
        }
    }
}