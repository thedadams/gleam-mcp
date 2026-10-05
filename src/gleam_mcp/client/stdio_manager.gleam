import child_process
import child_process/stdio as process_stdio
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/server/codec as server_codec
import youid/uuid

pub type Config {
  Config(
    command: String,
    args: List(String),
    env: List(#(String, String)),
    cwd: Option(String),
    timeout_ms: Option(Int),
  )
}

pub opaque type Manager {
  Manager(subject: process.Subject(Command))
}

type Command {
  Close(Option(String), process.Subject(Nil))
  SessionFailed(String)
  Request(
    config: Config,
    session_id: Option(String),
    capability_config: capabilities.Config,
    payload: String,
    reply_to: process.Subject(Result(#(String, Option(String)), String)),
  )
  Notification(
    config: Config,
    session_id: Option(String),
    capability_config: capabilities.Config,
    payload: String,
    reply_to: process.Subject(Result(Option(String), String)),
  )
  Listen(
    config: Config,
    session_id: Option(String),
    capability_config: capabilities.Config,
    reply_to: process.Subject(Result(Option(String), String)),
  )
}

type Session {
  Session(subject: process.Subject(SessionCommand))
}

type SessionCommand {
  Shutdown(process.Subject(Nil))
  DeliverReply(String)
  RequestTimeout(String)
  PerformRequest(
    payload: String,
    timeout: Int,
    capability_config: capabilities.Config,
    reply_to: process.Subject(Result(String, String)),
  )
  PerformNotification(
    payload: String,
    capability_config: capabilities.Config,
    reply_to: process.Subject(Result(Nil, String)),
  )
  PerformListen(
    capability_config: capabilities.Config,
    reply_to: process.Subject(Result(Nil, String)),
  )
}

type SessionEvent {
  SessionEvent(SessionCommand)
  ProcessData(BitArray)
  ProcessExited(Int)
}

type PendingRequest {
  PendingRequest(
    reply_to: process.Subject(Result(String, String)),
    token: String,
    timer: process.Timer,
    capability_config: capabilities.Config,
  )
}

type Listener {
  Listener(capability_config: capabilities.Config)
}

pub fn start() -> Manager {
  let reply_to = process.new_subject()
  let _pid = process.spawn(fn() { manager_worker(reply_to) })

  case process.receive(reply_to, 100) {
    Ok(subject) -> Manager(subject: subject)
    Error(Nil) -> panic as "Failed to start stdio manager"
  }
}

fn manager_worker(reply_to: process.Subject(process.Subject(Command))) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  loop(subject, dict.new())
}

/// Shut down one subprocess session, or all sessions owned by this manager.
pub fn close(
  manager: Manager,
  session_id: Option(String),
) -> Result(Nil, String) {
  let Manager(subject) = manager
  let reply = process.new_subject()
  process.send(subject, Close(session_id, reply))
  case process.receive(reply, 1000) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("timeout")
  }
}

pub fn request(
  manager: Manager,
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
  payload: String,
) -> Result(#(String, Option(String)), String) {
  let Manager(subject: manager_subject) = manager
  let reply_to = process.new_subject()
  process.send(
    manager_subject,
    Request(
      config: config,
      session_id: session_id,
      capability_config: capability_config,
      payload: payload,
      reply_to: reply_to,
    ),
  )

  case process.receive(reply_to, manager_timeout_ms(config)) {
    Ok(response) -> response
    Error(Nil) -> Error("timeout")
  }
}

pub fn notification(
  manager: Manager,
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
  payload: String,
) -> Result(Option(String), String) {
  let Manager(subject: manager_subject) = manager
  let reply_to = process.new_subject()
  process.send(
    manager_subject,
    Notification(
      config: config,
      session_id: session_id,
      capability_config: capability_config,
      payload: payload,
      reply_to: reply_to,
    ),
  )

  case process.receive(reply_to, manager_timeout_ms(config)) {
    Ok(response) -> response
    Error(Nil) -> Error("timeout")
  }
}

pub fn listen(
  manager: Manager,
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
) -> Result(Option(String), String) {
  let Manager(subject: manager_subject) = manager
  let reply_to = process.new_subject()
  process.send(
    manager_subject,
    Listen(
      config: config,
      session_id: session_id,
      capability_config: capability_config,
      reply_to: reply_to,
    ),
  )

  case process.receive(reply_to, manager_timeout_ms(config)) {
    Ok(response) -> response
    Error(Nil) -> Error("timeout")
  }
}

fn loop(
  subject: process.Subject(Command),
  sessions: dict.Dict(String, Session),
) {
  case process.receive_forever(subject) {
    SessionFailed(id) -> loop(subject, dict.delete(sessions, id))
    Close(session_id, reply) -> {
      let closing = case session_id {
        Some(id) ->
          case dict.get(sessions, id) {
            Ok(session) -> [#(id, session)]
            Error(_) -> []
          }
        None -> dict.to_list(sessions)
      }
      let remaining =
        list.fold(closing, sessions, fn(sessions, pair) {
          let #(id, Session(session_subject)) = pair
          let stopped = process.new_subject()
          process.send(session_subject, Shutdown(stopped))
          let _ = process.receive(stopped, 500)
          dict.delete(sessions, id)
        })
      process.send(reply, Nil)
      loop(subject, remaining)
    }
    Request(config:, session_id:, capability_config:, payload:, reply_to:) -> {
      case ensure_session(sessions, config, session_id) {
        Error(error) -> {
          process.send(reply_to, Error(error))
          loop(subject, sessions)
        }
        Ok(#(next_sessions, id)) -> {
          let assert Ok(Session(session)) = dict.get(next_sessions, id)
          let ready = process.new_subject()
          let _ =
            process.spawn_unlinked(fn() {
              let reply = process.new_subject()
              process.send(ready, reply)
              let response =
                process.receive(reply, timeout_ms(config) + 100)
                |> result.unwrap(Error("timeout"))
              case response {
                Error(_) -> process.send(subject, SessionFailed(id))
                Ok(_) -> Nil
              }
              process.send(
                reply_to,
                result.map(response, fn(payload) { #(payload, Some(id)) }),
              )
            })
          process.send(
            session,
            PerformRequest(
              payload,
              timeout_ms(config),
              capability_config,
              process.receive_forever(ready),
            ),
          )
          loop(subject, next_sessions)
        }
      }
    }
    Notification(config:, session_id:, capability_config:, payload:, reply_to:) -> {
      case ensure_session(sessions, config, session_id) {
        Error(error) -> {
          process.send(reply_to, Error(error))
          loop(subject, sessions)
        }
        Ok(#(next_sessions, id)) -> {
          let assert Ok(Session(session)) = dict.get(next_sessions, id)
          let ready = process.new_subject()
          let _ =
            process.spawn_unlinked(fn() {
              let reply = process.new_subject()
              process.send(ready, reply)
              let response =
                process.receive(reply, timeout_ms(config) + 100)
                |> result.unwrap(Error("timeout"))
              process.send(reply_to, result.map(response, fn(_) { Some(id) }))
            })
          process.send(
            session,
            PerformNotification(
              payload,
              capability_config,
              process.receive_forever(ready),
            ),
          )
          loop(subject, next_sessions)
        }
      }
    }
    Listen(config:, session_id:, capability_config:, reply_to:) -> {
      case ensure_session(sessions, config, session_id) {
        Error(error) -> {
          process.send(reply_to, Error(error))
          loop(subject, sessions)
        }
        Ok(#(next_sessions, id)) -> {
          let assert Ok(Session(session)) = dict.get(next_sessions, id)
          let ready = process.new_subject()
          let _ =
            process.spawn_unlinked(fn() {
              let reply = process.new_subject()
              process.send(ready, reply)
              let response =
                process.receive(reply, timeout_ms(config) + 100)
                |> result.unwrap(Error("timeout"))
              process.send(reply_to, result.map(response, fn(_) { Some(id) }))
            })
          process.send(
            session,
            PerformListen(capability_config, process.receive_forever(ready)),
          )
          loop(subject, next_sessions)
        }
      }
    }
  }
}

fn ensure_session(
  sessions: dict.Dict(String, Session),
  config: Config,
  session_id: Option(String),
) -> Result(#(dict.Dict(String, Session), String), String) {
  case session_id {
    Some(id) ->
      case dict.get(sessions, id) {
        Ok(_) -> Ok(#(sessions, id))
        Error(Nil) -> start_session(sessions, config)
      }
    None -> start_session(sessions, config)
  }
}

fn start_session(
  sessions: dict.Dict(String, Session),
  config: Config,
) -> Result(#(dict.Dict(String, Session), String), String) {
  let reply_to = process.new_subject()
  let _pid = process.spawn(fn() { session_worker(reply_to, config) })

  case process.receive(reply_to, timeout_ms(config) + 100) {
    Ok(Ok(subject)) -> {
      let session_id = uuid.v4_string()
      Ok(#(dict.insert(sessions, session_id, Session(subject)), session_id))
    }
    Ok(Error(error)) -> Error(error)
    Error(Nil) -> Error("timeout")
  }
}

fn session_worker(
  ready_to: process.Subject(Result(process.Subject(SessionCommand), String)),
  config: Config,
) {
  let subject = process.new_subject()
  case start_program(config) {
    Ok(handle) -> {
      process.send(ready_to, Ok(subject))
      session_loop(subject, handle, <<>>, None, None)
    }
    Error(error) -> process.send(ready_to, Error(error))
  }
}

fn start_program(config: Config) -> Result(child_process.Process, String) {
  let Config(command:, args:, env:, cwd:, ..) = config

  use executable <- result.try(find_executable(command))

  let builder =
    child_process.from_file(executable)
    |> child_process.args(args)
    |> child_process.envs(env)
  let builder = case cwd {
    Some(directory) -> child_process.cwd(builder, directory)
    None -> builder
  }

  // MCP frames arrive exclusively on stdout. Diagnostic stderr must never be
  // mistaken for a response, even when it happens to contain JSON.
  child_process.spawn_raw(builder, process_stdio.capture(False))
  |> result.map_error(child_process.describe_start_error)
}

fn session_loop(
  subject: process.Subject(SessionCommand),
  handle: child_process.Process,
  buffer: BitArray,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) {
  let selector =
    process.new_selector()
    |> process.select_map(subject, SessionEvent)
    |> process_stdio.select(handle, ProcessData, ProcessExited)

  let event = process.selector_receive_forever(selector) |> Ok

  case event {
    Ok(SessionEvent(RequestTimeout(token))) -> {
      case pending {
        Some(request) if request.token == token -> {
          notify_pending_error(pending, "timeout")
          stop_program(handle)
        }
        _ -> session_loop(subject, handle, buffer, pending, listener)
      }
    }
    Ok(SessionEvent(DeliverReply(payload))) -> {
      case child_process.writeln(handle, payload) {
        Ok(_) -> session_loop(subject, handle, buffer, pending, listener)
        Error(_) ->
          notify_pending_error(pending, "Stdio transport process exited")
      }
    }
    Ok(SessionEvent(Shutdown(reply))) -> {
      notify_pending_error(pending, "Stdio transport closed")
      stop_program(handle)
      process.send(reply, Nil)
    }
    Error(Nil) -> notify_pending_error(pending, "timeout")
    Ok(SessionEvent(PerformRequest(
      payload,
      timeout,
      capability_config,
      reply_to,
    ))) ->
      case pending {
        Some(_) -> {
          process.send(reply_to, Error("Stdio transport is busy"))
          session_loop(subject, handle, buffer, pending, listener)
        }
        None ->
          case child_process.writeln(handle, payload) {
            Ok(Nil) -> {
              let token = uuid.v4_string()
              let timer =
                process.send_after(subject, timeout, RequestTimeout(token))
              session_loop(
                subject,
                handle,
                buffer,
                Some(PendingRequest(reply_to, token, timer, capability_config)),
                listener,
              )
            }
            Error(_) ->
              process.send(reply_to, Error("Stdio transport process exited"))
          }
      }
    Ok(SessionEvent(PerformNotification(payload, _capability_config, reply_to))) ->
      case child_process.writeln(handle, payload) {
        Ok(Nil) -> {
          process.send(reply_to, Ok(Nil))
          session_loop(subject, handle, buffer, pending, listener)
        }
        Error(_) ->
          process.send(reply_to, Error("Stdio transport process exited"))
      }
    Ok(SessionEvent(PerformListen(capability_config, reply_to))) ->
      case listener {
        Some(_) -> {
          process.send(
            reply_to,
            Error("Stdio transport listener already active"),
          )
          session_loop(subject, handle, buffer, pending, listener)
        }
        None -> {
          process.send(reply_to, Ok(Nil))
          session_loop(
            subject,
            handle,
            buffer,
            pending,
            Some(Listener(capability_config)),
          )
        }
      }
    Ok(ProcessData(data)) ->
      case
        process_output(
          subject,
          handle,
          bit_array.append(to: buffer, suffix: data),
          pending,
          listener,
        )
      {
        Ok(#(next_buffer, next_pending, next_listener)) ->
          session_loop(
            subject,
            handle,
            next_buffer,
            next_pending,
            next_listener,
          )
        Error(error) -> notify_pending_error(pending, error)
      }
    Ok(ProcessExited(_)) -> {
      notify_pending_error(pending, "Stdio transport process exited")
    }
  }
}

fn process_output(
  subject: process.Subject(SessionCommand),
  handle: child_process.Process,
  buffer: BitArray,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) -> Result(#(BitArray, Option(PendingRequest), Option(Listener)), String) {
  let _ = subject
  case split_line(buffer) {
    Error(Nil) -> Ok(#(buffer, pending, listener))
    Ok(#(line_data, rest)) -> {
      use line <- result.try(
        bit_array.to_string(line_data)
        |> result.map_error(fn(_) {
          "Stdio transport process emitted invalid UTF-8"
        }),
      )
      let line = trim_carriage_return(line)
      use #(next_pending, next_listener) <- result.try(process_line(
        subject,
        handle,
        line,
        pending,
        listener,
      ))
      process_output(subject, handle, rest, next_pending, next_listener)
    }
  }
}

fn process_line(
  subject: process.Subject(SessionCommand),
  handle: child_process.Process,
  line: String,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) -> Result(#(Option(PendingRequest), Option(Listener)), String) {
  case string.starts_with(string.trim(line), "{") {
    False -> Ok(#(pending, listener))
    True ->
      case looks_like_jsonrpc_response(line), pending {
        True, Some(PendingRequest(reply_to:, timer:, ..)) -> {
          let _ = process.cancel_timer(timer)
          process.send(reply_to, Ok(line))
          Ok(#(None, listener))
        }
        _, _ -> handle_server_message(subject, handle, line, pending, listener)
      }
  }
}

fn handle_server_message(
  subject: process.Subject(SessionCommand),
  handle: child_process.Process,
  line: String,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) -> Result(#(Option(PendingRequest), Option(Listener)), String) {
  let capability_config = case pending, listener {
    Some(PendingRequest(capability_config:, ..)), _ -> capability_config
    None, Some(Listener(capability_config: capability_config)) ->
      capability_config
    None, None -> capabilities.none()
  }

  case client_codec.decode_server_message(line) {
    Ok(client_codec.ServerActionRequest(request)) -> {
      let registered = process.new_subject()
      let _ =
        process.spawn_unlinked(fn() {
          let reply = process.new_subject()
          process.send(registered, reply)
          let response = case process.receive_forever(reply) {
            Ok(response) -> response
            Error(error) -> {
              let assert jsonrpc.Request(id, _, _) = request
              jsonrpc.ErrorResponse(Some(id), error)
            }
          }
          process.send(
            subject,
            DeliverReply(server_codec.encode_server_response(response)),
          )
        })
      capabilities.start_request(
        capability_config,
        request,
        process.receive_forever(registered),
      )
      Ok(#(pending, listener))
    }
    Ok(client_codec.ActionNotification(notification)) ->
      capabilities.handle_notification(capability_config, notification)
      |> result.map_error(rpc_error_message)
      |> result.map(fn(_) { #(pending, listener) })
    Ok(client_codec.UnknownRequest(id, method)) ->
      send_server_message(
        handle,
        server_codec.encode_server_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        )),
      )
      |> result.map(fn(_) { #(pending, listener) })
    Ok(client_codec.UnknownNotification(_)) -> Ok(#(pending, listener))
    Error(_) -> Ok(#(pending, listener))
  }
}

fn send_server_message(
  handle: child_process.Process,
  payload: String,
) -> Result(Nil, String) {
  child_process.writeln(handle, payload)
  |> result.map_error(fn(_) { "Stdio transport process exited" })
}

fn notify_pending_error(pending: Option(PendingRequest), error: String) {
  case pending {
    Some(PendingRequest(reply_to:, timer:, ..)) -> {
      let _ = process.cancel_timer(timer)
      process.send(reply_to, Error(error))
    }
    None -> Nil
  }
}

fn rpc_error_message(error: jsonrpc.RpcError) -> String {
  let jsonrpc.RpcError(code, message, _) = error
  string.concat([
    "Stdio server request failed with code ",
    int.to_string(code),
    ": ",
    message,
  ])
}

fn split_line(buffer: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  split_line_loop(buffer, <<>>)
}

fn split_line_loop(
  remaining: BitArray,
  current: BitArray,
) -> Result(#(BitArray, BitArray), Nil) {
  case remaining {
    <<>> -> Error(Nil)
    <<10, rest:bits>> -> Ok(#(current, rest))
    <<byte, rest:bits>> ->
      split_line_loop(rest, bit_array.append(to: current, suffix: <<byte>>))
    _ -> Error(Nil)
  }
}

fn looks_like_jsonrpc_response(line: String) -> Bool {
  let trimmed = string.trim(line)
  let has_id = string.contains(trimmed, "\"id\"")
  let has_jsonrpc = string.contains(trimmed, "\"jsonrpc\"")
  let has_result = string.contains(trimmed, "\"result\"")
  let has_error = string.contains(trimmed, "\"error\"")

  case has_result {
    True -> has_id && has_jsonrpc
    False ->
      case has_error {
        True -> has_id && has_jsonrpc
        False -> False
      }
  }
}

fn timeout_ms(config: Config) -> Int {
  let Config(timeout_ms:, ..) = config
  case timeout_ms {
    Some(value) -> value
    None -> 5000
  }
}

fn manager_timeout_ms(config: Config) -> Int {
  let timeout = timeout_ms(config)
  timeout + timeout + 200
}

fn find_executable(command: String) -> Result(String, String) {
  case string.starts_with(command, "/") || string.starts_with(command, "./") {
    True -> Ok(command)
    False ->
      case child_process.find_executable(command) {
        Ok(path) -> Ok(path)
        Error(Nil) -> Error("Command not found: " <> command)
      }
  }
}

fn trim_carriage_return(line: String) -> String {
  case string.pop_grapheme(line) {
    Ok(#(rest, "\r")) -> rest
    _ -> line
  }
}

fn stop_program(handle: child_process.Process) {
  child_process.close(handle)
  let exited =
    process.new_selector()
    |> process_stdio.select(handle, fn(_) { False }, fn(_) { True })
  case wait_for_exit(exited, 100) {
    True -> Nil
    False -> {
      child_process.stop(handle)
      case wait_for_exit(exited, 100) {
        True -> Nil
        False -> child_process.kill(handle)
      }
    }
  }
}

fn wait_for_exit(selector: process.Selector(Bool), timeout: Int) -> Bool {
  case process.selector_receive(selector, timeout) {
    Ok(True) -> True
    Ok(False) -> wait_for_exit(selector, timeout)
    Error(_) -> False
  }
}
