import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
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

fn handle_post(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
) -> response.Response(mist.ResponseData) {
  case has_json_content_type(req) {
    False -> plain_response(415, "Expected application/json request body")
    True ->
      case mist.read_body(req, max_body_bytes) {
        Ok(body_request) ->
          case bit_array.to_string(body_request.body) {
            Ok(body) -> handle_message(server, body)
            Error(_) -> plain_response(400, "Request body was not valid UTF-8")
          }
        Error(_) -> plain_response(400, "Unable to read request body")
      }
  }
}

fn handle_message(
  server: server.Server,
  body: String,
) -> response.Response(mist.ResponseData) {
  case codec.decode_message(body) {
    Ok(codec.ActionRequest(message)) -> {
      let #(_, rpc_response) = server.handle_request(server, message)
      json_response(200, codec.encode_response(rpc_response))
    }
    Ok(codec.ActionNotification(notification)) -> {
      let #(_, _) = server.handle_notification(server, notification)
      accepted_response()
    }
    Ok(codec.UnknownRequest(id, method)) -> {
      let payload =
        codec.encode_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        ))
      json_response(200, payload)
    }
    Ok(codec.UnknownNotification(_)) -> accepted_response()
    Error(message) -> plain_response(400, message)
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
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn accepted_response() -> response.Response(mist.ResponseData) {
  response.new(202)
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
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
