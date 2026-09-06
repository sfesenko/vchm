// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using Vchm;
using Vchm.Model;
using WebKit;

int main (string[] args) {
    GLib.Intl.bindtextdomain (GETTEXT_PACKAGE, LOCALEDIR);
    GLib.Intl.bind_textdomain_codeset (GETTEXT_PACKAGE, "UTF-8");
    GLib.Intl.textdomain (GETTEXT_PACKAGE);

    // Initialize WebKit
    WebContext.get_default ();

    var app = new Gtk.Application (
        "org.gnome.vchm",
        ApplicationFlags.HANDLES_COMMAND_LINE | ApplicationFlags.HANDLES_OPEN
    );

    var model = new AppModel ();

    var program = new Elmish.ElmishProgram<AppMessage, AppModel, AppView> (
        model,
        (dispatch, model) => {
            var view = new AppView (app);
            view.build_ui (dispatch, model);
            view.present ();
            return view;
        },
        updateModel,
        (msg, model, view) => view.update (msg, model)
    );

    // Handle activate signal
    app.activate.connect (() => {
        program.start ();
    });

    // Handle command line
    app.command_line.connect ((cmdline) => {
        string[] cmdline_args = cmdline.get_arguments ();
        if (cmdline_args.length > 1) {
            // First activate the app (which calls program.start())
            app.activate ();
            
            for (int i = 1; i < cmdline_args.length; i++) {
                var arg = cmdline_args[i];
                if (!arg.has_prefix ("-")) {
                    program.dispatch_message (new OpenFileMessage (arg));
                }
            }
        } else {
            // No file argument - activate the app normally
            app.activate ();
        }
        return 0;
    });

    // Handle file open (drag & drop, "Open with...")
    app.open.connect ((app, files, hint) => {
        foreach (var file in files) {
            program.dispatch_message (new OpenFileMessage (file.get_path ()));
        }
    });

    // Subscription: auto-save only when something actually changed.
    program.add_subscription ((dispatch) => {
        var last_fp = "";
        GLib.Timeout.add_seconds (5, () => {
            var m = program.get_model ();
            if (m.settings.window_width == 0) return GLib.Source.CONTINUE;
            string fp = m.settings.fingerprint ();
            if (fp != last_fp) {
                last_fp = fp;
                m.settings.save ();
            }
            return GLib.Source.CONTINUE;
        });
    });

    // Integration test hook for open-close-reopen (Fort blank).
    // Enabled via VCHM_TEST_REOPEN_CYCLE=1 and VCHM_TEST_REOPEN_BOOK=<path>.
    // Used by tools/test_reopen.sh to verify the viewer is reset correctly.
    // The hook simply closes and reopens the same book after the initial
    // open has finished; the per-book last_url is preserved across the
    // cycle, so the viewer must reload the same URL after reopen (the
    // bug was that the cached (loaded_url, loaded_book) prevented the
    // reload and left the view blank).
    var reopen_cycle = GLib.Environment.get_variable ("VCHM_TEST_REOPEN_CYCLE");
    var reopen_book = GLib.Environment.get_variable ("VCHM_TEST_REOPEN_BOOK");
    if (reopen_cycle != null && reopen_cycle == "1" && reopen_book != null && reopen_book != "") {
        string rb = reopen_book;
        program.add_subscription ((dispatch) => {
            GLib.Timeout.add (3000, () => {
                dispatch (new TestReopenMessage ());
                return false;
            });
            GLib.Timeout.add (5000, () => {
                dispatch (new OpenFileMessage (rb));
                return false;
            });
        });
    }

    return app.run (args);
}