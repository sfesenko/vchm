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
                // Another open in flight — FIFO queue, preserves order and
                // avoids 150 ms poll thundering-herd (S2).
                model.enqueue_open (path);
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
                            // FIFO drain: release and if queued, dispatch next.
                            string? nxt = null;
                            if (model.release_and_dequeue_next (path, out nxt) && nxt != null) {
                                open_parent (new OpenFileMessage (nxt));
                            }
                        }
                        return null;
                    });
                } catch (GLib.Error e) {
                    string? nxt2 = null;
                    bool has_next = model.release_and_dequeue_next (path, out nxt2);
                    open_parent (new OpenFileFailedMessage (path, e.message));
                    if (has_next && nxt2 != null) {
                        open_parent (new OpenFileMessage (nxt2));
                    }
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
                model.add_book (ctx);
                nav_tab_index = model.books.size - 1;
            }

            model.active_book = ctx;

            // M1: restore per-book history/expanded/selected before first nav.
            // Prune already done at startup; refresh last_access.
            string arch_path = ctx.chm_file.filename ();
            if (model.per_books.has_book (arch_path)) {
                Gee.ArrayList<HistoryEntry> h; int hi;
                model.per_books.get_history (arch_path, out h, out hi);
                if (h.size > 0) {
                    ctx.history.entries.clear ();
                    foreach (var e in h) ctx.history.entries.add (e);
                    ctx.history.current_index = hi;
                }
                var exp = model.per_books.get_expanded (arch_path);
                if (exp.size > 0) ctx.topics.apply_expanded (exp);
                string sel = model.per_books.get_selected_url (arch_path);
                if (sel != "" && ctx.chm_file.has_object (sel)) ctx.topics.selected_url = sel;
            }
            model.per_books.touch (arch_path);
            model.file_open = true;

            // M4: if per-book last_url is stored, navigate there directly
            // instead of home->saved duplicate history (home + saved).
            string nav_url = done_msg.home_page;
            string nav_title = done_msg.title;
            string saved = model.per_books.get_last_url (arch_path);
            if (saved != "" && saved != nav_url && ctx.chm_file.has_object (saved)) {
                nav_url = saved;
                nav_title = null; // let worker extract <title>/<h1> for that page
            }
            // Panels were built on the open worker; here we just wire state.
            ctx.viewer.navigate (nav_url, nav_title, arch_path);

            // Dispatch NAVIGATE to actually load the content
            // DO NOT add to history here - NAVIGATE_DONE will handle it
            model.get_parent_dispatch () (new NavigateMessage (nav_url, nav_title, nav_tab_index));
            
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
            model.clear_books ();
            model.active_book = null;
            // Reset placeholder for next open
            model.placeholder.chm_file.close ();
            model.placeholder.topics.clear ();
            model.placeholder.index.clear ();
            model.placeholder.search.clear ();
            model.placeholder.viewer.current_url = "/";
            model.placeholder.viewer.current_title = "";
            model.placeholder.viewer.current_chm_file = "";
            model.placeholder.history.clear ();
            model.placeholder.history_navigation_in_progress = false;
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

            // M2/M3: route via tab_index so a tab-switch mid-load doesn't
            // steal the snapshot/file or the viewer's intended_url slot.
            BookContext? nav_ctx = null;
            if (nav_msg.tab_index >= 0 && nav_msg.tab_index < model.books.size)
                nav_ctx = model.books[nav_msg.tab_index];
            if (nav_ctx == null) nav_ctx = model.active_book;
            if (nav_ctx == null || !model.file_open) break;

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
            nav_ctx.viewer.intended_url = nav_msg.url;
            nav_ctx.viewer.current_title = nav_msg.title ?? "";
            nav_ctx.viewer.current_chm_file = nav_ctx.chm_file.filename ();
            nav_ctx.viewer.loading = true;
            nav_ctx.viewer.error = null;
            nav_ctx.viewer.pending_html = null;

            // Snapshot model state on the main thread before spawning the worker
            // (the worker must not touch `model` — concurrent CLOSE/OPEN can
            // mutate it).
            var snap_file = nav_ctx.chm_file;
            var snap_cur = nav_ctx.viewer.current_url;
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
            // M2/M3: route via tab_index so history/topic/viewer writes
            // target the originating book, not whichever is active now.
            int ti = done_msg.tab_index >= 0 ? done_msg.tab_index : model.active_tab_index;
            BookContext? target_ctx = null;
            if (ti >= 0 && ti < model.books.size)
                target_ctx = model.books[ti];
            if (target_ctx == null) target_ctx = model.active_book;
            if (target_ctx == null) break;

            target_ctx.viewer.load_finished (true);
            target_ctx.viewer.current_url = done_msg.url;
            target_ctx.viewer.current_title = done_msg.title;
            // Use this navigation's own intended target for history (the
            // CHM path), not the data: URI — and not the shared
            // intended_url slot, which a newer in-flight navigation may
            // already have overwritten (review F7).
            var history_url = done_msg.intended_url;
            target_ctx.viewer.intended_url = history_url;

            if (target_ctx.history_navigation_in_progress) {
                // Back/forward: the entry already exists in history; pushing
                // again would truncate the forward tail (review §4.6).
                target_ctx.history_navigation_in_progress = false;
            } else {
                target_ctx.history.add_entry (done_msg.title, history_url, target_ctx.chm_file.filename () ?? "");
            }

            target_ctx.topics.selected_url = history_url;
            target_ctx.topics.expand_path (history_url);
            // Persist per-book state: last_url, selected, expanded, history, last_access
            if (model.file_open) {
                string ap = target_ctx.chm_file.filename ();
                model.per_books.set_last_url (ap, history_url);
                model.per_books.set_selected_url (ap, history_url);
                model.per_books.set_expanded (ap, target_ctx.topics.collect_expanded ());
                model.per_books.set_history (ap, target_ctx.history.entries, target_ctx.history.current_index);
                model.per_books.prune (model.settings.per_book_expire_days);
                model.settings.per_book_rows = model.per_books.save ();
            }
            // Global status reflects the ACTIVE tab only; don't clobber it
            // with an inactive tab's load (user switched mid-load).
            if (ti == model.active_tab_index || target_ctx == model.active_book) {
                model.status_text = done_msg.title != "" ? done_msg.title : done_msg.url;
            }
            // Keep tab title in sync for the target book (view's tab bar
            // reads from DocumentTab.title, but model also stores title in
            // BookContext for window title fallback).
            target_ctx.title = done_msg.title != "" ? done_msg.title : target_ctx.title;
            break;
        }

        case AppMessageKind.NAVIGATE_FAILED: {
            var fail_msg = (NavigateFailedMessage) msg;
            // NAVIGATE_FAILED is tab-agnostic (decide_policy may not know tab);
            // route to active_book or placeholder.
            var v_fail = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_fail.load_finished (false, fail_msg.error);
            // Otherwise the stuck flag makes every later navigation skip
            // its history push.
            var h_fail = model.active_book != null ? model.active_book : model.placeholder;
            h_fail.history_navigation_in_progress = false;
            model.show_toast ("Navigation failed: %s".printf (fail_msg.error));
            break;
        }

        case AppMessageKind.GO_BACK: {
            var h_ctx = model.active_book != null ? model.active_book : model.placeholder;
            // A back/forward jump is still in flight; a second one would
            // desync the history cursor.
            if (h_ctx.history_navigation_in_progress) break;
            var entry = h_ctx.history.go_back ();
            if (entry != null) {
                h_ctx.history_navigation_in_progress = true;
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.GO_FORWARD: {
            var h_ctx2 = model.active_book != null ? model.active_book : model.placeholder;
            if (h_ctx2.history_navigation_in_progress) break;
            var entry = h_ctx2.history.go_forward ();
            if (entry != null) {
                h_ctx2.history_navigation_in_progress = true;
                model.get_parent_dispatch () (new NavigateMessage (entry.url, entry.title, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.GO_HOME: {
            var h_ctx3 = model.active_book;
            if (model.file_open && h_ctx3 != null) {
                var home = h_ctx3.chm_file.home_page ();
                model.get_parent_dispatch () (new NavigateMessage (home, h_ctx3.chm_file.title (), model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.CONTEXT_ID_NAVIGATE: {
            var cid_msg = (ContextIdNavigateMessage) msg;
            var h_ctx4 = model.active_book;
            if (model.file_open && h_ctx4 != null && h_ctx4.chm_file.is_valid_cid (cid_msg.context_id)) {
                var url = h_ctx4.chm_file.get_page_by_cid (cid_msg.context_id);
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
            // B+hybrid: explicit TabModel (active_book) not proxy
            var t_topics = model.active_book != null ? model.active_book.topics : model.topics;
            t_topics.selected_url = topics_msg.url;
            if (model.file_open) {
                string ap = model.active_book != null ? model.active_book.chm_file.filename () : model.chm_file.filename ();
                model.per_books.set_selected_url (ap, topics_msg.url);
                model.settings.per_book_rows = model.per_books.save ();
            }
            if (topics_msg.url != null) {
                model.get_parent_dispatch () (new NavigateMessage (topics_msg.url, null, model.active_tab_index));
            }
            break;
        }

        case AppMessageKind.TOPICS_ITEM_EXPANDED: {
            var exp_msg = (TopicsItemExpandedMessage) msg;
            var t_topics2 = model.active_book != null ? model.active_book.topics : model.topics;
            if (t_topics2.root != null) {
                var item = t_topics2.find_item_by_url (exp_msg.url);
                if (item != null) {
                    item.expanded = true;
                    if (model.file_open) {
                        string ap2 = model.active_book != null ? model.active_book.chm_file.filename () : model.chm_file.filename ();
                        model.per_books.set_expanded (ap2, t_topics2.collect_expanded ());
                        model.settings.per_book_rows = model.per_books.save ();
                    }
                }
            }
            break;
        }

        case AppMessageKind.TOPICS_ITEM_COLLAPSED: {
            var col_msg = (TopicsItemCollapsedMessage) msg;
            var t_topics3 = model.active_book != null ? model.active_book.topics : model.topics;
            if (t_topics3.root != null) {
                var item = t_topics3.find_item_by_url (col_msg.url);
                if (item != null) {
                    item.expanded = false;
                    if (model.file_open) {
                        string ap3 = model.active_book != null ? model.active_book.chm_file.filename () : model.chm_file.filename ();
                        model.per_books.set_expanded (ap3, t_topics3.collect_expanded ());
                        model.settings.per_book_rows = model.per_books.save ();
                    }
                }
            }
            break;
        }

        case AppMessageKind.INDEX_FILTER_CHANGED: {
            var filter_msg = (IndexFilterChangedMessage) msg;
            var t_index = model.active_book != null ? model.active_book.index : model.index;
            t_index.filter_text = filter_msg.filter;
            break;
        }

        case AppMessageKind.INDEX_SELECTION_CHANGED: {
            var index_msg = (IndexSelectionChangedMessage) msg;
            var t_index2 = model.active_book != null ? model.active_book.index : model.index;
            // Find the index of the selected URL in filtered entries
            var filtered = t_index2.filtered_entries ();
            for (int i = 0; i < filtered.size; i++) {
                if (filtered[i].url == index_msg.url) {
                    t_index2.selected_index = i;
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
            var t_index3 = model.active_book != null ? model.active_book.index : model.index;
            if (t_index3.entries.size > 0) {
                var filtered = t_index3.filtered_entries ();
                if (filtered.size > 0) {
                    t_index3.selected_index = (t_index3.selected_index + 1) % filtered.size;
                    var next_url = filtered[t_index3.selected_index].url;
                    model.get_parent_dispatch () (new NavigateMessage (next_url, null, model.active_tab_index));
                }
            }
            break;
        }

        case AppMessageKind.INDEX_PREV: {
            var t_index4 = model.active_book != null ? model.active_book.index : model.index;
            if (t_index4.entries.size > 0) {
                var filtered = t_index4.filtered_entries ();
                if (filtered.size > 0) {
                    t_index4.selected_index = (t_index4.selected_index - 1 + filtered.size) % filtered.size;
                    var prev_url = filtered[t_index4.selected_index].url;
                    model.get_parent_dispatch () (new NavigateMessage (prev_url, null, model.active_tab_index));
                }
            }
            break;
        }

        // ── Search ───────────────────────────────────────────────────────────
        case AppMessageKind.SEARCH_QUERY_CHANGED: {
            var search_msg = (SearchQueryChangedMessage) msg;
            var s_qc = model.active_book != null ? model.active_book.search : model.placeholder.search;
            s_qc.query = search_msg.query;
            break;
        }

        case AppMessageKind.SEARCH_EXECUTE: {
            var s_exec = model.active_book != null ? model.active_book.search : model.placeholder.search;
            var snap_ctx = model.active_book;
            if (model.file_open && snap_ctx != null && s_exec.query != "") {
                s_exec.searching = true;

                // Snapshot query state and the archive on the main thread;
                // the worker must not touch `model` (concurrent CLOSE_FILE
                // can swap or close it mid-scan).
                // M2/M3: capture originating tab so results route back even if
                // the user switches tabs before the worker finishes.
                var snap_file = snap_ctx.chm_file;
                var q = s_exec.query;
                bool ww = s_exec.whole_words;
                bool to = s_exec.titles_only;
                int snap_tab = model.active_tab_index;

                var search_parent = model.get_parent_dispatch ();
                cmd = new Elmish.Cmd<AppMessage> ((dispatch) => {
                    // Full scan is expensive — run on a worker thread.
                    // dispatch() marshals the result back to the main loop.
                    try {
                        new GLib.Thread<void*> ("vchm-search", () => {
                            Gee.ArrayList<SearchResult> res;
                            snap_file.search (q, ww, to, out res);
                            search_parent (new SearchDoneMessage (res, snap_tab));
                            return null;
                        });
                    } catch (GLib.Error e) {
                        search_parent (new SearchDoneMessage (new Gee.ArrayList<SearchResult> (), snap_tab));
                    }
                });
            }
            break;
        }

        case AppMessageKind.SEARCH_DONE: {
            var done_msg = (SearchDoneMessage) msg;
            // Route to the originating tab's search model (M2/M3)
            BookContext? s_ctx = null;
            if (done_msg.tab_index >= 0 && done_msg.tab_index < model.books.size)
                s_ctx = model.books[done_msg.tab_index];
            if (s_ctx == null) s_ctx = model.active_book;
            if (s_ctx == null) s_ctx = model.placeholder;
            s_ctx.search.searching = false;
            s_ctx.search.results = done_msg.results;
            s_ctx.search.selected_index = -1;
            break;
        }

        case AppMessageKind.SEARCH_SELECTION_CHANGED: {
            var search_msg = (SearchSelectionChangedMessage) msg;
            var s_ctx2 = model.active_book != null ? model.active_book : model.placeholder;
            if (s_ctx2.search.results.size > 0) {
                // Find index of the URL in results
                for (int i = 0; i < s_ctx2.search.results.size; i++) {
                    if (s_ctx2.search.results[i].url == search_msg.url) {
                        s_ctx2.search.selected_index = i;
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
            var s_ctx3 = model.active_book != null ? model.active_book : model.placeholder;
            if (s_ctx3.search.results.size > 0) {
                int next = (s_ctx3.search.selected_index + 1) % s_ctx3.search.results.size;
                var result = s_ctx3.search.results[next];
                if (result != null && result.url != null) {
                    s_ctx3.search.selected_index = next;
                    model.get_parent_dispatch () (new NavigateMessage (result.url, null, model.active_tab_index));
                }
            }
            break;
        }

        case AppMessageKind.SEARCH_PREV: {
            var s_ctx4 = model.active_book != null ? model.active_book : model.placeholder;
            if (s_ctx4.search.results.size > 0) {
                int prev = (s_ctx4.search.selected_index - 1 + s_ctx4.search.results.size) % s_ctx4.search.results.size;
                var result = s_ctx4.search.results[prev];
                if (result != null && result.url != null) {
                    s_ctx4.search.selected_index = prev;
                    model.get_parent_dispatch () (new NavigateMessage (result.url, null, model.active_tab_index));
                }
            }
            break;
        }

        case AppMessageKind.SEARCH_OPTIONS_CHANGED: {
            var opts_msg = (SearchOptionsChangedMessage) msg;
            var s_ctx5 = model.active_book != null ? model.active_book : model.placeholder;
            s_ctx5.search.whole_words = opts_msg.whole_words;
            s_ctx5.search.titles_only = opts_msg.titles_only;
            break;
        }

        // ── Viewer ───────────────────────────────────────────────────────────
        case AppMessageKind.VIEWER_FONT_INCREASE: {
            var v_ctx = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_ctx.increase_font_size ();
            model.settings.font_size = v_ctx.font_size;
            if (model.file_open && model.active_book != null) {
                model.per_books.set_font_size (model.active_book.chm_file.filename (), v_ctx.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_DECREASE: {
            var v_ctx2 = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_ctx2.decrease_font_size ();
            model.settings.font_size = v_ctx2.font_size;
            if (model.file_open && model.active_book != null) {
                model.per_books.set_font_size (model.active_book.chm_file.filename (), v_ctx2.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_RESET: {
            var v_ctx3 = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_ctx3.reset_font_size ();
            model.settings.font_size = v_ctx3.font_size;
            if (model.file_open && model.active_book != null) {
                model.per_books.set_font_size (model.active_book.chm_file.filename (), v_ctx3.font_size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FONT_CHANGED: {
            var font_msg = (ViewerFontChangedMessage) msg;
            var v_ctx4 = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_ctx4.font_size = font_msg.size;
            v_ctx4.font_family = font_msg.family;
            v_ctx4.fixed_font_family = font_msg.fixed_family;
            model.settings.font_size = font_msg.size;
            model.settings.font_family = font_msg.family;
            model.settings.fixed_font_family = font_msg.fixed_family;
            if (model.file_open && model.active_book != null) {
                model.per_books.set_font_size (model.active_book.chm_file.filename (), font_msg.size);
                model.settings.per_book_rows = model.per_books.save ();
            }
            break;
        }

        case AppMessageKind.VIEWER_FIND: {
            // State only — ViewerView reacts through the FindController.
            var find_msg = (ViewerFindMessage) msg;
            var v_ctx5 = model.active_book != null ? model.active_book.viewer : model.placeholder.viewer;
            v_ctx5.find_text = find_msg.text;
            v_ctx5.find_case_sensitive = find_msg.case_sensitive;
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
            var b_ctx = model.active_book;
            if (b_ctx == null || !model.file_open) break;
            var archive = b_ctx.chm_file.filename ();
            if (archive.length == 0) break;
            model.bookmarks.add (archive,
                                 b_ctx.viewer.current_title,
                                 b_ctx.viewer.current_url);
            model.settings.bookmark_rows = model.bookmarks.save ();
            model.settings.save ();
            model.show_toast (_("Bookmark added"));
            model.get_parent_dispatch () (new BookmarksChangedMessage ());
            break;
        }

        case AppMessageKind.BOOKMARK_REMOVE: {
            var rm = (BookmarkRemoveMessage) msg;
            var b_ctx2 = model.active_book;
            if (b_ctx2 == null || !model.file_open) break;
            var archive = b_ctx2.chm_file.filename ();
            if (archive.length == 0) break;
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
            var b_ctx3 = model.active_book;
            if (b_ctx3 == null || !model.file_open) break;
            var archive = b_ctx3.chm_file.filename ();
            if (archive.length == 0) break;
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
            var enc_ctx = model.active_book;
            if (!model.file_open || enc_ctx == null) break;
            var target = enc_ctx.viewer.current_url;

            // Metadata re-decode is fast; panel rebuild scans hundreds of
            // pages — move that off the UI thread (pattern: OPEN_FILE).
            enc_ctx.chm_file.override_encoding (em.encoding);

            // Snapshot on the main thread; the worker never touches `model`.
            var snap_file = enc_ctx.chm_file;
            var snap_url = target;
            int snap_tab = model.active_tab_index;
            string snap_title = enc_ctx.chm_file.title ();

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
                        rebuild_parent (new PanelsRebuiltMessage (topics, index, snap_tab));
                        return null;
                    });
                } catch (GLib.Error e) {
                    rebuild_parent (new PanelsRebuiltMessage (new TopicsModel (), new IndexModel (), snap_tab));
                }
            });

            model.get_parent_dispatch () (new NavigateMessage (target,
                                              snap_title,
                                              snap_tab));
            model.show_toast (_("Encoding: %s").printf (
                em.encoding == "auto" ? _("Automatic") : em.encoding));
            break;
        }

        case AppMessageKind.PANELS_REBUILT: {
            var rb_msg = (PanelsRebuiltMessage) msg;
            if (!model.file_open) break;   // book closed mid-rebuild
            BookContext? t_ctx = null;
            if (rb_msg.tab_index >= 0 && rb_msg.tab_index < model.books.size)
                t_ctx = model.books[rb_msg.tab_index];
            else
                t_ctx = model.active_book;
            if (t_ctx == null) t_ctx = model.placeholder;
            t_ctx.topics = rb_msg.topics;
            t_ctx.index = rb_msg.index;
            break;
        }

        case AppMessageKind.HISTORY_CLEAR: {
            var h_ctx = model.active_book != null ? model.active_book : model.placeholder;
            h_ctx.history.clear ();
            break;
        }

        // ── Window state ─────────────────────────────────────────────────────
        case AppMessageKind.WINDOW_STATE_CHANGED: {
            var ws_msg = (WindowStateChangedMessage) msg;
            model.settings.window_width = ws_msg.width;
            model.settings.window_height = ws_msg.height;
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

        case AppMessageKind.SET_PER_BOOK_EXPIRE: {
            var m = (SetPerBookExpireMessage) msg;
            model.settings.per_book_expire_days = m.days.clamp (0, 3650);
            if (model.per_books.prune (model.settings.per_book_expire_days)) {
                model.settings.per_book_rows = model.per_books.save ();
            }
            model.settings.save ();
            break;
        }

        case AppMessageKind.SET_BOOKMARKS_EXPIRE: {
            var m = (SetBookmarksExpireMessage) msg;
            model.settings.bookmarks_expire_days = m.days.clamp (0, 3650);
            if (model.bookmarks.prune (model.settings.bookmarks_expire_days)) {
                model.settings.bookmark_rows = model.bookmarks.save ();
            }
            model.settings.save ();
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