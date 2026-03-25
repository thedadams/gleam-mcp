import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import mist

// 1 MiB
const default_max_body_bytes = 1_048_576

pub fn handler(
  server: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body(server, default_max_body_bytes)
}

pub fn handler_with_max_body(
  server: server.Server,
  max_body_bytes: Int,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) { handle(server, req, max_body_bytes) }
}

fn handle(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
) -> response.Response(mist.ResponseData) {
  case authorize_request(server, req) {
    False -> plain_response(401, "Unauthorized")
    True -> {
      let request.Request(method: method, ..) = req

      case method {
        http.Get -> handle_get(server, req)
        http.Post -> handle_post(server, req, max_body_bytes)
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
  let session_id =
    server.ensure_streamable_http_session(server, request_session_id(req))
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

fn handle_post(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
) -> response.Response(mist.ResponseData) {
  let session_id =
    server.ensure_streamable_http_session(server, request_session_id(req))

  case has_json_content_type(req) {
    False -> plain_response(415, "Expected application/json request body")
    True ->
      case mist.read_body(req, max_body_bytes) {
        Ok(body_request) ->
          case bit_array.to_string(body_request.body) {
            Ok(body) -> handle_message(server, body, session_id)
            Error(_) -> plain_response(400, "Request body was not valid UTF-8")
          }
        Error(_) -> plain_response(400, "Unable to read request body")
      }
  }
}

fn handle_message(
  server: server.Server,
  body: String,
  session_id: String,
) -> response.Response(mist.ResponseData) {
  let context = server.RequestContext(Some(session_id))

  case codec.decode_message(body) {
    Ok(codec.ClientActionRequest(message)) -> {
      let #(_, rpc_response) =
        server.handle_request_with_context(server, context, message)
      json_response(200, codec.encode_response(rpc_response), Some(session_id))
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
