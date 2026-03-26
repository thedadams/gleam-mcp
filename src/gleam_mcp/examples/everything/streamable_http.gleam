import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import mist

// 1 MiB
const default_max_body_bytes = 1_048_576

type Logger {
  Logger(subject: process.Subject(LoggerMessage))
}

type LoggerMessage {
  Toggle(session_id: String, reply_to: process.Subject(Bool))
  SetLevel(session_id: String, level: actions.LoggingLevel)
}

type SessionLogger {
  SessionLogger(enabled: Bool, minimum_level: actions.LoggingLevel, tick: Int)
}

pub fn handler(
  app_server: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body(app_server, default_max_body_bytes)
}

pub fn handler_with_max_body(
  app_server: server.Server,
  max_body_bytes: Int,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  let logger = new_logger(app_server)
  fn(req) { handle(app_server, logger, req, max_body_bytes) }
}

fn handle(
  app_server: server.Server,
  logger: Logger,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
) -> response.Response(mist.ResponseData) {
  case authorize_request(app_server, req) {
    False -> plain_response(401, "Unauthorized")
    True -> {
      let request.Request(method: method, ..) = req

      case method {
        http.Get -> handle_get(app_server, req)
        http.Post -> handle_post(app_server, logger, req, max_body_bytes)
        _ -> plain_response(405, "Method Not Allowed")
      }
    }
  }
}

fn handle_get(
  app_server: server.Server,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case require_existing_session(app_server, request_session_id(req)) {
    Ok(session_id) -> {
      let listener_id = server.new_streamable_http_listener_id()

      mist.server_sent_events(
        request: req,
        initial_response: response.new(200)
          |> response.set_header(
            "mcp-protocol-version",
            jsonrpc.latest_protocol_version,
          )
          |> response.set_header("mcp-session-id", session_id),
        init: fn(listener) {
          server.register_streamable_http_listener(
            app_server,
            session_id,
            listener_id,
            listener,
          )
          SseState(app_server, session_id, listener_id)
        },
        loop: handle_sse_message,
      )
    }
    Error(Nil) -> plain_response(404, "Unknown MCP session")
  }
}

fn authorize_request(
  app_server: server.Server,
  req: request.Request(mist.Connection),
) -> Bool {
  case server.header_authorization(app_server) {
    None -> True
    Some(server.HeaderAuthorization(header, validate)) ->
      case request.get_header(req, header) {
        Ok(value) -> validate(value)
        Error(_) -> False
      }
  }
}

fn handle_post(
  app_server: server.Server,
  logger: Logger,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
) -> response.Response(mist.ResponseData) {
  case has_json_content_type(req) {
    False -> plain_response(415, "Expected application/json request body")
    True ->
      case mist.read_body(req, max_body_bytes) {
        Ok(body_request) ->
          case bit_array.to_string(body_request.body) {
            Ok(body) ->
              handle_post_body(
                app_server,
                logger,
                body,
                request_session_id(req),
              )
            Error(_) -> plain_response(400, "Request body was not valid UTF-8")
          }
        Error(_) -> plain_response(400, "Unable to read request body")
      }
  }
}

fn handle_post_body(
  app_server: server.Server,
  logger: Logger,
  body: String,
  requested_session_id: Option(String),
) -> response.Response(mist.ResponseData) {
  case codec.decode_message(body) {
    Ok(message) ->
      case session_id_for_message(app_server, requested_session_id, message) {
        Ok(session_id) -> handle_message(app_server, logger, body, session_id)
        Error(Nil) -> plain_response(404, "Unknown MCP session")
      }
    Error(_) ->
      case require_existing_session(app_server, requested_session_id) {
        Ok(session_id) -> handle_message(app_server, logger, body, session_id)
        Error(Nil) -> plain_response(404, "Unknown MCP session")
      }
  }
}

fn session_id_for_message(
  app_server: server.Server,
  requested_session_id: Option(String),
  message: codec.Message,
) -> Result(String, Nil) {
  case require_existing_session(app_server, requested_session_id) {
    Ok(session_id) -> Ok(session_id)
    Error(Nil) ->
      case is_initialize_message(message) {
        True -> Ok(initialize_session(app_server, requested_session_id))
        False -> Error(Nil)
      }
  }
}

fn require_existing_session(
  app_server: server.Server,
  requested_session_id: Option(String),
) -> Result(String, Nil) {
  case requested_session_id {
    Some(session_id) ->
      case server.has_streamable_http_session(app_server, session_id) {
        True -> Ok(session_id)
        False -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

fn initialize_session(
  app_server: server.Server,
  requested_session_id: Option(String),
) -> String {
  case require_existing_session(app_server, requested_session_id) {
    Ok(session_id) -> session_id
    Error(Nil) -> server.ensure_streamable_http_session(app_server, None)
  }
}

fn is_initialize_message(message: codec.Message) -> Bool {
  case message {
    codec.ClientActionRequest(jsonrpc.Request(
      _,
      _,
      Some(actions.ClientRequestInitialize(_)),
    )) -> True
    _ -> False
  }
}

fn handle_message(
  app_server: server.Server,
  logger: Logger,
  body: String,
  session_id: String,
) -> response.Response(mist.ResponseData) {
  let context = server.RequestContext(Some(session_id))

  case codec.decode_message(body) {
    Ok(codec.ClientActionRequest(message)) ->
      handle_client_request(app_server, logger, context, session_id, message)
    Ok(codec.ActionNotification(notification)) -> {
      let #(_, _) = server.handle_notification(app_server, notification)
      accepted_response(Some(session_id))
    }
    Ok(codec.UnknownRequest(id, method)) -> {
      let payload =
        codec.encode_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        ))
      json_response(200, payload, Some(session_id))
    }
    Ok(codec.UnknownNotification(_)) -> accepted_response(Some(session_id))
    Error(_message) ->
      case server.handle_server_sent_response(app_server, context, body) {
        Ok(Nil) -> accepted_response(Some(session_id))
        Error(jsonrpc.RpcError(message: response_error, ..)) ->
          plain_response(400, response_error)
      }
  }
}

fn handle_client_request(
  app_server: server.Server,
  logger: Logger,
  context: server.RequestContext,
  session_id: String,
  message: jsonrpc.Request(actions.ClientActionRequest),
) -> response.Response(mist.ResponseData) {
  case message {
    jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(params))) ->
      case params.name {
        "toggle-simulated-logging" ->
          logging_toggle_response(
            id,
            toggle_logger(logger, session_id),
            session_id,
          )
        _ -> delegate_request(app_server, context, message, session_id)
      }
    jsonrpc.Request(_, _, Some(actions.ClientRequestSetLoggingLevel(params))) -> {
      let actions.SetLevelRequestParams(level, _) = params
      set_logger_level(logger, session_id, level)
      delegate_request(app_server, context, message, session_id)
    }
    _ -> delegate_request(app_server, context, message, session_id)
  }
}

fn delegate_request(
  app_server: server.Server,
  context: server.RequestContext,
  message: jsonrpc.Request(actions.ClientActionRequest),
  session_id: String,
) -> response.Response(mist.ResponseData) {
  let #(_, rpc_response) =
    server.handle_request_with_context(app_server, context, message)
  json_response(200, codec.encode_response(rpc_response), Some(session_id))
}

fn logging_toggle_response(
  id: jsonrpc.RequestId,
  enabled: Bool,
  session_id: String,
) -> response.Response(mist.ResponseData) {
  let text = case enabled {
    True ->
      "Started simulated, random-leveled logging for session "
      <> session_id
      <> " at a 5 second pace. Client's selected logging level will be respected."
    False -> "Stopped simulated logging for session " <> session_id
  }

  json_response(
    200,
    codec.encode_response(jsonrpc.ResultResponse(
      id,
      actions.ClientResultCallTool(actions.CallToolResult(
        content: [actions.TextBlock(actions.TextContent(text, None, None))],
        structured_content: None,
        is_error: Some(False),
        meta: None,
      )),
    )),
    Some(session_id),
  )
}

fn new_logger(app_server: server.Server) -> Logger {
  let reply_to = process.new_subject()
  let _ = process.spawn(fn() { start_logger(app_server, reply_to) })
  Logger(expect_ok(process.receive(reply_to, within: 1000)))
}

fn start_logger(
  app_server: server.Server,
  reply_to: process.Subject(process.Subject(LoggerMessage)),
) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  logger_loop(app_server, subject, dict.new())
}

fn logger_loop(
  app_server: server.Server,
  subject: process.Subject(LoggerMessage),
  sessions: dict.Dict(String, SessionLogger),
) -> Nil {
  case process.receive(subject, within: 5000) {
    Ok(Toggle(session_id, reply_to)) -> {
      let state = session_logger(sessions, session_id)
      let SessionLogger(enabled, minimum_level, tick) = state
      let next_enabled = !enabled
      process.send(reply_to, next_enabled)
      logger_loop(
        app_server,
        subject,
        dict.insert(
          sessions,
          session_id,
          SessionLogger(next_enabled, minimum_level, tick),
        ),
      )
    }
    Ok(SetLevel(session_id, level)) -> {
      let SessionLogger(enabled, _, tick) = session_logger(sessions, session_id)
      logger_loop(
        app_server,
        subject,
        dict.insert(sessions, session_id, SessionLogger(enabled, level, tick)),
      )
    }
    Error(Nil) ->
      logger_loop(app_server, subject, emit_logs(app_server, sessions))
  }
}

fn emit_logs(
  app_server: server.Server,
  sessions: dict.Dict(String, SessionLogger),
) -> dict.Dict(String, SessionLogger) {
  list.fold(
    over: dict.to_list(sessions),
    from: dict.new(),
    with: fn(acc, entry) {
      let #(session_id, SessionLogger(enabled, minimum_level, tick)) = entry
      case enabled {
        True -> {
          let level = logging_level_for_tick(tick)
          let _ = case
            logging_level_priority(level)
            >= logging_level_priority(minimum_level)
          {
            True ->
              server.send_notification(
                app_server,
                server.RequestContext(Some(session_id)),
                jsonrpc.Notification(
                  mcp.method_notify_logging_message,
                  Some(
                    actions.NotifyLoggingMessage(
                      actions.LoggingMessageNotificationParams(
                        level,
                        Some("gleam-mcp/everything"),
                        jsonrpc.VString(logging_message_for_tick(tick)),
                        None,
                      ),
                    ),
                  ),
                ),
              )
            False -> Ok(Nil)
          }
          dict.insert(
            acc,
            session_id,
            SessionLogger(True, minimum_level, tick + 1),
          )
        }
        False ->
          dict.insert(
            acc,
            session_id,
            SessionLogger(False, minimum_level, tick),
          )
      }
    },
  )
}

fn toggle_logger(logger: Logger, session_id: String) -> Bool {
  let Logger(subject) = logger
  let reply_to = process.new_subject()
  process.send(subject, Toggle(session_id, reply_to))
  expect_ok(process.receive(reply_to, within: 1000))
}

fn set_logger_level(
  logger: Logger,
  session_id: String,
  level: actions.LoggingLevel,
) -> Nil {
  let Logger(subject) = logger
  process.send(subject, SetLevel(session_id, level))
}

fn session_logger(
  sessions: dict.Dict(String, SessionLogger),
  session_id: String,
) -> SessionLogger {
  case dict.get(sessions, session_id) {
    Ok(state) -> state
    Error(Nil) -> SessionLogger(False, actions.Debug, 0)
  }
}

fn logging_level_for_tick(tick: Int) -> actions.LoggingLevel {
  case int.remainder(tick, 8) {
    Ok(0) -> actions.Debug
    Ok(1) -> actions.Info
    Ok(2) -> actions.Notice
    Ok(3) -> actions.Warning
    Ok(4) -> actions.Error
    Ok(5) -> actions.Critical
    Ok(6) -> actions.Alert
    _ -> actions.Emergency
  }
}

fn logging_level_priority(level: actions.LoggingLevel) -> Int {
  case level {
    actions.Debug -> 0
    actions.Info -> 1
    actions.Notice -> 2
    actions.Warning -> 3
    actions.Error -> 4
    actions.Critical -> 5
    actions.Alert -> 6
    actions.Emergency -> 7
  }
}

fn logging_message_for_tick(tick: Int) -> String {
  case int.remainder(tick, 4) {
    Ok(0) -> "Simulated Everything log: resource poll complete"
    Ok(1) -> "Simulated Everything log: prompt registry healthy"
    Ok(2) -> "Simulated Everything log: tool execution heartbeat"
    _ -> "Simulated Everything log: session idle"
  }
}

fn has_json_content_type(req: request.Request(body)) -> Bool {
  case request.get_header(req, "content-type") {
    Ok(value) -> string.starts_with(value, "application/json")
    Error(_) -> False
  }
}

fn json_response(
  status: Int,
  body: String,
  session_id: Option(String),
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> prepend_session_id_header(session_id)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn accepted_response(
  session_id: Option(String),
) -> response.Response(mist.ResponseData) {
  response.new(202)
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> prepend_session_id_header(session_id)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
}

fn plain_response(
  status: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn prepend_session_id_header(
  response: response.Response(body),
  session_id: Option(String),
) -> response.Response(body) {
  case session_id {
    Some(value) -> response.set_header(response, "mcp-session-id", value)
    None -> response
  }
}

fn request_session_id(req: request.Request(body)) -> Option(String) {
  case request.get_header(req, "mcp-session-id") {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

type SseState {
  SseState(server: server.Server, session_id: String, listener_id: String)
}

fn handle_sse_message(
  state: SseState,
  message: streamable_http_store.ListenerMessage,
  connection: mist.SSEConnection,
) -> actor.Next(SseState, streamable_http_store.ListenerMessage) {
  let SseState(server: app_server, session_id:, listener_id:) = state

  case message {
    streamable_http_store.DeliverRequest(request) ->
      case
        mist.send_event(
          connection,
          mist.event(
            client_codec.encode_server_request(request)
            |> string_tree.from_string,
          ),
        )
      {
        Ok(Nil) -> actor.continue(state)
        Error(Nil) -> {
          server.unregister_streamable_http_listener(
            app_server,
            session_id,
            listener_id,
          )
          actor.stop()
        }
      }
    streamable_http_store.DeliverNotification(notification) ->
      case
        mist.send_event(
          connection,
          mist.event(
            client_codec.encode_notification(notification)
            |> string_tree.from_string,
          ),
        )
      {
        Ok(Nil) -> actor.continue(state)
        Error(Nil) -> {
          server.unregister_streamable_http_listener(
            app_server,
            session_id,
            listener_id,
          )
          actor.stop()
        }
      }
    streamable_http_store.CloseListener -> {
      server.unregister_streamable_http_listener(
        app_server,
        session_id,
        listener_id,
      )
      actor.stop()
    }
  }
}

fn expect_ok(value: Result(a, Nil)) -> a {
  case value {
    Ok(inner) -> inner
    Error(Nil) -> panic as "Timed out waiting for Everything HTTP logger"
  }
}
