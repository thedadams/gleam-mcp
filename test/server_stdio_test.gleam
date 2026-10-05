import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/stdio
import gleeunit/should

const initialized =
  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"

const initialize =
  "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"roots\":{}},\"clientInfo\":{\"name\":\"wire-client\",\"version\":\"1\"}}}"

type Input {
  Line(String)
  Eof
}

pub fn stdio_finite_input_drains_async_responses_test() {
  let output = process.new_subject()
  let app_server =
    test_server()
    |> server.add_tool("slow", "A delayed handler", jsonrpc.VObject([]), fn(_) {
      process.sleep(20)
      Ok(text_result("done"))
    })
  stdio.serve_with_writer(
    app_server,
    yielder.from_list([
      initialize,
      initialized,
      "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"method\":\"tools/call\",\"params\":{\"name\":\"slow\"}}",
    ]),
    fn(line) { process.send(output, line) },
  )
  let assert Ok(first) = process.receive(output, 0)
  let assert Ok(second) = process.receive(output, 0)
  should.be_true(string.contains(first, "\"id\":\"init\""))
  should.be_true(string.contains(second, "done"))
  process.receive(output, 0) |> should.equal(Error(Nil))
}

pub fn stdio_rejects_requests_before_initialize_test() {
  let output = process.new_subject()
  stdio.serve_with_writer(
    test_server(),
    yielder.from_list([
      "{\"jsonrpc\":\"2.0\",\"id\":\"early\",\"method\":\"tools/list\"}",
    ]),
    fn(line) { process.send(output, line) },
  )
  let assert Ok(response) = process.receive(output, 0)
  should.be_true(string.contains(response, "\"error\""))
  should.be_true(string.contains(response, "\"id\":\"early\""))
}

pub fn stdio_reads_cancellation_while_handler_is_running_test() {
  let started = process.new_subject()
  let finished_handler = process.new_subject()
  let app_server =
    test_server()
    |> server.add_tool(
      "slow",
      "Wait for cancellation",
      jsonrpc.VObject([]),
      fn(_) {
        process.send(started, Nil)
        process.sleep(500)
        process.send(finished_handler, Nil)
        Ok(text_result("finished"))
      },
    )
  let #(input, output, finished) = start_session(app_server)
  process.send(input, Line(initialize))
  process.receive(output, 1000) |> should.be_ok
  process.send(input, Line(initialized))
  process.send(
    input,
    Line(
      "{\"jsonrpc\":\"2.0\",\"id\":\"slow\",\"method\":\"tools/call\",\"params\":{\"name\":\"slow\"}}",
    ),
  )
  process.receive(started, 1000) |> should.be_ok
  process.send(
    input,
    Line(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"slow\"}}",
    ),
  )
  let assert Ok(response) = process.receive(output, 1000)
  should.be_true(string.contains(response, "-32800"))
  process.receive(finished_handler, 600) |> should.equal(Error(Nil))
  process.send(input, Eof)
  process.receive(finished, 1000) |> should.equal(Ok(Nil))
}

pub fn stdio_invalid_requests_emit_errors_and_notifications_do_not_test() {
  let output = process.new_subject()
  stdio.serve_with_writer(
    test_server(),
    yielder.from_list([
      "{",
      "{\"jsonrpc\":\"2.0\",\"id\":\"invalid\",\"method\":\"tools/call\",\"params\":{}}",
      "{\"jsonrpc\":\"wrong\",\"method\":\"ping\"}",
      "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\"}",
    ]),
    fn(line) { process.send(output, line) },
  )
  let assert Ok(first) = process.receive(output, 0)
  let assert Ok(second) = process.receive(output, 0)
  should.be_true(string.contains(first, "-32700"))
  should.be_true(string.contains(second, "-32602"))
  should.be_false(string.contains(first, "\n"))
  should.be_false(string.contains(second, "\n"))
  process.receive(output, 0) |> should.equal(Error(Nil))
}

pub fn stdio_server_request_roundtrip_uses_public_adapter_test() {
  let app_server =
    test_server()
    |> server.add_tool_with_context(
      "roots",
      "Ask the client for roots",
      jsonrpc.VObject([]),
      fn(app_server, context, _) {
        let result =
          server.send_request(
            app_server,
            context,
            jsonrpc.Request(
              jsonrpc.StringId("roots-1"),
              "roots/list",
              Some(actions.ServerRequestListRoots(None)),
            ),
          )
        case result {
          Ok(jsonrpc.ResultResponse(_, actions.ServerResultListRoots(result))) -> {
            let root = result.roots |> list.first
            case root {
              Ok(root) -> Ok(text_result(root.uri))
              Error(_) -> Error(jsonrpc.invalid_params_error("Missing root"))
            }
          }
          _ -> Error(jsonrpc.invalid_params_error("Root request failed"))
        }
      },
    )
  let #(input, output, finished) = start_session(app_server)
  process.send(input, Line(initialize))
  process.receive(output, 1000) |> should.be_ok
  process.send(input, Line(initialized))
  process.send(
    input,
    Line(
      "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"method\":\"tools/call\",\"params\":{\"name\":\"roots\"}}",
    ),
  )
  let assert Ok(request) = process.receive(output, 1000)
  should.be_true(string.contains(request, "\"method\":\"roots/list\""))
  process.send(
    input,
    Line(
      "{\"jsonrpc\":\"2.0\",\"id\":\"roots-1\",\"result\":{\"roots\":[{\"uri\":\"file:///workspace\"}]}}",
    ),
  )
  let assert Ok(response) = process.receive(output, 1000)
  should.be_true(string.contains(response, "file:///workspace"))
  should.be_true(string.contains(response, "\"id\":\"call\""))
  process.send(input, Eof)
  process.receive(finished, 1000) |> should.equal(Ok(Nil))
}

pub fn stdio_eof_unblocks_server_request_and_removes_session_test() {
  let session = process.new_subject()
  let app_server =
    test_server()
    |> server.add_tool_with_context(
      "roots",
      "Ask the client",
      jsonrpc.VObject([]),
      fn(app_server, context, _) {
        process.send(session, server.session_id(context))
        let _ =
          server.send_request(
            app_server,
            context,
            jsonrpc.Request(
              jsonrpc.StringId("roots-1"),
              "roots/list",
              Some(actions.ServerRequestListRoots(None)),
            ),
          )
        Ok(text_result("handler completed"))
      },
    )
  let #(input, output, finished) = start_session(app_server)
  process.send(input, Line(initialize))
  process.receive(output, 1000) |> should.be_ok
  process.send(input, Line(initialized))
  process.send(
    input,
    Line(
      "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"method\":\"tools/call\",\"params\":{\"name\":\"roots\"}}",
    ),
  )
  let assert Ok(Some(session_id)) = process.receive(session, 1000)
  process.receive(output, 1000) |> should.be_ok
  process.send(input, Eof)
  let assert Ok(response) = process.receive(output, 1000)
  should.be_true(string.contains(response, "handler completed"))
  process.receive(finished, 1000) |> should.equal(Ok(Nil))
  should.be_false(server.has_streamable_http_session(app_server, session_id))
}

fn start_session(
  app_server: server.Server,
) -> #(process.Subject(Input), process.Subject(String), process.Subject(Nil)) {
  let output = process.new_subject()
  let ready = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      // The reader owns this channel, so supply it from the yielder's initial
      // unfold step, which executes inside the stdio input reader process.
      let lines =
        yielder.unfold(None, fn(input) {
          let input = case input {
            Some(input) -> input
            None -> {
              let input = process.new_subject()
              process.send(ready, input)
              input
            }
          }
          case process.receive_forever(input) {
            Eof -> yielder.Done
            Line(line) -> yielder.Next(line, Some(input))
          }
        })
      stdio.serve_with_writer(app_server, lines, fn(line) {
        process.send(output, line)
      })
      process.send(finished, Nil)
    })
  let assert Ok(input) = process.receive(ready, 1000)
  #(input, output, finished)
}

fn test_server() -> server.Server {
  server.new(
    actions.Implementation("stdio-wire-test", "1", None, None, None, []),
  )
}

fn text_result(text: String) -> actions.CallToolResult {
  actions.CallToolResult(
    [actions.TextBlock(actions.TextContent(text, None, None))],
    None,
    None,
    None,
  )
}
