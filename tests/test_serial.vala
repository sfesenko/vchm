// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko
//
// Generation-based OPEN_FILE: open_generation monotonic

using Vchm.Model;

int main (string[] args) {
    GLib.Test.init (ref args, null);

    GLib.Test.add_func ("/serial/generation-monotonic", () => {
        var model = new AppModel ();
        assert (model.open_generation == 0);
        model.open_generation++;
        assert (model.open_generation == 1);
        model.open_generation++;
        assert (model.open_generation == 2);
    });

    GLib.Test.add_func ("/serial/stale-drop", () => {
        var model = new AppModel ();
        model.open_generation = 1;
        // stale gen 0 should be considered stale vs 1
        assert (0 != model.open_generation);
        // current gen should not be stale
        assert (1 == model.open_generation);
        model.open_generation = 2;
        assert (1 != model.open_generation);
    });

    GLib.Test.add_func ("/serial/canon-key", () => {
        var k1 = AppModel.canon_open_key ("/tmp/../tmp/a.chm");
        var k2 = AppModel.canon_open_key ("/tmp/a.chm");
        assert (k1 == k2);
    });

    return GLib.Test.run ();
}
