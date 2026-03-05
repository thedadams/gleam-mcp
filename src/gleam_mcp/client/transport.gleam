import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions.{
  type ActionNotification, type ActionRequest, type ActionResult,
}
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc.{type Request, type Response}

pub type CompatibilityMode {
  StreamableOnly
  AutoFallback
}

pub type Config {
  Stdio(StdioConfig)
  Http(HttpConfig)
}

pub type StdioConfig {
  StdioConfig(
    command: String,
    args: List(String),
    env: List(#(String, String)),
    cwd: Option(String),
    timeout_ms: Option(Int),
  )
}

pub type HttpConfig {
  HttpConfig(
    base_url: String,
    headers: List(#(String, String)),
    timeout_ms: Option(Int),
  )
}

pub type SelectedMode {
  StdioMode
  StreamableHttpMode
  LegacySseMode
}

pub type TransportError {
  ProcessError(String)
  HttpError(String)
  TimeoutError
  UnexpectedResponse(String)
}

pub type TransportResponse(result) {
  TransportResponse(response: Response(result), session_id: Option(String))
}

pub type Runners {
  Runners(
    stdio_request: fn(StdioConfig, Request(ActionRequest)) ->
      Result(TransportResponse(ActionResult), TransportError),
    stdio_notification: fn(StdioConfig, Request(ActionNotification)) ->
      Result(TransportResponse(Nil), TransportError),
    streamable_request: fn(
      HttpConfig,
      Option(String),
      String,
      Request(ActionRequest),
    ) ->
      Result(TransportResponse(ActionResult), TransportError),
    streamable_notification: fn(
      HttpConfig,
      Option(String),
      String,
      Request(ActionNotification),
    ) ->
      Result(TransportResponse(Nil), TransportError),
  )
}

pub fn default_runners() -> Runners {
  Runners(
    stdio_request: fn(_, _) {
      Error(ProcessError("Default stdio transport runner is not configured"))
    },
    stdio_notification: fn(_, _) {
      Error(ProcessError("Default stdio transport runner is not configured"))
    },
    streamable_request: fn(config, session_id, protocol_version, message) {
      streamable_http_request(
        config,
        session_id,
        protocol_version,
        message,
        client_codec.encode_request,
        client_codec.decode_response,
      )
    },
    streamable_notification: fn(config, session_id, protocol_version, message) {
      streamable_http_notification(
        config,
        session_id,
        protocol_version,
        message,
        client_codec.encode_notification,
      )
    },
  )
}

pub fn send_request(
  config: Config,
  session_id: Option(String),
  protocol_version: String,
  request: Request(action),
  stdio_request: fn(StdioConfig, Request(action)) ->
    Result(TransportResponse(action_result), TransportError),
  streamable_request: fn(HttpConfig, Option(String), String, Request(action)) ->
    Result(TransportResponse(action_result), TransportError),
) -> Result(TransportResponse(action_result), TransportError) {
  case config {
    Stdio(stdio_config) -> stdio_request(stdio_config, request)
    Http(http_config) ->
      streamable_request(http_config, session_id, protocol_version, request)
  }
}

pub fn streamable_http_request(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  message: Request(action),
  encode: fn(Request(action)) -> String,
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(TransportResponse(result), TransportError) {
  let http_request =
    build_post_request(
      config,
      session_id,
      protocol_version,
      encode(message),
      accept_header: "application/json, text/event-stream",
    )

  use http_response <- result.try(send_http_request(config, http_request))
  let next_session_id = session_id_from_response(http_response)
  let response.Response(status:, ..) = http_response

  case status {
    200 ->
      decode_post_response(http_response, message, decode)
      |> result.map(fn(response) {
        TransportResponse(response:, session_id: next_session_id)
      })
    202 -> Error(UnexpectedResponse("Expected a JSON-RPC response body"))
    _ -> Error(http_status_error(status, http_response.body))
  }
}

pub fn streamable_http_notification(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  message: Request(action),
  encode: fn(Request(action)) -> String,
) -> Result(TransportResponse(Nil), TransportError) {
  let http_request =
    build_post_request(
      config,
      session_id,
      protocol_version,
      encode(message),
      accept_header: "application/json, text/event-stream",
    )

  use http_response <- result.try(send_http_request(config, http_request))
  let response.Response(status:, ..) = http_response

  case status {
    202 ->
      Ok(TransportResponse(
        response: jsonrpc_ok(),
        session_id: session_id_from_response(http_response),
      ))
    _ -> Error(http_status_error(status, http_response.body))
  }
}

pub fn first_sse_data(body: String) -> Result(String, TransportError) {
  case parse_sse_events(body) {
    Ok(events) -> first_non_empty_sse_data(events)
    Error(error) -> Error(error)
  }
}

type SseEvent {
  SseEvent(data: String)
}

fn build_post_request(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  body: String,
  accept_header accept_header: String,
) -> request.Request(String) {
  let HttpConfig(base_url:, headers:, ..) = config
  let base_request = case request.to(base_url) {
    Ok(value) -> value
    Error(_) -> panic as "Invalid HTTP transport URL"
  }

  let request =
    base_request
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.set_header("accept", accept_header)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("mcp-protocol-version", protocol_version)

  let request = case session_id {
    Some(value) -> request.set_header(request, "mcp-session-id", value)
    None -> request
  }

  list.fold(over: headers, from: request, with: fn(request, header) {
    let #(key, value) = header
    request.set_header(request, string.lowercase(key), value)
  })
}

fn send_http_request(
  config: HttpConfig,
  request: request.Request(String),
) -> Result(response.Response(String), TransportError) {
  let HttpConfig(timeout_ms:, ..) = config

  let http_config = case timeout_ms {
    Some(timeout) -> httpc.configure() |> httpc.timeout(timeout)
    None -> httpc.configure()
  }

  httpc.dispatch(http_config, request) |> result.map_error(map_http_error)
}

fn decode_post_response(
  http_response: response.Response(String),
  message: Request(action),
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(Response(result), TransportError) {
  let response.Response(body:, ..) = http_response

  case response.get_header(http_response, "content-type") {
    Ok(content_type) ->
      case string.starts_with(content_type, "application/json") {
        True -> decode(body, message) |> result.map_error(UnexpectedResponse)
        False ->
          case string.starts_with(content_type, "text/event-stream") {
            True ->
              body
              |> first_matching_sse_data(message, decode)
              |> result.map_error(UnexpectedResponse)
            False ->
              Error(UnexpectedResponse(
                "Unsupported HTTP response content type: " <> content_type,
              ))
          }
      }
    Error(_) ->
      Error(UnexpectedResponse("HTTP response missing content-type header"))
  }
}

fn first_matching_sse_data(
  body: String,
  message: Request(action),
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(Response(result), String) {
  use events <- result.try(
    parse_sse_events(body) |> result.map_error(transport_error_message),
  )

  first_decoded_sse_response(events, message, decode)
}

fn parse_sse_events(body: String) -> Result(List(SseEvent), TransportError) {
  body
  |> normalise_sse_body
  |> string.split(on: "\n\n")
  |> list.filter(fn(chunk) { !string.is_empty(string.trim(chunk)) })
  |> list.try_map(parse_sse_event)
}

fn parse_sse_event(chunk: String) -> Result(SseEvent, TransportError) {
  let data =
    chunk
    |> string.split(on: "\n")
    |> list.filter_map(fn(line) {
      let line = string.trim_end(line)

      case line {
        "" -> Error(Nil)
        _ ->
          case string.starts_with(line, ":") {
            True -> Error(Nil)
            False ->
              case string.starts_with(line, "data:") {
                True ->
                  Ok(string.trim_start(string.drop_start(from: line, up_to: 5)))
                False -> Error(Nil)
              }
          }
      }
    })
    |> string.join(with: "\n")

  Ok(SseEvent(data: data))
}

fn first_non_empty_sse_data(
  events: List(SseEvent),
) -> Result(String, TransportError) {
  case events {
    [] ->
      Error(UnexpectedResponse(
        "SSE stream ended before a response was received",
      ))
    [SseEvent(data: data), ..rest] ->
      case string.is_empty(data) {
        True -> first_non_empty_sse_data(rest)
        False -> Ok(data)
      }
  }
}

fn first_decoded_sse_response(
  events: List(SseEvent),
  message: Request(action),
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(Response(result), String) {
  case events {
    [] -> Error("SSE stream ended before a JSON-RPC response was received")
    [SseEvent(data: data), ..rest] ->
      case string.is_empty(data) {
        True -> first_decoded_sse_response(rest, message, decode)
        False ->
          case decode(data, message) {
            Ok(value) -> Ok(value)
            Error(_) -> first_decoded_sse_response(rest, message, decode)
          }
      }
  }
}

fn normalise_sse_body(body: String) -> String {
  body
  |> string.replace(each: "\r\n", with: "\n")
  |> string.replace(each: "\r", with: "\n")
}

fn session_id_from_response(
  http_response: response.Response(String),
) -> Option(String) {
  case response.get_header(http_response, "mcp-session-id") {
    Ok(session_id) -> Some(session_id)
    Error(_) -> None
  }
}

fn http_status_error(status: Int, body: String) -> TransportError {
  let message = case string.trim(body) {
    "" -> "HTTP request failed with status " <> int.to_string(status)
    trimmed ->
      "HTTP request failed with status "
      <> int.to_string(status)
      <> ": "
      <> trimmed
  }

  HttpError(message)
}

fn map_http_error(error: httpc.HttpError) -> TransportError {
  case error {
    httpc.ResponseTimeout -> TimeoutError
    httpc.InvalidUtf8Response ->
      HttpError("HTTP response body was not valid UTF-8")
    httpc.FailedToConnect(_, _) ->
      HttpError("Failed to connect to HTTP transport")
  }
}

fn transport_error_message(error: TransportError) -> String {
  case error {
    ProcessError(message) -> message
    HttpError(message) -> message
    TimeoutError -> "Timed out waiting for transport response"
    UnexpectedResponse(message) -> message
  }
}

fn jsonrpc_ok() -> Response(Nil) {
  jsonrpc.ResultResponse(jsonrpc.StringId("accepted"), Nil)
}
