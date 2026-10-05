import argv
import conformance/server_content
import conformance/server_headers
import conformance/server_interactions
import conformance/server_mrtr
import conformance/server_schema
import conformance/server_tasks
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/streamable_http
import mist

/// Official conformance fixture. Protocol handling belongs to the SDK adapter;
/// the fixture supplies the application behavior required by the upstream tests.
pub fn main() -> Nil {
  let argv.Argv(arguments: arguments, ..) = argv.load()
  let port = case arguments {
    [] | ["streamableHttp"] -> Ok(3000)
    [port] | ["streamableHttp", port] -> int.parse(port)
    _ -> Error(Nil)
  }
  case port {
    Ok(port) -> {
      let assert Ok(_) =
        mist.new(streamable_http.handler(make_server()))
        |> mist.bind("127.0.0.1")
        |> mist.port(port)
        |> mist.start
      io.println("Conformance server listening on port " <> int.to_string(port))
      process.sleep_forever()
    }
    Error(_) ->
      io.println_error("Usage: gleam run -m conformance/server -- PORT")
  }
}

pub fn make_server() -> server.Server {
  server.new(
    actions.Implementation(
      name: "gleam-mcp-conformance",
      version: "1.0.0",
      title: Some("Gleam MCP conformance fixture"),
      description: Some("Official MCP conformance scenario fixtures"),
      website_url: None,
      icons: [],
    ),
  )
  |> server.with_instructions("Exercise the official MCP conformance fixtures.")
  |> server_content.register
  |> server_interactions.register
  |> server_mrtr.register
  |> server_schema.register
  |> server_headers.register
  |> server.with_capabilities(actions.ServerCapabilities(
    experimental: None,
    logging: Some(jsonrpc.VObject([])),
    completions: Some(jsonrpc.VObject([])),
    prompts: Some(actions.ServerPromptsCapabilities(Some(True))),
    resources: Some(actions.ServerResourcesCapabilities(Some(True), Some(True))),
    tools: Some(actions.ServerToolsCapabilities(Some(True))),
    tasks: None,
  ))
  |> server.set_completion_handler(fn(_) {
    Ok(actions.CompleteResult(
      actions.CompletionValues([], Some(0), Some(False)),
      None,
    ))
  })
  |> server.set_logging_handler(fn(_) { Ok(Nil) })
  |> server_tasks.register
  |> server.with_modern_request_handler(fn(app, context, request) {
    case server_tasks.handle(app, context, request) {
      Some(result) -> result
      None ->
        case server_headers.handle(app, context, request) {
          Some(result) -> result
          None -> server_mrtr.handle(app, context, request)
        }
    }
  })
}
