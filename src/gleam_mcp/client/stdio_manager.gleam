import envoy
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
import sceall
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
  PortEvent(sceall.ProgramMessage)
}

type PendingRequest {
  PendingRequest(
    reply_to: process.Subject(Result(String, String)),
    timeout: Int,
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

fn loop(subject: process.Subject(Command), sessions: dict.Dict(String, Session)) {
  case process.receive_forever(subject) {
    Request(config:, session_id:, capability_config:, payload:, reply_to:) -> {
      let #(next_sessions, response) =
        perform_request(
          sessions,
          config,
          session_id,
          capability_config,
          payload,
        )
      process.send(reply_to, response)
      loop(subject, next_sessions)
    }
    Notification(config:, session_id:, capability_config:, payload:, reply_to:) -> {
      let #(next_sessions, response) =
        perform_notification(
          sessions,
          config,
          session_id,
          capability_config,
          payload,
        )
      process.send(reply_to, response)
      loop(subject, next_sessions)
    }
    Listen(config:, session_id:, capability_config:, reply_to:) -> {
      let #(next_sessions, response) =
        perform_listen(sessions, config, session_id, capability_config)
      process.send(reply_to, response)
      loop(subject, next_sessions)
    }
  }
}

fn perform_request(
  sessions: dict.Dict(String, Session),
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
  payload: String,
) -> #(dict.Dict(String, Session), Result(#(String, Option(String)), String)) {
  case ensure_session(sessions, config, session_id) {
    Ok(#(next_sessions, ensured_session_id)) -> {
      let assert Ok(Session(subject: session_subject)) =
        dict.get(next_sessions, ensured_session_id)
      let reply_to = process.new_subject()
      process.send(
        session_subject,
        PerformRequest(payload, timeout_ms(config), capability_config, reply_to),
      )

      case process.receive(reply_to, timeout_ms(config) + 100) {
        Ok(Ok(response_payload)) -> #(
          next_sessions,
          Ok(#(response_payload, Some(ensured_session_id))),
        )
        Ok(Error(error)) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error(error),
        )
        Error(Nil) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error("timeout"),
        )
      }
    }
    Error(error) -> #(sessions, Error(error))
  }
}

fn perform_notification(
  sessions: dict.Dict(String, Session),
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
  payload: String,
) -> #(dict.Dict(String, Session), Result(Option(String), String)) {
  case ensure_session(sessions, config, session_id) {
    Ok(#(next_sessions, ensured_session_id)) -> {
      let assert Ok(Session(subject: session_subject)) =
        dict.get(next_sessions, ensured_session_id)
      let reply_to = process.new_subject()
      process.send(
        session_subject,
        PerformNotification(payload, capability_config, reply_to),
      )

      case process.receive(reply_to, timeout_ms(config) + 100) {
        Ok(Ok(Nil)) -> #(next_sessions, Ok(Some(ensured_session_id)))
        Ok(Error(error)) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error(error),
        )
        Error(Nil) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error("timeout"),
        )
      }
    }
    Error(error) -> #(sessions, Error(error))
  }
}

fn perform_listen(
  sessions: dict.Dict(String, Session),
  config: Config,
  session_id: Option(String),
  capability_config: capabilities.Config,
) -> #(dict.Dict(String, Session), Result(Option(String), String)) {
  case ensure_session(sessions, config, session_id) {
    Ok(#(next_sessions, ensured_session_id)) -> {
      let assert Ok(Session(subject: session_subject)) =
        dict.get(next_sessions, ensured_session_id)
      let reply_to = process.new_subject()
      process.send(session_subject, PerformListen(capability_config, reply_to))

      case process.receive(reply_to, timeout_ms(config) + 100) {
        Ok(Ok(Nil)) -> #(next_sessions, Ok(Some(ensured_session_id)))
        Ok(Error(error)) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error(error),
        )
        Error(Nil) -> #(
          dict.delete(next_sessions, ensured_session_id),
          Error("timeout"),
        )
      }
    }
    Error(error) -> #(sessions, Error(error))
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

fn start_program(config: Config) -> Result(sceall.ProgramHandle, String) {
  let Config(command:, args:, env:, cwd:, ..) = config

  use executable <- result.try(find_executable(command))

  let directory = case cwd {
    Some(value) -> value
    None -> "."
  }

  let environment =
    list.fold(over: env, from: envoy.all(), with: fn(environment, entry) {
      let #(key, value) = entry
      dict.insert(environment, key, value)
    })

  sceall.spawn_program(
    executable_path: executable,
    working_directory: directory,
    command_line_arguments: args,
    environment_variables: dict.to_list(environment),
  )
  |> result.map_error(spawn_error_message)
}

fn session_loop(
  subject: process.Subject(SessionCommand),
  handle: sceall.ProgramHandle,
  buffer: BitArray,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) {
  let selector =
    process.new_selector()
    |> process.select_map(subject, SessionEvent)
    |> sceall.select(handle, PortEvent)

  let event = case pending {
    Some(PendingRequest(timeout:, ..)) ->
      process.selector_receive(selector, timeout)
    None -> process.selector_receive_forever(selector) |> Ok
  }

  case event {
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
          case sceall.send(handle, bit_array.from_string(payload <> "\n")) {
            Ok(Nil) ->
              session_loop(
                subject,
                handle,
                buffer,
                Some(PendingRequest(reply_to, timeout, capability_config)),
                listener,
              )
            Error(_) ->
              process.send(reply_to, Error("Stdio transport process exited"))
          }
      }
    Ok(SessionEvent(PerformNotification(payload, _capability_config, reply_to))) ->
      case sceall.send(handle, bit_array.from_string(payload <> "\n")) {
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
    Ok(PortEvent(sceall.Data(_, data))) ->
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
    Ok(PortEvent(sceall.Exited(_, _))) -> {
      notify_pending_error(pending, "Stdio transport process exited")
    }
  }
}

fn process_output(
  subject: process.Subject(SessionCommand),
  handle: sceall.ProgramHandle,
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
  handle: sceall.ProgramHandle,
  line: String,
  pending: Option(PendingRequest),
  listener: Option(Listener),
) -> Result(#(Option(PendingRequest), Option(Listener)), String) {
  case string.starts_with(string.trim(line), "{") {
    False -> Ok(#(pending, listener))
    True ->
      case looks_like_jsonrpc_response(line), pending {
        True, Some(PendingRequest(reply_to:, ..)) -> {
          process.send(reply_to, Ok(line))
          Ok(#(None, listener))
        }
        _, _ -> handle_server_message(handle, line, pending, listener)
      }
  }
}

fn handle_server_message(
  handle: sceall.ProgramHandle,
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
    Ok(client_codec.ActionRequest(request)) ->
      case
        capabilities.handle_request(capability_config, request)
        |> result.map_error(rpc_error_message)
      {
        Ok(response) ->
          send_server_message(handle, server_codec.encode_response(response))
          |> result.map(fn(_) { #(pending, listener) })
        Error(error) -> Error(error)
      }
    Ok(client_codec.ActionNotification(notification)) ->
      capabilities.handle_notification(capability_config, notification)
      |> result.map_error(rpc_error_message)
      |> result.map(fn(_) { #(pending, listener) })
    Ok(client_codec.UnknownRequest(id, method)) ->
      send_server_message(
        handle,
        server_codec.encode_response(jsonrpc.ErrorResponse(
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
  handle: sceall.ProgramHandle,
  payload: String,
) -> Result(Nil, String) {
  sceall.send(handle, bit_array.from_string(payload <> "\n"))
  |> result.map_error(fn(_) { "Stdio transport process exited" })
}

fn notify_pending_error(pending: Option(PendingRequest), error: String) {
  case pending {
    Some(PendingRequest(reply_to:, ..)) -> process.send(reply_to, Error(error))
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
      case sceall.find_executable(command) {
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

fn spawn_error_message(error: sceall.SpawnProgramError) -> String {
  case error {
    sceall.NotEnoughBeamPorts ->
      "Unable to start stdio process: not enough BEAM ports"
    sceall.NotEnoughMemory -> "Unable to start stdio process: not enough memory"
    sceall.NotEnoughOsProcesses ->
      "Unable to start stdio process: not enough OS processes"
    sceall.ExternalCommandTooLong ->
      "Unable to start stdio process: external command too long"
    sceall.NotEnoughFileDescriptors ->
      "Unable to start stdio process: not enough file descriptors"
    sceall.OsFileTableFull ->
      "Unable to start stdio process: OS file table full"
    sceall.FileNotExecutable ->
      "Unable to start stdio process: file not executable"
    sceall.FileDoesNotExist ->
      "Unable to start stdio process: file does not exist"
  }
}
