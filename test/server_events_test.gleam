import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

pub fn subscriptions_deliver_once_and_stop_after_unsubscribe_or_close_test() {
  let app = resource_server() |> server.with_resource_subscriptions
  let subscribed = ready_session(app)
  let unrelated = ready_session(app)
  let first = process.new_subject()
  let second = process.new_subject()
  let unrelated_listener = process.new_subject()
  listen(app, subscribed, first)
  listen(app, subscribed, second)
  listen(app, unrelated, unrelated_listener)
  let selector =
    process.new_selector() |> process.select(first) |> process.select(second)

  subscribe(app, subscribed, True)
  server.notify_resource_updated(app, "file:///resource.txt")
  should.equal(
    process.selector_receive(selector, 1000),
    Ok(streamable_http_store.DeliverNotification(updated_notification())),
  )
  should.equal(process.selector_receive(selector, 20), Error(Nil))
  should.equal(process.receive(unrelated_listener, 20), Error(Nil))

  subscribe(app, subscribed, False)
  server.notify_resource_updated(app, "file:///resource.txt")
  should.equal(process.selector_receive(selector, 20), Error(Nil))

  subscribe(app, subscribed, True)
  server.close_session(app, subscribed)
  should.equal(
    process.selector_receive(selector, 1000),
    Ok(streamable_http_store.CloseListener),
  )
  should.equal(
    process.selector_receive(selector, 1000),
    Ok(streamable_http_store.CloseListener),
  )
  server.notify_resource_updated(app, "file:///resource.txt")
  should.equal(process.selector_receive(selector, 20), Error(Nil))
  should.equal(process.receive(unrelated_listener, 20), Error(Nil))
  should.be_false(server.has_streamable_http_session(app, subscribed))
  server.close_session(app, unrelated)
}

pub fn dead_newest_listener_falls_back_to_older_live_listener_test() {
  let store = streamable_http_store.new()
  let session = streamable_http_store.ensure_session(store, None)
  let first = process.new_subject()
  streamable_http_store.register_listener(store, session, "older", first)
  let registered = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let listener = process.new_subject()
      process.send(registered, listener)
      let _ = process.receive_forever(listener)
      Nil
    })
  let second = process.receive(registered, 1000) |> should.be_ok
  streamable_http_store.register_listener(store, session, "newer", second)
  let monitor = process.monitor(worker)
  process.kill(worker)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let _ = process.selector_receive(selector, 1000) |> should.be_ok

  let notification = updated_notification()
  streamable_http_store.send_notification(store, session, notification)
  should.equal(
    process.receive(first, 1000),
    Ok(streamable_http_store.DeliverNotification(notification)),
  )
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("ping-live-listener"),
      mcp.method_ping,
      Some(actions.ServerRequestPing(None)),
    )
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        reply,
        streamable_http_store.send_request(store, session, request, 1000),
      )
    })
  should.equal(
    process.receive(first, 1000),
    Ok(streamable_http_store.DeliverRequest(request)),
  )
  streamable_http_store.resolve_response(
    store,
    session,
    "{\"jsonrpc\":\"2.0\",\"id\":\"ping-live-listener\",\"result\":{}}",
  )
  |> should.be_ok
  should.equal(
    process.receive(reply, 1000),
    Ok(
      Ok(jsonrpc.ResultResponse(
        jsonrpc.StringId("ping-live-listener"),
        actions.ServerResultEmpty(None),
      )),
    ),
  )
  should.equal(process.receive(first, 20), Error(Nil))
  streamable_http_store.delete_session(store, session)
  should.equal(
    process.receive(first, 1000),
    Ok(streamable_http_store.CloseListener),
  )
}

pub fn subscriptions_require_capability_and_known_resource_test() {
  let app = resource_server()
  let session = ready_session(app)
  let #(_, unsupported) =
    server.handle_request_with_context(
      app,
      context(session),
      subscription_request("file:///resource.txt", True),
    )
  should.equal(
    response_error(unsupported).code,
    jsonrpc.method_not_found_error_code,
  )
  let enabled = app |> server.with_resource_subscriptions
  let #(_, unknown) =
    server.handle_request_with_context(
      enabled,
      context(session),
      subscription_request("file:///unknown.txt", True),
    )
  should.equal(response_error(unknown).code, jsonrpc.invalid_params_error_code)
  server.close_session(app, session)
}

pub fn progress_uses_request_token_and_delivers_to_one_listener_test() {
  let app = resource_server()
  let session = ready_session(app)
  let first = process.new_subject()
  let second = process.new_subject()
  listen(app, session, first)
  listen(app, session, second)
  let selector =
    process.new_selector() |> process.select(first) |> process.select(second)
  server.report_progress(
    app,
    context(session),
    1.0,
    Some(10.0),
    Some("working"),
  )
  |> should.be_ok
  should.equal(process.selector_receive(selector, 20), Error(Nil))
  let token = jsonrpc.StringId("progress-token")
  let request_context =
    server.RequestContextWithMeta(
      Some(session),
      None,
      jsonrpc.IntId(1),
      Some(actions.RequestMeta(Some(token), None)),
    )
  server.report_progress(app, request_context, 1.0, Some(10.0), Some("working"))
  |> should.be_ok
  let expected =
    jsonrpc.Notification(
      mcp.method_notify_progress,
      Some(
        actions.NotifyProgress(actions.ProgressNotificationParams(
          token,
          1.0,
          Some(10.0),
          Some("working"),
          None,
        )),
      ),
    )
  should.equal(
    process.selector_receive(selector, 1000),
    Ok(streamable_http_store.DeliverNotification(expected)),
  )
  should.equal(process.selector_receive(selector, 20), Error(Nil))
  server.close_session(app, session)
}

pub fn list_changed_notifications_require_advertised_flags_and_deliver_once_test() {
  let app =
    resource_server()
    |> server.with_capabilities(list_changed_capabilities(False))
  let session = ready_session(app)
  let first = process.new_subject()
  let second = process.new_subject()
  listen(app, session, first)
  listen(app, session, second)
  let selector =
    process.new_selector() |> process.select(first) |> process.select(second)
  let notifications = [
    jsonrpc.Notification(
      mcp.method_notify_resource_list_changed,
      Some(actions.NotifyResourceListChanged(None)),
    ),
    jsonrpc.Notification(
      mcp.method_notify_prompts_list_changed,
      Some(actions.NotifyPromptListChanged(None)),
    ),
    jsonrpc.Notification(
      mcp.method_notify_tools_list_changed,
      Some(actions.NotifyToolListChanged(None)),
    ),
  ]
  list.each(notifications, fn(notification) {
    let error =
      server.send_notification(app, context(session), notification)
      |> should.be_error
    should.equal(error.code, jsonrpc.method_not_found_error_code)
  })
  should.equal(process.selector_receive(selector, 20), Error(Nil))
  let enabled = app |> server.with_capabilities(list_changed_capabilities(True))
  list.each(notifications, fn(notification) {
    server.send_notification(enabled, context(session), notification)
    |> should.be_ok
    should.equal(
      process.selector_receive(selector, 1000),
      Ok(streamable_http_store.DeliverNotification(notification)),
    )
    should.equal(process.selector_receive(selector, 20), Error(Nil))
  })
  server.close_session(app, session)
}

fn resource_server() -> server.Server {
  server.new(server_test_support.sample_client_info())
  |> server.register_resource_descriptor(
    actions.Resource(
      "file:///resource.txt",
      "resource",
      None,
      None,
      Some("text/plain"),
      None,
      None,
      [],
      None,
    ),
    fn() { Ok([]) },
  )
}

fn ready_session(app: server.Server) -> String {
  let id = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, id, None))
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context(id),
      jsonrpc.Request(
        jsonrpc.StringId("initialize"),
        mcp.method_initialize,
        Some(
          actions.ClientRequestInitialize(actions.InitializeRequestParams(
            jsonrpc.legacy_protocol_version,
            actions.ClientCapabilities(None, None, None, None, None),
            server_test_support.sample_client_info(),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(_)) =
    response
  server.handle_notification_with_context(
    app,
    context(id),
    jsonrpc.Notification(
      mcp.method_initialized,
      Some(actions.NotifyInitialized(None)),
    ),
  )
  |> should.be_ok
  id
}

fn context(id: String) -> server.RequestContext {
  server.RequestContext(Some(id), None)
}

fn listen(
  app: server.Server,
  session: String,
  listener: process.Subject(streamable_http_store.ListenerMessage),
) -> Nil {
  server.register_streamable_http_listener(
    app,
    session,
    server.new_streamable_http_listener_id(),
    listener,
  )
}

fn subscription_request(
  uri: String,
  enabled: Bool,
) -> jsonrpc.Request(actions.ClientActionRequest) {
  case enabled {
    True ->
      jsonrpc.Request(
        jsonrpc.StringId("subscribe"),
        mcp.method_subscribe_resource,
        Some(
          actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
            uri,
            None,
          )),
        ),
      )
    False ->
      jsonrpc.Request(
        jsonrpc.StringId("unsubscribe"),
        mcp.method_unsubscribe_resource,
        Some(
          actions.ClientRequestUnsubscribeResource(
            actions.UnsubscribeRequestParams(uri, None),
          ),
        ),
      )
  }
}

fn subscribe(app: server.Server, session: String, enabled: Bool) -> Nil {
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context(session),
      subscription_request("file:///resource.txt", enabled),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = response
  Nil
}

fn updated_notification() -> jsonrpc.Request(actions.ActionNotification) {
  jsonrpc.Notification(
    mcp.method_notify_resource_updated,
    Some(
      actions.NotifyResourceUpdated(actions.ResourceUpdatedNotificationParams(
        "file:///resource.txt",
        None,
      )),
    ),
  )
}

fn response_error(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> jsonrpc.RpcError {
  let assert jsonrpc.ErrorResponse(_, error) = response
  error
}

fn list_changed_capabilities(enabled: Bool) -> actions.ServerCapabilities {
  actions.ServerCapabilities(
    None,
    None,
    None,
    Some(actions.ServerPromptsCapabilities(Some(enabled))),
    Some(actions.ServerResourcesCapabilities(None, Some(enabled))),
    Some(actions.ServerToolsCapabilities(Some(enabled))),
    None,
  )
}
