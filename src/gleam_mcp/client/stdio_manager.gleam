import envoy
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
    payload: String,
    reply_to: process.Subject(Result(#(String, Option(String)), String)),
  )
  Notification(
    config: Config,
    session_id: Option(String),
    payload: String,
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
    reply_to: process.Subject(Result(String, String)),
  )
  PerformNotification(
    payload: String,
    reply_to: process.Subject(Result(Nil, String)),
  )
}

type SessionEvent {
  SessionEvent(SessionCommand)
  PortEvent(sceall.ProgramMessage)
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
  payload: String,
) -> Result(#(String, Option(String)), String) {
  let Manager(subject: manager_subject) = manager
  let reply_to = process.new_subject()
  process.send(
    manager_subject,
    Request(
      config: config,
      session_id: session_id,
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
  payload: String,
) -> Result(Option(String), String) {
  let Manager(subject: manager_subject) = manager
  let reply_to = process.new_subject()
  process.send(
    manager_subject,
    Notification(
      config: config,
      session_id: session_id,
      payload: payload,
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
    Request(config:, session_id:, payload:, reply_to:) -> {
      let #(next_sessions, response) =
        perform_request(sessions, config, session_id, payload)
      process.send(reply_to, response)
      loop(subject, next_sessions)
    }
    Notification(config:, session_id:, payload:, reply_to:) -> {
      let #(next_sessions, response) =
        perform_notification(sessions, config, session_id, payload)
      process.send(reply_to, response)
      loop(subject, next_sessions)
    }
  }
}

fn perform_request(
  sessions: dict.Dict(String, Session),
  config: Config,
  session_id: Option(String),
  payload: String,
) -> #(dict.Dict(String, Session), Result(#(String, Option(String)), String)) {
  case ensure_session(sessions, config, session_id) {
    Ok(#(next_sessions, ensured_session_id)) -> {
      let assert Ok(Session(subject: session_subject)) =
        dict.get(next_sessions, ensured_session_id)
      let reply_to = process.new_subject()
      process.send(
        session_subject,
        PerformRequest(payload, timeout_ms(config), reply_to),
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
  payload: String,
) -> #(dict.Dict(String, Session), Result(Option(String), String)) {
  case ensure_session(sessions, config, session_id) {
    Ok(#(next_sessions, ensured_session_id)) -> {
      let assert Ok(Session(subject: session_subject)) =
        dict.get(next_sessions, ensured_session_id)
      let reply_to = process.new_subject()
      process.send(session_subject, PerformNotification(payload, reply_to))

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
      session_loop(subject, handle, <<>>)
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
) {
  let selector =
    process.new_selector()
    |> process.select_map(subject, SessionEvent)
    |> sceall.select(handle, PortEvent)

  case process.selector_receive_forever(selector) {
    SessionEvent(PerformRequest(payload, timeout, reply_to)) -> {
      case sceall.send(handle, bit_array.from_string(payload <> "\n")) {
        Ok(Nil) ->
          case read_line(subject, handle, buffer, timeout) {
            Ok(#(line, next_buffer)) -> {
              process.send(reply_to, Ok(line))
              session_loop(subject, handle, next_buffer)
            }
            Error(error) -> process.send(reply_to, Error(error))
          }
        Error(_) ->
          process.send(reply_to, Error("Stdio transport process exited"))
      }
    }
    SessionEvent(PerformNotification(payload, reply_to)) -> {
      case sceall.send(handle, bit_array.from_string(payload <> "\n")) {
        Ok(Nil) -> {
          process.send(reply_to, Ok(Nil))
          session_loop(subject, handle, buffer)
        }
        Error(_) ->
          process.send(reply_to, Error("Stdio transport process exited"))
      }
    }
    PortEvent(sceall.Data(_, data)) -> {
      session_loop(subject, handle, bit_array.append(to: buffer, suffix: data))
    }
    PortEvent(sceall.Exited(_, _)) -> Nil
  }
}

fn read_line(
  subject: process.Subject(SessionCommand),
  handle: sceall.ProgramHandle,
  buffer: BitArray,
  timeout: Int,
) -> Result(#(String, BitArray), String) {
  case split_line(buffer) {
    Ok(#(line_data, rest)) -> {
      use line <- result.try(
        bit_array.to_string(line_data)
        |> result.map_error(fn(_) {
          "Stdio transport process emitted invalid UTF-8"
        }),
      )

      let line = trim_carriage_return(line)
      case string.starts_with(string.trim(line), "{") {
        True ->
          case looks_like_jsonrpc_response(line) {
            True -> Ok(#(line, rest))
            False -> read_line(subject, handle, rest, timeout)
          }
        False -> read_line(subject, handle, rest, timeout)
      }
    }
    Error(Nil) -> {
      let selector =
        process.new_selector()
        |> process.select_map(subject, SessionEvent)
        |> sceall.select(handle, PortEvent)

      case process.selector_receive(selector, timeout) {
        Ok(PortEvent(sceall.Data(_, data))) -> {
          read_line(
            subject,
            handle,
            bit_array.append(to: buffer, suffix: data),
            timeout,
          )
        }
        Ok(PortEvent(sceall.Exited(_, _))) ->
          Error("Stdio transport process exited")
        Ok(SessionEvent(PerformRequest(_, _, reply_to))) -> {
          process.send(reply_to, Error("Stdio transport is busy"))
          read_line(subject, handle, buffer, timeout)
        }
        Ok(SessionEvent(PerformNotification(_, reply_to))) -> {
          process.send(reply_to, Error("Stdio transport is busy"))
          read_line(subject, handle, buffer, timeout)
        }
        Error(Nil) -> Error("timeout")
      }
    }
  }
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
