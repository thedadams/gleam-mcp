import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

pub fn http_logger_delivers_to_the_handler_session_test() {
  let #(app, _) = everything_server.make_http_server()
  let session = ready_session(app)
  let unrelated = ready_session(app)
  let listener = process.new_subject()
  let unrelated_listener = process.new_subject()
  listen(app, session, listener)
  listen(app, unrelated, unrelated_listener)

  toggle(app, session)
  |> string.contains("Started simulated")
  |> should.be_true
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    method,
    Some(actions.NotifyLoggingMessage(actions.LoggingMessageNotificationParams(
      actions.Debug,
      Some("gleam-mcp/everything"),
      jsonrpc.VString(message),
      None,
    ))),
  ))) = process.receive(listener, within: 6500)
  should.equal(method, mcp.method_notify_logging_message)
  string.is_empty(message) |> should.be_false
  process.receive(unrelated_listener, within: 0) |> should.be_error
  toggle(app, session)
  |> string.contains("Stopped simulated")
  |> should.be_true
  server.close_session(app, session)
  server.close_session(app, unrelated)
}

fn toggle(app: server.Server, session: String) -> String {
  let #(_, response) =
    server.handle_request_with_context(
      app,
      server.RequestContext(Some(session), None),
      jsonrpc.Request(
        jsonrpc.StringId("toggle"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "toggle-simulated-logging",
            None,
            None,
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultCallTool(actions.CallToolResult(
      [actions.TextBlock(actions.TextContent(text, _, _))],
      _,
      Some(False),
      _,
    )),
  ) = response
  text
}

fn ready_session(app: server.Server) -> String {
  let session = server.ensure_streamable_http_session(app, None)
  server.bind_session(app, session, None) |> should.be_true
  let context = server.RequestContext(Some(session), None)
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
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
    context,
    jsonrpc.Notification(
      mcp.method_initialized,
      Some(actions.NotifyInitialized(None)),
    ),
  )
  |> should.be_ok
  session
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
