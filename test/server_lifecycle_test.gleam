import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

pub fn sessions_keep_their_identity_and_close_cleanly_test() {
  let app = new_server()
  let session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, session, Some("alice")))
  should.be_true(server.bind_session(app, session, Some("alice")))
  should.be_false(server.bind_session(app, session, Some("bob")))
  let metadata = server.session_metadata(app, session) |> should.be_some
  should.equal(metadata.principal, Some("alice"))
  should.be_false(metadata.initialized)
  should.be_false(metadata.ready)
  server.close_session(app, session)
  should.be_false(server.has_streamable_http_session(app, session))
  server.session_metadata(app, session) |> should.be_none
}

pub fn session_initialization_gates_requests_and_rejects_reinitialization_test() {
  let app = new_server() |> with_tool("echo", actions.TaskOptional)
  let session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, session, None))
  let context = session_context(session)

  let #(_, ping) =
    server.handle_request_with_context(
      app,
      context,
      client_request("ping", mcp.method_ping, actions.ClientRequestPing(None)),
    )
  should.equal(
    ping,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("ping"),
      actions.ClientResultEmpty(None),
    ),
  )
  let #(_, before_init) =
    server.handle_request_with_context(app, context, list_tools(None))
  let _ = response_error(before_init)

  initialize_session(app, session, empty_capabilities())
  let initialized = server.session_metadata(app, session) |> should.be_some
  should.be_true(initialized.initialized)
  should.be_false(initialized.ready)
  should.equal(initialized.client_capabilities, empty_capabilities())
  let #(_, repeated) =
    server.handle_request_with_context(
      app,
      context,
      initialize_request(empty_capabilities()),
    )
  let _ = response_error(repeated)

  ready_session(app, session)
  let ready = server.session_metadata(app, session) |> should.be_some
  should.be_true(ready.ready)
  let #(_, after_init) =
    server.handle_request_with_context(app, context, list_tools(None))
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListTools(result)) =
    after_init
  should.equal(list.length(result.tools), 1)
  server.close_session(app, session)
}

pub fn roots_requests_require_ready_session_and_negotiated_capability_test() {
  let app = new_server() |> server.with_request_timeout(1000)
  let missing_roots = ready_identity_session(app, None, empty_capabilities())
  let denied_listener = process.new_subject()
  let denied_listener_id = server.new_streamable_http_listener_id()
  server.register_streamable_http_listener(
    app,
    missing_roots,
    denied_listener_id,
    denied_listener,
  )
  send_roots_request(app, missing_roots)
  |> should.be_error
  should.equal(process.receive(denied_listener, 20), Error(Nil))

  let roots_capabilities =
    actions.ClientCapabilities(
      None,
      Some(actions.ClientRootsCapabilities(Some(True))),
      None,
      None,
      None,
    )
  let roots_session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, roots_session, None))
  initialize_session(app, roots_session, roots_capabilities)
  let listener = process.new_subject()
  let listener_id = server.new_streamable_http_listener_id()
  server.register_streamable_http_listener(
    app,
    roots_session,
    listener_id,
    listener,
  )
  send_roots_request(app, roots_session)
  |> should.be_error
  should.equal(process.receive(listener, 20), Error(Nil))

  ready_session(app, roots_session)
  let reply_to = process.new_subject()
  let _ =
    process.spawn(fn() {
      let response =
        server.send_request(
          app,
          session_context(roots_session),
          roots_request(),
        )
      process.send(reply_to, response)
    })
  let assert Ok(streamable_http_store.DeliverRequest(request)) =
    process.receive(listener, 1000)
  should.equal(request, roots_request())
  server.handle_server_sent_response(
    app,
    session_context(roots_session),
    "{\"jsonrpc\":\"2.0\",\"id\":\"roots\",\"result\":{\"roots\":[]}}",
  )
  |> should.be_ok
  let response = process.receive(reply_to, 1000) |> should.be_ok |> should.be_ok
  should.equal(
    response,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("roots"),
      actions.ServerResultListRoots(actions.ListRootsResult([], None)),
    ),
  )
  server.close_session(app, missing_roots)
  server.close_session(app, roots_session)
}

pub fn task_access_follows_authenticated_identity_across_sessions_test() {
  let app = new_server() |> with_tool("echo", actions.TaskOptional)
  let alice_a = ready_identity_session(app, Some("alice"), empty_capabilities())
  let alice_b = ready_identity_session(app, Some("alice"), empty_capabilities())
  let bob = ready_identity_session(app, Some("bob"), empty_capabilities())
  let #(_, create) =
    server.handle_request_with_context(
      app,
      session_context(alice_a),
      tool_request(Some(actions.TaskMetadata(None))),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created)) =
    create
  let get =
    client_request(
      "get",
      mcp.method_get_task,
      actions.ClientRequestGetTask(actions.TaskIdParams(created.task.task_id)),
    )
  let #(_, same_user) =
    server.handle_request_with_context(app, session_context(alice_b), get)
  let assert jsonrpc.ResultResponse(_, actions.ClientResultGetTask(found)) =
    same_user
  should.equal(found.task.task_id, created.task.task_id)
  let #(_, task_result) =
    server.handle_request_with_context(
      app,
      session_context(alice_b),
      client_request(
        "result",
        mcp.method_get_task_result,
        actions.ClientRequestGetTaskResult(actions.TaskIdParams(
          created.task.task_id,
        )),
      ),
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultTaskResult(actions.TaskCallTool(result)),
  ) = task_result
  let actions.Meta(result_meta) = result.meta |> should.be_some
  should.equal(
    dict.get(result_meta, "io.modelcontextprotocol/related-task"),
    Ok(
      jsonrpc.VObject([
        #("taskId", jsonrpc.VString(created.task.task_id)),
      ]),
    ),
  )
  let #(_, other_user) =
    server.handle_request_with_context(app, session_context(bob), get)
  should.equal(
    response_error(other_user).code,
    jsonrpc.invalid_params_error_code,
  )
  let #(_, bob_list) =
    server.handle_request_with_context(
      app,
      session_context(bob),
      client_request(
        "list",
        mcp.method_list_tasks,
        actions.ClientRequestListTasks(actions.PaginatedRequestParams(
          None,
          None,
        )),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListTasks(listed)) =
    bob_list
  should.equal(listed.tasks, [])
  server.close_session(app, alice_a)
  server.close_session(app, alice_b)
  server.close_session(app, bob)
}

pub fn forbidden_task_augmentation_is_rejected_before_tool_execution_test() {
  let calls = process.new_subject()
  let app =
    new_server()
    |> server.register_tool_descriptor(
      tool_descriptor("echo", actions.TaskForbidden),
      fn(_) {
        process.send(calls, Nil)
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
    |> with_tool("task-support", actions.TaskOptional)
  let #(_, response) =
    server.handle_request(app, tool_request(Some(actions.TaskMetadata(None))))
  should.equal(response_error(response).code, jsonrpc.invalid_params_error_code)
  should.equal(process.receive(calls, 20), Error(Nil))
}

pub fn omitted_task_support_defaults_to_forbidden_test() {
  let descriptor =
    actions.Tool(
      ..tool_descriptor("echo", actions.TaskOptional),
      execution: None,
    )
  let app =
    new_server()
    |> server.register_tool_descriptor(descriptor, fn(_) {
      Ok(actions.CallToolResult([], None, None, None))
    })
  should.equal(server.advertised_capabilities(app).tasks, None)
  let app = with_tool(app, "task-support", actions.TaskOptional)
  let #(_, response) =
    server.handle_request(app, tool_request(Some(actions.TaskMetadata(None))))
  should.equal(response_error(response).code, jsonrpc.invalid_params_error_code)
}

pub fn unnegotiated_task_augmentation_runs_tool_normally_test() {
  let caps =
    actions.ServerCapabilities(
      None,
      None,
      None,
      None,
      None,
      Some(actions.ServerToolsCapabilities(None)),
      None,
    )
  let app =
    new_server()
    |> with_tool("echo", actions.TaskOptional)
    |> server.with_capabilities(caps)
  let session = ready_identity_session(app, None, empty_capabilities())
  let #(_, response) =
    server.handle_request_with_context(
      app,
      session_context(session),
      tool_request(Some(actions.TaskMetadata(None))),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCallTool(result)) =
    response
  should.equal(result, actions.CallToolResult([], None, None, None))
  server.close_session(app, session)
}

pub fn contextual_tools_receive_metadata_for_immediate_and_task_requests_test() {
  let calls = process.new_subject()
  let meta =
    Some(actions.RequestMeta(
      Some(jsonrpc.StringId("progress")),
      Some(
        actions.Meta(
          dict.from_list([
            #("com.example/trace", jsonrpc.VString("trace")),
          ]),
        ),
      ),
    ))
  let app =
    new_server()
    |> server.register_context_tool_descriptor(
      tool_descriptor("echo", actions.TaskOptional),
      fn(_, context, _) {
        process.send(calls, #(
          server.request_meta(context),
          server.task_id(context),
        ))
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
  list.each([None, Some(actions.TaskMetadata(None))], fn(task) {
    let #(_, response) =
      server.handle_request(
        app,
        client_request(
          "metadata",
          mcp.method_call_tool,
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "echo",
            None,
            task,
            meta,
          )),
        ),
      )
    let #(received_meta, task_id) = process.receive(calls, 1000) |> should.be_ok
    should.equal(received_meta, meta)
    case task, response {
      None, jsonrpc.ResultResponse(_, actions.ClientResultCallTool(_)) ->
        should.equal(task_id, None)
      Some(_),
        jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created))
      -> should.equal(task_id, Some(created.task.task_id))
      _, _ -> should.fail()
    }
  })
}

pub fn cancellation_terminates_active_requests_in_the_same_session_test() {
  let started = process.new_subject()
  let finished = process.new_subject()
  let app =
    new_server()
    |> server.register_tool_descriptor(
      tool_descriptor("echo", actions.TaskForbidden),
      fn(_) {
        process.send(started, Nil)
        process.sleep(500)
        process.send(finished, Nil)
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
    |> server.with_request_timeout(1000)
  let session = ready_identity_session(app, None, empty_capabilities())
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      let #(_, response) =
        server.handle_request_with_context(
          app,
          session_context(session),
          tool_request(None),
        )
      process.send(reply, response)
    })
  process.receive(started, 1000) |> should.be_ok
  server.handle_notification_with_context(
    app,
    session_context(session),
    jsonrpc.Notification(
      mcp.method_notify_cancelled,
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(jsonrpc.StringId("tool")),
          Some("Cancel test request"),
          None,
        )),
      ),
    ),
  )
  |> should.be_ok
  let response = process.receive(reply, 1000) |> should.be_ok
  should.equal(response_error(response).code, -32_800)
  should.equal(process.receive(finished, 20), Error(Nil))
  server.close_session(app, session)
}

pub fn configured_timeout_terminates_active_requests_test() {
  let app =
    new_server()
    |> server.register_tool_descriptor(
      tool_descriptor("echo", actions.TaskForbidden),
      fn(_) {
        process.sleep(500)
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
    |> server.with_request_timeout(20)
  let #(_, response) = server.handle_request(app, tool_request(None))
  let error = response_error(response)
  should.equal(error.code, -32_800)
  should.equal(error.message, "Request timed out")
}

pub fn descriptor_registration_and_explicit_capabilities_preserve_metadata_test() {
  let descriptor = tool_descriptor("echo", actions.TaskForbidden)
  let advertised =
    actions.ServerCapabilities(
      Some(dict.from_list([#("custom", jsonrpc.VObject([]))])),
      None,
      None,
      None,
      None,
      Some(actions.ServerToolsCapabilities(Some(True))),
      None,
    )
  let app =
    new_server()
    |> server.register_tool_descriptor(descriptor, fn(_) {
      Ok(actions.CallToolResult([], None, None, None))
    })
    |> server.with_capabilities(advertised)
  let #(_, initialize) =
    server.handle_request(app, initialize_request(empty_capabilities()))
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(result)) =
    initialize
  should.equal(result.capabilities, advertised)
  let #(_, listed) = server.handle_request(app, list_tools(None))
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListTools(result)) =
    listed
  should.equal(result.tools, [descriptor])
}

pub fn resource_template_and_prompt_descriptors_preserve_optional_fields_test() {
  let tool = tool_descriptor("metadata", actions.TaskForbidden)
  let annotations =
    Some(actions.Annotations(
      [actions.Assistant],
      Some(0.5),
      Some("2025-11-25T00:00:00Z"),
    ))
  let resource =
    actions.Resource(
      "file:///resource.txt",
      "resource",
      Some("Resource title"),
      Some("Resource description"),
      Some("text/plain"),
      annotations,
      Some(123),
      tool.icons,
      tool.meta,
    )
  let template =
    actions.ResourceTemplate(
      "file:///resource/{name}",
      "template",
      Some("Template title"),
      Some("Template description"),
      Some("text/plain"),
      annotations,
      tool.icons,
      tool.meta,
    )
  let prompt =
    actions.Prompt(
      "prompt",
      Some("Prompt title"),
      Some("Prompt description"),
      [
        actions.PromptArgument(
          "argument",
          Some("Argument title"),
          Some("Argument description"),
          Some(True),
        ),
      ],
      tool.icons,
      tool.meta,
    )
  let app =
    new_server()
    |> server.register_resource_descriptor(resource, fn() { Ok([]) })
    |> server.register_resource_template_descriptor(template, fn(_) { Ok([]) })
    |> server.register_prompt_descriptor(prompt, fn(_) {
      Ok(actions.GetPromptResult(None, [], None))
    })
  let #(_, resources) =
    server.handle_request(
      app,
      client_request(
        "resources",
        mcp.method_list_resources,
        actions.ClientRequestListResources(actions.PaginatedRequestParams(
          None,
          None,
        )),
      ),
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListResources(result),
  ) = resources
  should.equal(result.resources, [resource])
  let #(_, templates) =
    server.handle_request(
      app,
      client_request(
        "templates",
        mcp.method_list_resource_templates,
        actions.ClientRequestListResourceTemplates(
          actions.PaginatedRequestParams(None, None),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListResourceTemplates(result),
  ) = templates
  should.equal(result.resource_templates, [template])
  let #(_, prompts) =
    server.handle_request(
      app,
      client_request(
        "prompts",
        mcp.method_list_prompts,
        actions.ClientRequestListPrompts(actions.PaginatedRequestParams(
          None,
          None,
        )),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListPrompts(result)) =
    prompts
  should.equal(result.prompts, [prompt])
}

pub fn pagination_returns_following_page_and_rejects_invalid_cursors_test() {
  let app =
    new_server()
    |> with_tool("one", actions.TaskForbidden)
    |> with_tool("two", actions.TaskForbidden)
    |> with_tool("three", actions.TaskForbidden)
    |> server.with_page_size(2)
  let #(_, first) = server.handle_request(app, list_tools(None))
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListTools(first_page),
  ) = first
  should.equal(list.length(first_page.tools), 2)
  let cursor = first_page.page.next_cursor |> should.be_some
  let #(_, second) = server.handle_request(app, list_tools(Some(cursor)))
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListTools(second_page),
  ) = second
  should.equal(list.length(second_page.tools), 1)
  should.equal(second_page.page.next_cursor, None)
  should.equal(
    list.length(
      list.unique(
        list.map(list.append(first_page.tools, second_page.tools), fn(tool) {
          tool.name
        }),
      ),
    ),
    3,
  )
  let #(_, invalid) =
    server.handle_request(app, list_tools(Some(actions.Cursor("invalid"))))
  should.equal(response_error(invalid).code, jsonrpc.invalid_params_error_code)
}

pub fn completion_results_never_exceed_one_hundred_values_test() {
  let values = list.repeat("completion", 101)
  let app =
    new_server()
    |> server.set_completion_handler(fn(_) {
      Ok(actions.CompleteResult(
        actions.CompletionValues(values, Some(101), Some(False)),
        None,
      ))
    })
  let #(_, response) =
    server.handle_request(
      app,
      client_request(
        "complete",
        mcp.method_complete,
        actions.ClientRequestComplete(actions.CompleteRequestParams(
          actions.PromptRef("prompt", None),
          actions.CompleteArgument("argument", ""),
          None,
          None,
        )),
      ),
    )
  case response {
    jsonrpc.ResultResponse(_, actions.ClientResultComplete(result)) -> {
      should.be_true(list.length(result.completion.values) <= 100)
      should.equal(result.completion.total, Some(101))
      should.equal(result.completion.has_more, Some(True))
    }
    jsonrpc.ErrorResponse(_, _) -> Nil
    _ -> should.fail()
  }
}

fn new_server() -> server.Server {
  server.new(server_test_support.sample_client_info())
}

fn empty_capabilities() -> actions.ClientCapabilities {
  actions.ClientCapabilities(None, None, None, None, None)
}

fn session_context(id: String) -> server.RequestContext {
  server.RequestContext(Some(id), None)
}

fn initialize_request(
  capabilities: actions.ClientCapabilities,
) -> jsonrpc.Request(actions.ClientActionRequest) {
  client_request(
    "initialize",
    mcp.method_initialize,
    actions.ClientRequestInitialize(actions.InitializeRequestParams(
      jsonrpc.latest_protocol_version,
      capabilities,
      server_test_support.sample_client_info(),
      None,
    )),
  )
}

fn initialize_session(
  app: server.Server,
  session: String,
  capabilities: actions.ClientCapabilities,
) -> Nil {
  let #(_, response) =
    server.handle_request_with_context(
      app,
      session_context(session),
      initialize_request(capabilities),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(_)) =
    response
  Nil
}

fn ready_session(app: server.Server, session: String) -> Nil {
  server.handle_notification_with_context(
    app,
    session_context(session),
    jsonrpc.Notification(
      mcp.method_initialized,
      Some(actions.NotifyInitialized(None)),
    ),
  )
  |> should.be_ok
}

fn ready_identity_session(
  app: server.Server,
  principal: Option(String),
  capabilities: actions.ClientCapabilities,
) -> String {
  let session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, session, principal))
  initialize_session(app, session, capabilities)
  ready_session(app, session)
  session
}

fn roots_request() -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("roots"),
    mcp.method_list_roots,
    Some(actions.ServerRequestListRoots(None)),
  )
}

fn send_roots_request(
  app: server.Server,
  session: String,
) -> Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError) {
  let reply = process.new_subject()
  let worker =
    process.spawn(fn() {
      process.send(
        reply,
        server.send_request(app, session_context(session), roots_request()),
      )
    })
  case process.receive(reply, 1000) {
    Ok(response) -> response
    Error(Nil) -> {
      process.kill(worker)
      panic as "Expected capability denial before sending roots request"
    }
  }
}

fn client_request(
  id: String,
  method: String,
  action: actions.ClientActionRequest,
) -> jsonrpc.Request(actions.ClientActionRequest) {
  jsonrpc.Request(jsonrpc.StringId(id), method, Some(action))
}

fn list_tools(
  cursor: Option(actions.Cursor),
) -> jsonrpc.Request(actions.ClientActionRequest) {
  client_request(
    "tools",
    mcp.method_list_tools,
    actions.ClientRequestListTools(actions.PaginatedRequestParams(cursor, None)),
  )
}

fn tool_request(
  task: Option(actions.TaskMetadata),
) -> jsonrpc.Request(actions.ClientActionRequest) {
  client_request(
    "tool",
    mcp.method_call_tool,
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "echo",
      None,
      task,
      None,
    )),
  )
}

fn response_error(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> jsonrpc.RpcError {
  let assert jsonrpc.ErrorResponse(_, error) = response
  error
}

fn with_tool(
  app: server.Server,
  name: String,
  support: actions.TaskSupport,
) -> server.Server {
  server.register_tool_descriptor(app, tool_descriptor(name, support), fn(_) {
    Ok(actions.CallToolResult([], None, None, None))
  })
}

fn tool_descriptor(name: String, support: actions.TaskSupport) -> actions.Tool {
  actions.Tool(
    name,
    Some("Tool title"),
    Some("Tool description"),
    jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
    Some(actions.ToolExecution(Some(support))),
    Some(jsonrpc.VObject([#("type", jsonrpc.VString("object"))])),
    Some(actions.ToolAnnotations(
      Some("Annotation title"),
      Some(True),
      Some(False),
      Some(True),
      Some(False),
    )),
    [
      actions.Icon(
        "https://example.com/icon.png",
        Some("image/png"),
        ["32x32"],
        Some(actions.LightTheme),
      ),
    ],
    Some(
      actions.Meta(
        dict.from_list([#("com.example/tag", jsonrpc.VString("tag"))]),
      ),
    ),
  )
}
