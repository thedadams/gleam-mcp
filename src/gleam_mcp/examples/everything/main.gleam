import argv
import envoy
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/result
import gleam/string
import gleam_mcp/examples/everything/http
import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/examples/everything/session_resources
import gleam_mcp/examples/everything/sse
import gleam_mcp/examples/everything/stdio as everything_stdio
import mist

pub fn main() -> Nil {
  let argv.Argv(arguments: arguments, ..) = argv.load()
  case arguments {
    [] | ["stdio"] -> everything_stdio.serve()
    ["streamableHttp"] -> run_http(False, default_port())
    ["sse"] -> run_http(True, default_port())
    ["streamableHttp", port] -> parse_port(False, port)
    ["sse", port] -> parse_port(True, port)
    _ -> print_usage()
  }
}

fn default_port() -> Int {
  envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(3001)
}

fn parse_port(deprecated_sse: Bool, port: String) -> Nil {
  case int.parse(port) {
    Ok(parsed) -> run_http(deprecated_sse, parsed)
    Error(_) -> print_usage()
  }
}

fn run_http(deprecated_sse: Bool, port: Int) -> Nil {
  let #(app, _) =
    everything_server.make_application(session_resources.StreamableHttp)
  let handler: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData) = case deprecated_sse {
    True -> sse.handler(app) |> http.deprecated_cors
    False -> http.handler(app)
  }
  let builder = mist.new(handler) |> mist.bind("127.0.0.1") |> mist.port(port)
  case mist.start(builder) {
    Ok(_) -> {
      io.println(
        "Everything server listening on http://127.0.0.1:"
        <> int.to_string(port)
        <> case deprecated_sse {
          True -> "/sse"
          False -> "/mcp"
        },
      )
      process.sleep_forever()
    }
    Error(error) ->
      io.println("Failed to start HTTP server: " <> string.inspect(error))
  }
}

fn print_usage() -> Nil {
  io.println(
    "Usage: gleam run -m gleam_mcp/examples/everything/main -- [stdio|sse [port]|streamableHttp [port]]",
  )
}
