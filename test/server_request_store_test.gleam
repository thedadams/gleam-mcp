import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/streamable_http_store as store
import gleeunit/should

pub fn main() {
  duplicate_active_ids_preserve_the_first_waiter_test()
  timeout_removes_queued_request_before_listener_registration_test()
  missing_and_closed_sessions_are_not_recreated_by_outgoing_requests_test()
  closing_a_session_releases_its_pending_request_test()
  stopped_callers_cancel_their_pending_children_test()
  completed_request_timer_cannot_expire_a_reused_id_test()
}

pub fn duplicate_active_ids_preserve_the_first_waiter_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let listener = process.new_subject()
  store.register_listener(app, session, "listener", listener)
  let first = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(first, store.send_request(app, session, ping("same"), 1000))
    })
  should.equal(
    process.receive(listener, 1000),
    Ok(store.DeliverRequest(ping("same"))),
  )
  let duplicate = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        duplicate,
        store.send_request(app, session, ping("same"), 1000),
      )
    })
  process.receive(duplicate, 100) |> should.be_ok |> should.be_error
  should.equal(process.receive(first, 5), Error(Nil))
  should.equal(process.receive(listener, 5), Error(Nil))
  store.resolve_response(app, session, ping_response("same")) |> should.be_ok
  let response = process.receive(first, 1000) |> should.be_ok |> should.be_ok
  should.equal(
    response,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("same"),
      actions.ServerResultEmpty(None),
    ),
  )
  store.delete_session(app, session)
}

pub fn timeout_removes_queued_request_before_listener_registration_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  store.send_request(app, session, ping("expired"), 10) |> should.be_error
  let listener = process.new_subject()
  store.register_listener(app, session, "listener", listener)
  should.equal(process.receive(listener, 10), Error(Nil))
  should.be_true(store.has_session(app, session))
  store.resolve_response(app, session, ping_response("expired"))
  |> should.be_error
  store.delete_session(app, session)
}

pub fn missing_and_closed_sessions_are_not_recreated_by_outgoing_requests_test() {
  let app = store.new()
  assert_session_stays_missing(app, "missing")
  let session = store.ensure_session(app, None)
  store.delete_session(app, session)
  assert_session_stays_missing(app, session)
}

pub fn closing_a_session_releases_its_pending_request_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let listener = process.new_subject()
  store.register_listener(app, session, "listener", listener)
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        store.send_request(app, session, ping("pending"), 1000),
      )
    })
  process.receive(listener, 1000) |> should.be_ok
  store.delete_session(app, session)
  process.receive(reply, 100) |> should.be_ok |> should.be_error
  should.equal(process.receive(listener, 1000), Ok(store.CloseListener))
  should.be_false(store.has_session(app, session))
  assert_session_stays_missing(app, session)
}

pub fn stopped_callers_cancel_their_pending_children_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let listener = process.new_subject()
  store.register_listener(app, session, "listener", listener)
  let caller =
    process.spawn_unlinked(fn() {
      let request =
        jsonrpc.Request(
          jsonrpc.StringId("child"),
          mcp.method_ping,
          Some(
            actions.ServerRequestPing(
              Some(actions.RequestMeta(
                Some(jsonrpc.StringId("progress")),
                Some(
                  actions.Meta(
                    dict.from_list([
                      #(
                        "io.modelcontextprotocol/related-task",
                        jsonrpc.VObject([
                          #("taskId", jsonrpc.VString("parent-task")),
                        ]),
                      ),
                      #("trace", jsonrpc.VString("request-trace")),
                    ]),
                  ),
                ),
              )),
            ),
          ),
        )
      let _ = store.send_request(app, session, request, 60_000)
      Nil
    })
  process.receive(listener, 1000) |> should.be_ok
  process.kill(caller)
  let assert store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyCancelled(params)),
  )) = process.receive(listener, 1000) |> should.be_ok
  should.equal(params.request_id, Some(jsonrpc.StringId("child")))
  should.equal(
    params.meta,
    Some(
      actions.NotificationMeta(
        Some(
          actions.Meta(
            dict.from_list([
              #(
                "io.modelcontextprotocol/related-task",
                jsonrpc.VObject([#("taskId", jsonrpc.VString("parent-task"))]),
              ),
            ]),
          ),
        ),
      ),
    ),
  )
  store.resolve_response(app, session, ping_response("child"))
  |> should.be_error
  store.delete_session(app, session)
}

pub fn completed_request_timer_cannot_expire_a_reused_id_test() {
  let app = store.new()
  let session = store.ensure_session(app, None)
  let listener = process.new_subject()
  store.register_listener(app, session, "listener", listener)
  let first = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(first, store.send_request(app, session, ping("reuse"), 50))
    })
  process.receive(listener, 1000) |> should.be_ok
  store.resolve_response(app, session, ping_response("reuse")) |> should.be_ok
  process.receive(first, 1000) |> should.be_ok |> should.be_ok
  let second = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        second,
        store.send_request(app, session, ping("reuse"), 1000),
      )
    })
  process.receive(listener, 1000) |> should.be_ok
  should.equal(process.receive(second, 80), Error(Nil))
  should.equal(process.receive(listener, 5), Error(Nil))
  store.resolve_response(app, session, ping_response("reuse")) |> should.be_ok
  process.receive(second, 1000) |> should.be_ok |> should.be_ok
  store.delete_session(app, session)
}

fn assert_session_stays_missing(app: store.Store, session: String) -> Nil {
  store.send_request(app, session, ping("closed"), 50) |> should.be_error
  should.be_false(store.has_session(app, session))
  store.metadata(app, session) |> should.be_none
  let listener = process.new_subject()
  store.register_listener(app, session, "new-listener", listener)
  should.equal(process.receive(listener, 1000), Ok(store.CloseListener))
  store.send_notification(
    app,
    session,
    jsonrpc.Notification(
      mcp.method_notify_cancelled,
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(jsonrpc.StringId("closed")),
          None,
          None,
        )),
      ),
    ),
  )
  should.be_false(store.has_session(app, session))
}

fn ping(id: String) -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId(id),
    mcp.method_ping,
    Some(actions.ServerRequestPing(None)),
  )
}

fn ping_response(id: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\"" <> id <> "\",\"result\":{}}"
}
