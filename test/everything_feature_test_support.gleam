import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

pub fn app() -> server.Server {
  server.new(server_test_support.sample_client_info())
  |> server.set_logging_handler(fn(_) { Ok(Nil) })
}

pub fn empty_capabilities() -> actions.ClientCapabilities {
  actions.ClientCapabilities(None, None, None, None, None)
}

pub fn ready_session(
  app: server.Server,
  capabilities: actions.ClientCapabilities,
) -> String {
  ready_identity_session(app, capabilities, None)
}

pub fn ready_identity_session(
  app: server.Server,
  capabilities: actions.ClientCapabilities,
  principal: Option(String),
) -> String {
  let id = server.ensure_streamable_http_session(app, None)
  server.bind_session(app, id, principal) |> should.be_true
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
            capabilities,
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

pub fn context(id: String) -> server.RequestContext {
  server.RequestContext(Some(id), None)
}

pub fn listen(
  app: server.Server,
  id: String,
) -> process.Subject(streamable_http_store.ListenerMessage) {
  let listener = process.new_subject()
  server.register_streamable_http_listener(
    app,
    id,
    server.new_streamable_http_listener_id(),
    listener,
  )
  listener
}

pub fn respond(
  app: server.Server,
  session: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  result: actions.ServerActionResult,
) -> Nil {
  server.handle_server_sent_response(
    app,
    context(session),
    codec.encode_server_response(jsonrpc.ResultResponse(
      request_id(request),
      result,
    )),
  )
  |> should.be_ok
}

pub fn text(result: actions.CallToolResult) -> String {
  let assert [actions.TextBlock(actions.TextContent(value, _, _))] =
    result.content
  value
}

pub fn task(id: String, status: actions.TaskStatus) -> actions.Task {
  actions.Task(
    id,
    status,
    None,
    "2026-10-05T00:00:00.000Z",
    "2026-10-05T00:00:00.000Z",
    Some(600_000),
    Some(1000),
  )
}

pub fn drain(
  listener: process.Subject(streamable_http_store.ListenerMessage),
) -> Nil {
  case process.receive(listener, 0) {
    Ok(_) -> drain(listener)
    Error(_) -> Nil
  }
}

pub fn action(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> Option(actions.ServerActionRequest) {
  let assert jsonrpc.Request(_, _, action) = request
  action
}

fn request_id(request: jsonrpc.Request(a)) -> jsonrpc.RequestId {
  let assert jsonrpc.Request(id, _, _) = request
  id
}
