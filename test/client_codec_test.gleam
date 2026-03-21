import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn encode_request_serializes_initialize_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "initialize",
      Some(
        actions.ClientRequestInitialize(actions.InitializeRequestParams(
          protocol_version: jsonrpc.latest_protocol_version,
          capabilities: actions.ClientCapabilities(None, None, None, None, None),
          client_info: actions.Implementation(
            name: "test-client",
            version: "1.0.0",
            title: None,
            description: None,
            website_url: None,
            icons: [],
          ),
          meta: None,
        )),
      ),
    )

  codec.encode_request(request)
  |> should.equal(
    "{\"id\":\"req-1\",\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\""
    <> jsonrpc.latest_protocol_version
    <> "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0.0\"}}}",
  )
}

pub fn encode_notification_serializes_jsonrpc_notification_test() {
  let notification = jsonrpc.Notification("notifications/initialized", None)

  codec.encode_notification(notification)
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
}

pub fn decode_response_parses_call_tool_result_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "tools/call",
      Some(
        actions.ClientRequestCallTool(actions.CallToolRequestParams(
          "weather",
          None,
          None,
          None,
        )),
      ),
    )

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Sunny\"}],\"isError\":false}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("req-1"),
      actions.ClientResultCallTool(actions.CallToolResult(
        content: [actions.TextBlock(actions.TextContent("Sunny", None, None))],
        structured_content: None,
        is_error: Some(False),
        meta: None,
      )),
    )),
  )
}

pub fn decode_response_parses_error_response_test() {
  let request = jsonrpc.Request(jsonrpc.StringId("req-1"), "ping", None)

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"error\":{\"code\":-32601,\"message\":\"missing\"}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ErrorResponse(
      Some(jsonrpc.StringId("req-1")),
      jsonrpc.RpcError(code: -32_601, message: "missing", data: None),
    )),
  )
}

pub fn encode_request_serializes_task_augmented_tool_call_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-2"),
      "tools/call",
      Some(
        actions.ClientRequestCallTool(actions.CallToolRequestParams(
          "weather",
          None,
          Some(actions.TaskMetadata(Some(60_000))),
          None,
        )),
      ),
    )

  codec.encode_request(request)
  |> should.equal(
    "{\"id\":\"req-2\",\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"weather\",\"task\":{\"ttl\":60000}}}",
  )
}

pub fn decode_response_parses_create_task_result_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-3"),
      "tools/call",
      Some(
        actions.ClientRequestCallTool(actions.CallToolRequestParams(
          "weather",
          None,
          Some(actions.TaskMetadata(Some(1000))),
          None,
        )),
      ),
    )

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-3\",\"result\":{\"task\":{\"taskId\":\"task-1\",\"status\":\"working\",\"createdAt\":\"2026-03-20T00:00:00Z\",\"lastUpdatedAt\":\"2026-03-20T00:00:00Z\",\"ttl\":1000,\"pollInterval\":100}}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("req-3"),
      actions.ClientResultCreateTask(actions.CreateTaskResult(
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
    )),
  )
}

pub fn decode_response_parses_task_result_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-4"),
      "tasks/result",
      Some(actions.ClientRequestGetTaskResult(actions.TaskIdParams("task-1"))),
    )

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-4\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"isError\":false}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("req-4"),
      actions.ClientResultTaskResult(
        actions.TaskCallTool(actions.CallToolResult(
          content: [actions.TextBlock(actions.TextContent("done", None, None))],
          structured_content: None,
          is_error: Some(False),
          meta: None,
        )),
      ),
    )),
  )
}
