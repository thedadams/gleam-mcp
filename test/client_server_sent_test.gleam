import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/task_store
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn decode_server_sent_roots_request_test() {
  let assert Ok(codec.ServerActionRequest(request)) =
    codec.decode_server_message(
      "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"roots/list\"}",
    )

  should.equal(
    request,
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      mcp.method_list_roots,
      Some(actions.ServerRequestListRoots(None)),
    ),
  )
}

pub fn decode_server_sent_sampling_request_test() {
  let assert Ok(codec.ServerActionRequest(request)) =
    codec.decode_server_message(
      "{\"jsonrpc\":\"2.0\",\"id\":\"req-2\",\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Hello\"}}],\"maxTokens\":64}}",
    )

  should.equal(
    request,
    jsonrpc.Request(
      jsonrpc.StringId("req-2"),
      mcp.method_create_message,
      Some(
        actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
          messages: [
            actions.SamplingMessage(
              actions.User,
              actions.SingleSamplingContent(
                actions.SamplingText(actions.TextContent("Hello", None, None)),
              ),
              None,
            ),
          ],
          model_preferences: None,
          system_prompt: None,
          include_context: None,
          temperature: None,
          max_tokens: 64,
          stop_sequences: [],
          metadata: None,
          tools: [],
          tool_choice: None,
          task: None,
          meta: None,
        )),
      ),
    ),
  )
}

pub fn decode_server_sent_sampling_response_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-2"),
      mcp.method_create_message,
      Some(
        actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
          messages: [
            actions.SamplingMessage(
              actions.User,
              actions.SingleSamplingContent(
                actions.SamplingText(actions.TextContent("Hello", None, None)),
              ),
              None,
            ),
          ],
          model_preferences: None,
          system_prompt: None,
          include_context: None,
          temperature: None,
          max_tokens: 64,
          stop_sequences: [],
          metadata: None,
          tools: [],
          tool_choice: None,
          task: None,
          meta: None,
        )),
      ),
    )

  let assert Ok(jsonrpc.ResultResponse(
    _,
    actions.ServerResultCreateMessage(actions.CreateMessageResult(model:, ..)),
  )) =
    codec.decode_server_response(
      "{\"jsonrpc\":\"2.0\",\"id\":\"req-2\",\"result\":{\"model\":\"inspector-model\",\"stopReason\":\"endTurn\",\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"Hi back\"}}}",
      request,
    )

  should.equal(model, "inspector-model")
}

pub fn handle_server_sent_roots_request_test() {
  let config =
    capabilities.Config(
      list_roots: Some(fn(_) {
        Ok([
          capabilities.Root("file:///workspace", Some("workspace"), None),
        ])
      }),
      notify_cancelled: None,
      notify_progress: None,
      notify_resource_list_changed: None,
      notify_resource_updated: None,
      notify_prompt_list_changed: None,
      notify_tool_list_changed: None,
      notify_logging_message: None,
      notify_roots_list_changed: None,
      notify_elicitation_complete: None,
      notify_task_status: None,
      task_store: task_store.new(),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  let result =
    capabilities.handle_request(
      config,
      jsonrpc.Request(
        jsonrpc.StringId("req-1"),
        mcp.method_list_roots,
        Some(actions.ServerRequestListRoots(None)),
      ),
    )
    |> should.be_ok

  should.equal(
    result,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("req-1"),
      actions.ServerResultListRoots(actions.ListRootsResult(
        roots: [actions.Root("file:///workspace", Some("workspace"), None)],
        meta: None,
      )),
    ),
  )
}

pub fn handle_server_sent_sampling_request_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_cancelled: None,
      notify_progress: None,
      notify_resource_list_changed: None,
      notify_resource_updated: None,
      notify_prompt_list_changed: None,
      notify_tool_list_changed: None,
      notify_logging_message: None,
      notify_roots_list_changed: None,
      notify_elicitation_complete: None,
      notify_task_status: None,
      task_store: task_store.new(),
      create_message: Some(fn(_) {
        Ok(
          capabilities.CreateMessage(actions.CreateMessageResult(
            message: actions.SamplingMessage(
              actions.Assistant,
              actions.SingleSamplingContent(
                actions.SamplingText(actions.TextContent("Hi back", None, None)),
              ),
              None,
            ),
            model: "test-model",
            stop_reason: None,
            meta: None,
          )),
        )
      }),
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  let params =
    actions.CreateMessageRequestParams(
      messages: [],
      model_preferences: None,
      system_prompt: None,
      include_context: None,
      temperature: None,
      max_tokens: 64,
      stop_sequences: [],
      metadata: None,
      tools: [],
      tool_choice: None,
      task: None,
      meta: None,
    )

  let result =
    capabilities.handle_request(
      config,
      jsonrpc.Request(
        jsonrpc.StringId("req-2"),
        mcp.method_create_message,
        Some(actions.ServerRequestCreateMessage(params)),
      ),
    )
    |> should.be_ok

  case result {
    jsonrpc.ResultResponse(
      _,
      actions.ServerResultCreateMessage(actions.CreateMessageResult(model:, ..)),
    ) -> should.equal(model, "test-model")
    _ -> should.fail()
  }
}

pub fn handle_server_sent_sampling_task_request_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      Ok(
        capabilities.CreateMessage(actions.CreateMessageResult(
          message: actions.SamplingMessage(
            actions.Assistant,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent("Hi back", None, None)),
            ),
            None,
          ),
          model: "test-model",
          stop_reason: None,
          meta: None,
        )),
      )
    })

  let params =
    actions.CreateMessageRequestParams(
      messages: [],
      model_preferences: None,
      system_prompt: None,
      include_context: None,
      temperature: None,
      max_tokens: 64,
      stop_sequences: [],
      metadata: None,
      tools: [],
      tool_choice: None,
      task: Some(actions.TaskMetadata(Some(1000))),
      meta: None,
    )

  let task_id = case
    capabilities.handle_request(
      config,
      jsonrpc.Request(
        jsonrpc.StringId("req-2"),
        mcp.method_create_message,
        Some(actions.ServerRequestCreateMessage(params)),
      ),
    )
    |> should.be_ok
  {
    jsonrpc.ResultResponse(
      _,
      actions.ServerResultCreateTask(actions.CreateTaskResult(task:, ..)),
    ) -> task.task_id
    _ -> panic
  }

  let get_result =
    capabilities.handle_request(
      config,
      jsonrpc.Request(
        jsonrpc.StringId("req-3"),
        mcp.method_get_task,
        Some(actions.ServerRequestGetTask(actions.TaskIdParams(task_id))),
      ),
    )
    |> should.be_ok

  case get_result {
    jsonrpc.ResultResponse(
      _,
      actions.ServerResultGetTask(actions.GetTaskResult(task:, ..)),
    ) -> should.equal(task.status, actions.Completed)
    _ -> should.fail()
  }

  let result =
    capabilities.handle_request(
      config,
      jsonrpc.Request(
        jsonrpc.StringId("req-4"),
        mcp.method_get_task_result,
        Some(actions.ServerRequestGetTaskResult(actions.TaskIdParams(task_id))),
      ),
    )
    |> should.be_ok

  case result {
    jsonrpc.ResultResponse(
      _,
      actions.ServerResultTaskResult(actions.TaskCreateMessage(actions.CreateMessageResult(
        model:,
        ..,
      ))),
    ) -> should.equal(model, "test-model")
    _ -> should.fail()
  }
}

pub fn handle_server_sent_roots_notification_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_cancelled: None,
      notify_progress: None,
      notify_resource_list_changed: None,
      notify_resource_updated: None,
      notify_prompt_list_changed: None,
      notify_tool_list_changed: None,
      notify_logging_message: None,
      notify_roots_list_changed: Some(fn() { Ok(Nil) }),
      notify_elicitation_complete: None,
      notify_task_status: None,
      task_store: task_store.new(),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  capabilities.handle_notification(
    config,
    jsonrpc.Notification(
      mcp.method_notify_roots_list_changed,
      Some(actions.NotifyRootsListChanged(None)),
    ),
  )
  |> should.equal(Ok(Nil))
}

pub fn decode_server_sent_logging_notification_test() {
  let assert Ok(codec.ActionNotification(notification)) =
    codec.decode_server_message(
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":\"hello\"}}",
    )

  should.equal(
    notification,
    jsonrpc.Notification(
      mcp.method_notify_logging_message,
      Some(
        actions.NotifyLoggingMessage(actions.LoggingMessageNotificationParams(
          actions.Info,
          None,
          jsonrpc.VString("hello"),
          None,
        )),
      ),
    ),
  )
}

pub fn handle_server_sent_logging_notification_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_cancelled: None,
      notify_progress: None,
      notify_resource_list_changed: None,
      notify_resource_updated: None,
      notify_prompt_list_changed: None,
      notify_tool_list_changed: None,
      notify_logging_message: Some(fn(params) {
        let actions.LoggingMessageNotificationParams(level, logger, data, meta) =
          params
        should.equal(level, actions.Info)
        should.equal(logger, None)
        should.equal(data, jsonrpc.VString("hello"))
        should.equal(meta, None)
        Ok(Nil)
      }),
      notify_roots_list_changed: None,
      notify_elicitation_complete: None,
      notify_task_status: None,
      task_store: task_store.new(),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  capabilities.handle_notification(
    config,
    jsonrpc.Notification(
      mcp.method_notify_logging_message,
      Some(
        actions.NotifyLoggingMessage(actions.LoggingMessageNotificationParams(
          actions.Info,
          None,
          jsonrpc.VString("hello"),
          None,
        )),
      ),
    ),
  )
  |> should.equal(Ok(Nil))
}

pub fn handle_server_sent_task_status_notification_test() {
  let task =
    actions.Task(
      task_id: "task-1",
      status: actions.Working,
      status_message: Some("working"),
      created_at: "2026-03-18T00:00:00Z",
      last_updated_at: "2026-03-18T00:00:00Z",
      ttl_ms: Some(1000),
      poll_interval_ms: Some(100),
    )

  let config =
    capabilities.Config(
      list_roots: None,
      notify_cancelled: None,
      notify_progress: None,
      notify_resource_list_changed: None,
      notify_resource_updated: None,
      notify_prompt_list_changed: None,
      notify_tool_list_changed: None,
      notify_logging_message: None,
      notify_roots_list_changed: None,
      notify_elicitation_complete: None,
      notify_task_status: Some(fn(params) {
        let actions.TaskStatusNotificationParams(notified_task, meta) = params
        should.equal(notified_task, task)
        should.equal(meta, None)
        Ok(Nil)
      }),
      task_store: task_store.new(),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  capabilities.handle_notification(
    config,
    jsonrpc.Notification(
      mcp.method_notify_task_status,
      Some(
        actions.NotifyTaskStatus(actions.TaskStatusNotificationParams(
          task,
          None,
        )),
      ),
    ),
  )
  |> should.equal(Ok(Nil))
}
