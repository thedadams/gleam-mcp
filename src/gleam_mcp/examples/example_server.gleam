import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/stdio
import stdin

pub fn main() {
  stdio.serve_with_lines(sample_server(), stdin.read_lines())
}

pub fn sample_server() -> server.Server {
  server.new(sample_implementation())
  |> server.with_instructions("Use the Gleam MCP demo server.")
  |> server.add_tool(
    "echo",
    "Echo a message back to the caller",
    jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
    echo_tool,
  )
  |> server.add_resource(
    "demo://resource/static",
    "static-resource",
    "A static text resource",
    Some("text/plain"),
    fn() {
      Ok([
        actions.TextResourceContents(
          uri: "demo://resource/static",
          mime_type: Some("text/plain"),
          text: "Static resource contents",
          meta: None,
        ),
      ])
    },
  )
  |> server.add_resource_template(
    "demo://resource/dynamic/{id}",
    "dynamic-resource",
    "A dynamic text resource",
    Some("text/plain"),
    dynamic_resource,
  )
  |> server.add_prompt("simple-prompt", "A simple prompt", [], fn(_arguments) {
    Ok(actions.GetPromptResult(
      description: Some("A prompt returned by the test server"),
      messages: [
        actions.PromptMessage(
          actions.User,
          actions.TextBlock(actions.TextContent(
            "This is a simple prompt from the Gleam MCP test server.",
            None,
            None,
          )),
        ),
      ],
      meta: None,
    ))
  })
  |> server.set_completion_handler(fn(params) {
    let actions.CompleteRequestParams(ref, argument, _, _) = params
    let actions.CompleteArgument(_, value) = argument
    let values = case ref {
      actions.PromptRef(_, _) -> [value <> "-prompt"]
      actions.ResourceTemplateRef(_) -> [value <> "-resource"]
    }
    Ok(actions.CompleteResult(
      completion: actions.CompletionValues(values, Some(1), Some(False)),
      meta: None,
    ))
  })
  |> server.set_logging_handler(fn(_params) { Ok(Nil) })
}

pub fn sample_client_info() -> actions.Implementation {
  actions.Implementation(
    name: "gleam-mcp-test-client",
    version: "0.1.0",
    title: None,
    description: None,
    website_url: None,
    icons: [],
  )
}

fn sample_implementation() -> actions.Implementation {
  actions.Implementation(
    name: "gleam-mcp-test-server",
    version: "0.1.0",
    title: Some("Gleam MCP Test Server"),
    description: Some("A server used by the Gleam MCP test suite"),
    website_url: None,
    icons: [],
  )
}

fn echo_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let message = case arguments {
    Some(values) ->
      case dict.get(values, "message") {
        Ok(jsonrpc.VString(value)) -> Ok(value)
        Ok(_) -> Error(jsonrpc.invalid_params_error("message must be a string"))
        Error(Nil) -> Error(jsonrpc.invalid_params_error("message is required"))
      }
    None -> Error(jsonrpc.invalid_params_error("message is required"))
  }

  case message {
    Ok(value) ->
      Ok(actions.CallToolResult(
        content: [
          actions.TextBlock(actions.TextContent("Echo: " <> value, None, None)),
        ],
        structured_content: None,
        is_error: Some(False),
        meta: None,
      ))
    Error(error) -> Error(error)
  }
}

fn dynamic_resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  Ok([
    actions.TextResourceContents(
      uri: uri,
      mime_type: Some("text/plain"),
      text: "Dynamic resource contents for " <> uri,
      meta: None,
    ),
  ])
}
