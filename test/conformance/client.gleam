import argv
import conformance/client_core
import conformance/oauth
import envoy
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc

pub fn main() -> Nil {
  case run() {
    Ok(_) -> io.println("Conformance client scenario completed")
    Error(error) -> {
      io.println_error("Conformance client failed: " <> error)
      panic as error
    }
  }
}

fn run() -> Result(Nil, String) {
  let argv.Argv(arguments:, ..) = argv.load()
  use server_url <- result.try(
    arguments
    |> list.reverse
    |> list.first
    |> result.replace_error(
      "Expected the conformance server URL as the final argument",
    ),
  )
  use scenario <- result.try(required_env("MCP_CONFORMANCE_SCENARIO"))
  use protocol_version <- result.try(required_env(
    "MCP_CONFORMANCE_PROTOCOL_VERSION",
  ))
  use context <- result.try(case envoy.get("MCP_CONFORMANCE_CONTEXT") {
    Ok(raw) ->
      case json.parse(raw, codec.value_decoder()) {
        Ok(jsonrpc.VObject(_) as context) -> Ok(context)
        _ -> Error("MCP_CONFORMANCE_CONTEXT must contain a JSON object")
      }
    Error(_) -> Ok(jsonrpc.VObject([]))
  })
  case string.starts_with(scenario, "auth/") {
    True -> oauth.run(server_url, scenario, protocol_version, context)
    False -> client_core.run(server_url, scenario, protocol_version, context)
  }
}

fn required_env(name: String) -> Result(String, String) {
  case envoy.get(name) {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error("Missing required environment variable: " <> name)
  }
}
