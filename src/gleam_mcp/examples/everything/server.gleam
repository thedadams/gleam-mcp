import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/prompts
import gleam_mcp/examples/everything/resources
import gleam_mcp/examples/everything/tools
import gleam_mcp/server

pub fn make_server() -> server.Server {
  make_server_with_http_logger(None)
}

pub fn make_server_with_http_logger(
  logger: Option(http_logging.Logger),
) -> server.Server {
  base_server() |> tools.register_tools(logger)
}

/// The logger and HTTP handler share the same stores and session metadata.
pub fn make_http_server() -> #(server.Server, http_logging.Logger) {
  let app_server = base_server()
  let logger = http_logging.new_logger(app_server)
  #(tools.register_tools(app_server, Some(logger)), logger)
}

fn base_server() -> server.Server {
  server.new(implementation())
  |> server.with_instructions(instructions())
  |> resources.register_resources
  |> prompts.register_prompts
  |> server.set_completion_handler(prompts.completion_handler)
  |> server.set_logging_handler(fn(_) { Ok(Nil) })
}

pub fn implementation() -> actions.Implementation {
  actions.Implementation(
    name: "gleam-mcp/everything",
    version: "0.1.0",
    title: Some("Gleam Everything Server"),
    description: Some(
      "A best-effort Gleam port of the MCP Everything reference server",
    ),
    website_url: None,
    icons: [],
  )
}

fn instructions() -> String {
  "Use the Gleam Everything server to exercise tools, prompts, resources, templates, completions, structured content, images, and embedded resources. Some advanced reference-server capabilities are intentionally omitted because the current SDK does not expose them yet."
}
