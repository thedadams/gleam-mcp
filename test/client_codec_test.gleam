import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc
import gleam_mcp/server/codec as server_codec
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

pub fn response_envelopes_reject_wrong_versions_ids_and_ambiguous_results_test() {
  let request = jsonrpc.Request(jsonrpc.StringId("req-1"), "ping", None)
  list.each(
    [
      "{\"id\":\"req-1\",\"result\":{}}",
      "{\"jsonrpc\":\"1.0\",\"id\":\"req-1\",\"result\":{}}",
      "{\"jsonrpc\":\"2.0\",\"id\":\"other\",\"result\":{}}",
      "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{},\"error\":{\"code\":-32603,\"message\":\"failed\"}}",
      "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":null}",
      "{\"jsonrpc\":\"2.0\",\"id\":\"other\",\"error\":{\"code\":-32603,\"message\":\"failed\"}}",
      "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"failed\"}}",
    ],
    fn(body) {
      let _ = codec.decode_response(body, request) |> should.be_error
      Nil
    },
  )
}

pub fn response_errors_allow_null_id_when_request_cannot_be_identified_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}"
  let request = jsonrpc.Request(jsonrpc.StringId("req-1"), "ping", None)
  codec.decode_response(body, request)
  |> should.equal(
    Ok(jsonrpc.ErrorResponse(
      None,
      jsonrpc.RpcError(-32_600, "Invalid Request", None),
    )),
  )
  let server_request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "ping",
      Some(actions.ServerRequestPing(None)),
    )
  codec.decode_server_response(body, server_request)
  |> should.equal(
    Ok(jsonrpc.ErrorResponse(
      None,
      jsonrpc.RpcError(-32_600, "Invalid Request", None),
    )),
  )
  codec.decode_server_response(
    "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}",
    server_request,
  )
  |> should.be_error
}

pub fn server_request_envelopes_require_jsonrpc_and_object_params_test() {
  list.each(
    [
      "{\"id\":1,\"method\":\"ping\"}",
      "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}",
      "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}",
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":[]}",
    ],
    fn(body) {
      let _ = codec.decode_server_message(body) |> should.be_error
      Nil
    },
  )
}

pub fn roots_request_and_notification_preserve_flattened_metadata_test() {
  let extra =
    actions.Meta(
      dict.from_list([
        #("com.example/trace", jsonrpc.VString("trace-1")),
        #("extra", jsonrpc.VObject([#("literal", jsonrpc.VBool(True))])),
        #(
          "io.modelcontextprotocol/related-task",
          jsonrpc.VObject([#("taskId", jsonrpc.VString("task-1"))]),
        ),
      ]),
    )
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("roots-1"),
      "roots/list",
      Some(
        actions.ServerRequestListRoots(
          Some(actions.RequestMeta(Some(jsonrpc.IntId(42)), Some(extra))),
        ),
      ),
    )
  codec.encode_server_request(request)
  |> codec.decode_server_message
  |> should.equal(Ok(codec.ServerActionRequest(request)))

  let notification =
    jsonrpc.Notification(
      "notifications/progress",
      Some(
        actions.NotifyProgress(actions.ProgressNotificationParams(
          jsonrpc.StringId("progress-1"),
          1.5,
          Some(2.5),
          None,
          Some(actions.NotificationMeta(Some(extra))),
        )),
      ),
    )
  codec.encode_notification(notification)
  |> codec.decode_server_message
  |> should.equal(Ok(codec.ActionNotification(notification)))
}

pub fn sampling_results_preserve_multiple_and_empty_content_arrays_test() {
  let blocks = [
    actions.SamplingToolUse(actions.ToolUseContent(
      "call-1",
      "weather",
      dict.from_list([#("city", jsonrpc.VString("Paris"))]),
      None,
    )),
    actions.SamplingToolUse(actions.ToolUseContent(
      "call-2",
      "weather",
      dict.from_list([#("city", jsonrpc.VString("London"))]),
      None,
    )),
  ]
  list.each([blocks, []], fn(content) {
    let request = sampling_request()
    let response =
      jsonrpc.ResultResponse(
        jsonrpc.StringId("sampling-1"),
        actions.ServerResultCreateMessage(actions.CreateMessageResult(
          actions.SamplingMessage(
            actions.Assistant,
            actions.MultipleSamplingContent(content),
            None,
          ),
          "model-1",
          Some("toolUse"),
          None,
        )),
      )
    server_codec.encode_server_response(response)
    |> codec.decode_server_response(request)
    |> should.equal(Ok(response))
  })
}

pub fn sampling_task_result_arrays_are_not_decoded_as_tool_results_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":\"task-result\",\"result\":{\"role\":\"assistant\",\"model\":\"model-1\",\"stopReason\":\"endTurn\",\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"text\",\"text\":\"two\"}]}}"
  let result =
    actions.TaskCreateMessage(actions.CreateMessageResult(
      actions.SamplingMessage(
        actions.Assistant,
        actions.MultipleSamplingContent([
          actions.SamplingText(actions.TextContent("one", None, None)),
          actions.SamplingText(actions.TextContent("two", None, None)),
        ]),
        None,
      ),
      "model-1",
      Some("endTurn"),
      None,
    ))
  let id = jsonrpc.StringId("task-result")
  codec.decode_response(
    body,
    jsonrpc.Request(
      id,
      "tasks/result",
      Some(actions.ClientRequestGetTaskResult(actions.TaskIdParams("task-1"))),
    ),
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(id, actions.ClientResultTaskResult(result))),
  )
  codec.decode_server_response(
    body,
    jsonrpc.Request(
      id,
      "tasks/result",
      Some(actions.ServerRequestGetTaskResult(actions.TaskIdParams("task-1"))),
    ),
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(id, actions.ServerResultTaskResult(result))),
  )
}

pub fn elicitation_rejects_unknown_modes_and_defaults_omitted_mode_test() {
  let _ =
    codec.decode_server_message(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"elicitation/create\",\"params\":{\"mode\":\"invalid\",\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}",
    )
    |> should.be_error
  case
    codec.decode_server_message(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"elicitation/create\",\"params\":{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}}",
    )
    |> should.be_ok
  {
    codec.ServerActionRequest(jsonrpc.Request(
      _,
      _,
      Some(actions.ServerRequestElicit(actions.ElicitRequestForm(_))),
    )) -> Nil
    _ -> should.fail()
  }
}

fn sampling_request() -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("sampling-1"),
    "sampling/createMessage",
    Some(
      actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
        messages: [],
        model_preferences: None,
        system_prompt: None,
        include_context: None,
        temperature: None,
        max_tokens: 100,
        stop_sequences: [],
        metadata: None,
        tools: [],
        tool_choice: None,
        task: None,
        meta: None,
      )),
    ),
  )
}

pub fn elicitation_complete_notifications_preserve_metadata_and_old_constructor_test() {
  let plain =
    jsonrpc.Notification(
      "notifications/elicitation/complete",
      Some(
        actions.NotifyElicitationComplete(
          actions.ElicitationCompleteNotificationParams("elicitation-1"),
        ),
      ),
    )
  should.equal(
    codec.encode_notification(plain),
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"elicitation-1\"}}",
  )
  let tagged =
    jsonrpc.Notification(
      "notifications/elicitation/complete",
      Some(
        actions.NotifyElicitationComplete(
          actions.ElicitationCompleteNotificationParamsWithMeta(
            "elicitation-1",
            Some(
              actions.NotificationMeta(
                Some(
                  actions.Meta(
                    dict.from_list([
                      #(
                        "io.modelcontextprotocol/related-task",
                        jsonrpc.VObject([#("taskId", jsonrpc.VString("task-1"))]),
                      ),
                      #("com.example/trace", jsonrpc.VString("trace-1")),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  let encoded = codec.encode_notification(tagged)
  should.equal(
    codec.decode_server_message(encoded),
    Ok(codec.ActionNotification(tagged)),
  )
  should.equal(
    codec.decode_server_message(codec.encode_notification(plain)),
    Ok(codec.ActionNotification(plain)),
  )
}
