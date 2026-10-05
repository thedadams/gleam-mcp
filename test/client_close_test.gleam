import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/response
import gleam/int
import gleam/option.{Some}
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleeunit/should
import mist

type Message {
  Heartbeat
}

pub fn main() {
  closing_http_listener_does_not_depend_on_delete_support_test()
}

pub fn closing_http_listener_does_not_depend_on_delete_support_test() {
  let started = process.new_subject()
  let connected = process.new_subject()
  let deleted = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn(fn() {
      let assert Ok(_) =
        mist.new(fn(req) {
          case req.method {
            http.Get ->
              mist.chunked(
                req,
                response.new(200)
                  |> response.set_header("content-type", "text/event-stream")
                  |> response.set_header("mcp-session-id", "wire-session"),
                fn(subject) {
                  process.send(connected, process.self())
                  process.send(subject, Heartbeat)
                  subject
                },
                fn(subject, _, connection) {
                  case
                    mist.send_chunk(
                      connection,
                      bit_array.from_string(": heartbeat\n\n"),
                    )
                  {
                    Ok(_) -> {
                      let _ = process.send_after(subject, 10, Heartbeat)
                      mist.chunk_continue(subject)
                    }
                    Error(_) -> mist.chunk_stop()
                  }
                },
              )
            http.Delete -> {
              process.send(deleted, Nil)
              response.new(405)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            }
            _ ->
              response.new(405)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
          }
        })
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(port, _, _) { process.send(started, port) })
        |> mist.start
      process.sleep_forever()
    })
  let port = process.receive(started, 1000) |> should.be_ok
  let created =
    client.new(
      transport.Http(transport.HttpConfig(
        "http://127.0.0.1:" <> int.to_string(port) <> "/mcp",
        [],
        Some(1000),
      )),
      capabilities.none(),
    )
  let created =
    client.with_protocol_version(created, jsonrpc.legacy_protocol_version)
  let created = client.Client(..created, session_id: Some("wire-session"))
  let _ =
    process.spawn_unlinked(fn() {
      process.send(finished, client.listen(created))
    })
  let connection = process.receive(connected, 1000) |> should.be_ok
  let monitor = process.monitor(connection)
  let #(closed, result) = client.close(created)
  result |> should.be_ok
  should.equal(closed.closed, True)
  should.equal(process.receive(deleted, 1000), Ok(Nil))
  let #(listener, outcome) = process.receive(finished, 1000) |> should.be_ok
  outcome |> should.be_ok
  should.equal(listener.closed, True)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  // Closing the SDK listener must also release the underlying SSE connection.
  process.selector_receive(selector, 1000) |> should.be_ok
}
