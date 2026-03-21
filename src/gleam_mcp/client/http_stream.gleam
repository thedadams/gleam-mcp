import dream_http_client/client as dream_client
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

type StreamMessage {
  StreamStarted(List(dream_client.Header))
  StreamChunk(BitArray)
  StreamEnded
  StreamFailed(String)
}

type ParserState {
  ParserState(
    pending_line: String,
    event_lines: List(String),
    session_id: Option(String),
    status: Result(Nil, String),
    stream_started: Bool,
  )
}

pub fn listen(
  url: String,
  headers: List(#(String, String)),
  timeout_ms: Int,
  on_event: fn(String) -> Result(Nil, String),
) -> Result(Option(String), String) {
  let mailbox = process.new_subject()

  use _stream <- result.try(
    url
    |> request_builder(headers, timeout_ms, mailbox)
    |> dream_client.start_stream,
  )

  loop(mailbox, on_event, timeout_ms, ParserState("", [], None, Ok(Nil), False))
}

fn request_builder(
  url: String,
  headers: List(#(String, String)),
  _timeout_ms: Int,
  mailbox: process.Subject(StreamMessage),
) -> dream_client.ClientRequest {
  let #(scheme, host, port, path, query) = parse_url(url)

  dream_client.new()
  |> dream_client.method(http.Get)
  |> dream_client.scheme(scheme)
  |> dream_client.host(host)
  |> apply_port(port)
  |> dream_client.path(path)
  |> apply_query(query)
  |> add_headers(headers)
  |> dream_client.on_stream_start(fn(headers) {
    process.send(mailbox, StreamStarted(headers))
  })
  |> dream_client.on_stream_chunk(fn(chunk) {
    process.send(mailbox, StreamChunk(chunk))
  })
  |> dream_client.on_stream_end(fn(_) { process.send(mailbox, StreamEnded) })
  |> dream_client.on_stream_error(fn(reason) {
    process.send(mailbox, StreamFailed(reason))
  })
}

fn loop(
  mailbox: process.Subject(StreamMessage),
  on_event: fn(String) -> Result(Nil, String),
  timeout_ms: Int,
  state: ParserState,
) -> Result(Option(String), String) {
  case next_stream_message(mailbox, timeout_ms, state) {
    Error(Nil) -> Error("Timed out waiting for transport response")
    Ok(StreamFailed(reason)) -> Error(reason)
    Ok(StreamStarted(headers)) ->
      loop(mailbox, on_event, timeout_ms, set_session_id(state, headers))
    Ok(StreamChunk(chunk)) ->
      case state_status(state) {
        Error(message) -> Error(message)
        Ok(Nil) ->
          loop(
            mailbox,
            on_event,
            timeout_ms,
            process_chunk(state, chunk, on_event),
          )
      }
    Ok(StreamEnded) -> finalise(state, on_event)
  }
}

fn next_stream_message(
  mailbox: process.Subject(StreamMessage),
  timeout_ms: Int,
  state: ParserState,
) -> Result(StreamMessage, Nil) {
  let ParserState(stream_started: stream_started, ..) = state
  case stream_started {
    True -> Ok(process.receive_forever(mailbox))
    False -> process.receive(mailbox, timeout_ms)
  }
}

fn process_chunk(
  state: ParserState,
  chunk: BitArray,
  on_event: fn(String) -> Result(Nil, String),
) -> ParserState {
  case bit_array.to_string(chunk) {
    Error(_) -> set_status(state, Error("Stream chunk was not valid UTF-8"))
    Ok(text) ->
      text
      |> normalise_sse_body
      |> process_text(state, on_event)
  }
}

fn process_text(
  text: String,
  state: ParserState,
  on_event: fn(String) -> Result(Nil, String),
) -> ParserState {
  let ParserState(pending_line:, ..) = state
  let combined = pending_line <> text
  let pieces = string.split(combined, on: "\n")

  case list.reverse(pieces) {
    [] -> state
    [remainder, ..reversed_complete] -> {
      let complete_lines = list.reverse(reversed_complete)
      let next_state = process_lines(complete_lines, state, on_event)
      set_pending_line(next_state, remainder)
    }
  }
}

fn process_lines(
  lines: List(String),
  state: ParserState,
  on_event: fn(String) -> Result(Nil, String),
) -> ParserState {
  case lines {
    [] -> state
    [line, ..rest] ->
      process_lines(rest, process_line(line, state, on_event), on_event)
  }
}

fn process_line(
  line: String,
  state: ParserState,
  on_event: fn(String) -> Result(Nil, String),
) -> ParserState {
  case state_status(state) {
    Error(_) -> state
    Ok(Nil) ->
      case line == "" {
        True -> dispatch_event(state, on_event)
        False -> append_line(state, line)
      }
  }
}

fn append_line(state: ParserState, line: String) -> ParserState {
  case string.starts_with(line, ":") {
    True -> state
    False ->
      case string.starts_with(line, "data:") {
        True -> {
          let ParserState(event_lines:, ..) = state
          let ParserState(pending_line, _, session_id, status, stream_started) =
            state
          ParserState(
            pending_line,
            list.append(event_lines, [data_value(line)]),
            session_id,
            status,
            stream_started,
          )
        }
        False -> state
      }
  }
}

fn dispatch_event(
  state: ParserState,
  on_event: fn(String) -> Result(Nil, String),
) -> ParserState {
  let ParserState(event_lines:, ..) = state
  let payload = string.join(event_lines, with: "\n")

  case payload == "" {
    True -> {
      let ParserState(pending_line, _, session_id, status, stream_started) =
        state
      ParserState(pending_line, [], session_id, status, stream_started)
    }
    False -> {
      let ParserState(pending_line, _, session_id, _, stream_started) = state
      ParserState(
        pending_line,
        [],
        session_id,
        on_event(payload),
        stream_started,
      )
    }
  }
}

fn finalise(
  state: ParserState,
  on_event: fn(String) -> Result(Nil, String),
) -> Result(Option(String), String) {
  let ParserState(pending_line:, ..) = state
  let state = case pending_line == "" {
    True -> state
    False -> process_line(pending_line, set_pending_line(state, ""), on_event)
  }
  let state = dispatch_event(state, on_event)

  case state {
    ParserState(status: Ok(Nil), session_id: session_id, ..) -> Ok(session_id)
    ParserState(status: Error(message), ..) -> Error(message)
  }
}

fn data_value(line: String) -> String {
  string.drop_start(line, 5) |> string.trim_start
}

fn set_pending_line(state: ParserState, pending_line: String) -> ParserState {
  let ParserState(_, event_lines, session_id, status, stream_started) = state
  ParserState(pending_line, event_lines, session_id, status, stream_started)
}

fn set_status(state: ParserState, status: Result(Nil, String)) -> ParserState {
  let ParserState(pending_line, event_lines, session_id, _, stream_started) =
    state
  ParserState(pending_line, event_lines, session_id, status, stream_started)
}

fn set_session_id(
  state: ParserState,
  headers: List(dream_client.Header),
) -> ParserState {
  let ParserState(pending_line, event_lines, _, status, _) = state
  ParserState(
    pending_line,
    event_lines,
    extract_session_id(headers),
    status,
    True,
  )
}

fn state_status(state: ParserState) -> Result(Nil, String) {
  let ParserState(status:, ..) = state
  status
}

fn extract_session_id(headers: List(dream_client.Header)) -> Option(String) {
  case headers {
    [] -> None
    [dream_client.Header(name, value), ..rest] ->
      case string.lowercase(name) == "mcp-session-id" {
        True -> Some(value)
        False -> extract_session_id(rest)
      }
  }
}

fn add_headers(
  request: dream_client.ClientRequest,
  headers: List(#(String, String)),
) -> dream_client.ClientRequest {
  list.fold(over: headers, from: request, with: fn(request, header) {
    let #(name, value) = header
    dream_client.add_header(request, name, value)
  })
}

fn apply_port(
  request: dream_client.ClientRequest,
  port: Option(Int),
) -> dream_client.ClientRequest {
  case port {
    Some(port) -> dream_client.port(request, port)
    None -> request
  }
}

fn apply_query(
  request: dream_client.ClientRequest,
  query: Option(String),
) -> dream_client.ClientRequest {
  case query {
    Some(query) -> dream_client.query(request, query)
    None -> request
  }
}

fn parse_url(
  url: String,
) -> #(http.Scheme, String, Option(Int), String, Option(String)) {
  let assert Ok(parsed) = uri.parse(url) as "Invalid HTTP transport URL"
  let scheme = case parsed.scheme {
    Some("https") -> http.Https
    _ -> http.Http
  }
  let host = case parsed.host {
    Some(host) -> host
    None -> "localhost"
  }
  let path = case parsed.path {
    "" -> "/"
    value -> value
  }
  #(scheme, host, parsed.port, path, parsed.query)
}

fn normalise_sse_body(body: String) -> String {
  body
  |> string.replace(each: "\r\n", with: "\n")
  |> string.replace(each: "\r", with: "\n")
}
