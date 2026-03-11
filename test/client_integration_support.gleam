import envoy
import gleam/option.{type Option, None, Some}

pub fn everything_url() -> Option(String) {
  case envoy.get("MCP_EVERYTHING_URL") {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}
