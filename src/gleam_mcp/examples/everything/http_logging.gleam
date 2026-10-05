import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http

pub opaque type Logger {
  Logger(subject: process.Subject(LoggerMessage), label_sessions: Bool)
}

type LoggerMessage {
  Bind(server.Server, process.Subject(Nil))
  Toggle(session_id: String, reply_to: process.Subject(Bool))
  SetLevel(session_id: String, level: actions.LoggingLevel)
  Send(session_id: String, params: actions.LoggingMessageNotificationParams)
  Tick(session_id: String, generation: Int)
  Cleanup(session_id: String, reply_to: process.Subject(Nil))
  Stop(reply_to: process.Subject(Nil))
}

type SessionLogger {
  SessionLogger(minimum_level: actions.LoggingLevel, interval: Option(Interval))
}

type Interval {
  Interval(generation: Int, timer: process.Timer)
}

pub fn middleware(logger: Logger) -> streamable_http.ClientActionMiddleware {
  fn(_, _, session_id, message) {
    case message {
      jsonrpc.Request(_, _, Some(actions.ClientRequestSetLoggingLevel(params))) ->
        set_level(logger, session_id, params.level)
      _ -> Nil
    }
    streamable_http.Continue
  }
}

pub fn toggle_tool(
  logger: Logger,
  _app_server: server.Server,
  context: server.RequestContext,
  _arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case server.session_id(context) {
    Some(session_id) ->
      Ok(
        toggle_result(
          toggle_logger(logger, session_id),
          case logger.label_sessions {
            True -> session_id
            False -> "undefined"
          },
        ),
      )
    None ->
      Error(jsonrpc.invalid_params_error(
        "toggle-simulated-logging requires a session-based transport",
      ))
  }
}

fn toggle_result(enabled: Bool, session_id: String) -> actions.CallToolResult {
  let text = case enabled {
    True ->
      "Started simulated, random-leveled logging for session "
      <> session_id
      <> " at a 5 second pace. Client's selected logging level will be respected. "
      <> "If an interval elapses and the message to be sent is below the selected level, "
      <> "it will not be sent. Thus at higher chosen logging levels, messages should arrive further apart. "
    False -> "Stopped simulated logging for session " <> session_id
  }
  actions.CallToolResult(
    [actions.TextBlock(actions.TextContent(text, None, None))],
    None,
    None,
    None,
  )
}

pub fn new_logger(app_server: server.Server) -> Logger {
  new_logger_with_config(app_server, 5000, True)
}

/// Keep a supplied logger attached to the factory's actual transport stores.
pub fn bind(logger: Logger, app: server.Server) -> Nil {
  let reply = process.new_subject()
  process.send(logger.subject, Bind(app, reply))
  let assert Ok(Nil) = process.receive(reply, 1000)
  Nil
}

/// The normal example interval is five seconds. A shorter interval is useful
/// when demonstrating or verifying the simulation without waiting for it.
pub fn new_logger_with_interval(
  app_server: server.Server,
  interval_ms: Int,
) -> Logger {
  new_logger_with_config(app_server, interval_ms, True)
}

pub fn new_without_session_labels(app: server.Server) -> Logger {
  new_logger_with_config(app, 5000, False)
}

fn new_logger_with_config(
  app_server: server.Server,
  interval_ms: Int,
  label_sessions: Bool,
) -> Logger {
  let reply_to = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(reply_to, subject)
      logger_loop(
        app_server,
        label_sessions,
        subject,
        int.max(interval_ms, 1),
        dict.new(),
        0,
      )
    })
  Logger(expect_ok(process.receive(reply_to, within: 1000)), label_sessions)
}

fn logger_loop(
  app: server.Server,
  label_sessions: Bool,
  subject: process.Subject(LoggerMessage),
  interval_ms: Int,
  sessions: dict.Dict(String, SessionLogger),
  generation: Int,
) -> Nil {
  case process.receive_forever(subject) {
    Bind(next_app, reply) -> {
      process.send(reply, Nil)
      logger_loop(
        next_app,
        label_sessions,
        subject,
        interval_ms,
        sessions,
        generation,
      )
    }
    Toggle(id, reply_to) -> {
      let state = session_logger(sessions, id)
      let next = case state.interval {
        Some(interval) -> {
          cancel_interval(Some(interval))
          SessionLogger(state.minimum_level, None)
        }
        None -> {
          emit_log(app, label_sessions, id, state.minimum_level)
          SessionLogger(
            state.minimum_level,
            Some(Interval(
              generation,
              process.send_after(subject, interval_ms, Tick(id, generation)),
            )),
          )
        }
      }
      process.send(reply_to, option_is_some(next.interval))
      logger_loop(
        app,
        label_sessions,
        subject,
        interval_ms,
        dict.insert(sessions, id, next),
        generation + 1,
      )
    }
    SetLevel(id, level) -> {
      let state = session_logger(sessions, id)
      logger_loop(
        app,
        label_sessions,
        subject,
        interval_ms,
        dict.insert(sessions, id, SessionLogger(..state, minimum_level: level)),
        generation,
      )
    }
    Send(id, params) -> {
      emit_message(app, id, session_logger(sessions, id).minimum_level, params)
      logger_loop(
        app,
        label_sessions,
        subject,
        interval_ms,
        sessions,
        generation,
      )
    }
    Tick(id, token) -> {
      let next = case dict.get(sessions, id) {
        Ok(SessionLogger(level, Some(Interval(current, _))))
          if current == token
        -> {
          case server.has_streamable_http_session(app, id) {
            True -> {
              emit_log(app, label_sessions, id, level)
              dict.insert(
                sessions,
                id,
                SessionLogger(
                  level,
                  Some(Interval(
                    token,
                    process.send_after(subject, interval_ms, Tick(id, token)),
                  )),
                ),
              )
            }
            False -> dict.delete(sessions, id)
          }
        }
        _ -> sessions
      }
      logger_loop(app, label_sessions, subject, interval_ms, next, generation)
    }
    Cleanup(id, reply_to) -> {
      cancel_interval(session_logger(sessions, id).interval)
      process.send(reply_to, Nil)
      logger_loop(
        app,
        label_sessions,
        subject,
        interval_ms,
        dict.delete(sessions, id),
        generation,
      )
    }
    Stop(reply_to) -> {
      list.each(dict.values(sessions), fn(state) {
        cancel_interval(state.interval)
      })
      process.send(reply_to, Nil)
    }
  }
}

fn emit_log(
  app: server.Server,
  label_sessions: Bool,
  id: String,
  minimum: actions.LoggingLevel,
) -> Nil {
  let assert <<random:8>> = crypto.strong_random_bytes(1)
  let level = level_at(random % 8)
  emit_message(
    app,
    id,
    minimum,
    actions.LoggingMessageNotificationParams(
      level,
      None,
      jsonrpc.VString(
        level_message(level)
        <> case label_sessions {
          True -> " - SessionId " <> id
          False -> ""
        },
      ),
      None,
    ),
  )
}

fn emit_message(
  app: server.Server,
  id: String,
  minimum: actions.LoggingLevel,
  params: actions.LoggingMessageNotificationParams,
) -> Nil {
  case level_priority(params.level) >= level_priority(minimum) {
    True -> {
      let _ =
        server.send_notification(
          app,
          server.RequestContext(Some(id), None),
          jsonrpc.Notification(
            mcp.method_notify_logging_message,
            Some(actions.NotifyLoggingMessage(params)),
          ),
        )
      Nil
    }
    False -> Nil
  }
}

/// Send a regular example log through the client's selected minimum level.
pub fn send(
  logger: Logger,
  session_id: String,
  params: actions.LoggingMessageNotificationParams,
) -> Nil {
  process.send(logger.subject, Send(session_id, params))
}

pub fn set_level(
  logger: Logger,
  session_id: String,
  level: actions.LoggingLevel,
) -> Nil {
  process.send(logger.subject, SetLevel(session_id, level))
}

pub fn cleanup_session(logger: Logger, session_id: String) -> Nil {
  let reply_to = process.new_subject()
  process.send(logger.subject, Cleanup(session_id, reply_to))
  let _ = process.receive(reply_to, 1000)
  Nil
}

pub fn stop(logger: Logger) -> Nil {
  let reply_to = process.new_subject()
  process.send(logger.subject, Stop(reply_to))
  let _ = process.receive(reply_to, 1000)
  Nil
}

fn toggle_logger(logger: Logger, session_id: String) -> Bool {
  let reply_to = process.new_subject()
  process.send(logger.subject, Toggle(session_id, reply_to))
  expect_ok(process.receive(reply_to, within: 1000))
}

fn session_logger(
  sessions: dict.Dict(String, SessionLogger),
  id: String,
) -> SessionLogger {
  case dict.get(sessions, id) {
    Ok(state) -> state
    Error(_) -> SessionLogger(actions.Debug, None)
  }
}

fn cancel_interval(interval: Option(Interval)) -> Nil {
  case interval {
    Some(Interval(_, timer)) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

fn option_is_some(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

fn level_at(index: Int) -> actions.LoggingLevel {
  case index {
    0 -> actions.Debug
    1 -> actions.Info
    2 -> actions.Notice
    3 -> actions.Warning
    4 -> actions.Error
    5 -> actions.Critical
    6 -> actions.Alert
    _ -> actions.Emergency
  }
}

fn level_priority(level: actions.LoggingLevel) -> Int {
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

fn level_message(level: actions.LoggingLevel) -> String {
  case level {
    actions.Debug -> "Debug-level message"
    actions.Info -> "Info-level message"
    actions.Notice -> "Notice-level message"
    actions.Warning -> "Warning-level message"
    actions.Error -> "Error-level message"
    actions.Critical -> "Critical-level message"
    actions.Alert -> "Alert level-message"
    actions.Emergency -> "Emergency-level message"
  }
}

fn expect_ok(value: Result(a, Nil)) -> a {
  case value {
    Ok(inner) -> inner
    Error(Nil) -> panic as "Timed out waiting for Everything logger"
  }
}
