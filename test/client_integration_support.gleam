import envoy
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/client/transport

pub fn local_server_sent_stdio_transport() -> transport.Config {
  transport.Stdio(transport.StdioConfig(
    "gleam",
    ["run", "-m", "gleam_mcp/examples/server_sent_stdio_server"],
    [],
    None,
    Some(5000),
  ))
}

pub fn http_transport() -> Option(transport.Config) {
  case envoy.get("MCP_EVERYTHING_URL") {
    Ok(url) -> Some(transport.Http(transport.HttpConfig(url, [], Some(5000))))
    Error(Nil) -> None
  }
}

pub fn stdio_transport() -> Option(transport.Config) {
  case envoy.get("MCP_EVERYTHING_STDIO_COMMAND") {
    Ok(command) -> {
      let args = case envoy.get("MCP_EVERYTHING_STDIO_ARGS") {
        Ok(value) -> parse_args(value)
        Error(Nil) -> []
      }

      Some(
        transport.Stdio(transport.StdioConfig(
          command,
          args,
          [],
          None,
          Some(5000),
        )),
      )
    }
    Error(Nil) -> None
  }
}

fn parse_args(raw: String) -> List(String) {
  raw
  |> string.split(on: " ")
  |> list.filter(fn(arg) { !string.is_empty(string.trim(arg)) })
}
