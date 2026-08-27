// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Sergii Fesenko

using GLib;

namespace Elmish {

    public delegate void Dispatch<Message> (Message message);
    public delegate View CreateView<View, Model> (Dispatch dispatch, Model model);
    public delegate Cmd<Message>? UpdateModel<Message, Model> (Message msg, Model model);
    public delegate void UpdateView<Message, Model, View> (Message msg, Model model, View view);
    public delegate void Sub<Message> (Dispatch<Message> dispatch);
    public delegate MessageOut Mapper<MessageOut, MessageIn> (MessageIn message);

    // A "command": a side effect bundled with a message. Commands are the only
    // place where IO happens (file writes, network, timers, ...).
    // They are returned from updateModel and executed right after the model
    // update, receiving the same dispatch so they can send messages back
    // (async result, progress, ...).
    public class Cmd<Message> {
        private Sub<Message> sub;
        private Cmd<Message>? next;

        public Cmd (owned Sub<Message> sub, Cmd<Message>? parent = null) {
            this.sub = (owned) sub;
            this.next = parent;
        }

        public static void exec<Message> (Dispatch<Message> dispatch, Cmd<Message>? cmd) {
            var current_cmd = cmd;
            while (current_cmd != null) {
                current_cmd.sub (dispatch);
                current_cmd = current_cmd.next;
            }
        }

        // Lifts this command into another message space — the composition
        // primitive for components. Each component works with its own
        // message type; the parent maps child commands into its own space:
        //
        //     child_cmd.map<AppMessage> (mapper_object.method)
        //                        ── dispatch (AppMessage) ──▶ updateModel
        //
        // Vala delegate contract (verified): closures BORROW captured
        // delegates — valac's delegate calling convention carries no destroy
        // notify, so a temporary closure is freed as soon as its creating
        // frame returns. Therefore:
        //   • the mapper must be a METHOD-BOUND delegate (a method on a
        //     long-lived object), never an inline lambda with captures;
        //   • the child sub must use the passed dispatch only synchronously
        //     within the sub call. Deferred use (timers, async IO) requires
        //     the child to capture its own long-lived dispatch at creation
        //     (see the sample's counter component).
        public Cmd<MessageOut> map<MessageOut> (Mapper<MessageOut, Message> f) {
            var head = new Cmd<MessageOut> ((dispatch) => {
                this.sub ((m) => dispatch (f (m)));
            });
            Cmd<MessageOut> tail = head;
            var cur = this.next;
            while (cur != null) {
                var cur2 = cur;
                var wrapped = new Cmd<MessageOut> ((dispatch) => {
                    cur2.sub ((m) => dispatch (f (m)));
                });
                tail.next = wrapped;
                tail = wrapped;
                cur = cur.next;
            }
            return head;
        }
    }

    // Wires the half-elmish loop together:
    //
    //     dispatch(msg)
    //       -> updateModel(msg, model) -> Cmd?        (pure, testable)
    //       -> queue view update                       (coalesced, on the main loop)
    //            -> updateView(msg, model, view)       (imperative widget mutation)
    //
    // dispatch is thread-safe: messages sent from worker threads are marshalled
    // to the main loop before touching the model.
    public class ElmishProgram<Message, Model, View> : Object {

        private CreateView createView;
        private UpdateModel updateModel;
        private UpdateView updateView;
        private Model model;
        private View? view;

        private Message? pending_message = null;
        private bool view_update_queued = false;
        private uint view_update_source_id = 0;
        private bool disposed = false;

        public ElmishProgram (
            Model model,
            owned CreateView<View, Model> createView,
            owned UpdateModel<Message, Model> updateModel,
            owned UpdateView<Message, Model, View> updateView) {

            this.model = model;
            this.createView = (owned) createView;
            this.updateModel = (owned) updateModel;
            this.updateView = (owned) updateView;
        }

        ~ElmishProgram () {
            disposed = true;
            if (view_update_source_id != 0) {
                GLib.Source.remove (view_update_source_id);
                view_update_source_id = 0;
            }
        }

        // Creates the view and runs the optional initial command
        // (e.g. asynchronously load persisted state).
        public void start (Cmd<Message>? init_cmd = null) {
            // Idempotent: GtkApplication can emit ::activate more than once
            // (e.g. second launch hands off via command_line). Recreating the
            // view would duplicate signal connections and URI-scheme handlers.
            if (this.view != null) {
                Cmd.exec (dispatch, init_cmd);
                return;
            }
            this.view = createView (dispatch, model);
            Cmd.exec (dispatch, init_cmd);
        }

        // Registers a subscription: a callback that runs now (with dispatch)
        // and is expected to set up its own sources (timers, gio watchers, ...).
        public void add_subscription (owned Sub<Message> sub) {
            sub (dispatch);
        }

        public void dispatch_message (Message msg) {
            dispatch (msg);
        }

        public unowned Model get_model () {
            return model;
        }

        public unowned View? get_view () {
            return view;
        }

        // ── internals ──────────────────────────────────────────────────────

        private void dispatch (Message msg) {
            if (GLib.MainContext.default ().is_owner ()) {
                process (msg);
            } else {
                // Called from a worker thread: marshal to the main loop.
                GLib.MainContext.default ().invoke (() => {
                    process (msg);
                    return false;
                });
            }
        }

        private void process (Message msg) {
            var cmd = updateModel (msg, model);
            queue_view_update (msg);
            Cmd.exec (dispatch, cmd);
        }

        // Coalesces view updates: bursts of messages (position ticks, drags)
        // collapse into a single idle callback that re-renders from the model,
        // using the latest message of the burst.
        private void queue_view_update (Message msg) {
            pending_message = msg;
            if (view_update_queued) {
                return;
            }
            view_update_queued = true;
            weak ElmishProgram<Message, Model, View> weak_self = this;
            view_update_source_id = GLib.Idle.add (() => {
                view_update_source_id = 0;
                view_update_queued = false;
                if (weak_self == null) return false;
                if (weak_self.disposed) return false;
                var message = weak_self.pending_message;
                weak_self.pending_message = null;
                if (weak_self.view != null && message != null) {
                    try {
                        weak_self.updateView (message, weak_self.model, weak_self.view);
                    } catch (Error e) {
                        // Ignore errors in view update
                    }
                }
                return false;
            });
        }
    }
}