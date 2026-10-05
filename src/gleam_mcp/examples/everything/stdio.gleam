import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/examples/everything/session_resources
import gleam_mcp/server/stdio

pub fn serve() -> Nil {
  let #(app, cleanup) =
    everything_server.make_application(session_resources.Stdio)
  stdio.serve(app)
  cleanup()
}
