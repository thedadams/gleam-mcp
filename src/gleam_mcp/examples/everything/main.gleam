import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/examples/everything/stdio as everything_stdio
import gleam_mcp/examples/everything/streamable_http
import mist

pub fn main() -> Nil {
  let argv.Argv(arguments: arguments, ..) = argv.load()
  let _ = case arguments {
    [] -> {
      let _ = everything_stdio.serve()
      Nil
    }
    ["stdio"] -> {
      let _ = everything_stdio.serve()
      Nil
    }
    ["streamableHttp"] -> run_streamable_http(3000)
    ["streamableHttp", port] ->
      case int.parse(port) {
        Ok(parsed) -> run_streamable_http(parsed)
        Error(_) -> print_usage()
      }
    _ -> print_usage()
  }
  Nil
}

fn run_streamable_http(port: Int) -> Nil {
  let builder =
    mist.new(streamable_http.handler(everything_server.make_server()))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)

  case mist.start(builder) {
    Ok(_) -> {
      io.println(
        "Everything server listening on http://127.0.0.1:"
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
  io.println(
    "Usage: gleam run -m everything/main -- [stdio|streamableHttp [port]]",
  )
}
