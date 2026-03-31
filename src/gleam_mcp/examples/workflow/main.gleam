import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import gleam_mcp/examples/workflow/server as workflow_server
import gleam_mcp/server/streamable_http
import mist

pub fn main() -> Nil {
  let argv.Argv(arguments: arguments, ..) = argv.load()
  let _ = case arguments {
    [] -> run_streamable_http(3000)
    [port] ->
      case int.parse(port) {
        Ok(parsed) -> run_streamable_http(parsed)
        Error(_) -> print_usage()
      }
    _ -> print_usage()
  }
  Nil
}

fn run_streamable_http(port: Int) -> Nil {
  let app_server = workflow_server.make_server()
  let builder =
    mist.new(streamable_http.handler(app_server))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)

  case mist.start(builder) {
    Ok(_) -> {
      io.println(
        "Workflow server listening on http://127.0.0.1:"
        <> int.to_string(port)
        <> "/mcp",
      )
      process.sleep_forever()
    }
    Error(error) ->
      io.println(
        "Failed to start streamable HTTP server: " <> string.inspect(error),
      )
  }
}

fn print_usage() -> Nil {
  io.println("Usage: gleam run -m workflow/main -- [port]")
}
