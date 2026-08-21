// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

// Unit tests for the elmish core itself (Cmd, dispatch, coalescing,
// subscriptions, thread marshalling). No GTK, no app types — the core is
// generic over any message/model/view.

using Elmish;

class CounterModel : Object {
    public int count;
    public string? last_msg;
}

class MockView : Object {
    public int update_calls;
    public string? last_msg;
}

void test_cmd_chain_executes_in_order () {
    string[] log = {};
    Dispatch<CounterModel> probe = (msg) => log += "dispatch";

    var cmd = new Cmd<CounterModel> ((dispatch) => log += "first",
        new Cmd<CounterModel> ((dispatch) => log += "second",
            new Cmd<CounterModel> ((dispatch) => log += "third")));

    Cmd.exec<CounterModel> (probe, cmd);

    assert (log.length == 3);
    assert (log[0] == "first");
    assert (log[1] == "second");
    assert (log[2] == "third");
}

void test_cmd_null_is_noop () {
    string[] log = {};
    Cmd.exec<CounterModel> ((msg) => log += "dispatch", null);
    assert (log.length == 0);
}

void test_cmd_can_dispatch_back () {
    // A command receives dispatch and can send messages back — the async
    // result pattern (e.g. save completed).
    int received = 0;
    Dispatch<CounterModel> probe = (msg) => received = msg.count;

    var cmd = new Cmd<CounterModel> ((dispatch) => dispatch (new CounterModel () { count = 7 }));
    Cmd.exec<CounterModel> (probe, cmd);

    assert (received == 7);
}

ElmishProgram<CounterModel, CounterModel, MockView> build_program (CounterModel model) {
    return new ElmishProgram<CounterModel, CounterModel, MockView> (
        model,
        (dispatch, model) => new MockView (),
        (msg, model) => {
            model.count += 1;
            model.last_msg = "updated";
            return null;
        },
        (msg, model, view) => {
            view.update_calls += 1;
            view.last_msg = "viewed";
        }
    );
}

void test_dispatch_updates_model () {
    var model = new CounterModel ();
    var program = build_program (model);

    program.start ();
    program.dispatch_message (new CounterModel ());

    assert (model.count == 1);
    assert (model.last_msg == "updated");
}

void test_view_update_runs_on_main_loop () {
    var model = new CounterModel ();
    var program = build_program (model);
    program.start ();
    MockView? view = program.get_view () as MockView;

    program.dispatch_message (new CounterModel ());

    // updateView is queued via idle — nothing ran yet
    assert (view.update_calls == 0);

    // Drain the main loop until the queued view update has run
    while (view.update_calls == 0) {
        assert (GLib.MainContext.default ().iteration (true));
    }
    assert (view.last_msg == "viewed");
}

void test_coalescing_collapses_burst_into_one_view_update () {
    var model = new CounterModel ();
    var program = build_program (model);
    program.start ();
    MockView? view = program.get_view () as MockView;

    // A burst of messages before the idle callback gets a chance to run
    for (var i = 0; i < 100; i++) {
        program.dispatch_message (new CounterModel ());
    }

    // Model sees every message...
    assert (model.count == 100);

    // ...but the view update runs exactly once, with the latest message
    while (view.update_calls == 0) {
        assert (GLib.MainContext.default ().iteration (true));
    }
    assert (view.update_calls == 1);
}

void test_subscription_receives_dispatch () {
    var model = new CounterModel ();
    var program = build_program (model);
    program.start ();

    int sub_dispatches = 0;
    program.add_subscription ((dispatch) => {
        // Subscriptions run their setup immediately with a dispatch
        dispatch (new CounterModel ());
        sub_dispatches += 1;
    });

    assert (sub_dispatches == 1);
    assert (model.count == 1);
}

void test_init_cmd_runs_on_start () {
    var model = new CounterModel ();
    var program = build_program (model);

    var init_cmd = new Cmd<CounterModel> ((dispatch) => dispatch (new CounterModel ()));
    program.start (init_cmd);

    // init command dispatched back into the loop right away
    assert (model.count == 1);
}

void test_dispatch_from_worker_thread_is_marshalled () {
    var model = new CounterModel ();
    var program = build_program (model);
    program.start ();

    var thread = new GLib.Thread<void*> ("test-worker", () => {
        program.dispatch_message (new CounterModel ());
        return null;
    });

    // The worker can't touch the model directly — the message is marshalled
    // to the main loop, so we must pump the loop for it to land.
    while (model.count == 0) {
        assert (GLib.MainContext.default ().iteration (true));
    }
    thread.join ();
    assert (model.count == 1);
}

// ── Cmd.map: component composition ────────────────────────────────────────

// A second, plain-class message space, as a child component would use.
class ChildMsg {
    public string tag;
}

void test_cmd_map_lifts_into_another_space () {
    var child_cmd = new Cmd<ChildMsg> ((dispatch) => dispatch (new ChildMsg () { tag = "hi" }));

    string? received = null;
    var mapped = child_cmd.map<CounterModel> ((m) => new CounterModel () { count = m.tag.length });
    Cmd.exec<CounterModel> ((m) => received = m.last_msg ?? "seen", mapped);

    assert (received == "seen");
}

void test_cmd_map_preserves_chain_order () {
    string[] log = {};
    var child_cmd = new Cmd<ChildMsg> ((dispatch) => log += "first",
        new Cmd<ChildMsg> ((dispatch) => log += "second",
            new Cmd<ChildMsg> ((dispatch) => log += "third")));

    var mapped = child_cmd.map<CounterModel> ((m) => new CounterModel ());
    Cmd.exec<CounterModel> ((m) => {}, mapped);

    assert (log.length == 3);
    assert (log[0] == "first");
    assert (log[1] == "second");
    assert (log[2] == "third");
}

// ── Plain classes as the generic message type ─────────────────────────────

// The template's own message representation: plain classes (no Object, no
// [Compact]) — ref-counted, type-checkable, valid generic args.
class PlainMsg {
    public int value;
}

void test_plain_class_messages_work_with_generic_core () {
    var model = new CounterModel ();
    var program = new ElmishProgram<PlainMsg, CounterModel, MockView> (
        model,
        (dispatch, model) => new MockView (),
        (msg, model) => {
            model.count += msg.value;
            return null;
        },
        (msg, model, view) => view.update_calls += 1
    );
    program.start ();

    program.dispatch_message (new PlainMsg () { value = 5 });
    assert (model.count == 5);
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/elmish/cmd_chain_executes_in_order", test_cmd_chain_executes_in_order);
    Test.add_func ("/elmish/cmd_null_is_noop", test_cmd_null_is_noop);
    Test.add_func ("/elmish/cmd_can_dispatch_back", test_cmd_can_dispatch_back);
    Test.add_func ("/elmish/dispatch_updates_model", test_dispatch_updates_model);
    Test.add_func ("/elmish/view_update_runs_on_main_loop", test_view_update_runs_on_main_loop);
    Test.add_func ("/elmish/coalescing_collapses_burst", test_coalescing_collapses_burst_into_one_view_update);
    Test.add_func ("/elmish/subscription_receives_dispatch", test_subscription_receives_dispatch);
    Test.add_func ("/elmish/init_cmd_runs_on_start", test_init_cmd_runs_on_start);
    Test.add_func ("/elmish/dispatch_from_worker_thread", test_dispatch_from_worker_thread_is_marshalled);
    Test.add_func ("/elmish/cmd_map_lifts_into_another_space", test_cmd_map_lifts_into_another_space);
    Test.add_func ("/elmish/cmd_map_preserves_chain_order", test_cmd_map_preserves_chain_order);
    Test.add_func ("/elmish/plain_class_messages_in_generic_core", test_plain_class_messages_work_with_generic_core);

    return Test.run ();
}