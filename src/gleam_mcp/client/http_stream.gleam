import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/client/http_stream_driver as driver

const maximum_message_bytes = 1_048_576

pub type StreamError {
  AuthorizationRequired(status: Int, challenge: Option(String))
  HttpStatus(status: Int, message: String)
  Failed(String)
  InvalidResponse(String)
  TimedOut
  Closed
}

type StreamMessage {
  AuthorizationFailed(status: Int, challenge: Option(String))
  StreamStarted(status: Int, headers: List(http.Header))
  StreamChunk(BitArray)
  StreamEnded
  StreamFailed(String)
  Deadline
  Reconnect
  Stop
  Ignored
}

type ResponseFormat {
  AwaitingHeaders
  Json
  Sse
}

type Mode {
  OneConnection
  ResumableRequest
  ResumableListener
}

type ParserState {
  ParserState(
    pending: BitArray,
    skip_lf: Bool,
    first_line: Bool,
    event_lines: List(String),
    event_bytes: Int,
    session_id: Option(String),
    last_event_id: Option(String),
    retry_ms: Int,
    format: ResponseFormat,
    allow_json: Bool,
    completed: Bool,
    status: Result(Nil, StreamError),
  )
}

pub fn listen(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
  on_event: fn(String) -> Result(Nil, String),
) -> Result(Option(String), String) {
  run(
    http.Get,
    url,
    headers,
    "",
    timeout_ms,
    ResumableListener,
    None,
    fn(data, _) {
      on_event(data) |> result.map(fn(_) { False }) |> result.map_error(Failed)
    },
  )
  |> result.map_error(error_message)
}

/// Compatibility wrapper for callers that consume a single complete connection.
pub fn request(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
  on_event: fn(String) -> Result(Nil, String),
) -> Result(Option(String), String) {
  run(method, url, headers, body, timeout_ms, OneConnection, None, fn(data, _) {
    on_event(data) |> result.map(fn(_) { False }) |> result.map_error(Failed)
  })
  |> result.map_error(error_message)
}

/// Incrementally consume JSON or SSE until the callback identifies the response.
/// Closed SSE connections resume through GET using the last event ID, without
/// repeating the originating POST. One deadline bounds the entire operation.
pub fn request_until(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  run(method, url, headers, body, timeout_ms, ResumableRequest, None, on_event)
}

/// A listener retains its SSE cursor and retry delay across reconnections.
pub fn listen_resumable(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  run(http.Get, url, headers, "", timeout_ms, ResumableListener, None, on_event)
}

pub fn listen_until_closed(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
  stop: process.Subject(Nil),
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  run(
    http.Get,
    url,
    headers,
    "",
    timeout_ms,
    ResumableListener,
    Some(stop),
    on_event,
  )
}

fn run(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
  mode: Mode,
  stop: Option(process.Subject(Nil)),
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  let mailbox = process.new_subject()
  let deadline_subject = process.new_subject()
  let deadline = process.send_after(deadline_subject, timeout_ms, Nil)
  let selector =
    process.new_selector()
    |> process.select(mailbox)
    |> process.select_map(deadline_subject, fn(_) { Deadline })
  let selector = case stop {
    Some(stop) -> process.select_map(selector, stop, fn(_) { Stop })
    None -> selector
  }
  let bounded_callback = fn(payload, session_id) {
    invoke_event(on_event, payload, session_id, deadline_subject, stop)
  }
  let initial =
    ParserState(
      <<>>,
      False,
      True,
      [],
      0,
      header_value(headers, "mcp-session-id"),
      header_value(headers, "last-event-id"),
      1000,
      AwaitingHeaders,
      method != http.Get,
      False,
      Ok(Nil),
    )
  let outcome =
    connect(
      method,
      url,
      headers,
      body,
      timeout_ms,
      mailbox,
      selector,
      initial,
      mode,
      bounded_callback,
    )
  let _ = process.cancel_timer(deadline)
  outcome
}

fn connect(
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
  mailbox: process.Subject(StreamMessage),
  selector: process.Selector(StreamMessage),
  state: ParserState,
  mode: Mode,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  let events = process.new_subject()
  let stream =
    driver.start(method, url, headers, body, timeout_ms, events, fn(event) {
      event
    })
  let stream_selector =
    process.select_map(selector, events, fn(event) {
      case event {
        driver.Started(status, headers) -> StreamStarted(status, headers)
        driver.Chunk(bytes) -> StreamChunk(bytes)
        driver.Ended -> StreamEnded
        driver.Failed(reason) -> StreamFailed(reason)
      }
    })
  let outcome = loop(stream_selector, state, on_event)
  driver.stop(stream)
  case outcome {
    Error(error) -> Error(error)
    Ok(next_state) ->
      case next_state.completed || mode == OneConnection {
        True -> Ok(next_state.session_id)
        False ->
          case mode == ResumableRequest && next_state.last_event_id == None {
            True ->
              Error(InvalidResponse(
                "SSE stream ended before a JSON-RPC response was received",
              ))
            False ->
              reconnect(
                url,
                headers,
                timeout_ms,
                mailbox,
                selector,
                next_state,
                mode,
                on_event,
              )
          }
      }
  }
}

fn reconnect(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
  mailbox: process.Subject(StreamMessage),
  selector: process.Selector(StreamMessage),
  state: ParserState,
  mode: Mode,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(Option(String), StreamError) {
  let retry_timer = process.send_after(mailbox, state.retry_ms, Reconnect)
  // Stream callbacks from the previous connection may still be queued. Ignore
  // them while waiting; the operation deadline remains active in the selector.
  let ready = wait_reconnect(selector)
  let _ = process.cancel_timer(retry_timer)
  use _ <- result.try(ready)
  let headers =
    headers
    |> set_header("accept", "text/event-stream")
    |> set_optional_header("mcp-session-id", state.session_id)
    |> set_optional_header("last-event-id", state.last_event_id)
  let next_state =
    ParserState(
      ..state,
      pending: <<>>,
      skip_lf: False,
      first_line: True,
      event_lines: [],
      event_bytes: 0,
      format: AwaitingHeaders,
      allow_json: False,
    )
  connect(
    http.Get,
    url,
    headers,
    "",
    timeout_ms,
    mailbox,
    selector,
    next_state,
    mode,
    on_event,
  )
}

fn wait_reconnect(
  selector: process.Selector(StreamMessage),
) -> Result(Nil, StreamError) {
  case process.selector_receive_forever(selector) {
    Deadline -> Error(TimedOut)
    Stop -> Error(Closed)
    Reconnect -> Ok(Nil)
    _ -> wait_reconnect(selector)
  }
}

fn loop(
  selector: process.Selector(StreamMessage),
  state: ParserState,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> Result(ParserState, StreamError) {
  case state.status, state.completed {
    Error(error), _ -> Error(error)
    Ok(Nil), True -> Ok(state)
    Ok(Nil), False ->
      case process.selector_receive_forever(selector) {
        Deadline -> Error(TimedOut)
        Stop -> Error(Closed)
        Ignored -> loop(selector, state, on_event)
        AuthorizationFailed(status, challenge) ->
          Error(AuthorizationRequired(status, challenge))
        Reconnect -> loop(selector, state, on_event)
        StreamFailed(reason) ->
          case parse_stream_error(reason) {
            Failed(_) if state.format == Sse -> Ok(state)
            error -> Error(error)
          }
        StreamStarted(status, headers) ->
          case status {
            401 | 403 ->
              Error(AuthorizationRequired(
                status,
                authentication_challenge(headers),
              ))
            status if status < 200 || status >= 300 ->
              Error(HttpStatus(status, "HTTP status " <> int.to_string(status)))
            _ -> loop(selector, start_response(state, headers), on_event)
          }
        StreamChunk(chunk) ->
          loop(selector, process_chunk(state, chunk, on_event), on_event)
        StreamEnded ->
          case state.format {
            Json ->
              case state.status, state.completed {
                Error(error), _ -> Error(error)
                _, True -> Ok(state)
                _, False -> Error(InvalidResponse("Incomplete JSON response"))
              }
            _ -> Ok(state)
          }
      }
  }
}

fn start_response(
  state: ParserState,
  headers: List(http.Header),
) -> ParserState {
  let session_id = case header_value(headers, "mcp-session-id") {
    Some(value) -> Some(value)
    None -> state.session_id
  }
  let state = ParserState(..state, session_id: session_id)
  case header_value(headers, "content-type") {
    None ->
      ParserState(
        ..state,
        status: Error(InvalidResponse(
          "HTTP response missing content-type header",
        )),
      )
    Some(value) -> {
      let media_type =
        value
        |> string.split(on: ";")
        |> list.first
        |> result.unwrap("")
        |> string.trim
        |> string.lowercase
      case media_type {
        "application/json" if state.allow_json ->
          ParserState(..state, format: Json)
        "text/event-stream" -> ParserState(..state, format: Sse)
        _ ->
          ParserState(
            ..state,
            status: Error(InvalidResponse(
              "Unsupported HTTP response content type: " <> value,
            )),
          )
      }
    }
  }
}

fn process_chunk(
  state: ParserState,
  chunk: BitArray,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> ParserState {
  let combined = bit_array.append(state.pending, chunk)
  case bit_array.byte_size(combined) > maximum_message_bytes {
    True ->
      ParserState(
        ..state,
        status: Error(InvalidResponse("HTTP message exceeds maximum size")),
      )
    False ->
      case state.format {
        Json -> {
          let state = ParserState(..state, pending: combined)
          case bit_array.to_string(combined) {
            Error(_) -> state
            Ok(body) ->
              case json.parse(body, decode.dynamic) {
                Error(_) -> state
                Ok(_) -> deliver(state, body, on_event)
              }
          }
        }
        Sse ->
          consume_lines(ParserState(..state, pending: <<>>), combined, on_event)
        AwaitingHeaders ->
          ParserState(
            ..state,
            status: Error(InvalidResponse("HTTP body arrived before headers")),
          )
      }
  }
}

fn consume_lines(
  state: ParserState,
  bytes: BitArray,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> ParserState {
  case state.status, state.completed {
    Error(_), _ -> state
    _, True -> state
    _, False -> {
      let #(bytes, state) = case state.skip_lf, bytes {
        True, <<10, rest:bits>> -> #(rest, ParserState(..state, skip_lf: False))
        True, <<>> -> #(bytes, state)
        _, _ -> #(bytes, ParserState(..state, skip_lf: False))
      }
      case scan_line(bytes, bytes, 0) {
        None -> ParserState(..state, pending: bytes)
        Some(#(line, rest, carriage_return)) ->
          case bit_array.to_string(line) {
            Error(_) ->
              ParserState(
                ..state,
                status: Error(InvalidResponse("SSE message was not valid UTF-8")),
              )
            Ok(line) -> {
              let line = case state.first_line {
                True ->
                  case string.starts_with(line, "\u{feff}") {
                    True -> string.drop_start(line, 1)
                    False -> line
                  }
                False -> line
              }
              let next =
                process_line(
                  ParserState(
                    ..state,
                    skip_lf: carriage_return,
                    first_line: False,
                  ),
                  line,
                  on_event,
                )
              consume_lines(next, rest, on_event)
            }
          }
      }
    }
  }
}

fn scan_line(
  bytes: BitArray,
  original: BitArray,
  length: Int,
) -> Option(#(BitArray, BitArray, Bool)) {
  case bytes {
    <<>> -> None
    <<10, rest:bits>> -> {
      let assert Ok(line) = bit_array.slice(original, 0, length)
      Some(#(line, rest, False))
    }
    <<13, rest:bits>> -> {
      let assert Ok(line) = bit_array.slice(original, 0, length)
      Some(#(line, rest, True))
    }
    <<_, rest:bits>> -> scan_line(rest, original, length + 1)
    _ -> None
  }
}

fn process_line(
  state: ParserState,
  line: String,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> ParserState {
  case line {
    "" -> {
      let data = state.event_lines |> list.reverse |> string.join(with: "\n")
      let next = ParserState(..state, event_lines: [], event_bytes: 0)
      case data == "" {
        True -> next
        False -> deliver(next, data, on_event)
      }
    }
    _ -> {
      let #(field, value) = split_field(line)
      case field {
        "data" -> {
          let size = state.event_bytes + string.byte_size(value)
          case size > maximum_message_bytes {
            True ->
              ParserState(
                ..state,
                status: Error(InvalidResponse(
                  "SSE message exceeds maximum size",
                )),
              )
            False ->
              ParserState(
                ..state,
                event_lines: [value, ..state.event_lines],
                event_bytes: size,
              )
          }
        }
        "id" ->
          case string.contains(value, "\u{0000}") {
            True -> state
            False ->
              ParserState(..state, last_event_id: case value {
                "" -> None
                _ -> Some(value)
              })
          }
        "retry" ->
          case decimal_digits(value), int.parse(value) {
            True, Ok(delay) -> ParserState(..state, retry_ms: delay)
            _, _ -> state
          }
        _ -> state
      }
    }
  }
}

fn decimal_digits(value: String) -> Bool {
  value != ""
  && list.all(string.to_graphemes(value), fn(char) {
    string.contains("0123456789", char)
  })
}

// A slow capability callback or its response POST cannot extend the transport
// deadline. Separate subjects leave already queued HTTP chunks in wire order.
fn invoke_event(
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
  payload: String,
  session_id: Option(String),
  deadline: process.Subject(Nil),
  stop: Option(process.Subject(Nil)),
) -> Result(Bool, StreamError) {
  let reply = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(reply, on_event(payload, session_id))
    })
  let selector =
    process.new_selector()
    |> process.select(reply)
    |> process.select_map(deadline, fn(_) { Error(TimedOut) })
  let selector = case stop {
    Some(stop) -> process.select_map(selector, stop, fn(_) { Error(Closed) })
    None -> selector
  }
  let outcome = process.selector_receive_forever(selector)
  case outcome {
    Error(TimedOut) | Error(Closed) -> process.kill(worker)
    _ -> Nil
  }
  outcome
}

fn split_field(line: String) -> #(String, String) {
  case string.split_once(line, on: ":") {
    Error(_) -> #(line, "")
    Ok(#(field, value)) -> #(field, case string.starts_with(value, " ") {
      True -> string.drop_start(value, 1)
      False -> value
    })
  }
}

fn deliver(
  state: ParserState,
  body: String,
  on_event: fn(String, Option(String)) -> Result(Bool, StreamError),
) -> ParserState {
  case on_event(body, state.session_id) {
    Ok(completed) ->
      ParserState(..state, completed: completed || state.format == Json)
    Error(error) -> ParserState(..state, status: Error(error))
  }
}

fn parse_stream_error(message: String) -> StreamError {
  case string.contains(string.lowercase(message), "timeout") {
    True -> TimedOut
    False -> parse_http_error(message)
  }
}

fn parse_http_error(message: String) -> StreamError {
  case string.split(message, on: " ") {
    ["HTTP", code, ..] ->
      case int.parse(code) {
        Ok(status) -> HttpStatus(status, message)
        Error(_) -> Failed(message)
      }
    _ -> Failed(message)
  }
}

pub fn error_message(error: StreamError) -> String {
  case error {
    AuthorizationRequired(status, _) ->
      "HTTP authorization required: " <> int.to_string(status)
    HttpStatus(_, message) | Failed(message) | InvalidResponse(message) ->
      message
    TimedOut -> "Timed out waiting for transport response"
    Closed -> "HTTP listener closed"
  }
}

fn header_value(
  headers: List(#(String, String)),
  name: String,
) -> Option(String) {
  headers
  |> list.find(fn(header) { string.lowercase(header.0) == name })
  |> result.map(fn(header) { header.1 })
  |> option.from_result
}

fn set_header(
  headers: List(#(String, String)),
  name: String,
  value: String,
) -> List(#(String, String)) {
  [
    #(name, value),
    ..list.filter(headers, fn(header) { string.lowercase(header.0) != name })
  ]
}

fn set_optional_header(
  headers: List(#(String, String)),
  name: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(value) -> set_header(headers, name, value)
    None ->
      list.filter(headers, fn(header) { string.lowercase(header.0) != name })
  }
}

fn authentication_challenge(headers: List(http.Header)) -> Option(String) {
  let challenge =
    headers
    |> list.filter(fn(header) {
      string.lowercase(header.0) == "www-authenticate"
    })
    |> list.map(fn(header) { header.1 })
    |> string.join(", ")
  case challenge {
    "" -> None
    _ -> Some(challenge)
  }
}
