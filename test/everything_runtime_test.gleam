import everything_feature_test_support as support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/client_tasks
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/resource_updates
import gleam_mcp/examples/everything/roots
import gleam_mcp/examples/everything/runtime
import gleam_mcp/examples/everything/tasks
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store as store
import gleeunit/should

pub fn logging_interval_runs_during_controls_and_stops_on_cleanup_test() {
  let app = support.app()
  let session = support.ready_session(app, support.empty_capabilities())
  let listener = support.listen(app, session)
  let logger = http_logging.new_logger_with_interval(app, 60)
  http_logging.toggle_tool(logger, app, support.context(session), None)
  |> should.be_ok
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(_)),
  ))) = process.receive(listener, 1000)
  let _ =
    process.spawn_unlinked(fn() { repeat_level_controls(logger, session, 12) })
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(_)),
  ))) = process.receive(listener, 120)
  http_logging.cleanup_session(logger, session)
  support.drain(listener)
  process.receive(listener, 100) |> should.be_error
  http_logging.stop(logger)
  server.close_session(app, session)
}

fn repeat_level_controls(
  logger: http_logging.Logger,
  session: String,
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      http_logging.set_level(logger, session, actions.Debug)
      process.sleep(10)
      repeat_level_controls(logger, session, remaining - 1)
    }
  }
}

pub fn selected_logging_level_filters_immediate_and_interval_messages_test() {
  let app = support.app()
  let session = support.ready_session(app, support.empty_capabilities())
  let listener = support.listen(app, session)
  let logger = http_logging.new_logger_with_interval(app, 2)
  http_logging.set_level(logger, session, actions.Emergency)
  http_logging.toggle_tool(logger, app, support.context(session), None)
  |> should.be_ok
  // Every emitted message must pass the threshold; the choice itself is random.
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(actions.LoggingMessageNotificationParams(
      level,
      logger_name,
      jsonrpc.VString(text),
      _,
    ))),
  ))) = process.receive(listener, 1000)
  should.equal(level, actions.Emergency)
  should.equal(logger_name, None)
  should.equal(text, "Emergency-level message - SessionId " <> session)
  http_logging.cleanup_session(logger, session)
  http_logging.stop(logger)
  server.close_session(app, session)
}

pub fn resource_updates_only_reach_enabled_sessions_and_current_subscriptions_test() {
  let app =
    support.app()
    |> server.register_resource_descriptor(
      actions.Resource(
        "file:///demo",
        "demo",
        None,
        None,
        None,
        None,
        None,
        [],
        None,
      ),
      fn() { Ok([]) },
    )
    |> server.with_resource_subscriptions
  let first = support.ready_session(app, support.empty_capabilities())
  let second = support.ready_session(app, support.empty_capabilities())
  subscribe(app, first, True)
  subscribe(app, second, True)
  let first_listener = support.listen(app, first)
  let second_listener = support.listen(app, second)
  let simulation = resource_updates.new_with_interval(app, 20)
  resource_updates.toggle_tool(simulation, support.context(first))
  |> should.be_ok
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    method,
    Some(actions.NotifyResourceUpdated(actions.ResourceUpdatedNotificationParams(
      uri,
      _,
    ))),
  ))) = process.receive(first_listener, 1000)
  should.equal(method, mcp.method_notify_resource_updated)
  should.equal(uri, "file:///demo")
  process.receive(second_listener, 0) |> should.be_error
  subscribe(app, first, False)
  support.drain(first_listener)
  process.receive(first_listener, 60) |> should.be_error
  resource_updates.close_session(simulation, first)
  resource_updates.stop(simulation)
  server.close_session(app, first)
  server.close_session(app, second)
}

fn subscribe(app: server.Server, session: String, enabled: Bool) -> Nil {
  let action = case enabled {
    True ->
      actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
        "file:///demo",
        None,
      ))
    False ->
      actions.ClientRequestUnsubscribeResource(actions.UnsubscribeRequestParams(
        "file:///demo",
        None,
      ))
  }
  let method = case enabled {
    True -> mcp.method_subscribe_resource
    False -> mcp.method_unsubscribe_resource
  }
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(jsonrpc.StringId("subscription"), method, Some(action)),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = response
  Nil
}

pub fn roots_cache_is_session_scoped_and_refreshes_after_change_test() {
  let app = support.app()
  let cache = roots.new(app)
  let caps =
    actions.ClientCapabilities(
      None,
      Some(actions.ClientRootsCapabilities(Some(True))),
      None,
      None,
      None,
    )
  let first = support.ready_session(app, caps)
  let second = support.ready_session(app, caps)
  let first_listener = support.listen(app, first)
  let second_listener = support.listen(app, second)
  roots.sync(cache, support.context(first), False)
  let assert Ok(store.DeliverRequest(request)) =
    process.receive(first_listener, 1000)
  should.equal(
    support.action(request),
    Some(actions.ServerRequestListRoots(None)),
  )
  let original = [actions.Root("file:///first", Some("First"), None)]
  support.respond(
    app,
    first,
    request,
    actions.ServerResultListRoots(actions.ListRootsResult(original, None)),
  )
  should.equal(roots.fetch(cache, support.context(first)), Ok(original))
  // Cached reads neither refetch nor leak to the second session.
  should.equal(roots.fetch(cache, support.context(first)), Ok(original))
  assert_no_requests(first_listener)
  process.receive(second_listener, 0) |> should.be_error
  roots.sync(cache, support.context(first), True)
  let assert Ok(store.DeliverRequest(refresh)) =
    process.receive(first_listener, 1000)
  support.respond(
    app,
    first,
    refresh,
    actions.ServerResultListRoots(actions.ListRootsResult([], None)),
  )
  wait_for_empty_roots(cache, first, 30)
  roots.close_session(cache, first)
  roots.stop(cache)
  server.close_session(app, first)
  server.close_session(app, second)
}

fn wait_for_empty_roots(cache: roots.Store, id: String, remaining: Int) -> Nil {
  let current = roots.fetch(cache, support.context(id)) |> should.be_ok
  case current, remaining {
    [], _ -> Nil
    _, 0 -> panic as "Roots refresh did not replace cached roots"
    _, _ -> {
      process.sleep(5)
      wait_for_empty_roots(cache, id, remaining - 1)
    }
  }
}

pub fn long_running_tool_reports_each_step_with_the_original_progress_token_test() {
  let app = support.app()
  let session = support.ready_session(app, support.empty_capabilities())
  let listener = support.listen(app, session)
  let done = process.new_subject()
  let context =
    server.RequestContextWithMeta(
      Some(session),
      None,
      jsonrpc.StringId("long-running"),
      Some(actions.RequestMeta(Some(jsonrpc.StringId("progress")), None)),
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        tasks.long_running(
          app,
          context,
          Some(
            dict.from_list([
              #("duration", jsonrpc.VFloat(0.015)),
              #("steps", jsonrpc.VInt(3)),
            ]),
          ),
        ),
      )
    })
  list.each([1.0, 2.0, 3.0], fn(progress) {
    let assert Ok(store.DeliverNotification(jsonrpc.Notification(
      method,
      Some(actions.NotifyProgress(params)),
    ))) = process.receive(listener, 1000)
    should.equal(method, mcp.method_notify_progress)
    should.equal(params.progress_token, jsonrpc.StringId("progress"))
    should.equal(params.progress, progress)
    should.equal(params.total, Some(3.0))
  })
  let result = process.receive(done, 1000) |> should.be_ok |> should.be_ok
  support.text(result) |> string.contains("Steps: 3.") |> should.be_true
  process.receive(listener, 0) |> should.be_error
  server.close_session(app, session)
}

pub fn async_sampling_polls_then_fetches_client_task_result_test() {
  let app = support.app()
  let session = support.ready_session(app, async_capabilities())
  let listener = support.listen(app, session)
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        client_tasks.sampling(
          app,
          support.context(session),
          Some(dict.from_list([#("prompt", jsonrpc.VString("hello"))])),
        ),
      )
    })
  let assert Ok(store.DeliverRequest(request)) = process.receive(listener, 1000)
  let assert Some(actions.ServerRequestCreateMessage(params)) =
    support.action(request)
  should.equal(params.task, Some(actions.TaskMetadata(Some(300_000))))
  should.equal(params.max_tokens, 100)
  should.equal(params.temperature, Some(0.7))
  support.respond(
    app,
    session,
    request,
    actions.ServerResultCreateTask(actions.CreateTaskResult(
      support.task("sampling", actions.Working),
      None,
    )),
  )
  let assert Ok(store.DeliverRequest(poll)) = process.receive(listener, 1500)
  should.equal(request_task_id(poll), "sampling")
  support.respond(
    app,
    session,
    poll,
    actions.ServerResultGetTask(actions.GetTaskResult(
      support.task("sampling", actions.Completed),
      None,
    )),
  )
  let assert Ok(store.DeliverRequest(fetch)) = process.receive(listener, 1000)
  should.equal(request_task_id(fetch), "sampling")
  support.respond(
    app,
    session,
    fetch,
    actions.ServerResultTaskResult(actions.TaskCreateMessage(sample_message())),
  )
  let result = process.receive(done, 1000) |> should.be_ok |> should.be_ok
  let text = support.text(result)
  text
  |> string.contains("[COMPLETED] Async sampling completed!")
  |> should.be_true
  text |> string.contains("Poll 1: completed") |> should.be_true
  text |> string.contains("sampled response") |> should.be_true
  server.close_session(app, session)
}

pub fn async_elicitation_formats_client_task_inputs_test() {
  let app = support.app()
  let session = support.ready_session(app, async_capabilities())
  let listener = support.listen(app, session)
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        client_tasks.elicitation(app, support.context(session), None),
      )
    })
  let assert Ok(store.DeliverRequest(request)) = process.receive(listener, 1000)
  let assert Some(actions.ServerRequestElicit(actions.ElicitRequestForm(params))) =
    support.action(request)
  should.equal(params.task, Some(actions.TaskMetadata(Some(600_000))))
  support.respond(
    app,
    session,
    request,
    actions.ServerResultCreateTask(actions.CreateTaskResult(
      support.task("elicit", actions.InputRequired),
      None,
    )),
  )
  let assert Ok(store.DeliverRequest(poll)) = process.receive(listener, 1500)
  support.respond(
    app,
    session,
    poll,
    actions.ServerResultGetTask(actions.GetTaskResult(
      support.task("elicit", actions.Completed),
      None,
    )),
  )
  let assert Ok(store.DeliverRequest(fetch)) = process.receive(listener, 1000)
  support.respond(
    app,
    session,
    fetch,
    actions.ServerResultTaskResult(
      actions.TaskElicit(actions.ElicitResult(
        actions.ElicitAccept,
        Some(
          dict.from_list([
            #("name", actions.ElicitString("Ada")),
            #("agreeToTerms", actions.ElicitBool(False)),
          ]),
        ),
        None,
      )),
    ),
  )
  let result = process.receive(done, 1000) |> should.be_ok |> should.be_ok
  let assert [
    actions.TextBlock(actions.TextContent(lead, _, _)),
    actions.TextBlock(actions.TextContent(inputs, _, _)),
    actions.TextBlock(actions.TextContent(history, _, _)),
  ] = result.content
  should.equal(lead, "[COMPLETED] User provided the requested information!")
  should.equal(inputs, "User inputs:\n- Name: Ada\n- Agreed to terms: false")
  history |> string.contains("Poll 1: completed") |> should.be_true
  server.close_session(app, session)
}

pub fn cancelled_async_tool_cancels_its_client_task_test() {
  let app = support.app()
  let session = support.ready_session(app, async_capabilities())
  let listener = support.listen(app, session)
  let ready = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(ready, Nil)
      let _ =
        client_tasks.sampling(
          app,
          support.context(session),
          Some(dict.from_list([#("prompt", jsonrpc.VString("hello"))])),
        )
    })
  process.receive(ready, 1000) |> should.be_ok
  let assert Ok(store.DeliverRequest(request)) = process.receive(listener, 1000)
  support.respond(
    app,
    session,
    request,
    actions.ServerResultCreateTask(actions.CreateTaskResult(
      support.task("cancel-me", actions.Working),
      None,
    )),
  )
  // Allow the child monitor handshake to complete while the tool waits to poll.
  process.sleep(20)
  process.kill(worker)
  let assert Ok(store.DeliverRequest(cancel)) = process.receive(listener, 1000)
  should.equal(request_task_id(cancel), "cancel-me")
  support.respond(
    app,
    session,
    cancel,
    actions.ServerResultCancelTask(actions.CancelTaskResult(
      support.task("cancel-me", actions.Cancelled),
      None,
    )),
  )
  server.close_session(app, session)
}

pub fn conditional_tool_visibility_requires_the_precise_client_capability_test() {
  let empty = support.empty_capabilities()
  runtime.tool_visible("trigger-sampling-request-async", empty, False)
  |> should.be_false
  let caps = async_capabilities()
  runtime.tool_visible("trigger-sampling-request-async", caps, False)
  |> should.be_true
  runtime.tool_visible("trigger-elicitation-request-async", caps, False)
  |> should.be_true
  runtime.tool_visible("trigger-sampling-request-async", caps, True)
  |> should.be_false
  runtime.tool_visible("trigger-long-running-operation", empty, True)
  |> should.be_true
  let roots_caps =
    actions.ClientCapabilities(
      ..empty,
      roots: Some(actions.ClientRootsCapabilities(Some(True))),
    )
  runtime.tool_visible("get-roots-list", roots_caps, False) |> should.be_true
  runtime.tool_visible("get-roots-list", roots_caps, True) |> should.be_false
}

fn async_capabilities() -> actions.ClientCapabilities {
  actions.ClientCapabilities(
    None,
    None,
    Some(actions.ClientSamplingCapabilities(None, None)),
    Some(actions.ClientElicitationCapabilities(Some(jsonrpc.VObject([])), None)),
    Some(actions.ClientTasksCapabilities(
      None,
      Some(jsonrpc.VObject([])),
      Some(actions.ClientTaskRequestCapabilities(
        Some(jsonrpc.VObject([])),
        Some(jsonrpc.VObject([])),
      )),
    )),
  )
}

fn sample_message() -> actions.CreateMessageResult {
  actions.CreateMessageResult(
    actions.SamplingMessage(
      actions.Assistant,
      actions.SingleSamplingContent(
        actions.SamplingText(actions.TextContent("sampled response", None, None)),
      ),
      None,
    ),
    "model",
    None,
    None,
  )
}

pub fn research_task_pauses_for_related_elicitation_and_stores_report_test() {
  let app = support.app() |> tasks.register
  let caps =
    actions.ClientCapabilities(
      ..support.empty_capabilities(),
      elicitation: Some(actions.ClientElicitationCapabilities(
        Some(jsonrpc.VObject([])),
        None,
      )),
    )
  let session = support.ready_session(app, caps)
  let listener = support.listen(app, session)
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(
        jsonrpc.StringId("research"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "simulate-research-query",
            Some(
              dict.from_list([
                #("topic", jsonrpc.VString("Python")),
                #("ambiguous", jsonrpc.VBool(True)),
              ]),
            ),
            Some(actions.TaskMetadata(Some(10_000))),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created)) =
    response
  let request = receive_elicitation(listener)
  let assert Some(actions.ServerRequestElicit(actions.ElicitRequestForm(params))) =
    support.action(request)
  let meta = params.meta |> should.be_some
  let actions.Meta(fields) = meta.extra |> should.be_some
  should.equal(
    dict.get(fields, "io.modelcontextprotocol/related-task"),
    Ok(jsonrpc.VObject([#("taskId", jsonrpc.VString(created.task.task_id))])),
  )
  let #(_, status_response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(
        jsonrpc.StringId("status"),
        mcp.method_get_task,
        Some(
          actions.ClientRequestGetTask(actions.TaskIdParams(
            created.task.task_id,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultGetTask(status)) =
    status_response
  should.equal(status.task.status, actions.InputRequired)
  support.respond(
    app,
    session,
    request,
    actions.ServerResultElicit(actions.ElicitResult(
      actions.ElicitAccept,
      Some(
        dict.from_list([
          #("interpretation", actions.ElicitString("programming")),
        ]),
      ),
      None,
    )),
  )
  let assert actions.TaskCallTool(report) =
    server.task_result(app, created.task.task_id) |> should.be_ok
  let text = support.text(report)
  text
  |> string.contains("# Research Report: Python (programming)")
  |> should.be_true
  text
  |> string.contains("`input_required` → `working` → `completed`")
  |> should.be_true
  text |> string.contains("Stage 4: Generating report ✓") |> should.be_true
  server.close_session(app, session)
}

fn receive_elicitation(
  listener: process.Subject(store.ListenerMessage),
) -> jsonrpc.Request(actions.ServerActionRequest) {
  case process.receive(listener, 3500) {
    Ok(store.DeliverRequest(request)) -> request
    Ok(store.DeliverNotification(_)) -> receive_elicitation(listener)
    _ -> panic as "Research did not request clarification"
  }
}

fn request_task_id(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> String {
  case support.action(request) {
    Some(actions.ServerRequestGetTask(params))
    | Some(actions.ServerRequestGetTaskResult(params))
    | Some(actions.ServerRequestCancelTask(params)) -> actions.task_id(params)
    _ -> panic as "Expected a task operation"
  }
}

fn assert_no_requests(listener: process.Subject(store.ListenerMessage)) -> Nil {
  case process.receive(listener, 0) {
    Ok(store.DeliverNotification(_)) -> assert_no_requests(listener)
    Error(_) -> Nil
    _ -> panic as "Cached roots unexpectedly requested the client again"
  }
}

pub fn stdio_logging_uses_reference_labels_and_normal_logs_respect_the_threshold_test() {
  let app = support.app()
  let session = support.ready_session(app, support.empty_capabilities())
  let listener = support.listen(app, session)
  let logger = http_logging.new_without_session_labels(app)
  let result =
    http_logging.toggle_tool(logger, app, support.context(session), None)
    |> should.be_ok
  support.text(result)
  |> string.contains("for session undefined at a 5 second pace.")
  |> should.be_true
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(params)),
  ))) = process.receive(listener, 1000)
  let assert jsonrpc.VString(message) = params.data
  message |> string.contains("SessionId") |> should.be_false
  http_logging.cleanup_session(logger, session)
  http_logging.set_level(logger, session, actions.Emergency)
  http_logging.send(
    logger,
    session,
    actions.LoggingMessageNotificationParams(
      actions.Info,
      Some("everything-server"),
      jsonrpc.VString("below threshold"),
      None,
    ),
  )
  http_logging.send(
    logger,
    session,
    actions.LoggingMessageNotificationParams(
      actions.Emergency,
      Some("everything-server"),
      jsonrpc.VString("above threshold"),
      None,
    ),
  )
  let assert Ok(store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(filtered)),
  ))) = process.receive(listener, 1000)
  should.equal(filtered.data, jsonrpc.VString("above threshold"))
  process.receive(listener, 0) |> should.be_error
  http_logging.stop(logger)
  server.close_session(app, session)
}
