import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/jsonrpc.{VObject}
import gleam_mcp/mcp
import gleam_mcp/task_store
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn none_config_produces_empty_capabilities_test() {
  capabilities.none()
  |> capabilities.to_initialize_capabilities
  |> should.equal(actions.ClientCapabilities(
    experimental: None,
    roots: None,
    sampling: None,
    elicitation: None,
    tasks: None,
  ))
}

pub fn roots_capability_tracks_list_changed_support_test() {
  let config =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) { Ok([]) })
    |> capabilities.with_notify_roots_list_changed(fn() { Ok(Nil) })

  capabilities.to_initialize_capabilities(config)
  |> should.equal(actions.ClientCapabilities(
    experimental: None,
    roots: Some(actions.ClientRootsCapabilities(list_changed: Some(True))),
    sampling: None,
    elicitation: None,
    tasks: None,
  ))
}

pub fn helper_builders_enable_sampling_capabilities_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      Ok(
        capabilities.CreateMessage(actions.CreateMessageResult(
          message: actions.SamplingMessage(
            actions.Assistant,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent("ok", None, None)),
            ),
            None,
          ),
          model: "demo",
          stop_reason: None,
          meta: None,
        )),
      )
    })
    |> capabilities.with_sampling_tools(fn(_) { Ok(Nil) })

  let actions.ClientCapabilities(sampling: sampling, ..) =
    capabilities.to_initialize_capabilities(config)

  sampling
  |> should.equal(
    Some(actions.ClientSamplingCapabilities(
      context: None,
      tools: Some(VObject([])),
    )),
  )
}

pub fn task_capabilities_are_reported_for_request_handlers_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      Ok(
        capabilities.CreateMessage(actions.CreateMessageResult(
          message: actions.SamplingMessage(
            actions.Assistant,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent("ok", None, None)),
            ),
            None,
          ),
          model: "demo",
          stop_reason: None,
          meta: None,
        )),
      )
    })
    |> capabilities.with_elicit_form(fn(_) {
      Ok(
        capabilities.Elicit(actions.ElicitResult(
          actions.ElicitAccept,
          None,
          None,
        )),
      )
    })

  let actions.ClientCapabilities(tasks: tasks, ..) =
    capabilities.to_initialize_capabilities(config)

  tasks
  |> should.equal(
    Some(actions.ClientTasksCapabilities(
      list: Some(VObject([])),
      cancel: Some(VObject([])),
      requests: Some(actions.ClientTaskRequestCapabilities(
        sampling_create_message: Some(VObject([])),
        elicitation_create: Some(VObject([])),
      )),
    )),
  )
}

pub fn roots_capability_is_disabled_without_list_roots_test() {
  let config =
    capabilities.Config(
      ..capabilities.none(),
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

  let actions.ClientCapabilities(roots: roots, ..) =
    capabilities.to_initialize_capabilities(config)
  roots |> should.be_none
}

pub fn sampling_capability_requires_a_sampling_handler_test() {
  let config =
    capabilities.Config(
      ..capabilities.none(),
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
      create_message: None,
      sampling_tools: Some(fn(_) { Ok(Nil) }),
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  let actions.ClientCapabilities(sampling: sampling, ..) =
    capabilities.to_initialize_capabilities(config)

  sampling |> should.be_none
}

pub fn elicitation_capability_reports_available_handlers_test() {
  let config =
    capabilities.Config(
      ..capabilities.none(),
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
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: Some(fn(_) {
        Ok(
          capabilities.Elicit(actions.ElicitResult(
            actions.ElicitAccept,
            None,
            None,
          )),
        )
      }),
      elicit_url: Some(fn(_) {
        Ok(
          capabilities.Elicit(actions.ElicitResult(
            actions.ElicitAccept,
            None,
            None,
          )),
        )
      }),
    )

  let actions.ClientCapabilities(elicitation: elicitation, ..) =
    capabilities.to_initialize_capabilities(config)

  elicitation
  |> should.equal(
    Some(actions.ClientElicitationCapabilities(
      form: Some(VObject([])),
      url: Some(VObject([])),
    )),
  )
}

pub fn task_elicitation_without_ttl_returns_before_user_input_test() {
  let requested = process.new_subject()
  let reply = process.new_subject()
  let config =
    capabilities.none()
    |> capabilities.with_elicit_form(fn(_) {
      let continue = process.new_subject()
      process.send(requested, continue)
      process.receive_forever(continue)
      Ok(
        capabilities.Elicit(actions.ElicitResult(
          actions.ElicitAccept,
          None,
          None,
        )),
      )
    })
  let params =
    actions.ElicitRequestFormParams(
      message: "Please confirm",
      requested_schema: jsonrpc.VObject([
        #("type", jsonrpc.VString("object")),
        #("properties", jsonrpc.VObject([])),
      ]),
      task: Some(actions.TaskMetadata(None)),
      meta: None,
    )
  let _ =
    process.spawn(fn() {
      process.send(
        reply,
        request(
          config,
          actions.ServerRequestElicit(actions.ElicitRequestForm(params)),
        ),
      )
    })
  let continue = process.receive(requested, 1000) |> should.be_ok
  let response = process.receive(reply, 1000)
  // Release the handler even if acceptance fails, so this test cannot leak a
  // blocked user-interaction worker.
  process.send(continue, Nil)
  let assert jsonrpc.ResultResponse(_, actions.ServerResultCreateTask(created)) =
    response |> should.be_ok
  should.equal(created.task.ttl_ms, None)
  let assert jsonrpc.ResultResponse(
    _,
    actions.ServerResultTaskResult(actions.TaskElicit(result)),
  ) =
    request(
      config,
      actions.ServerRequestGetTaskResult(actions.TaskIdParams(
        created.task.task_id,
      )),
    )
  let actions.Meta(fields) = result.meta |> should.be_some
  should.equal(
    dict.get(fields, "io.modelcontextprotocol/related-task"),
    Ok(jsonrpc.VObject([#("taskId", jsonrpc.VString(created.task.task_id))])),
  )
}

pub fn invalid_task_cursor_returns_a_protocol_error_test() {
  let response =
    request(
      capabilities.none(),
      actions.ServerRequestListTasks(actions.PaginatedRequestParams(
        Some(actions.Cursor("not-issued")),
        None,
      )),
    )
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, jsonrpc.invalid_params_error_code)
}

pub fn root_handler_cannot_return_non_file_uris_test() {
  let config =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) {
      Ok([capabilities.Root("https://example.com", None, None)])
    })
  let assert jsonrpc.ErrorResponse(_, error) =
    request(config, actions.ServerRequestListRoots(None))
  should.equal(error.code, jsonrpc.invalid_params_error_code)
}

pub fn valid_file_roots_are_returned_test() {
  let config =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) {
      Ok([capabilities.Root("file:///workspace", None, None)])
    })
  let assert jsonrpc.ResultResponse(_, actions.ServerResultListRoots(result)) =
    request(config, actions.ServerRequestListRoots(None))
  should.equal(result.roots, [actions.Root("file:///workspace", None, None)])
}

pub fn unsupported_sampling_subcapabilities_are_rejected_test() {
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) { Ok(sample_sampling_response()) })
  let params = sampling_params()
  let assert jsonrpc.ErrorResponse(_, context_error) =
    request(
      config,
      actions.ServerRequestCreateMessage(
        actions.CreateMessageRequestParams(
          ..params,
          include_context: Some(actions.AllServersContext),
        ),
      ),
    )
  should.equal(context_error.code, jsonrpc.invalid_params_error_code)
  let assert jsonrpc.ErrorResponse(_, tool_error) =
    request(
      config,
      actions.ServerRequestCreateMessage(
        actions.CreateMessageRequestParams(
          ..params,
          tool_choice: Some(actions.ToolChoice(Some(actions.ToolAuto))),
        ),
      ),
    )
  should.equal(tool_error.code, jsonrpc.invalid_params_error_code)
}

pub fn sampling_subcapability_callbacks_run_before_sampling_test() {
  let observed = process.new_subject()
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      process.send(observed, "sample")
      Ok(sample_sampling_response())
    })
    |> capabilities.with_sampling_tools(fn(value) {
      let assert jsonrpc.VObject(fields) = value
      should.equal(
        dict.get(dict.from_list(fields), "tools"),
        Ok(jsonrpc.VArray([])),
      )
      process.send(observed, "tools")
      Ok(Nil)
    })
    |> capabilities.with_sampling_context(fn(value) {
      should.equal(value, jsonrpc.VString("thisServer"))
      process.send(observed, "context")
      Ok(Nil)
    })
  let params = sampling_params()
  let response =
    request(
      config,
      actions.ServerRequestCreateMessage(
        actions.CreateMessageRequestParams(
          ..params,
          tool_choice: Some(actions.ToolChoice(Some(actions.ToolAuto))),
          include_context: Some(actions.ThisServerContext),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ServerResultCreateMessage(_)) =
    response
  should.equal(process.receive(observed, 1000), Ok("tools"))
  should.equal(process.receive(observed, 1000), Ok("context"))
  should.equal(process.receive(observed, 1000), Ok("sample"))
}

pub fn sampling_handler_errors_are_returned_as_jsonrpc_errors_test() {
  let rejected = jsonrpc.user_rejected_error()
  let config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) { Error(rejected) })
  should.equal(
    request(config, actions.ServerRequestCreateMessage(sampling_params())),
    jsonrpc.ErrorResponse(Some(jsonrpc.StringId("test")), rejected),
  )
}

fn request(
  config: capabilities.Config,
  action: actions.ServerActionRequest,
) -> jsonrpc.Response(actions.ServerActionResult) {
  capabilities.handle_request(
    config,
    jsonrpc.Request(
      jsonrpc.StringId("test"),
      mcp.method_create_message,
      Some(action),
    ),
  )
  |> should.be_ok
}

fn sampling_params() -> actions.CreateMessageRequestParams {
  actions.CreateMessageRequestParams(
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
  )
}

fn sample_sampling_response() -> capabilities.CreateMessageHandlerResult {
  capabilities.CreateMessage(actions.CreateMessageResult(
    actions.SamplingMessage(
      actions.Assistant,
      actions.SingleSamplingContent(
        actions.SamplingText(actions.TextContent("ok", None, None)),
      ),
      None,
    ),
    "test",
    None,
    None,
  ))
}
