import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/examples/everything/sse
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/examples/everything/tools
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec as server_codec
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

pub fn deprecated_sse_keeps_one_session_for_multiple_results_test() {
  let app = base_server()
  let store = sse.new(app)
  let listener = process.new_subject()
  let id = sse.attach(store, listener)
  should.equal(sse.endpoint(id), "/message?sessionId=" <> id)
  should.equal(
    process.receive(listener, 1000),
    Ok(streamable_http_store.DeliverResponse("")),
  )
  initialize(
    store,
    id,
    listener,
    actions.ClientCapabilities(None, None, None, None, None),
  )
  let ping = rpc("ping-one", "ping", actions.ClientRequestPing(None))
  sse.receive_message(store, id, client_codec.encode_request(ping))
  |> should.be_ok
  let result = reply(listener, ping)
  should.equal(
    result,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("ping-one"),
      actions.ClientResultEmpty(None),
    ),
  )
  let ping = rpc("ping-two", "ping", actions.ClientRequestPing(None))
  sse.receive_message(store, id, client_codec.encode_request(ping))
  |> should.be_ok
  reply(listener, ping)
  |> should.equal(jsonrpc.ResultResponse(
    jsonrpc.StringId("ping-two"),
    actions.ClientResultEmpty(None),
  ))
  should.be_true(server.has_streamable_http_session(app, id))
  sse.close_session(store, id)
  should.equal(
    process.receive(listener, 1000),
    Ok(streamable_http_store.CloseListener),
  )
  should.be_false(server.has_streamable_http_session(app, id))
  should.equal(
    sse.receive_message(store, id, client_codec.encode_request(ping)),
    Error(#(404, "Unknown SSE session")),
  )
  sse.stop(store)
}

pub fn deprecated_sse_routes_server_requests_and_posted_client_responses_test() {
  let app = base_server()
  let store = sse.new(app)
  let listener = process.new_subject()
  let id = sse.attach(store, listener)
  process.receive(listener, 1000) |> should.be_ok
  initialize(
    store,
    id,
    listener,
    actions.ClientCapabilities(
      None,
      Some(actions.ClientRootsCapabilities(Some(True))),
      None,
      None,
      None,
    ),
  )
  let completion = process.new_subject()
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("roots"),
      "roots/list",
      Some(actions.ServerRequestListRoots(None)),
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        completion,
        server.send_request(app, server.RequestContext(Some(id), None), request),
      )
    })
  should.equal(
    process.receive(listener, 1000),
    Ok(streamable_http_store.DeliverRequest(request)),
  )
  let result =
    actions.ServerResultListRoots(actions.ListRootsResult(
      [actions.Root("file:///workspace", Some("Workspace"), None)],
      None,
    ))
  sse.receive_message(
    store,
    id,
    server_codec.encode_server_response(jsonrpc.ResultResponse(
      jsonrpc.StringId("roots"),
      result,
    )),
  )
  |> should.be_ok
  should.equal(
    process.receive(completion, 1000),
    Ok(Ok(jsonrpc.ResultResponse(jsonrpc.StringId("roots"), result))),
  )
  sse.close_session(store, id)
  sse.stop(store)
}

pub fn deprecated_sse_disconnect_closes_session_and_pending_server_request_test() {
  let closed = process.new_subject()
  let app =
    base_server()
    |> server.with_session_close_handler(fn(id) { process.send(closed, id) })
  let store = sse.new(app)
  let created = process.new_subject()
  let delivered = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let listener = process.new_subject()
      let id = sse.attach(store, listener)
      process.receive(listener, 1000) |> should.be_ok
      initialize(
        store,
        id,
        listener,
        actions.ClientCapabilities(
          None,
          Some(actions.ClientRootsCapabilities(None)),
          None,
          None,
          None,
        ),
      )
      process.send(created, #(id, listener))
      process.send(delivered, process.receive_forever(listener))
      process.sleep_forever()
    })
  let #(id, _) = process.receive(created, 1000) |> should.be_ok
  let pending = process.new_subject()
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("pending-roots"),
      "roots/list",
      Some(actions.ServerRequestListRoots(None)),
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        pending,
        server.send_request(app, server.RequestContext(Some(id), None), request),
      )
    })
  should.equal(
    process.receive(delivered, 1000),
    Ok(streamable_http_store.DeliverRequest(request)),
  )
  // Closing the socket-owner process must clean up even without a loop callback.
  process.kill(owner)
  should.equal(process.receive(closed, 1000), Ok(id))
  process.receive(pending, 1000) |> should.be_ok |> should.be_error
  should.be_false(server.has_streamable_http_session(app, id))
  should.equal(
    sse.receive_message(
      store,
      id,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
    ),
    Error(#(404, "Unknown SSE session")),
  )
  sse.stop(store)
}

pub fn deprecated_sse_valid_envelopes_report_method_errors_on_stream_test() {
  let app = base_server()
  let store = sse.new(app)
  let listener = process.new_subject()
  let id = sse.attach(store, listener)
  process.receive(listener, 1000) |> should.be_ok
  sse.receive_message(
    store,
    id,
    "{\"jsonrpc\":\"2.0\",\"id\":\"unknown\",\"method\":\"unknown-method\"}",
  )
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverResponse(body)) =
    process.receive(listener, 1000)
  should.be_true(string.contains(body, "-32601"))
  should.be_true(string.contains(body, "\"id\":\"unknown\""))
  sse.receive_message(
    store,
    id,
    "{\"jsonrpc\":\"2.0\",\"id\":\"invalid\",\"method\":\"tools/call\",\"params\":{}}",
  )
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverResponse(body)) =
    process.receive(listener, 1000)
  should.be_true(string.contains(body, "-32602"))
  sse.receive_message(store, id, "{not json}") |> should.be_error
  sse.receive_message(
    store,
    id,
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
  )
  |> should.be_error
  sse.close_session(store, id)
  sse.stop(store)
}

pub fn deprecated_sse_cancellation_is_registered_before_post_acknowledgment_test() {
  let app =
    base_server()
    |> server.register_tool_descriptor(
      helpers.descriptor(
        "wait",
        "Wait",
        "Wait until cancelled",
        helpers.empty_schema(),
        None,
        helpers.interactive_annotations(False),
      ),
      fn(_) {
        process.sleep_forever()
        Ok(helpers.text_result("unreachable"))
      },
    )
  let store = sse.new(app)
  let listener = process.new_subject()
  let id = sse.attach(store, listener)
  process.receive(listener, 1000) |> should.be_ok
  initialize(
    store,
    id,
    listener,
    actions.ClientCapabilities(None, None, None, None, None),
  )
  let request =
    rpc(
      "wait",
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "wait",
        None,
        None,
        None,
      )),
    )
  sse.receive_message(store, id, client_codec.encode_request(request))
  |> should.be_ok
  let cancellation =
    jsonrpc.Notification(
      "notifications/cancelled",
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(jsonrpc.StringId("wait")),
          None,
          None,
        )),
      ),
    )
  sse.receive_message(store, id, client_codec.encode_notification(cancellation))
  |> should.be_ok
  let assert jsonrpc.ErrorResponse(Some(jsonrpc.StringId("wait")), error) =
    reply(listener, request)
  should.equal(error.message, "Request cancelled")
  sse.close_session(store, id)
  sse.stop(store)
}

fn base_server() -> server.Server {
  server.new(server_test_support.sample_client_info())
  |> tools.register_base_tools(None)
}

fn rpc(
  id: String,
  method: String,
  action: actions.ClientActionRequest,
) -> jsonrpc.Request(actions.ClientActionRequest) {
  jsonrpc.Request(jsonrpc.StringId(id), method, Some(action))
}

fn initialize(
  store: sse.Store,
  id: String,
  listener: process.Subject(streamable_http_store.ListenerMessage),
  caps: actions.ClientCapabilities,
) -> Nil {
  let request =
    rpc(
      "initialize",
      "initialize",
      actions.ClientRequestInitialize(actions.InitializeRequestParams(
        jsonrpc.legacy_protocol_version,
        caps,
        server_test_support.sample_client_info(),
        None,
      )),
    )
  sse.receive_message(store, id, client_codec.encode_request(request))
  |> should.be_ok
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(_)) =
    reply(listener, request)
  sse.receive_message(
    store,
    id,
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
  |> should.be_ok
}

fn reply(
  listener: process.Subject(streamable_http_store.ListenerMessage),
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> jsonrpc.Response(actions.ClientActionResult) {
  let assert Ok(streamable_http_store.DeliverResponse(body)) =
    process.receive(listener, 1000)
  client_codec.decode_response(body, request) |> should.be_ok
}
