import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/yielder
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
import stdin

pub fn serve(server: server.Server) {
  serve_with_lines(server, stdin.read_lines())
}

pub fn serve_with_lines(server: server.Server, lines: yielder.Yielder(String)) {
  let _ = yielder.fold(lines, from: server, with: handle_message)
}

fn handle_message(server: server.Server, message: String) -> server.Server {
  case codec.decode_message(message) {
    Ok(codec.ClientActionRequest(request)) -> {
      let #(_, response) = server.handle_request(server, request)
      io.println(codec.encode_response(response))
    }
    Ok(codec.ActionNotification(notification)) -> {
      let #(_, result) = server.handle_notification(server, notification)
      case result {
        Ok(_) -> Nil
        Error(error) -> io.println_error(rpc_error_message(error))
      }
    }
    Ok(codec.UnknownRequest(id, method)) ->
      jsonrpc.ErrorResponse(Some(id), jsonrpc.method_not_found_error(method))
      |> codec.encode_response
      |> io.println
    Ok(codec.UnknownNotification(method)) ->
      io.println_error("Ignoring unknown stdio notification: " <> method)
    Error(message) ->
      io.println_error("Ignoring invalid stdio message: " <> message)
  }
  server
}

fn rpc_error_message(error: jsonrpc.RpcError) -> String {
  let jsonrpc.RpcError(code, message, _) = error
  "RPC error " <> int.to_string(code) <> ": " <> message
}
