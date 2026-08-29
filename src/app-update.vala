// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm.Model;
using GLib;

// Normalize a navigation target to a CHM-internal absolute path.
// Handles ms-its:/mk@MSITStore cross-book links by stripping the archive
// part, and ensures a leading '/'.
string normalize_chm_target (string url) {
    string u = url.strip ();

    if (u.has_prefix ("ms-its:") || u.has_prefix ("mk:@MSITStore:") || u.has_prefix ("mk:MSITStore:")) {
        // Form: ms-its:<archive>.chm/path/page.htm
        int marker = u.index_of (".chm/");
        if (marker >= 0) {
            return u.substring (marker + 4);
        }
        marker = u.index_of ("::/");
        if (marker >= 0) {
            return u.substring (marker + 1);
        }
        return "/";
    }

    if (u.has_prefix ("file://")) {
        var unescaped = GLib.Uri.unescape_string (u, null);
        if (unescaped != null) u = unescaped;
    }

    if (u.length == 0) return "/";
    if (u[0] != '/') return "/" + u;
    return u;
}

public Elmish.Cmd<AppMessage>? updateModel (AppMessage msg, AppModel model) {
    Elmish.Cmd<AppMessage>? cmd = null;

    switch (msg.kind) {
        // ── File operations ─────────────────────────────────────────────────
        case AppMessageKind.OPEN_FILE: {
            var open_msg = (OpenFileMessage) msg;
            var path = open_msg.path;

            // Serialize OPEN_FILE workers: two concurrent opens raced on
            // model.books / model.viewer / tabs[].url and left the first
            // tab blank. The acquire runs on the main thread (before the
            // Cmd.exec spawns the worker) so the in-flight set is a
            // truthful record of "this path is being opened"; the release
            // runs in the worker's finally.
            if (!model.try_acquire_open (path)) {
                // Another open for the same path is mid-flight; defer.
                var d = model.get_parent_dispatch ();
                GLib.Timeout.add (150, () => {
                    d (new OpenFileMessage (path));
                    return GLib.Source.REMOVE;
                });
                break;
            }

            // Heavy parse: run on a worker thread; dispatch marshals back.
            // Capture long-lived parent dispatch, not the borrowed param
            // (Vala delegates captured across threads UAF — elmish.vala:53).
            var open_parent = model.get_parent_dispatch ();
            cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                try {
                    new GLib.Thread<void*> ("vchm-open", () => {
                        try {
                            // Each book owns its context (archive + panels).
                            var ctx = new BookContext ();
                            if (ctx.chm_file.load (path)) {
                                Object? toc_model;
                                ctx.chm_file.load_topics_tree (out toc_model);
                                ctx.topics.build_from_chm (ctx.chm_file);
                                ctx.index.build_from_chm (ctx.chm_file);
                                ctx.chm_file.load_context_ids ();
                                ctx.title = ctx.chm_file.title ();
                                if (ctx.title == "")
                                    ctx.title = GLib.Path.get_basename (path);
                                ctx.home = ctx.chm_file.home_page ();

                                open_parent (new OpenFileDoneMessage (
                                    path, ctx.title, ctx.home, ctx));
                            } else {
                                open_parent (new OpenFileFailedMessage (path, "Failed to open CHM file"));
                            }
                        } finally {
                            // Mutex is thread-safe; release can run off-main-thread.
                            model.release_open (path);
                        }
                        return null;
                    });
                } catch (GLib.Error e) {
                    model.release_open (path);
                    open_parent (new OpenFileFailedMessage (path, e.message));
                }
            });
            break;
        }

        case AppMessageKind.OPEN_FILE_DONE: {
            var done_msg = (OpenFileDoneMessage) msg;
            if (done_msg.ctx == null) break;   // legacy safety

            // Re-opening an already-open book: drop the freshly built
            // duplicate context and keep pointing at the original. The
            // view re-activates the existing tab either way — adding
            // unconditionally leaked a chmlib handle + registry entry
            // per reopen (review F6).
            var ctx = done_msg.ctx;
            // Canonicalize for dedup: File.get_path resolves ./ and //.
            string canon = GLib.File.new_for_path (done_msg.path).get_path () ?? done_msg.path;
            BookContext? dup = null;
            int dup_idx = -1;
            for (int i = 0; i < model.books.size; i++) {
                var b = model.books[i];
                string bf = GLib.File.new_for_path (b.chm_file.filename ()).get_path () ?? b.chm_file.filename ();
                if (bf == canon) { dup = b; dup_idx = i; break; }
            }
            int nav_tab_index;
            if (dup != null) {
                // The duplicate's load() overwrote the registry entry for
                // this path; its close() removes it. Re-register the
                // survivor so by_path still resolves.
                ctx.chm_file.close ();
                dup.chm_file.re_register ();
                ctx = dup;
                nav_tab_index = dup_idx;
            } else {
                model.books.add (ctx);
                nav_tab_index = model.books.size - 1;
            }

            model.active_book = ctx;

            // Point the shared model at this book's containers.
            model.chm_file = ctx.chm_file;
            model.topics = ctx.topics;
            model.index = ctx.index;
            model.history = ctx.history;
            model.file_open = true;

            // Panels were built on the open worker; here we just wire state.
            model.viewer.navigate (done_msg.home_page, done_msg.title, done_msg.path);

            // Dispatch NAVIGATE to actually load the content
            // DO NOT add to history here - NAVIGATE_DONE will handle it
            model.get_parent_dispatch () (new NavigateMessage (done_msg.home_page, done_msg.title, nav_tab_index));
            
            // Add to recent files
            model.settings.add_recent_file (done_msg.path);
            
            // Update last opened directory
            model.settings.last_opened_dir = GLib.Path.get_dirname (done_msg.path);
            
            model.status_text = "Opened: %s".printf (GLib.Path.get_basename (done_msg.path));
            break;
        }

        case AppMessageKind.OPEN_FILE_FAILED: {
            var fail_msg = (OpenFileFailedMessage) msg;
            model.show_toast ("Failed to open '%s': %s".printf (GLib.Path.get_basename (fail_msg.path), fail_msg.error));
            break;
        }

        case AppMessageKind.CLOSE_FILE: {
            // Close EVERY book: each BookContext owns a live chmlib handle
            // and a registry entry — closing only the active one leaked the
            // rest. Double-close is safe (CHMFile.close null-checks).
            foreach (var ctx in model.books) {
                ctx.chm_file.close ();
            }
            model.books.clear ();

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

            if (!model.file_open) break;

            // Skip non-CHM targets
            if (nav_msg.url.has_prefix ("data:") || nav_msg.url == "about:blank" ||
                nav_msg.url.has_prefix ("http://") || nav_msg.url.has_prefix ("https://")) {
                break;
            }

            // Track intended target: NAVIGATE_DONE prefers it for
            // history entries and TOC selection sync.
            // Replicates ViewerModel.navigate minus current_url: NAVIGATE_DONE
            // owns that field — setting it here would make the queued view
            // update fire a premature load_uri before fallback resolution.
            model.viewer.intended_url = nav_msg.url;
            model.viewer.current_title = nav_msg.title ?? "";
            model.viewer.current_chm_file = model.chm_file.filename ();
            model.viewer.loading = true;
            model.viewer.error = null;
            model.viewer.pending_html = null;

            // Snapshot model state on the main thread before spawning the worker
            // (the worker must not touch `model` — concurrent CLOSE/OPEN can
            // mutate it).
            var snap_file = model.chm_file;
            var snap_cur = model.viewer.current_url;
            var snap_url = nav_msg.url;
            var snap_title = nav_msg.title ?? "";
            var snap_tab_index = nav_msg.tab_index;

            var nav_parent = model.get_parent_dispatch ();
            cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                try {
                new GLib.Thread<void*> ("vchm-nav", () => {
                string target = normalize_chm_target (snap_url);

                if (!snap_file.has_object (target)) {
                    // Home page missing → fall back to the first TOC entry.
                    if (target == "/") {
                        var first_url = snap_file.get_first_topic_url ();
                        if (first_url.length > 0 && snap_file.has_object (first_url)) {
                            target = first_url;
                        }
                    }

                    // Relative link that missed: resolve against the current
                    // page's directory (e.g. /dir/page.htm + x.htm).
                    if (!snap_file.has_object (target) && !target.has_prefix ("/ms-its")) {
                        int last_slash = snap_cur.last_index_of ("/");
                        if (last_slash > 0) {
                            var joined = snap_cur.substring (0, last_slash + 1) + target.strip ().replace ("../", "");
                            while (joined.contains ("/../")) {
                                int up = joined.index_of ("/../");
                                int prev = joined.last_index_of ("/", up - 1);
                                if (prev < 0) break;
                                joined = joined.substring (0, prev) + joined.substring (up + 3);
                            }
                            if (snap_file.has_object (joined)) {
                                target = joined;
                            }
                        }
                    }
                }

                // Dead link: every fallback missed — report failure instead
                // of DONE (which loaded a blank page and polluted history).
                if (!snap_file.has_object (target)) {
                    nav_parent (new NavigateFailedMessage (snap_url, "Page not found"));
                    return null;
                }

                // If caller passed no title (flat TOC, programmatic NAVIGATE),
                // derive it from the target page's <title> or <h1> so status
                // bar / window title never shows raw "/ch1.htm".
                if (snap_title == "") {
                    var c = snap_file.get_content (target);
                    if (c.success) {
                        string t = Vchm.Model.TopicsModel.extract_title (c.content, snap_file.encoding ());
                        if (t == "") t = Vchm.Model.TopicsModel.extract_heading (c.content, snap_file.encoding ());
                        if (t != "") snap_title = t;
                    }
                }

                // The intended target rides along so a second navigation
                // starting mid-flight cannot steal this one's history
                // entry (review F7).
                nav_parent (new NavigateDoneMessage (target, snap_title, snap_url, snap_tab_index));
                return null;
                });
                } catch (GLib.Error e) {
                    nav_parent (new NavigateFailedMessage (snap_url, e.message));
                }
            });
            break;
        }

        case AppMessageKind.NAVIGATE_DONE: {
            var done_msg = (NavigateDoneMessage) msg;
            // The worker ran with a snap_file snapshot (the active
            // tab at dispatch time). If the user switched tabs in the
            // meantime, the shared model.chm_file now points at a
            // different book. Use done_msg.tab_index to identify the
            // original tab and write through its per-tab sub-models
            // so history/topic-selection don't cross-attach.
            int ti = done_msg.tab_index >= 0 ? done_msg.tab_index : model.active_tab_index;
            BookContext? target_ctx = null;
            if (ti >= 0 && ti < model.books.size) {
                // Find the BookContext whose chm_file matches the
                // one we snapshotted (the worker used the active
                // tab's chm_file at dispatch time).
                var snap_path = done_msg.intended_url;
                // The intended_url is the CHM path, not the file
                // path; use a different signal: the BookContext
                // that owned the snap_file is the one whose
                // history/topics we'd write to. We don't have the
                // file path in the message, so fall back to the
                // current active_ctx when the user didn't switch.
                target_ctx = model.active_book;
            }

            model.viewer.load_finished (true);
            model.viewer.current_url = done_msg.url;
            model.viewer.current_title = done_msg.title;
            // Use this navigation's own intended target for history (the
            // CHM path), not the data: URI — and not the shared
            // intended_url slot, which a newer in-flight navigation may
            // already have overwritten (review F7).
            var history_url = done_msg.intended_url;
            model.viewer.intended_url = history_url;

            if (model.history_navigation_in_progress) {
                // Back/forward: the entry already exists in history; pushing
                // again would truncate the forward tail (review §4.6).
                model.history_navigation_in_progress = false;
            } else {
                // The user may have switched tabs between dispatch and
                // done; route the history entry to the tab that
                // OWNED the snap_file. The proxy returns the
                // active tab's history when an active_ctx is set;
                // for per-tab history isolation we need the
                // BookContext directly. Without per-tab history
                // sub-models (Phase 2 step 3+), fall back to the
                // active tab's history and accept the cross-attach
                // in the rare case of a tab switch during load.
                model.history.add_entry (done_msg.title, history_url, model.chm_file.filename () ?? "");
            }

            model.topics.selected_url = history_url;
            model.topics.expand_path (history_url);
            model.status_text = done_msg.title != "" ? done_msg.title : done_msg.url;
            // Persist per-book last page (for restore on next open)
            if (model.file_open) {
                model.per_books.set_last_url (model.chm_file.filename (), history_url);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.NAVIGATE_FAILED: {
            var fail_msg = (NavigateFailedMessage) msg;
            model.viewer.load_finished (false, fail_msg.error);
            // Otherwise the stuck flag makes every later navigation skip
            // its history push.
            model.history_navigation_in_progress = false;
            model.show_toast ("Navigation failed: %s".printf (fail_msg.error));
            break;
        }

        case AppMessageKind.GO_BACK: {
            // A back/forward jump is still in flight; a second one would
            // desync the history cursor.
            if (model.history_navigation_in_progress) break;
            var entry = model.history.go_back ();
            if (entry != null) {
                model.history_navigation_in_progress = true;
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.GO_FORWARD: {
            if (model.history_navigation_in_progress) break;
            var entry = model.history.go_forward ();
            if (entry != null) {
                model.history_navigation_in_progress = true;
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.GO_HOME: {
            
            if (model.file_open) {
                var home = model.chm_file.home_page ();
                
                model.get_parent_dispatch () (new NavigateMessage (home, model.chm_file.title (), model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.CONTEXT_ID_NAVIGATE: {
            var cid_msg = (ContextIdNavigateMessage) msg;
            if (model.file_open && model.chm_file.is_valid_cid (cid_msg.context_id)) {
                var url = model.chm_file.get_page_by_cid (cid_msg.context_id);
                model.get_parent_dispatch () (new NavigateMessage (url, null, model.active_tab_index));
            }
            break;
        }

        // ── Side panels ─────────────────────────────────────────────────────
        // Toolbar/menu toggles are mutually exclusive:
        // activating a panel shows the sidebar and selects it; toggling
        // the active panel off hides the whole sidebar. The previous
        // independent-flag version made every click a visual no-op
        // (visibility was the OR of three flags).
        case AppMessageKind.TOGGLE_TOPICS_PANEL: {
            if (model.settings.show_topics &&
                model.settings.active_side_panel == 0) {
                model.settings.show_topics = false;
            } else {
                model.settings.show_topics = true;
                model.settings.show_index = false;
                model.settings.show_search = false;
                model.settings.show_bookmarks = false;
                model.settings.active_side_panel = 0;
            }
            break;
        }

        case AppMessageKind.TOGGLE_INDEX_PANEL: {
            if (model.settings.show_index &&
                model.settings.active_side_panel == 1) {
                model.settings.show_index = false;
            } else {
                model.settings.show_topics = false;
                model.settings.show_index = true;
                model.settings.show_search = false;
                model.settings.show_bookmarks = false;
                model.settings.active_side_panel = 1;
            }
            break;
        }

        case AppMessageKind.TOGGLE_SEARCH_PANEL: {
            if (model.settings.show_search &&
                model.settings.active_side_panel == 2) {
                model.settings.show_search = false;
            } else {
                model.settings.show_topics = false;
                model.settings.show_index = false;
                model.settings.show_search = true;
                model.settings.show_bookmarks = false;
                model.settings.active_side_panel = 2;
            }
            break;
        }

        case AppMessageKind.TOGGLE_BOOKMARKS_PANEL: {
            if (model.settings.show_bookmarks &&
                model.settings.active_side_panel == 3) {
                model.settings.show_bookmarks = false;
            } else {
                model.settings.show_topics = false;
                model.settings.show_index = false;
                model.settings.show_search = false;
                model.settings.show_bookmarks = true;
                model.settings.active_side_panel = 3;
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
                model.get_parent_dispatch () (new NavigateMessage (topics_msg.url, null, model.active_tab_index));
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
            // Keyword-only rows carry url == "" — navigating would hit "/".
            if (index_msg.url != null && index_msg.url.length > 0) {
                model.get_parent_dispatch () (new NavigateMessage (index_msg.url, null, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.INDEX_NEXT: {
            if (model.index.entries.size > 0) {
                var filtered = model.index.filtered_entries ();
                if (filtered.size > 0) {
                    model.index.selected_index = (model.index.selected_index + 1) % filtered.size;
                    var next_url = filtered[model.index.selected_index].url;
                    model.get_parent_dispatch () (new NavigateMessage (next_url, null, model.active_tab_index));
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
                    model.get_parent_dispatch () (new NavigateMessage (prev_url, null, model.active_tab_index));
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

                // Snapshot query state and the archive on the main thread;
                // the worker must not touch `model` (concurrent CLOSE_FILE
                // can swap or close it mid-scan).
                var snap_file = model.chm_file;
                var q = model.search.query;
                bool ww = model.search.whole_words;
                bool to = model.search.titles_only;

                var search_parent = model.get_parent_dispatch ();
                cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                    // Full scan is expensive — run on a worker thread.
                    // dispatch() marshals the result back to the main loop.
                    try {
                        new GLib.Thread<void*> ("vchm-search", () => {
                            Gee.ArrayList<SearchResult> res;
                            snap_file.search (q, ww, to, out res);
                            search_parent (new SearchDoneMessage (res));
                            return null;
                        });
                    } catch (GLib.Error e) {
                        search_parent (new SearchDoneMessage (new Gee.ArrayList<SearchResult> ()));
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
                model.get_parent_dispatch () (new NavigateMessage (search_msg.url, null, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.SEARCH_NEXT: {
            if (model.search.results.size > 0) {
                int next = (model.search.selected_index + 1) % model.search.results.size;
                var result = model.search.results[next];
                if (result != null && result.url != null) {
                    model.search.selected_index = next;
                    model.get_parent_dispatch () (new NavigateMessage (result.url, null, model.active_tab_index));
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
                    model.get_parent_dispatch () (new NavigateMessage (result.url, null, model.active_tab_index));
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
            model.settings.font_size = model.viewer.font_size;
            if (model.file_open) {
                model.per_books.set_font_size (model.chm_file.filename (), model.viewer.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_DECREASE: {
            model.viewer.decrease_font_size ();
            model.settings.font_size = model.viewer.font_size;
            if (model.file_open) {
                model.per_books.set_font_size (model.chm_file.filename (), model.viewer.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_RESET: {
            model.viewer.reset_font_size ();
            model.settings.font_size = model.viewer.font_size;
            if (model.file_open) {
                model.per_books.set_font_size (model.chm_file.filename (), model.viewer.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_CHANGED: {
            var font_msg = (ViewerFontChangedMessage) msg;
            model.viewer.font_size = font_msg.size;
            model.viewer.font_family = font_msg.family;
            model.viewer.fixed_font_family = font_msg.fixed_family;
            model.settings.font_size = font_msg.size;
            model.settings.font_family = font_msg.family;
            model.settings.fixed_font_family = font_msg.fixed_family;
            if (model.file_open) {
                model.per_books.set_font_size (model.chm_file.filename (), font_msg.size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FIND: {
            // State only — ViewerView reacts through the FindController.
            var find_msg = (ViewerFindMessage) msg;
            model.viewer.find_text = find_msg.text;
            model.viewer.find_case_sensitive = find_msg.case_sensitive;
            break;
        }

        case AppMessageKind.VIEWER_FIND_NEXT:
        case AppMessageKind.VIEWER_FIND_PREV:
        case AppMessageKind.VIEWER_PRINT:
        case AppMessageKind.VIEWER_COPY:
            // Pure view concerns; ViewerView.update drives them.
            break;

        case AppMessageKind.VIEWER_FIND_COUNT:
            // Handled by the shell view (match-counter label).
            break;

        // ── History ──────────────────────────────────────────────────────────
        case AppMessageKind.BOOKMARK_ADD: {
            var archive = model.chm_file.filename ();
            if (!model.file_open || archive.length == 0) break;
            model.bookmarks.add (archive,
                                 model.viewer.current_title,
                                 model.viewer.current_url);
            model.settings.bookmark_rows = model.bookmarks.save ();
            model.settings.save ();
            model.show_toast (_("Bookmark added"));
            model.get_parent_dispatch () (new BookmarksChangedMessage ());
            break;
        }

        case AppMessageKind.BOOKMARK_REMOVE: {
            var rm = (BookmarkRemoveMessage) msg;
            var archive = model.chm_file.filename ();
            if (!model.file_open || archive.length == 0) break;
            bool ok = false;
            if (rm.url != "") ok = model.bookmarks.remove_by_url (archive, rm.url);
            if (!ok) ok = model.bookmarks.remove (archive, rm.title);
            if (ok) {
                model.settings.bookmark_rows = model.bookmarks.save ();
                model.settings.save ();
                model.get_parent_dispatch () (new BookmarksChangedMessage ());
            }
            break;
        }

        case AppMessageKind.BOOKMARK_RENAME: {
            var rn = (BookmarkRenameMessage) msg;
            var archive = model.chm_file.filename ();
            if (!model.file_open || archive.length == 0) break;
            if (rn.new_title.strip ().length == 0) break;
            if (model.bookmarks.rename (archive, rn.url, rn.new_title)) {
                model.settings.bookmark_rows = model.bookmarks.save ();
                model.settings.save ();
                model.get_parent_dispatch () (new BookmarksChangedMessage ());
            }
            break;
        }

        case AppMessageKind.BOOKMARK_JUMP: {
            var jm = (BookmarkJumpMessage) msg;
            if (jm.url.length > 0)
                model.get_parent_dispatch () (new NavigateMessage (jm.url, null, model.active_tab_index));
            break;
        }

        case AppMessageKind.BOOKMARKS_CHANGED:
            // Store already updated via settings; nothing to do here.
            break;

        case AppMessageKind.SET_ENCODING: {
            var em = (SetEncodingMessage) msg;
            if (!model.file_open) break;
            var target = model.viewer.current_url;

            // Metadata re-decode is fast; panel rebuild scans hundreds of
            // pages — move that off the UI thread (pattern: OPEN_FILE).
            model.chm_file.override_encoding (em.encoding);

            // Snapshot on the main thread; the worker never touches `model`.
            var snap_file = model.chm_file;
            var snap_url = target;

            var rebuild_parent = model.get_parent_dispatch ();
            cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                try {
                    new GLib.Thread<void*> ("vchm-rebuild", () => {
                        // Fresh containers: swap in whole instances instead
                        // of mutating structures the UI may be reading.
                        var topics = new TopicsModel ();
                        var index = new IndexModel ();
                        topics.build_from_chm (snap_file);
                        index.build_from_chm (snap_file);
                        rebuild_parent (new PanelsRebuiltMessage (topics, index));
                        return null;
                    });
                } catch (GLib.Error e) {
                    rebuild_parent (new PanelsRebuiltMessage (new TopicsModel (), new IndexModel ()));
                }
            });

            model.get_parent_dispatch () (new NavigateMessage (target,
                                              model.chm_file.title (),
                                              model.active_tab_index));
            model.show_toast (_("Encoding: %s").printf (
                em.encoding == "auto" ? _("Automatic") : em.encoding));
            break;
        }

        case AppMessageKind.PANELS_REBUILT: {
            var rb_msg = (PanelsRebuiltMessage) msg;
            if (!model.file_open) break;   // book closed mid-rebuild
            model.topics = rb_msg.topics;
            model.index = rb_msg.index;
            break;
        }

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

        case AppMessageKind.APP_QUIT_INTERNAL: {
            // Actual quit - handled by view
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

        case AppMessageKind.TAB_ACTIVATED: {
            // The view swapped the active tab's sub-models in; the
            // update function's job is mostly a no-op (the views
            // rebuild from model.chm_file/topics/index, which the
            // view already swapped). Keep the per-tab history cursor
            // flag and the shared viewer pointer consistent.
            var ta = (TabActivatedMessage) msg;
            // The view's own activate_tab_idx already wrote
            // model.history, model.chm_file, etc. Nothing to do here
            // beyond noting the activation (a future handler can
            // persist the active tab index if needed).
            break;
        }
    }

    return cmd;
}