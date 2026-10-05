import child_process
import child_process/stdio
import envoy
import gleam/string
import gleeunit/should
import server_test_support

pub fn official_july_sdk_can_use_the_gleam_http_server_test() {
  case envoy.get("MCP_2026_CLIENT_SCRIPT") {
    Error(_) -> Nil
    Ok(script) -> {
      let url = server_test_support.start_http_server()
      let output =
        child_process.from_name("node")
        |> child_process.args([script, url])
        |> child_process.run(stdio.capture(True))
        |> should.be_ok
      case output.status_code {
        0 -> Nil
        _ ->
          panic as { "Official SDK failed: " <> string.inspect(output.output) }
      }
    }
  }
}
