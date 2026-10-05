import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleeunit/should

pub fn main() {
  cancellation_stops_ordinary_sampling_worker_test()
  cancellation_registration_is_acknowledged_test()
  callback_crashes_return_jsonrpc_errors_without_waiting_for_timeout_test()
  callback_deadline_stops_worker_and_returns_error_test()
  sampling_message_tool_blocks_require_tools_capability_test()
}

pub fn cancellation_stops_ordinary_sampling_worker_test() {
  let started = process.new_subject()
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      let release = process.new_subject()
      process.send(started, process.self())
      process.receive_forever(release)
      panic as "Cancelled callback was allowed to continue"
    })
  let reply = process.new_subject()
  capabilities.start_request(config, request("sample"), reply)
  let worker = process.receive(started, 1000) |> should.be_ok
  let monitor = process.monitor(worker)
  cancel(config, "sample")
  let response = process.receive(reply, 1000) |> should.be_ok |> should.be_ok
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, -32_800)
  let selector =
    process.new_selector() |> process.select_monitors(fn(down) { down })
  let assert process.ProcessDown(reference, pid, _) =
    process.selector_receive(selector, 1000) |> should.be_ok
  should.equal(reference, monitor)
  should.equal(pid, worker)
}

pub fn cancellation_registration_is_acknowledged_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      let release = process.new_subject()
      process.receive_forever(release)
      panic as "Cancelled callback was allowed to continue"
    })
  let reply = process.new_subject()
  capabilities.start_request(config, request("registered"), reply)
  // No callback-start handshake is needed: start_request has already registered
  // the incoming ID before this cancellation is dispatched.
  cancel(config, "registered")
  let response = process.receive(reply, 1000) |> should.be_ok |> should.be_ok
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, -32_800)
}

pub fn callback_crashes_return_jsonrpc_errors_without_waiting_for_timeout_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) { panic as "sampling crashed" })
    |> capabilities.with_request_timeout(60_000)
  let reply = process.new_subject()
  capabilities.start_request(config, request("crash"), reply)
  let response = process.receive(reply, 1000) |> should.be_ok |> should.be_ok
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, -32_603)
}

pub fn callback_deadline_stops_worker_and_returns_error_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      let release = process.new_subject()
      process.receive_forever(release)
      panic as "Timed out callback was allowed to continue"
    })
    |> capabilities.with_request_timeout(10)
  let reply = process.new_subject()
  capabilities.start_request(config, request("timeout"), reply)
  let response = process.receive(reply, 1000) |> should.be_ok |> should.be_ok
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, -32_800)
}

pub fn sampling_message_tool_blocks_require_tools_capability_test() {
  let called = process.new_subject()
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      process.send(called, Nil)
      panic as "Unsupported tool blocks reached sampling handler"
    })
  let blocks = [
    actions.SamplingToolUse(actions.ToolUseContent(
      "tool",
      "echo",
      dict.new(),
      None,
    )),
    actions.SamplingToolResult(actions.ToolResultContent(
      "tool",
      [],
      None,
      None,
      None,
    )),
  ]
  list.each(blocks, fn(block) {
    let assert jsonrpc.Request(
      id,
      method,
      Some(actions.ServerRequestCreateMessage(params)),
    ) = request("tool-content")
    let params =
      actions.CreateMessageRequestParams(..params, messages: [
        actions.SamplingMessage(
          actions.User,
          actions.SingleSamplingContent(block),
          None,
        ),
      ])
    let response =
      capabilities.handle_request(
        config,
        jsonrpc.Request(
          id,
          method,
          Some(actions.ServerRequestCreateMessage(params)),
        ),
      )
      |> should.be_ok
    let assert jsonrpc.ErrorResponse(_, error) = response
    should.equal(error.code, jsonrpc.invalid_params_error_code)
  })
  should.equal(process.receive(called, 5), Error(Nil))
}

fn request(id: String) -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId(id),
    mcp.method_create_message,
    Some(
      actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
        [],
        None,
        None,
        None,
        None,
        64,
        [],
        None,
        [],
        None,
        None,
        None,
      )),
    ),
  )
}

fn cancel(config: capabilities.Config, id: String) -> Nil {
  capabilities.handle_notification(
    config,
    jsonrpc.Notification(
      mcp.method_notify_cancelled,
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(jsonrpc.StringId(id)),
          None,
          None,
        )),
      ),
    ),
  )
  |> should.be_ok
}
