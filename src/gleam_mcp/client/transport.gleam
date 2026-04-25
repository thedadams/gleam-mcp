import gleam/erlang/process
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
  type ActionNotification, type ClientActionRequest, type ClientActionResult,
}
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec as client_codec
import gleam_mcp/client/http_stream
import gleam_mcp/client/stdio_manager
import gleam_mcp/jsonrpc.{type Request, type Response}
import gleam_mcp/mcp
import gleam_mcp/server/codec as server_codec

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

const default_http_timeout_ms = 30_000

const minimum_stream_listener_timeout_ms = 3_600_000

pub type Runners {
  Runners(
    stdio_request: fn(
      StdioConfig,
      Option(String),
      capabilities.Config,
      Request(ClientActionRequest),
    ) ->
      Result(TransportResponse(ClientActionResult), TransportError),
    stdio_notification: fn(
      StdioConfig,
      Option(String),
      capabilities.Config,
      Request(ActionNotification),
    ) ->
      Result(TransportResponse(Nil), TransportError),
    stdio_listen: fn(StdioConfig, Option(String), capabilities.Config) ->
      Result(TransportResponse(Nil), TransportError),
    streamable_request: fn(
      HttpConfig,
      Option(String),
      String,
      capabilities.Config,
      Request(ClientActionRequest),
    ) ->
      Result(TransportResponse(ClientActionResult), TransportError),
    streamable_notification: fn(
      HttpConfig,
      Option(String),
      String,
      capabilities.Config,
      Request(ActionNotification),
    ) ->
      Result(TransportResponse(Nil), TransportError),
  )
}

pub fn default_runners() -> Runners {
  let manager = stdio_manager.start()

  Runners(
    stdio_request: fn(config, session_id, capability_config, message) {
      stdio_process_request(
        manager,
        config,
        session_id,
        capability_config,
        message,
      )
    },
    stdio_notification: fn(config, session_id, capability_config, message) {
      stdio_process_notification(
        manager,
        config,
        session_id,
        capability_config,
        message,
      )
    },
    stdio_listen: fn(config, session_id, capability_config) {
      stdio_listen(manager, config, session_id, capability_config)
    },
    streamable_request: fn(
      config,
      session_id,
      protocol_version,
      capability_config,
      message,
    ) {
      streamable_http_request(
        config,
        session_id,
        protocol_version,
        capability_config,
        message,
        client_codec.encode_request,
        client_codec.decode_response,
      )
    },
    streamable_notification: fn(
      config,
      session_id,
      protocol_version,
      capability_config,
      message,
    ) {
      streamable_http_notification(
        config,
        session_id,
        protocol_version,
        capability_config,
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
  capability_config: capabilities.Config,
  request: Request(action),
  stdio_request: fn(
    StdioConfig,
    Option(String),
    capabilities.Config,
    Request(action),
  ) ->
    Result(TransportResponse(action_result), TransportError),
  streamable_request: fn(
    HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    Request(action),
  ) ->
    Result(TransportResponse(action_result), TransportError),
) -> Result(TransportResponse(action_result), TransportError) {
  case config {
    Stdio(stdio_config) ->
      stdio_request(stdio_config, session_id, capability_config, request)
    Http(http_config) ->
      streamable_request(
        http_config,
        session_id,
        protocol_version,
        capability_config,
        request,
      )
  }
}

fn stdio_process_request(
  manager: stdio_manager.Manager,
  config: StdioConfig,
  session_id: Option(String),
  capability_config: capabilities.Config,
  message: Request(ClientActionRequest),
) -> Result(TransportResponse(ClientActionResult), TransportError) {
  use #(response_payload, next_session_id) <- result.try(
    stdio_manager.request(
      manager,
      to_stdio_manager_config(config),
      session_id,
      capability_config,
      client_codec.encode_request(message),
    )
    |> result.map_error(map_stdio_error),
  )

  client_codec.decode_response(response_payload, message)
  |> result.map_error(UnexpectedResponse)
  |> result.map(fn(response) {
    TransportResponse(response:, session_id: next_session_id)
  })
}

fn stdio_process_notification(
  manager: stdio_manager.Manager,
  config: StdioConfig,
  session_id: Option(String),
  capability_config: capabilities.Config,
  message: Request(ActionNotification),
) -> Result(TransportResponse(Nil), TransportError) {
  stdio_manager.notification(
    manager,
    to_stdio_manager_config(config),
    session_id,
    capability_config,
    client_codec.encode_notification(message),
  )
  |> result.map_error(map_stdio_error)
  |> result.map(fn(next_session_id) {
    TransportResponse(response: jsonrpc_ok(), session_id: next_session_id)
  })
}

fn stdio_listen(
  manager: stdio_manager.Manager,
  config: StdioConfig,
  session_id: Option(String),
  capability_config: capabilities.Config,
) -> Result(TransportResponse(Nil), TransportError) {
  stdio_manager.listen(
    manager,
    to_stdio_manager_config(config),
    session_id,
    capability_config,
  )
  |> result.map_error(map_stdio_error)
  |> result.map(fn(next_session_id) {
    TransportResponse(response: jsonrpc_ok(), session_id: next_session_id)
  })
}

fn to_stdio_manager_config(config: StdioConfig) -> stdio_manager.Config {
  let StdioConfig(command:, args:, env:, cwd:, timeout_ms:) = config
  stdio_manager.Config(command, args, env, cwd, timeout_ms)
}

fn map_stdio_error(message: String) -> TransportError {
  case message {
    "timeout" -> TimeoutError
    _ -> ProcessError(message)
  }
}

pub fn streamable_http_request(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  message: Request(action),
  encode: fn(Request(action)) -> String,
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(TransportResponse(result), TransportError) {
  case should_stream_post_response(message) {
    True ->
      streamable_http_request_streaming(
        config,
        session_id,
        protocol_version,
        capability_config,
        message,
        encode,
        decode,
      )
    False -> {
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
          decode_post_response(
            config,
            session_id,
            protocol_version,
            capability_config,
            http_response,
            message,
            decode,
          )
          |> result.map(fn(response) {
            TransportResponse(response:, session_id: next_session_id)
          })
        202 -> Error(UnexpectedResponse("Expected a JSON-RPC response body"))
        _ -> Error(http_status_error(status, http_response.body))
      }
    }
  }
}

fn streamable_http_request_streaming(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  message: Request(action),
  encode: fn(Request(action)) -> String,
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(TransportResponse(result), TransportError) {
  let HttpConfig(base_url:, timeout_ms:, ..) = config
  let timeout_ms = case timeout_ms {
    Some(timeout) -> timeout
    None -> 30_000
  }
  let response_reply = process.new_subject()
  let body = encode(message)

  use next_session_id <- result.try(
    http_stream.request(
      http.Post,
      base_url,
      post_stream_headers(config, session_id, protocol_version),
      body,
      timeout_ms,
      fn(payload) {
        case decode(payload, message) {
          Ok(response) -> {
            process.send(response_reply, response)
            Ok(Nil)
          }
          Error(_) -> {
            process_server_message(
              config,
              session_id,
              protocol_version,
              capability_config,
              payload,
            )
            |> result.map_error(transport_error_message)
          }
        }
      },
    )
    |> result.map_error(map_stream_listener_error),
  )

  case process.receive(response_reply, 100) {
    Ok(response) ->
      Ok(TransportResponse(response:, session_id: next_session_id))
    Error(Nil) ->
      Error(UnexpectedResponse(
        "SSE stream ended before a JSON-RPC response was received",
      ))
  }
}

fn should_stream_post_response(message: Request(action)) -> Bool {
  case message {
    jsonrpc.Request(_, method, _) -> method == mcp.method_get_task_result
    jsonrpc.Notification(_, _) -> False
  }
}

fn post_stream_headers(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
) -> List(#(String, String)) {
  let HttpConfig(headers:, ..) = config

  [
    #("accept", "application/json, text/event-stream"),
    #("content-type", "application/json"),
    #("mcp-protocol-version", protocol_version),
  ]
  |> prepend_optional_header("mcp-session-id", session_id)
  |> list.append(
    list.map(headers, fn(header) {
      let #(key, value) = header
      #(string.lowercase(key), value)
    }),
  )
}

pub fn streamable_http_notification(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  message: Request(action),
  encode: fn(Request(action)) -> String,
) -> Result(TransportResponse(Nil), TransportError) {
  let _ = capability_config
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

pub fn streamable_http_listen(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
) -> Result(Option(String), TransportError) {
  let HttpConfig(base_url:, ..) = config
  let headers = streamable_get_headers(config, session_id, protocol_version)

  http_stream.listen(
    base_url,
    headers,
    stream_listener_timeout_ms(config),
    fn(payload) {
      process_server_message(
        config,
        session_id,
        protocol_version,
        capability_config,
        payload,
      )
      |> result.map_error(transport_error_message)
    },
  )
  |> result.map_error(map_stream_listener_error)
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

fn streamable_get_headers(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
) -> List(#(String, String)) {
  let HttpConfig(headers:, ..) = config

  [
    #("accept", "text/event-stream"),
    #("mcp-protocol-version", protocol_version),
  ]
  |> prepend_optional_header("mcp-session-id", session_id)
  |> list.append(
    list.map(headers, fn(header) {
      let #(key, value) = header
      #(string.lowercase(key), value)
    }),
  )
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

fn stream_listener_timeout_ms(config: HttpConfig) -> Int {
  let timeout = http_timeout_ms(config)
  case timeout < minimum_stream_listener_timeout_ms {
    True -> minimum_stream_listener_timeout_ms
    False -> timeout
  }
}

fn http_timeout_ms(config: HttpConfig) -> Int {
  let HttpConfig(timeout_ms:, ..) = config
  case timeout_ms {
    Some(timeout) -> timeout
    None -> default_http_timeout_ms
  }
}

fn decode_post_response(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
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
              process_sse_request_events(
                config,
                session_id,
                protocol_version,
                capability_config,
                body,
                message,
                decode,
              )
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

fn process_sse_request_events(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  body: String,
  message: Request(action),
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(Response(result), TransportError) {
  use events <- result.try(parse_sse_events(body))
  process_sse_request_event_list(
    config,
    session_id,
    protocol_version,
    capability_config,
    events,
    message,
    decode,
  )
}

fn process_sse_request_event_list(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  events: List(SseEvent),
  message: Request(action),
  decode: fn(String, Request(action)) -> Result(Response(result), String),
) -> Result(Response(result), TransportError) {
  case events {
    [] ->
      Error(UnexpectedResponse(
        "SSE stream ended before a JSON-RPC response was received",
      ))
    [SseEvent(data: data), ..rest] ->
      case string.is_empty(data) {
        True ->
          process_sse_request_event_list(
            config,
            session_id,
            protocol_version,
            capability_config,
            rest,
            message,
            decode,
          )
        False ->
          case decode(data, message) {
            Ok(value) -> Ok(value)
            Error(_) -> {
              use _ <- result.try(process_server_message(
                config,
                session_id,
                protocol_version,
                capability_config,
                data,
              ))
              process_sse_request_event_list(
                config,
                session_id,
                protocol_version,
                capability_config,
                rest,
                message,
                decode,
              )
            }
          }
      }
  }
}

fn process_server_message(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  payload: String,
) -> Result(Nil, TransportError) {
  case client_codec.decode_server_message(payload) {
    Ok(client_codec.ServerActionRequest(request)) ->
      case
        capabilities.handle_request(capability_config, request)
        |> result.map_error(rpc_error_to_transport_error)
      {
        Ok(response) ->
          post_streamable_message(
            config,
            session_id,
            protocol_version,
            server_codec.encode_server_response(response),
          )
        Error(error) -> Error(error)
      }
    Ok(client_codec.ActionNotification(notification)) ->
      capabilities.handle_notification(capability_config, notification)
      |> result.map_error(rpc_error_to_transport_error)
    Ok(client_codec.UnknownRequest(id, method)) ->
      post_streamable_message(
        config,
        session_id,
        protocol_version,
        server_codec.encode_server_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        )),
      )
    Ok(client_codec.UnknownNotification(_)) -> Ok(Nil)
    Error(_) -> Ok(Nil)
  }
}

fn post_streamable_message(
  config: HttpConfig,
  session_id: Option(String),
  protocol_version: String,
  payload: String,
) -> Result(Nil, TransportError) {
  let http_request =
    build_post_request(
      config,
      session_id,
      protocol_version,
      payload,
      accept_header: "application/json, text/event-stream",
    )

  use http_response <- result.try(send_http_request(config, http_request))
  let response.Response(status:, ..) = http_response
  case status {
    202 -> Ok(Nil)
    _ -> Error(http_status_error(status, http_response.body))
  }
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

fn normalise_sse_body(body: String) -> String {
  body
  |> string.replace(each: "\r\n", with: "\n")
  |> string.replace(each: "\r", with: "\n")
}

fn transport_error_message(error: TransportError) -> String {
  case error {
    ProcessError(message) -> message
    HttpError(message) -> message
    TimeoutError -> "Timed out waiting for transport response"
    UnexpectedResponse(message) -> message
  }
}

fn map_stream_listener_error(message: String) -> TransportError {
  case message {
    "Timed out waiting for transport response" -> TimeoutError
    _ -> HttpError(message)
  }
}

fn prepend_optional_header(
  headers: List(#(String, String)),
  key: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(value) -> [#(key, value), ..headers]
    None -> headers
  }
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

fn rpc_error_to_transport_error(error: jsonrpc.RpcError) -> TransportError {
  let jsonrpc.RpcError(code, message, _) = error
  UnexpectedResponse(
    "Server request failed with code " <> int.to_string(code) <> ": " <> message,
  )
}

fn jsonrpc_ok() -> Response(Nil) {
  jsonrpc.ResultResponse(jsonrpc.StringId("accepted"), Nil)
}
