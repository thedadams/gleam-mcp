import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleeunit/should
import mist

type QuietStreamMessage {
  FlushHeaders
  ReplyAfterQuietPeriod
}

pub fn main() {
  bearer_authenticated_mcp_requests_do_not_follow_redirects_test()
  quiet_sse_stream_respects_the_sdk_deadline()
}

pub fn quiet_sse_stream_respects_the_sdk_deadline_test_() {
  #(atom.create("timeout"), 10, fn() {
    quiet_sse_stream_respects_the_sdk_deadline()
  })
}

fn quiet_sse_stream_respects_the_sdk_deadline() {
  let #(url, owner) =
    start_wire_server(fn(req) {
      mist.chunked(
        req,
        response.new(200)
          |> response.set_header("content-type", "text/event-stream"),
        fn(subject) {
          process.send(subject, FlushHeaders)
          subject
        },
        fn(subject, message, connection) {
          case message {
            FlushHeaders ->
              case
                mist.send_chunk(connection, bit_array.from_string(": open\n\n"))
              {
                Ok(_) -> {
                  let _ =
                    process.send_after(subject, 5500, ReplyAfterQuietPeriod)
                  mist.chunk_continue(subject)
                }
                Error(_) -> mist.chunk_stop()
              }
            ReplyAfterQuietPeriod -> {
              let _ =
                mist.send_chunk(
                  connection,
                  bit_array.from_string(
                    "data: {\"jsonrpc\":\"2.0\",\"id\":\"quiet-ping\",\"result\":{}}\n\n",
                  ),
                )
              mist.chunk_stop()
            }
          }
        },
      )
    })
  let message =
    jsonrpc.Request(
      jsonrpc.StringId("quiet-ping"),
      mcp.method_ping,
      Some(actions.ClientRequestPing(None)),
    )
  let outcome =
    transport.streamable_http_request(
      transport.HttpConfig(url, [], Some(7500)),
      None,
      jsonrpc.latest_protocol_version,
      capabilities.none(),
      message,
      codec.encode_request,
      codec.decode_response,
    )
  process.kill(owner)
  let actual = outcome |> should.be_ok
  should.equal(
    actual.response,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("quiet-ping"),
      actions.ClientResultEmpty(None),
    ),
  )
}

pub fn bearer_authenticated_mcp_requests_do_not_follow_redirects_test() {
  let source_authorization = process.new_subject()
  let target_authorization = process.new_subject()
  let #(target_url, target_owner) =
    start_wire_server(fn(req) {
      process.send(
        target_authorization,
        request.get_header(req, "authorization") |> option.from_result,
      )
      // Also answer a redirected GET so following the303 cannot hide behind a
      // timeout or a mismatched response id.
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "{\"jsonrpc\":\"2.0\",\"id\":\"redirect-ping\",\"result\":{}}",
        )),
      )
    })
  let #(source_url, source_owner) =
    start_wire_server(fn(req) {
      process.send(
        source_authorization,
        request.get_header(req, "authorization") |> option.from_result,
      )
      response.new(303)
      |> response.set_header("location", target_url)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
  let message =
    jsonrpc.Request(
      jsonrpc.StringId("redirect-ping"),
      mcp.method_ping,
      Some(actions.ClientRequestPing(None)),
    )
  let outcome =
    transport.streamable_http_request(
      transport.HttpConfig(
        source_url,
        [#("authorization", "Bearer fixture-secret")],
        Some(1000),
      ),
      None,
      jsonrpc.latest_protocol_version,
      capabilities.none(),
      message,
      codec.encode_request,
      codec.decode_response,
    )
  let source_seen = process.receive(source_authorization, 1000)
  let target_seen = process.receive(target_authorization, 100)
  process.kill(source_owner)
  process.kill(target_owner)
  should.equal(source_seen, Ok(Some("Bearer fixture-secret")))
  should.equal(target_seen, Error(Nil))
  case outcome {
    Error(transport.TimeoutError) -> should.fail()
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

fn start_wire_server(
  handler: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
) -> #(String, process.Pid) {
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        mist.new(handler)
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(port, _, _) { process.send(started, port) })
        |> mist.start
      process.sleep_forever()
    })
  let port = process.receive(started, 1000) |> should.be_ok
  #("http://127.0.0.1:" <> int.to_string(port) <> "/mcp", owner)
}
