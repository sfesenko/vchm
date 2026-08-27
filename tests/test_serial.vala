// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Phase-1 OPEN_FILE serialization: two concurrent OpenFileMessage
// dispatches must run their workers sequentially, not in parallel.
// F26 follow-up.

using Vchm.Model;

int main (string[] args) {
    GLib.Test.init (ref args, null);

    // try_acquire_open should grant the first request and block the
    // second until release.
    GLib.Test.add_func ("/serial/first-acquire", () => {
        var model = new AppModel ();
        assert (model.try_acquire_open ("/tmp/a.chm"));
        assert (!model.try_acquire_open ("/tmp/a.chm"));  // same path blocked
        assert (!model.try_acquire_open ("/tmp/b.chm"));  // any-path blocked
        model.release_open ("/tmp/a.chm");
        // After release, a different path can acquire.
        assert (model.try_acquire_open ("/tmp/b.chm"));
        model.release_open ("/tmp/b.chm");
    });

    // The serialization set is keyed by path: releasing A must not
    // accidentally unblock A's own re-acquire under a new in-flight
    // OPEN_FILE (the second try_acquire for A should still block
    // until the second release).
    GLib.Test.add_func ("/serial/paired-release", () => {
        var model = new AppModel ();
        assert (model.try_acquire_open ("/tmp/a.chm"));
        model.release_open ("/tmp/a.chm");
        assert (model.try_acquire_open ("/tmp/a.chm"));
        // While the second hold is live, a third request for the same
        // path must be blocked.
        assert (!model.try_acquire_open ("/tmp/a.chm"));
        model.release_open ("/tmp/a.chm");
    });

    return GLib.Test.run ();
}
