import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/example_server
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec
import gleeunit
import gleeunit/should
import server_test_support

pub fn main() {
  gleeunit.main()
}

pub fn decode_message_parses_initialize_request_test() {
  let body =
    "{"
    <> "\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"initialize\",\"params\":{"
    <> "\"protocolVersion\":\""
    <> jsonrpc.latest_protocol_version
    <> "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0.0\"}}}"

  case codec.decode_message(body) |> should.be_ok {
    codec.ActionRequest(jsonrpc.Request(
      id,
      method,
      Some(actions.RequestInitialize(params)),
    )) -> {
      should.equal(id, jsonrpc.StringId("req-1"))
      should.equal(method, "initialize")
      should.equal(params.protocol_version, jsonrpc.latest_protocol_version)
      should.equal(params.client_info.name, "test-client")
    }
    _ -> should.fail()
  }
}

pub fn decode_message_parses_initialized_notification_test() {
  codec.decode_message(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
  |> should.equal(
    Ok(
      codec.ActionNotification(jsonrpc.Notification(
        "notifications/initialized",
        Some(actions.NotifyInitialized(None)),
      )),
    ),
  )
}

pub fn encode_response_serializes_initialize_result_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "initialize",
      Some(
        actions.RequestInitialize(actions.InitializeRequestParams(
          protocol_version: jsonrpc.latest_protocol_version,
          capabilities: actions.ClientCapabilities(None, None, None, None, None),
          client_info: server_test_support.sample_client_info(),
          meta: None,
        )),
      ),
    )
  let #(_, response) =
    example_server.sample_server() |> server.handle_request(request)
  let encoded = codec.encode_response(response)

  should.be_true(string.contains(
    encoded,
    "\"protocolVersion\":\"" <> jsonrpc.latest_protocol_version <> "\"",
  ))
  should.be_true(string.contains(
    encoded,
    "\"serverInfo\":{\"name\":\"gleam-mcp-test-server\"",
  ))
  should.be_true(string.contains(encoded, "\"tools\":{"))
}

pub fn decode_message_parses_task_get_request_test() {
  let body =
    "{"
    <> "\"jsonrpc\":\"2.0\",\"id\":\"req-2\",\"method\":\"tasks/get\",\"params\":{\"taskId\":\"task-1\"}}"

  case codec.decode_message(body) |> should.be_ok {
    codec.ActionRequest(jsonrpc.Request(
      id,
      method,
      Some(actions.RequestGetTask(actions.TaskIdParams(task_id))),
    )) -> {
      should.equal(id, jsonrpc.StringId("req-2"))
      should.equal(method, mcp.method_get_task)
      should.equal(task_id, "task-1")
    }
    _ -> should.fail()
  }
}

pub fn encode_response_serializes_create_task_result_test() {
  let response =
    jsonrpc.ResultResponse(
      jsonrpc.StringId("req-3"),
      actions.ResultCreateTask(actions.CreateTaskResult(
        task: actions.Task(
          task_id: "task-1",
          status: actions.Working,
          status_message: None,
          created_at: "2026-03-20T00:00:00Z",
          last_updated_at: "2026-03-20T00:00:00Z",
          ttl_ms: Some(1000),
          poll_interval_ms: Some(100),
        ),
        meta: None,
      )),
    )

  let encoded = codec.encode_response(response)
  should.be_true(string.contains(encoded, "\"task\":{"))
  should.be_true(string.contains(encoded, "\"taskId\":\"task-1\""))
  should.be_true(string.contains(encoded, "\"ttl\":1000"))
}
