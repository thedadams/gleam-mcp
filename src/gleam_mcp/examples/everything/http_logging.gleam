import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http

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

pub fn middleware(
  app_server: server.Server,
) -> streamable_http.ClientActionMiddleware {
  let logger = new_logger(app_server)
  fn(_, _, session_id, message) {
    case message {
      jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(params))) ->
        case params.name {
          "toggle-simulated-logging" ->
            streamable_http.RespondRpc(toggle_response(
              id,
              toggle_logger(logger, session_id),
              session_id,
            ))
          _ -> streamable_http.Continue
        }
      jsonrpc.Request(_, _, Some(actions.ClientRequestSetLoggingLevel(params))) -> {
        let actions.SetLevelRequestParams(level, _) = params
        set_logger_level(logger, session_id, level)
        streamable_http.Continue
      }
      _ -> streamable_http.Continue
    }
  }
}

fn toggle_response(
  id: jsonrpc.RequestId,
  enabled: Bool,
  session_id: String,
) -> jsonrpc.Response(actions.ClientActionResult) {
  let text = case enabled {
    True ->
      "Started simulated, random-leveled logging for session "
      <> session_id
      <> " at a 5 second pace. Client's selected logging level will be respected."
    False -> "Stopped simulated logging for session " <> session_id
  }

  jsonrpc.ResultResponse(
    id,
    actions.ClientResultCallTool(actions.CallToolResult(
      content: [actions.TextBlock(actions.TextContent(text, None, None))],
      structured_content: None,
      is_error: Some(False),
      meta: None,
    )),
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
      let SessionLogger(enabled, minimum_level, tick) =
        session_logger(sessions, session_id)
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

fn expect_ok(value: Result(a, Nil)) -> a {
  case value {
    Ok(inner) -> inner
    Error(Nil) -> panic as "Timed out waiting for Everything HTTP logger"
  }
}
