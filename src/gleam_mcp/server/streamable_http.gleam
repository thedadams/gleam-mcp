import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import mist

// 1 MiB
const default_max_body_bytes = 1_048_576

pub type ClientActionMiddleware =
  fn(
    server.Server,
    server.RequestContext,
    String,
    jsonrpc.Request(actions.ClientActionRequest),
  ) ->
    MiddlewareDecision

pub type MiddlewareDecision {
  Continue
  RespondRpc(jsonrpc.Response(actions.ClientActionResult))
  RespondAccepted
  RespondPlain(status: Int, body: String)
}

pub fn handler(
  server: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body(server, default_max_body_bytes)
}

pub fn handler_with_middleware(
  server: server.Server,
  middleware: ClientActionMiddleware,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body_and_middleware(
    server,
    default_max_body_bytes,
    middleware,
  )
}

pub fn handler_with_max_body(
  server: server.Server,
  max_body_bytes: Int,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body_and_middleware(server, max_body_bytes, fn(_, _, _, _) {
    Continue
  })
}

pub fn handler_with_max_body_and_middleware(
  server: server.Server,
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) { handle(server, req, max_body_bytes, middleware) }
}

fn handle(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case authorize_request(server, req) {
    False -> plain_response(401, "Unauthorized")
    True -> {
      let request.Request(method: method, ..) = req

      case method {
        http.Get -> handle_get(server, req)
        http.Post -> handle_post(server, req, max_body_bytes, middleware)
        _ -> plain_response(405, "Method Not Allowed")
      }
    }
  }
}

fn authorize_request(
  server: server.Server,
  req: request.Request(mist.Connection),
) -> Bool {
  case server.header_authorization(server) {
    None -> True
    Some(server.HeaderAuthorization(header, validate)) ->
      case request.get_header(req, header) {
        Ok(value) -> validate(value)
        Error(_) -> False
      }
  }
}

fn handle_get(
  server: server.Server,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case require_existing_session(server, request_session_id(req)) {
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
            server,
            session_id,
            listener_id,
            listener,
          )
          SseState(server, session_id, listener_id)
        },
        loop: handle_sse_message,
      )
    }
    Error(Nil) -> plain_response(404, "Unknown MCP session")
  }
}

fn handle_post(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case has_json_content_type(req) {
    False -> plain_response(415, "Expected application/json request body")
    True ->
      case mist.read_body(req, max_body_bytes) {
        Ok(body_request) ->
          case bit_array.to_string(body_request.body) {
            Ok(body) ->
              handle_post_body(
                server,
                req,
                body,
                request_session_id(req),
                accepts_sse(req),
                middleware,
              )
            Error(_) -> plain_response(400, "Request body was not valid UTF-8")
          }
        Error(_) -> plain_response(400, "Unable to read request body")
      }
  }
}

fn handle_post_body(
  server: server.Server,
  req: request.Request(mist.Connection),
  body: String,
  requested_session_id: Option(String),
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case codec.decode_message(body) {
    Ok(message) ->
      case session_id_for_message(server, requested_session_id, message) {
        Ok(session_id) ->
          handle_decoded_message(
            server,
            req,
            body,
            session_id,
            message,
            accepts_sse_response,
            middleware,
          )
        Error(Nil) -> plain_response(404, "Unknown MCP session")
      }
    Error(_) ->
      case require_existing_session(server, requested_session_id) {
        Ok(session_id) ->
          handle_message(
            server,
            req,
            body,
            session_id,
            accepts_sse_response,
            middleware,
          )
        Error(Nil) -> plain_response(404, "Unknown MCP session")
      }
  }
}

fn handle_decoded_message(
  server: server.Server,
  req: request.Request(mist.Connection),
  body: String,
  session_id: String,
  message: codec.Message,
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case message {
    codec.ClientActionRequest(request) ->
      case accepts_sse_response && should_stream_request_response(request) {
        True ->
          handle_streamed_request(server, req, session_id, request, middleware)
        False ->
          handle_message(
            server,
            req,
            body,
            session_id,
            accepts_sse_response,
            middleware,
          )
      }
    _ ->
      handle_message(
        server,
        req,
        body,
        session_id,
        accepts_sse_response,
        middleware,
      )
  }
}

fn session_id_for_message(
  server: server.Server,
  requested_session_id: Option(String),
  message: codec.Message,
) -> Result(String, Nil) {
  case require_existing_session(server, requested_session_id) {
    Ok(session_id) -> Ok(session_id)
    Error(Nil) ->
      case is_initialize_message(message) {
        True -> Ok(initialize_session(server, requested_session_id))
        False -> Error(Nil)
      }
  }
}

fn require_existing_session(
  server: server.Server,
  requested_session_id: Option(String),
) -> Result(String, Nil) {
  case requested_session_id {
    Some(session_id) ->
      case server.has_streamable_http_session(server, session_id) {
        True -> Ok(session_id)
        False -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

fn initialize_session(
  server: server.Server,
  requested_session_id: Option(String),
) -> String {
  case require_existing_session(server, requested_session_id) {
    Ok(session_id) -> session_id
    Error(Nil) -> server.ensure_streamable_http_session(server, None)
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
  server: server.Server,
  req: request.Request(mist.Connection),
  body: String,
  session_id: String,
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  let context =
    server.RequestContext(session_id: Some(session_id), task_id: None)

  case codec.decode_message(body) {
    Ok(codec.ClientActionRequest(message)) ->
      case middleware(server, context, session_id, message) {
        Continue -> {
          case accepts_sse_response && should_stream_request_response(message) {
            True ->
              handle_streamed_request(
                server,
                req,
                session_id,
                message,
                middleware,
              )
            False -> {
              let #(_, rpc_response) =
                server.handle_request_with_context(server, context, message)
              json_response(
                200,
                codec.encode_response(rpc_response),
                Some(session_id),
              )
            }
          }
        }
        RespondRpc(rpc_response) ->
          json_response(
            200,
            codec.encode_response(rpc_response),
            Some(session_id),
          )
        RespondAccepted -> accepted_response(Some(session_id))
        RespondPlain(status, response_body) ->
          plain_response(status, response_body)
      }
    Ok(codec.ActionNotification(notification)) -> {
      let #(_, _) = server.handle_notification(server, notification)
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
      case server.handle_server_sent_response(server, context, body) {
        Ok(Nil) -> accepted_response(Some(session_id))
        Error(jsonrpc.RpcError(message: response_error, ..)) ->
          plain_response(400, response_error)
      }
  }
}

fn handle_streamed_request(
  server: server.Server,
  req: request.Request(mist.Connection),
  session_id: String,
  message: jsonrpc.Request(actions.ClientActionRequest),
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  let listener_id = server.new_streamable_http_listener_id()
  let context =
    server.RequestContext(session_id: Some(session_id), task_id: None)

  case middleware(server, context, session_id, message) {
    Continue ->
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
            server,
            session_id,
            listener_id,
            listener,
          )
          let _ =
            process.spawn(fn() {
              let #(_, rpc_response) =
                server.handle_request_with_context(server, context, message)
              process.send(
                listener,
                streamable_http_store.DeliverResponse(codec.encode_response(
                  rpc_response,
                )),
              )
              Nil
            })
          SseState(server, session_id, listener_id)
        },
        loop: handle_sse_message,
      )
    RespondRpc(rpc_response) ->
      json_response(200, codec.encode_response(rpc_response), Some(session_id))
    RespondAccepted -> accepted_response(Some(session_id))
    RespondPlain(status, response_body) -> plain_response(status, response_body)
  }
}

fn should_stream_request_response(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> Bool {
  case request {
    jsonrpc.Request(_, _, Some(actions.ClientRequestGetTaskResult(_))) -> True
    _ -> False
  }
}

fn accepts_sse(req: request.Request(body)) -> Bool {
  case request.get_header(req, "accept") {
    Ok(value) -> string.contains(value, "text/event-stream")
    Error(_) -> False
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
    streamable_http_store.DeliverResponse(payload) -> {
      let _ =
        server.unregister_streamable_http_listener(
          app_server,
          session_id,
          listener_id,
        )

      case
        mist.send_event(
          connection,
          mist.event(payload |> string_tree.from_string),
        )
      {
        Ok(Nil) -> actor.stop()
        Error(Nil) -> actor.stop()
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
