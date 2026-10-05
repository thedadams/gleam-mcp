import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
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
    codec.ClientActionRequest(jsonrpc.Request(
      id,
      method,
      Some(actions.ClientRequestInitialize(params)),
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
        actions.ClientRequestInitialize(actions.InitializeRequestParams(
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
    codec.ClientActionRequest(jsonrpc.Request(
      id,
      method,
      Some(actions.ClientRequestGetTask(actions.TaskIdParams(task_id))),
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
    )

  let encoded = codec.encode_response(response)
  should.be_true(string.contains(encoded, "\"task\":{"))
  should.be_true(string.contains(encoded, "\"taskId\":\"task-1\""))
  should.be_true(string.contains(encoded, "\"ttl\":1000"))
}

pub fn malformed_message_errors_classify_parse_envelope_and_params_test() {
  list.each(
    [
      #("{", -32_700, None),
      #("{\"id\":1,\"method\":\"ping\"}", -32_600, Some(jsonrpc.IntId(1))),
      #(
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}",
        -32_600,
        Some(jsonrpc.IntId(1)),
      ),
      #("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}", -32_600, None),
      #(
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"weather\"}}",
        -32_600,
        None,
      ),
      #(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
        -32_602,
        Some(jsonrpc.IntId(1)),
      ),
      #(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":[]}",
        -32_602,
        Some(jsonrpc.IntId(1)),
      ),
    ],
    fn(example) {
      let #(body, code, id) = example
      let codec_common.MessageDecodeError(actual_id, error) =
        codec.decode_message_with_error(body) |> should.be_error
      should.equal(actual_id, id)
      should.equal(error.code, code)
    },
  )
  should.be_true(codec_common.is_notification(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}",
  ))
  should.be_false(codec_common.is_notification(
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}",
  ))
  should.be_true(codec_common.is_response(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
  ))
}

pub fn unidentified_errors_serialize_null_response_id_test() {
  let error = jsonrpc.RpcError(-32_600, "Invalid Request", None)
  let response = jsonrpc.ErrorResponse(None, error)
  let encoded = codec.encode_response(response)
  should.be_true(string.contains(encoded, "\"id\":null"))
  client_codec.decode_response(
    encoded,
    jsonrpc.Request(jsonrpc.IntId(1), "ping", None),
  )
  |> should.equal(Ok(response))
}

pub fn initialize_requires_capabilities_test() {
  let codec_common.MessageDecodeError(id, error) =
    codec.decode_message_with_error(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
    )
    |> should.be_error
  should.equal(id, Some(jsonrpc.IntId(1)))
  should.equal(error.code, -32_602)
}

pub fn ping_and_tool_requests_preserve_flattened_metadata_test() {
  let meta =
    actions.RequestMeta(
      Some(jsonrpc.StringId("progress-1")),
      Some(
        actions.Meta(
          dict.from_list([
            #("com.example/trace", jsonrpc.VString("trace-1")),
            #(
              "io.modelcontextprotocol/related-task",
              jsonrpc.VObject([#("taskId", jsonrpc.VString("task-1"))]),
            ),
          ]),
        ),
      ),
    )
  list.each(
    [
      jsonrpc.Request(
        jsonrpc.StringId("ping-1"),
        "ping",
        Some(actions.ClientRequestPing(Some(meta))),
      ),
      jsonrpc.Request(
        jsonrpc.StringId("tool-1"),
        "tools/call",
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "weather",
            None,
            None,
            Some(meta),
          )),
        ),
      ),
    ],
    fn(request) {
      client_codec.encode_request(request)
      |> codec.decode_message
      |> should.equal(Ok(codec.ClientActionRequest(request)))
    },
  )
}

pub fn all_client_notification_families_are_decoded_test() {
  let meta =
    Some(
      actions.NotificationMeta(
        Some(
          actions.Meta(
            dict.from_list([
              #("com.example/trace", jsonrpc.VString("trace-1")),
            ]),
          ),
        ),
      ),
    )
  let task =
    actions.Task(
      "task-1",
      actions.Working,
      None,
      "2025-11-25T00:00:00Z",
      "2025-11-25T00:00:00Z",
      None,
      None,
    )
  list.each(
    [
      jsonrpc.Notification(
        "notifications/cancelled",
        Some(
          actions.NotifyCancelled(actions.CancelledNotificationParams(
            Some(jsonrpc.IntId(1)),
            Some("cancelled"),
            meta,
          )),
        ),
      ),
      jsonrpc.Notification(
        "notifications/progress",
        Some(
          actions.NotifyProgress(actions.ProgressNotificationParams(
            jsonrpc.IntId(1),
            1.5,
            None,
            None,
            meta,
          )),
        ),
      ),
      jsonrpc.Notification(
        "notifications/roots/list_changed",
        Some(actions.NotifyRootsListChanged(meta)),
      ),
      jsonrpc.Notification(
        "notifications/tasks/status",
        Some(
          actions.NotifyTaskStatus(actions.TaskStatusNotificationParams(
            task,
            meta,
          )),
        ),
      ),
    ],
    fn(notification) {
      client_codec.encode_notification(notification)
      |> codec.decode_message
      |> should.equal(Ok(codec.ActionNotification(notification)))
    },
  )
}

pub fn resource_subscription_requests_decode_and_require_uri_test() {
  let meta =
    Some(actions.RequestMeta(
      Some(jsonrpc.StringId("progress-1")),
      Some(
        actions.Meta(
          dict.from_list([
            #("com.example/trace", jsonrpc.VString("trace-1")),
          ]),
        ),
      ),
    ))
  list.each(
    [
      jsonrpc.Request(
        jsonrpc.IntId(1),
        mcp.method_subscribe_resource,
        Some(
          actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
            "file:///resource.txt",
            meta,
          )),
        ),
      ),
      jsonrpc.Request(
        jsonrpc.IntId(2),
        mcp.method_unsubscribe_resource,
        Some(
          actions.ClientRequestUnsubscribeResource(
            actions.UnsubscribeRequestParams("file:///resource.txt", meta),
          ),
        ),
      ),
    ],
    fn(request) {
      client_codec.encode_request(request)
      |> codec.decode_message
      |> should.equal(Ok(codec.ClientActionRequest(request)))
    },
  )
  list.each(
    [mcp.method_subscribe_resource, mcp.method_unsubscribe_resource],
    fn(method) {
      let body =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\""
        <> method
        <> "\",\"params\":{}}"
      let codec_common.MessageDecodeError(id, error) =
        codec.decode_message_with_error(body) |> should.be_error
      should.equal(id, Some(jsonrpc.IntId(1)))
      should.equal(error.code, -32_602)
    },
  )
}
