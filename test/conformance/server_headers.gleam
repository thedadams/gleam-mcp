import conformance/server_content as content
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{VObject, VString}
import gleam_mcp/server

/// Synchronous application fixtures for standard and custom HTTP headers.
/// Header parsing, decoding, and body consistency remain SDK responsibilities.
pub fn register(app: server.Server) -> server.Server {
  app
  |> server.add_tool_with_execution(
    "aaa_header_probe",
    "Complete a header validation probe without arguments",
    content.schema([]),
    actions.TaskForbidden,
    fn(_) { Ok(content.text_result("Header probe complete")) },
  )
  |> server.add_tool_with_execution(
    "aab_header_echo",
    "Echo a string mirrored into an HTTP parameter header",
    content.schema([
      #(
        "value",
        VObject([
          #("type", VString("string")),
          #("x-mcp-header", VString("Value")),
        ]),
      ),
    ]),
    actions.TaskForbidden,
    fn(arguments) {
      content.argument_string(arguments, "value")
      |> result.map(content.text_result)
    },
  )
}

pub fn handle(
  app: server.Server,
  context: server.RequestContext,
  request: actions.ClientActionRequest,
) -> Option(Result(actions.ClientActionResult, jsonrpc.RpcError)) {
  case actions.request_without_input(request) {
    actions.ClientRequestCallTool(params) ->
      case params.name {
        "aaa_header_probe" | "aab_header_echo" ->
          Some(server.dispatch_registered_tool(app, context, params))
        _ -> None
      }
    _ -> None
  }
}
