import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/stdio
import gleam_mcp/server/streamable_http_store
import gleam_mcp/task_store
import gleam_mcp/wire
import gleeunit/should

pub fn main() {
  discovery_is_stateless_and_reports_both_versions_test()
  modern_metadata_is_required_and_removed_methods_are_rejected_test()
  mrtr_capabilities_are_checked_and_retry_state_is_preserved_test()
  signed_continuations_bind_caller_parameters_and_expiry_test()
  tasks_are_opt_in_and_poll_inline_results_without_old_methods_test()
  task_input_updates_ignore_unknown_keys_and_resume_after_all_inputs_test()
  subscriptions_acknowledge_before_events_filter_and_correlate_test()
  modern_stdio_requests_work_without_initialize_test()
  progress_and_logs_are_request_scoped_and_gated_test()
  modern_stdio_subscription_stream_ack_events_and_cancel_test()
  modern_stdio_initialize_and_malformed_claims_do_not_enter_legacy_test()
}

pub fn discovery_is_stateless_and_reports_both_versions_test() {
  let app = app()
  let result =
    invoke(app, "server/discover", actions.ClientRequestDiscover(meta([])))
    |> response_result
  let assert actions.ClientResultDiscover(discovery) = result
  should.equal(discovery.supported_versions, [
    jsonrpc.latest_protocol_version,
    jsonrpc.legacy_protocol_version,
  ])
  let assert jsonrpc.VObject(fields) =
    wire.result_value(
      result,
      jsonrpc.latest_protocol_version,
      server.implementation(app),
    )
  let fields = dict.from_list(fields)
  should.equal(dict.get(fields, "resultType"), Ok(jsonrpc.VString("complete")))
  should.equal(dict.get(fields, "ttlMs"), Ok(jsonrpc.VInt(0)))
  should.equal(dict.get(fields, "cacheScope"), Ok(jsonrpc.VString("private")))
  let assert Ok(jsonrpc.VObject(metadata)) = dict.get(fields, "_meta")
  should.be_true(dict.has_key(
    dict.from_list(metadata),
    "io.modelcontextprotocol/serverInfo",
  ))
}

pub fn modern_metadata_is_required_and_removed_methods_are_rejected_test() {
  let app = app()
  let context = server.modern_request_context(None, "test", None)
  let #(_, missing) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(
        jsonrpc.IntId(1),
        "server/discover",
        Some(actions.ClientRequestDiscover(None)),
      ),
    )
  should.equal(response_error(missing).code, -32_602)
  should.equal(
    invoke(app, "server/discover", actions.ClientRequestDiscover(None))
      |> response_error
      |> fn(error) { error.code },
    -32_602,
  )
  let malformed =
    Some(actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #("io.modelcontextprotocol/protocolVersion", jsonrpc.VNull),
            #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
          ]),
        ),
      ),
    ))
  should.equal(
    invoke(app, "server/discover", actions.ClientRequestDiscover(malformed))
      |> response_error
      |> fn(error) { error.code },
    -32_602,
  )
  let wrong =
    Some(actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #(
              "io.modelcontextprotocol/protocolVersion",
              jsonrpc.VString("2024-11-05"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
          ]),
        ),
      ),
    ))
  should.equal(
    invoke(app, "server/discover", actions.ClientRequestDiscover(wrong))
      |> response_error
      |> fn(error) { error.code },
    -32_022,
  )
  should.equal(
    invoke(app, "ping", actions.ClientRequestPing(meta([])))
      |> response_error
      |> fn(error) { error.code },
    -32_601,
  )
}

pub fn mrtr_capabilities_are_checked_and_retry_state_is_preserved_test() {
  let app =
    with_tool(app(), None)
    |> server.with_modern_request_handler(fn(_, _, request) {
      case actions.request_state(request), actions.input_responses(request) {
        Some("state"), Some(inputs) -> {
          should.equal(
            dict.get(inputs, "roots"),
            Ok(jsonrpc.VObject([#("roots", jsonrpc.VArray([]))])),
          )
          Ok(
            actions.ClientResultCallTool(actions.CallToolResult(
              [],
              None,
              None,
              None,
            )),
          )
        }
        _, _ ->
          Ok(
            actions.ClientResultInputRequired(actions.InputRequiredResult(
              Some(
                dict.from_list([
                  #(
                    "roots",
                    jsonrpc.VObject([
                      #("method", jsonrpc.VString("roots/list")),
                      #("params", jsonrpc.VObject([])),
                    ]),
                  ),
                ]),
              ),
              Some("state"),
              None,
            )),
          )
      }
    })
  let call =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "echo",
      None,
      None,
      meta([]),
    ))
  should.equal(
    invoke(app, "tools/call", call)
      |> response_error
      |> fn(error) { error.code },
    -32_021,
  )
  let call =
    actions.with_request_meta(call, meta([#("roots", jsonrpc.VObject([]))]))
  let assert actions.ClientResultInputRequired(first) =
    invoke(app, "tools/call", call) |> response_result
  should.equal(first.request_state, Some("state"))
  let retry =
    actions.ClientRequestWithInput(
      call,
      first.request_state,
      Some(
        dict.from_list([
          #("roots", jsonrpc.VObject([#("roots", jsonrpc.VArray([]))])),
        ]),
      ),
    )
  let assert actions.ClientResultCallTool(_) =
    invoke(app, "tools/call", retry) |> response_result
}

pub fn signed_continuations_bind_caller_parameters_and_expiry_test() {
  let app = app()
  let alice = server.modern_request_context(Some("alice"), "a", None)
  let bob = server.modern_request_context(Some("bob"), "b", None)
  let token =
    server.sign_request_state(
      app,
      alice,
      "tools/call:echo:arguments",
      "state",
      1000,
    )
  should.equal(
    server.verify_request_state(app, alice, "tools/call:echo:arguments", token),
    Ok("state"),
  )
  server.verify_request_state(app, bob, "tools/call:echo:arguments", token)
  |> should.be_error
  server.verify_request_state(app, alice, "tools/call:other", token)
  |> should.be_error
  server.verify_request_state(
    app,
    alice,
    "tools/call:echo:arguments",
    token <> "x",
  )
  |> should.be_error
}

pub fn tasks_are_opt_in_and_poll_inline_results_without_old_methods_test() {
  let app = with_tool(app(), Some(actions.TaskOptional))
  let ordinary =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "echo",
      None,
      Some(actions.TaskMetadata(None)),
      meta([]),
    ))
  let assert actions.ClientResultCallTool(_) =
    invoke(app, "tools/call", ordinary) |> response_result
  let call = actions.with_request_meta(ordinary, task_meta())
  let assert actions.ClientResultTaskModern(jsonrpc.VObject(created)) =
    invoke(app, "tools/call", call) |> response_result
  let assert Ok(jsonrpc.VString(id)) =
    dict.get(dict.from_list(created), "taskId")
  should.equal(
    dict.get(dict.from_list(created), "resultType"),
    Ok(jsonrpc.VString("task")),
  )
  let completed = poll_task(app, id, 100)
  should.equal(dict.get(completed, "status"), Ok(jsonrpc.VString("completed")))
  let assert Ok(jsonrpc.VObject(result)) = dict.get(completed, "result")
  // A business error is still a completed result in the modern extension.
  should.equal(
    dict.get(dict.from_list(result), "isError"),
    Ok(jsonrpc.VBool(True)),
  )
  let list_tasks =
    actions.ClientRequestListTasks(actions.PaginatedRequestParams(
      None,
      task_meta(),
    ))
  should.equal(
    invoke(app, "tasks/list", list_tasks)
      |> response_error
      |> fn(error) { error.code },
    -32_601,
  )
}

pub fn task_input_updates_ignore_unknown_keys_and_resume_after_all_inputs_test() {
  let app = with_tool(app(), Some(actions.TaskOptional))
  let context =
    server.modern_request_context(Some("alice"), "first", None)
    |> server.request_context(
      jsonrpc.IntId(10),
      Some(actions.RequestMeta(
        None,
        Some(
          actions.Meta(
            dict.from_list([
              #(
                "io.modelcontextprotocol/protocolVersion",
                jsonrpc.VString(jsonrpc.latest_protocol_version),
              ),
              #(
                "io.modelcontextprotocol/clientCapabilities",
                jsonrpc.VObject([
                  #("roots", jsonrpc.VObject([])),
                  #(
                    "extensions",
                    jsonrpc.VObject([
                      #("io.modelcontextprotocol/tasks", jsonrpc.VObject([])),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      )),
    )
  let request =
    jsonrpc.VObject([
      #("method", jsonrpc.VString("roots/list")),
      #("params", jsonrpc.VObject([])),
    ])
  let assert Ok(actions.ClientResultTaskModern(jsonrpc.VObject(created))) =
    server.create_modern_task(app, context, Some(1000), fn() {
      Ok(
        task_store.ModernInputRequired(
          dict.from_list([#("one", request), #("two", request)]),
          fn(inputs) {
            should.equal(dict.size(inputs), 2)
            Ok(
              task_store.ModernComplete(
                jsonrpc.VObject([#("resultType", jsonrpc.VString("complete"))]),
              ),
            )
          },
        ),
      )
    })
  let assert Ok(jsonrpc.VString(id)) =
    dict.get(dict.from_list(created), "taskId")
  let waiting = poll_status(app, context, id, "input_required", 100)
  should.equal(
    dict.get(waiting, "status"),
    Ok(jsonrpc.VString("input_required")),
  )
  let update = fn(inputs) {
    let action =
      actions.ClientRequestUpdateTask(actions.TaskUpdateParams(
        id,
        Some(jsonrpc.VObject(inputs)),
        server.request_meta(context),
      ))
    let #(_, response) =
      server.handle_request_with_context(
        app,
        context,
        jsonrpc.Request(jsonrpc.IntId(20), "tasks/update", Some(action)),
      )
    response_result(response)
  }
  let _ =
    update([#("unknown", jsonrpc.VObject([])), #("one", jsonrpc.VObject([]))])
  let waiting = poll_status(app, context, id, "input_required", 100)
  let assert Ok(jsonrpc.VObject(remaining)) = dict.get(waiting, "inputRequests")
  should.equal(list.length(remaining), 1)
  let _ = update([#("one", jsonrpc.VObject([])), #("two", jsonrpc.VObject([]))])
  let completed = poll_status(app, context, id, "completed", 100)
  should.equal(dict.get(completed, "status"), Ok(jsonrpc.VString("completed")))
  let bob = server.modern_request_context(Some("bob"), "second", None)
  let action =
    actions.ClientRequestGetTask(actions.TaskIdParamsWithMeta(
      id,
      server.request_meta(context),
    ))
  let #(_, denied) =
    server.handle_request_with_context(
      app,
      bob,
      jsonrpc.Request(jsonrpc.IntId(30), "tasks/get", Some(action)),
    )
  should.equal(response_error(denied).code, -32_602)
  server.update_task_status(app, bob, id, actions.Cancelled, None)
  |> should.be_error
}

pub fn subscriptions_acknowledge_before_events_filter_and_correlate_test() {
  let app = with_tool(app(), None)
  let caps = server.advertised_capabilities(app)
  let app =
    server.with_capabilities(
      app,
      actions.ServerCapabilities(
        ..caps,
        tools: Some(actions.ServerToolsCapabilities(Some(True))),
      ),
    )
  let sink = process.new_subject()
  let context =
    server.modern_request_context(None, "subscribe", Some(sink))
    |> server.request_context(jsonrpc.StringId("listen"), meta([]))
  server.listen_subscription(
    app,
    context,
    actions.SubscriptionsListenParams(
      Some(jsonrpc.VObject([#("toolsListChanged", jsonrpc.VBool(True))])),
      meta([]),
    ),
  )
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    "notifications/subscriptions/acknowledged",
    Some(actions.NotifySubscriptionsAcknowledgedWithFilter(_, Some(metadata))),
  ))) = process.receive(sink, 1000)
  let assert Some(extra) = metadata.extra
  should.equal(
    dict.get(extra.fields, "io.modelcontextprotocol/subscriptionId"),
    Ok(jsonrpc.VString("listen")),
  )
  server.publish_notification(
    app,
    jsonrpc.Notification(
      "notifications/prompts/list_changed",
      Some(actions.NotifyPromptListChanged(None)),
    ),
  )
  server.publish_notification(
    app,
    jsonrpc.Notification(
      "notifications/tools/list_changed",
      Some(actions.NotifyToolListChanged(None)),
    ),
  )
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    "notifications/tools/list_changed",
    Some(actions.NotifyToolListChanged(Some(metadata))),
  ))) = process.receive(sink, 1000)
  let assert Some(extra) = metadata.extra
  should.equal(
    dict.get(extra.fields, "io.modelcontextprotocol/subscriptionId"),
    Ok(jsonrpc.VString("listen")),
  )
  should.equal(process.receive(sink, 10), Error(Nil))
  let #(_, collision) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(
        jsonrpc.StringId("listen"),
        "tools/list",
        Some(
          actions.ClientRequestListTools(actions.PaginatedRequestParams(
            None,
            meta([]),
          )),
        ),
      ),
    )
  should.equal(response_error(collision).code, -32_600)
  server.cancel_incoming_request(app, context, jsonrpc.StringId("listen"))
  let assert Ok(streamable_http_store.DeliverResponse(closing)) =
    process.receive(sink, 1000)
  should.be_true(string.contains(closing, "subscriptionId"))
  server.publish_notification(
    app,
    jsonrpc.Notification(
      "notifications/tools/list_changed",
      Some(actions.NotifyToolListChanged(None)),
    ),
  )
  should.equal(process.receive(sink, 10), Error(Nil))
}

pub fn progress_and_logs_are_request_scoped_and_gated_test() {
  let captured = process.new_subject()
  let base = app()
  let app =
    server.register_context_tool_descriptor(
      base,
      actions.Tool(
        "observe",
        None,
        None,
        jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
        None,
        None,
        None,
        [],
        None,
      ),
      fn(app, context, _) {
        process.send(captured, context)
        server.report_progress(app, context, 1.0, None, None) |> should.be_ok
        server.send_notification(
          app,
          context,
          jsonrpc.Notification(
            "notifications/message",
            Some(
              actions.NotifyLoggingMessage(
                actions.LoggingMessageNotificationParams(
                  actions.Info,
                  None,
                  jsonrpc.VString("below threshold"),
                  None,
                ),
              ),
            ),
          ),
        )
        |> should.be_ok
        server.send_notification(
          app,
          context,
          jsonrpc.Notification(
            "notifications/message",
            Some(
              actions.NotifyLoggingMessage(
                actions.LoggingMessageNotificationParams(
                  actions.Warning,
                  None,
                  jsonrpc.VString("visible"),
                  None,
                ),
              ),
            ),
          ),
        )
        |> should.be_ok
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
  let caps = server.advertised_capabilities(app)
  let app =
    server.with_capabilities(
      app,
      actions.ServerCapabilities(..caps, logging: Some(jsonrpc.VObject([]))),
    )
  let sink = process.new_subject()
  let context = server.modern_request_context(None, "observe", Some(sink))
  let assert Some(metadata) = meta([])
  let assert Some(extra) = metadata.extra
  let metadata =
    Some(actions.RequestMeta(
      Some(jsonrpc.IntId(50)),
      Some(
        actions.Meta(dict.insert(
          extra.fields,
          "io.modelcontextprotocol/logLevel",
          jsonrpc.VString("warning"),
        )),
      ),
    ))
  let action =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "observe",
      None,
      None,
      metadata,
    ))
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(jsonrpc.IntId(1), "tools/call", Some(action)),
    )
  let _ = response_result(response)
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyProgress(progress)),
  ))) = process.receive(sink, 1000)
  should.equal(progress.progress_token, jsonrpc.IntId(50))
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyLoggingMessage(log)),
  ))) = process.receive(sink, 1000)
  should.equal(log.level, actions.Warning)
  should.equal(process.receive(sink, 10), Error(Nil))
  let ended = process.receive(captured, 1000) |> should.be_ok
  server.report_progress(app, ended, 2.0, None, None) |> should.be_ok
  should.equal(process.receive(sink, 10), Error(Nil))
  let action = actions.with_request_meta(action, meta([]))
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(jsonrpc.IntId(2), "tools/call", Some(action)),
    )
  let _ = response_result(response)
  should.equal(process.receive(sink, 10), Error(Nil))
  let app =
    server.with_modern_request_handler(app, fn(app, current, _) {
      server.report_progress(app, ended, 2.0, None, None) |> should.be_ok
      server.report_progress(app, current, 3.0, None, None) |> should.be_ok
      Ok(
        actions.ClientResultCallTool(actions.CallToolResult(
          [],
          None,
          None,
          None,
        )),
      )
    })
  let reused = actions.with_request_meta(action, metadata)
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(jsonrpc.IntId(1), "tools/call", Some(reused)),
    )
  let _ = response_result(response)
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    _,
    Some(actions.NotifyProgress(progress)),
  ))) = process.receive(sink, 1000)
  should.equal(progress.progress, 3.0)
  should.equal(process.receive(sink, 10), Error(Nil))
}

pub fn modern_stdio_requests_work_without_initialize_test() {
  let app = with_tool(app(), None)
  let output = process.new_subject()
  let requests = [
    jsonrpc.Request(
      jsonrpc.IntId(1),
      "server/discover",
      Some(actions.ClientRequestDiscover(meta([]))),
    ),
    jsonrpc.Request(
      jsonrpc.IntId(2),
      "tools/list",
      Some(
        actions.ClientRequestListTools(actions.PaginatedRequestParams(
          None,
          meta([]),
        )),
      ),
    ),
  ]
  stdio.serve_with_writer(
    app,
    requests |> list.map(client_codec.encode_request) |> yielder.from_list,
    fn(line) { process.send(output, line) },
  )
  let one = process.receive(output, 1000) |> should.be_ok
  let two = process.receive(output, 1000) |> should.be_ok
  should.be_true(string.contains(one, "resultType"))
  should.be_true(string.contains(two, "resultType"))
  should.be_true(string.contains(one <> two, "supportedVersions"))
  should.be_true(string.contains(one <> two, "tools"))
}

pub fn modern_stdio_subscription_stream_ack_events_and_cancel_test() {
  let app = with_tool(app(), None)
  let caps = server.advertised_capabilities(app)
  let app =
    server.with_capabilities(
      app,
      actions.ServerCapabilities(
        ..caps,
        tools: Some(actions.ServerToolsCapabilities(Some(True))),
      ),
    )
  let output = process.new_subject()
  let control = process.new_subject()
  let listen =
    client_codec.encode_request(jsonrpc.Request(
      jsonrpc.StringId("subscription"),
      "subscriptions/listen",
      Some(
        actions.ClientRequestSubscriptionsListen(
          actions.SubscriptionsListenParams(
            Some(jsonrpc.VObject([#("toolsListChanged", jsonrpc.VBool(True))])),
            meta([]),
          ),
        ),
      ),
    ))
  let cancel =
    client_codec.encode_notification(jsonrpc.Notification(
      "notifications/cancelled",
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(jsonrpc.StringId("subscription")),
          None,
          None,
        )),
      ),
    ))
  let lines =
    yielder.from_list([listen, cancel])
    |> yielder.map(fn(line) {
      case line == cancel {
        False -> line
        True -> {
          let gate = process.new_subject()
          process.send(control, gate)
          process.receive_forever(gate)
          line
        }
      }
    })
  stdio.serve_with_writer(app, lines, fn(line) {
    process.send(output, line)
    case string.contains(line, "notifications/subscriptions/acknowledged") {
      True ->
        server.publish_notification(
          app,
          jsonrpc.Notification(
            "notifications/tools/list_changed",
            Some(actions.NotifyToolListChanged(None)),
          ),
        )
      False ->
        case string.contains(line, "notifications/tools/list_changed") {
          True -> {
            let gate = process.receive(control, 1000) |> should.be_ok
            process.send(gate, Nil)
          }
          False -> Nil
        }
    }
  })
  let ack = process.receive(output, 1000) |> should.be_ok
  let changed = process.receive(output, 1000) |> should.be_ok
  let closed = process.receive(output, 1000) |> should.be_ok
  should.be_true(string.contains(
    ack,
    "notifications/subscriptions/acknowledged",
  ))
  should.be_true(string.contains(changed, "notifications/tools/list_changed"))
  list.each([ack, changed, closed], fn(line) {
    should.be_true(string.contains(line, "subscriptionId"))
  })
  should.be_true(string.contains(closed, "resultType"))
}

pub fn modern_stdio_initialize_and_malformed_claims_do_not_enter_legacy_test() {
  let app = app()
  let output = process.new_subject()
  let initialized =
    client_codec.encode_request(jsonrpc.Request(
      jsonrpc.IntId(1),
      "initialize",
      Some(
        actions.ClientRequestInitialize(actions.InitializeRequestParams(
          jsonrpc.legacy_protocol_version,
          actions.ClientCapabilities(None, None, None, None, None),
          actions.Implementation("test", "1", None, None, None, []),
          meta([]),
        )),
      ),
    ))
  let malformed =
    Some(actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #("io.modelcontextprotocol/protocolVersion", jsonrpc.VInt(2026)),
            #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
          ]),
        ),
      ),
    ))
  let unknown =
    client_codec.encode_request(jsonrpc.Request(
      jsonrpc.IntId(2),
      "unknown/method",
      Some(actions.ClientRequestDiscover(malformed)),
    ))
  stdio.serve_with_writer(
    app,
    yielder.from_list([initialized, unknown]),
    fn(line) { process.send(output, line) },
  )
  let initialize_error = process.receive(output, 1000) |> should.be_ok
  let invalid_error = process.receive(output, 1000) |> should.be_ok
  should.be_true(string.contains(initialize_error, "-32601"))
  should.be_false(string.contains(initialize_error, "protocolVersion"))
  should.be_true(string.contains(invalid_error, "-32602"))
}

fn app() -> server.Server {
  server.new(actions.Implementation("modern-test", "1", None, None, None, []))
}

fn with_tool(app: server.Server, support) -> server.Server {
  server.register_tool_descriptor(
    app,
    actions.Tool(
      "echo",
      None,
      None,
      jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
      support |> option.map(fn(value) { actions.ToolExecution(Some(value)) }),
      None,
      None,
      [],
      None,
    ),
    fn(_) { Ok(actions.CallToolResult([], None, Some(True), None)) },
  )
}

fn meta(caps) {
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #(
            "io.modelcontextprotocol/protocolVersion",
            jsonrpc.VString(jsonrpc.latest_protocol_version),
          ),
          #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject(caps)),
        ]),
      ),
    ),
  ))
}

fn task_meta() {
  meta([
    #(
      "extensions",
      jsonrpc.VObject([#("io.modelcontextprotocol/tasks", jsonrpc.VObject([]))]),
    ),
  ])
}

fn invoke(app, method, action) {
  server.handle_request(
    app,
    jsonrpc.Request(jsonrpc.IntId(1), method, Some(action)),
  ).1
}

fn response_result(response) {
  let assert jsonrpc.ResultResponse(_, result) = response
  result
}

fn response_error(response) {
  let assert jsonrpc.ErrorResponse(_, error) = response
  error
}

fn poll_task(app, id, attempts) {
  poll_status(
    app,
    server.modern_request_context(None, "poll", None)
      |> server.request_context(jsonrpc.IntId(2), task_meta()),
    id,
    "completed",
    attempts,
  )
}

fn poll_status(app, context, id, status, attempts) {
  let action =
    actions.ClientRequestGetTask(actions.TaskIdParamsWithMeta(
      id,
      server.request_meta(context),
    ))
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(jsonrpc.IntId(2), "tasks/get", Some(action)),
    )
  let assert actions.ClientResultTaskModern(jsonrpc.VObject(fields)) =
    response_result(response)
  let fields = dict.from_list(fields)
  case
    dict.get(fields, "status") == Ok(jsonrpc.VString(status)) || attempts == 0
  {
    True -> fields
    False -> {
      process.sleep(2)
      poll_status(app, context, id, status, attempts - 1)
    }
  }
}
