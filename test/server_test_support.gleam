import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import gleam_mcp/actions
import gleam_mcp/examples/example_server
import gleam_mcp/server
import gleam_mcp/server/streamable_http
import mist

pub fn start_http_server() -> String {
  start_http_server_with_server(example_server.sample_server())
}

pub fn start_http_server_with_server(app_server: server.Server) -> String {
  let reply_to = process.new_subject()
  let _pid =
    process.spawn(fn() { start_http_server_process(reply_to, app_server) })

  case process.receive(reply_to, 1000) {
    Ok(port) -> "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
    Error(Nil) -> panic as "Timed out waiting for test HTTP server to start"
  }
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

fn start_http_server_process(
  reply_to: process.Subject(Int),
  app_server: server.Server,
) {
  let builder =
    mist.new(streamable_http.handler(app_server))
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(reply_to, port) })

  let assert Ok(_) = mist.start(builder)
  process.sleep_forever()
}
