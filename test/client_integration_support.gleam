import gleam/option.{type Option, None, Some}

pub fn everything_url() -> Option(String) {
  case get_env("MCP_EVERYTHING_URL") {
    "" -> None
    value -> Some(value)
  }
}

pub fn sleep_ms(duration: Int) -> Nil {
  sleep(duration)
}

@external(erlang, "client_integration_support_ffi", "get_env")
@external(javascript, "./client_integration_support_ffi.mjs", "getEnv")
fn get_env(name: String) -> String

@external(erlang, "client_integration_support_ffi", "sleep_ms")
@external(javascript, "./client_integration_support_ffi.mjs", "sleepMs")
fn sleep(duration: Int) -> Nil
