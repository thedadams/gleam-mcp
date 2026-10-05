import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/events
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store as store
import gleeunit/should

pub fn replay_restores_and_filters_the_original_stream_within_its_session_test() {
  let history = events.new()
  let adapter = events.adapter(history)
  let assert server.ResumableLegacyEventStore(resume: resume, ..) = adapter
  let origin = adapter.record("session", "tool", "")
  let _ = adapter.record("session", "notifications", "other-stream")
  let first = adapter.record("session", "tool", "progress")
  let _ = adapter.record("other-session", "tool", "other-session")
  let final = adapter.record("session", "tool", "final")
  should.equal(resume("session", origin), Some("tool"))
  should.equal(resume("other-session", origin), None)
  should.equal(adapter.replay("session", origin), [
    #(first, "progress"),
    #(final, "final"),
  ])
  should.equal(adapter.replay("session", first), [#(final, "final")])
  should.equal(adapter.replay("session", "unknown"), [])
  events.close_session(history, "session")
  should.equal(resume("session", origin), None)
  should.equal(adapter.replay("session", origin), [])
  events.stop(history)
}

pub fn final_responses_route_to_the_resumed_stream_and_old_cleanup_cannot_detach_it_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let original = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let listener = process.new_subject()
      let release = process.new_subject()
      process.send(original, #(listener, release, process.self()))
      process.receive(release, 1000) |> should.be_ok
    })
  let #(old_listener, release, old_owner) =
    process.receive(original, 1000) |> should.be_ok
  store.register_listener(app, session, "tool", old_listener)
  let resumed = process.new_subject()
  store.register_listener(app, session, "tool", resumed)
  let unrelated = process.new_subject()
  store.register_listener(app, session, "notifications", unrelated)
  store.unregister_listener_owned(app, session, "tool", old_owner)
  let recorded = process.new_subject()
  store.send_stream_response(
    app,
    session,
    "tool",
    "result",
    Some(fn(stream, payload) {
      process.send(recorded, #(stream, payload))
      "final-id"
    }),
  )
  should.equal(process.receive(recorded, 1000), Ok(#("tool", "result")))
  should.equal(
    process.receive(resumed, 1000),
    Ok(store.DeliverReplay("final-id", "result", True)),
  )
  should.equal(process.receive(unrelated, 0), Error(Nil))
  process.send(release, Nil)
  store.delete_session(app, session)
}

pub fn notifications_are_recorded_under_the_chosen_live_stream_and_only_delivered_once_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let first = process.new_subject()
  let chosen = process.new_subject()
  store.register_listener(app, session, "earlier", first)
  store.register_listener(app, session, "active-tool", chosen)
  let recorded = process.new_subject()
  store.send_notification_with_recorder(
    app,
    session,
    notification(),
    Some(fn(stream, payload) {
      process.send(recorded, #(stream, payload))
      "notification-id"
    }),
  )
  let #(stream, payload) = process.receive(recorded, 1000) |> should.be_ok
  should.equal(stream, "active-tool")
  should.equal(
    process.receive(chosen, 1000),
    Ok(store.DeliverReplay("notification-id", payload, False)),
  )
  should.equal(process.receive(first, 0), Error(Nil))
  store.delete_session(app, session)
}

pub fn queued_reverse_requests_are_recorded_before_wire_delivery_and_not_recorded_again_on_resume_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let history = events.new()
  let adapter = events.adapter(history)
  let origin = adapter.record(session, "tool", "")
  let recorded = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let outcome =
        store.send_request_with_recorder(
          app,
          session,
          jsonrpc.Request(
            jsonrpc.StringId("reverse"),
            mcp.method_ping,
            Some(actions.ServerRequestPing(None)),
          ),
          1000,
          Some(fn(stream, payload) {
            let id = adapter.record(session, stream, payload)
            process.send(recorded, #(id, payload))
            id
          }),
        )
      process.send(finished, outcome)
    })
  should.equal(process.receive(recorded, 5), Error(Nil))
  let original = process.new_subject()
  store.register_listener(app, session, "tool", original)
  let #(id, payload) = process.receive(recorded, 1000) |> should.be_ok
  // No SSE actor has consumed the delivery yet; a reconnect snapshot already
  // contains the request and replacing the listener cannot lose it.
  should.equal(adapter.replay(session, origin), [#(id, payload)])
  let resumed = process.new_subject()
  store.register_listener(app, session, "tool", resumed)
  should.equal(adapter.replay(session, origin), [#(id, payload)])
  should.equal(process.receive(recorded, 0), Error(Nil))
  should.equal(process.receive(resumed, 0), Error(Nil))
  store.resolve_response(
    app,
    session,
    "{\"jsonrpc\":\"2.0\",\"id\":\"reverse\",\"result\":{}}",
  )
  |> should.be_ok
  process.receive(finished, 1000) |> should.be_ok |> should.be_ok
  store.delete_session(app, session)
  events.stop(history)
}

pub fn events_without_a_listener_are_retained_but_closed_sessions_do_not_recreate_history_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let recorded = process.new_subject()
  let recorder =
    Some(fn(stream, payload) {
      process.send(recorded, #(stream, payload))
      "event"
    })
  store.send_notification_with_recorder(app, session, notification(), recorder)
  let #(stream, _) = process.receive(recorded, 1000) |> should.be_ok
  should.equal(stream, "notifications")
  store.send_stream_response(app, session, "detached-tool", "result", recorder)
  should.equal(
    process.receive(recorded, 1000),
    Ok(#("detached-tool", "result")),
  )
  store.delete_session(app, session)
  store.send_notification_with_recorder(app, session, notification(), recorder)
  store.send_stream_response(app, session, "detached-tool", "late", recorder)
  should.be_false(store.has_session(app, session))
  should.equal(process.receive(recorded, 0), Error(Nil))
}

fn notification() -> jsonrpc.Request(actions.ActionNotification) {
  jsonrpc.Notification(
    mcp.method_notify_tools_list_changed,
    Some(actions.NotifyToolListChanged(None)),
  )
}
