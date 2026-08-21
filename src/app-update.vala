// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;

// Helper to find first topic URL in the tree
string? find_first_topic_url (TopicsItem item) {
    if (item.url != null && item.url != "/" && item.url != "") {
        return item.url;
    }
    foreach (var child in item.children) {
        var url = find_first_topic_url (child);
        if (url != null) return url;
    }
    return null;
}

public Elmish.Cmd<AppMessage>? updateModel (AppMessage msg, AppModel model) {
    Elmish.Cmd<AppMessage>? cmd = null;

    switch (msg.kind) {
        // ── File operations ─────────────────────────────────────────────────
        case AppMessageKind.OPEN_FILE: {
            var open_msg = (OpenFileMessage) msg;
            var path = open_msg.path;

            // Load CHM file asynchronously
            cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                var chm = new CHMFile ();
                if (chm.load (path)) {
                    var title = chm.title ();
                    if (title == "") title = GLib.Path.get_basename (path);
                    var home = chm.home_page ();
                    dispatch (new OpenFileDoneMessage (path, title, home));
                } else {
                    dispatch (new OpenFileFailedMessage (path, "Failed to open CHM file"));
                }
            });
            break;
        }

        case AppMessageKind.OPEN_FILE_DONE: {
            var done_msg = (OpenFileDoneMessage) msg;
            model.file_open = true;
            // Use the existing chm_file instance to load the file
            if (model.chm_file.load (done_msg.path)) {
                Object dummy; model.chm_file.load_topics_tree (out dummy);
                // Build topics tree
                model.topics.build_from_chm (model.chm_file);
                
                // Build index
                model.index.build_from_chm (model.chm_file);
                
                // Load context IDs
                model.chm_file.load_context_ids ();
                
                // Navigate to home page (model state)
                model.viewer.navigate (done_msg.home_page, done_msg.title, done_msg.path);
                
                // Dispatch NAVIGATE to actually load the content
                model.get_parent_dispatch () (new NavigateMessage (done_msg.home_page, done_msg.title));
                
                // Add to history
                model.history.add_entry (done_msg.title, done_msg.home_page, done_msg.path);
                
                // Add to recent files
                model.settings.add_recent_file (done_msg.path);
                
                // Update last opened directory
                model.settings.last_opened_dir = GLib.Path.get_dirname (done_msg.path);
                
                model.status_text = "Opened: %s".printf (GLib.Path.get_basename (done_msg.path));
            }
            break;
        }

        case AppMessageKind.OPEN_FILE_FAILED: {
            var fail_msg = (OpenFileFailedMessage) msg;
            model.show_toast ("Failed to open '%s': %s".printf (GLib.Path.get_basename (fail_msg.path), fail_msg.error));
            break;
        }

        case AppMessageKind.CLOSE_FILE: {
            model.chm_file.close ();
            model.topics.clear ();
            model.index.clear ();
            model.search.clear ();
            model.viewer.current_url = "/";
            model.viewer.current_title = "";
            model.viewer.current_chm_file = "";
            model.file_open = false;
            model.status_text = "Ready";
            break;
        }

        case AppMessageKind.RECENT_FILE_ACTIVATED: {
            var recent_msg = (RecentFileActivatedMessage) msg;
            model.get_parent_dispatch () (new OpenFileMessage (recent_msg.path));
            break;
        }

        // ── Navigation ──────────────────────────────────────────────────────
        case AppMessageKind.NAVIGATE: {
            var nav_msg = (NavigateMessage) msg;
            stderr.printf ("DEBUG: NAVIGATE handler called for '%s', file_open=%b\n", nav_msg.url, model.file_open);
            
            if (!model.file_open) break;
            
            // Skip CHM resolution for data: URIs and about:blank
            if (nav_msg.url.has_prefix ("data:") || nav_msg.url == "about:blank") {
                stderr.printf ("DEBUG: Skipping CHM resolution for %s\n", nav_msg.url);
                break;
            }
            
            model.viewer.navigate (nav_msg.url, nav_msg.title ?? "", model.chm_file.filename ());
            
            // Load content asynchronously using new CHMContent API
            cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                stderr.printf ("DEBUG: Resolving object: '%s'\n", nav_msg.url);
                
                var content = model.chm_file.get_content (nav_msg.url);
                
                // If home page "/" resolves to empty, try to find first topic
                if (!content.success && nav_msg.url == "/") {
                    stderr.printf ("DEBUG: Home page '/' not found, trying first topic\n");
                    
                    // Get first topic URL from CHM file
                    var first_url = model.chm_file.get_first_topic_url ();
                    stderr.printf ("DEBUG: First topic URL from CHM: '%s'\n", first_url);
                    
                    if (first_url != null && first_url != "/") {
                        content = model.chm_file.get_content (first_url);
                        if (content.success) {
                            nav_msg = new NavigateMessage (first_url, nav_msg.title ?? "");
                            stderr.printf ("DEBUG: Using first topic URL: %s\n", first_url);
                        }
                    }
                }
                
                if (content.success) {
                    // Store content in viewer model for the view to load
                    model.viewer.pending_html = content.content;
                    dispatch (new NavigateDoneMessage (nav_msg.url, nav_msg.title ?? ""));
                } else {
                    dispatch (new NavigateFailedMessage (nav_msg.url, content.error ?? "Page not found"));
                }
            });
            break;
        }

        case AppMessageKind.NAVIGATE_DONE: {
            var done_msg = (NavigateDoneMessage) msg;
            model.viewer.load_finished (true);
            model.viewer.current_url = done_msg.url;
            model.viewer.current_title = done_msg.title;
            // Use intended_url for history (the CHM path), not the data: URI
            var history_url = model.viewer.intended_url ?? done_msg.url;
            model.history.add_entry (done_msg.title, history_url, model.chm_file.filename () ?? "");
            model.topics.selected_url = history_url;
            model.topics.expand_path (history_url);
            model.status_text = done_msg.title;
            break;
        }

        case AppMessageKind.NAVIGATE_FAILED: {
            var fail_msg = (NavigateFailedMessage) msg;
            model.viewer.load_finished (false, fail_msg.error);
            model.show_toast ("Navigation failed: %s".printf (fail_msg.error));
            break;
        }

        case AppMessageKind.GO_BACK: {
            
            var entry = model.history.go_back ();
            if (entry != null) {
                
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title));
            }
            break;
        }

        case AppMessageKind.GO_FORWARD: {
            
            var entry = model.history.go_forward ();
            if (entry != null) {
                
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title));
            }
            break;
        }

        case AppMessageKind.GO_HOME: {
            
            if (model.file_open) {
                var home = model.chm_file.home_page ();
                
                model.get_parent_dispatch () (new NavigateMessage (home, model.chm_file.title ()));
            }
            break;
        }

        case AppMessageKind.CONTEXT_ID_NAVIGATE: {
            var cid_msg = (ContextIdNavigateMessage) msg;
            if (model.file_open && model.chm_file.is_valid_cid (cid_msg.context_id)) {
                var url = model.chm_file.get_page_by_cid (cid_msg.context_id);
                model.get_parent_dispatch () (new NavigateMessage (url));
            }
            break;
        }

        // ── Side panels ─────────────────────────────────────────────────────
        case AppMessageKind.TOGGLE_TOPICS_PANEL: {
            model.settings.show_topics = !model.settings.show_topics;
            break;
        }

        case AppMessageKind.TOGGLE_INDEX_PANEL: {
            model.settings.show_index = !model.settings.show_index;
            break;
        }

        case AppMessageKind.TOGGLE_SEARCH_PANEL: {
            model.settings.show_search = !model.settings.show_search;
            if (model.settings.show_search) {
                model.settings.active_side_panel = 2;
            }
            break;
        }

        case AppMessageKind.SET_ACTIVE_SIDE_PANEL: {
            var panel_msg = (SetActiveSidePanelMessage) msg;
            model.settings.active_side_panel = panel_msg.panel;
            break;
        }

        case AppMessageKind.SET_SASH_POSITION: {
            var sash_msg = (SetSashPositionMessage) msg;
            model.settings.sash_position = sash_msg.position;
            break;
        }

        case AppMessageKind.TOPICS_SELECTION_CHANGED: {
            var topics_msg = (TopicsSelectionChangedMessage) msg;
            model.topics.selected_url = topics_msg.url;
            if (topics_msg.url != null) {
                model.get_parent_dispatch () (new NavigateMessage (topics_msg.url));
            }
            break;
        }

        case AppMessageKind.TOPICS_ITEM_EXPANDED: {
            var exp_msg = (TopicsItemExpandedMessage) msg;
            if (model.topics.root != null) {
                var item = model.topics.find_item_by_url (exp_msg.url);
                if (item != null) {
                    item.expanded = true;
                }
            }
            break;
        }

        case AppMessageKind.TOPICS_ITEM_COLLAPSED: {
            var col_msg = (TopicsItemCollapsedMessage) msg;
            if (model.topics.root != null) {
                var item = model.topics.find_item_by_url (col_msg.url);
                if (item != null) {
                    item.expanded = false;
                }
            }
            break;
        }

        case AppMessageKind.INDEX_FILTER_CHANGED: {
            var filter_msg = (IndexFilterChangedMessage) msg;
            model.index.filter_text = filter_msg.filter;
            break;
        }

        case AppMessageKind.INDEX_SELECTION_CHANGED: {
            var index_msg = (IndexSelectionChangedMessage) msg;
            // Find the index of the selected URL in filtered entries
            var filtered = model.index.filtered_entries ();
            for (int i = 0; i < filtered.size; i++) {
                if (filtered[i].url == index_msg.url) {
                    model.index.selected_index = i;
                    break;
                }
            }
            if (index_msg.url != null) {
                model.get_parent_dispatch () (new NavigateMessage (index_msg.url));
            }
            break;
        }

        case AppMessageKind.INDEX_NEXT: {
            if (model.index.entries.size > 0) {
                var filtered = model.index.filtered_entries ();
                if (filtered.size > 0) {
                    model.index.selected_index = (model.index.selected_index + 1) % filtered.size;
                    var next_url = filtered[model.index.selected_index].url;
                    model.get_parent_dispatch () (new NavigateMessage (next_url));
                }
            }
            break;
        }

        case AppMessageKind.INDEX_PREV: {
            if (model.index.entries.size > 0) {
                var filtered = model.index.filtered_entries ();
                if (filtered.size > 0) {
                    model.index.selected_index = (model.index.selected_index - 1 + filtered.size) % filtered.size;
                    var prev_url = filtered[model.index.selected_index].url;
                    model.get_parent_dispatch () (new NavigateMessage (prev_url));
                }
            }
            break;
        }

        // ── Search ───────────────────────────────────────────────────────────
        case AppMessageKind.SEARCH_QUERY_CHANGED: {
            var search_msg = (SearchQueryChangedMessage) msg;
            model.search.query = search_msg.query;
            break;
        }

        case AppMessageKind.SEARCH_EXECUTE: {
            if (model.file_open && model.search.query != "") {
                model.search.searching = true;
                cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                    Gee.HashMap<string, string> results;
                    if (model.chm_file.search (model.search.query, model.search.whole_words, model.search.titles_only, out results)) {
                        var list = new Gee.ArrayList<SearchResult> ();
                        foreach (var entry in results) {
                            list.add (new SearchResult (entry.key, entry.value, 1));
                        }
                        dispatch (new SearchDoneMessage (list));
                    } else {
                        dispatch (new SearchDoneMessage (new Gee.ArrayList<SearchResult> ()));
                    }
                });
            }
            break;
        }

        case AppMessageKind.SEARCH_DONE: {
            var done_msg = (SearchDoneMessage) msg;
            model.search.searching = false;
            model.search.results = done_msg.results;
            model.search.selected_index = -1;
            break;
        }

        case AppMessageKind.SEARCH_SELECTION_CHANGED: {
            var search_msg = (SearchSelectionChangedMessage) msg;
            if (model.search.results.size > 0) {
                // Find index of the URL in results
                for (int i = 0; i < model.search.results.size; i++) {
                    if (model.search.results[i].url == search_msg.url) {
                        model.search.selected_index = i;
                        break;
                    }
                }
            }
            if (search_msg.url != null) {
                model.get_parent_dispatch () (new NavigateMessage (search_msg.url));
            }
            break;
        }

        case AppMessageKind.SEARCH_NEXT: {
            if (model.search.results.size > 0) {
                int next = (model.search.selected_index + 1) % model.search.results.size;
                var result = model.search.results[next];
                if (result != null && result.url != null) {
                    model.search.selected_index = next;
                    model.get_parent_dispatch () (new NavigateMessage (result.url));
                }
            }
            break;
        }

        case AppMessageKind.SEARCH_PREV: {
            if (model.search.results.size > 0) {
                int prev = (model.search.selected_index - 1 + model.search.results.size) % model.search.results.size;
                var result = model.search.results[prev];
                if (result != null && result.url != null) {
                    model.search.selected_index = prev;
                    model.get_parent_dispatch () (new NavigateMessage (result.url));
                }
            }
            break;
        }

        case AppMessageKind.SEARCH_OPTIONS_CHANGED: {
            var opts_msg = (SearchOptionsChangedMessage) msg;
            model.search.whole_words = opts_msg.whole_words;
            model.search.titles_only = opts_msg.titles_only;
            break;
        }

        // ── Viewer ───────────────────────────────────────────────────────────
        case AppMessageKind.VIEWER_FONT_INCREASE: {
            model.viewer.increase_font_size ();
            break;
        }

        case AppMessageKind.VIEWER_FONT_DECREASE: {
            model.viewer.decrease_font_size ();
            break;
        }

        case AppMessageKind.VIEWER_FONT_RESET: {
            model.viewer.reset_font_size ();
            break;
        }

        case AppMessageKind.VIEWER_FONT_CHANGED: {
            var font_msg = (ViewerFontChangedMessage) msg;
            model.viewer.font_size = font_msg.size;
            model.viewer.font_family = font_msg.family;
            model.viewer.fixed_font_family = font_msg.fixed_family;
            break;
        }

        case AppMessageKind.VIEWER_TOGGLE_IMAGES: {
            model.viewer.show_images = !model.viewer.show_images;
            break;
        }

        case AppMessageKind.VIEWER_FIND: {
            var find_msg = (ViewerFindMessage) msg;
            model.viewer.find_text = find_msg.text;
            // TODO: Implement find in WebKitGTK 6.0
            break;
        }

        case AppMessageKind.VIEWER_FIND_NEXT: {
            // TODO: Implement
            break;
        }

        case AppMessageKind.VIEWER_FIND_PREV: {
            // TODO: Implement
            break;
        }

        // ── History ──────────────────────────────────────────────────────────
        case AppMessageKind.HISTORY_CLEAR: {
            model.history.clear ();
            break;
        }

        // ── Window state ─────────────────────────────────────────────────────
        case AppMessageKind.WINDOW_STATE_CHANGED: {
            var ws_msg = (WindowStateChangedMessage) msg;
            model.settings.window_width = ws_msg.width;
            model.settings.window_height = ws_msg.height;
            model.settings.window_x = ws_msg.x;
            model.settings.window_y = ws_msg.y;
            break;
        }

        case AppMessageKind.WINDOW_MAXIMIZED_CHANGED: {
            var max_msg = (WindowMaximizedChangedMessage) msg;
            model.settings.window_maximized = max_msg.maximized;
            break;
        }

        // ── Application ──────────────────────────────────────────────────────
        case AppMessageKind.APP_QUIT: {
            // Get window state for quit message
            model.get_parent_dispatch () (new QuitMessage (model.settings.window_width, model.settings.window_height, model.settings.window_maximized));
            break;
        }

        case AppMessageKind.ABOUT_DIALOG: {
            // Show about dialog via view
            break;
        }

        case AppMessageKind.PREFERENCES_DIALOG: {
            // Show preferences dialog via view
            break;
        }

        case AppMessageKind.SHOW_TOAST: {
            var toast_msg = (ShowToastMessage) msg;
            // View handles toast display
            break;
        }
    }

    return cmd;
}