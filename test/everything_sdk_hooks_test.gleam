import everything_feature_test_support as support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/tool_helpers
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store as store
import gleam_mcp/task_store
import gleeunit/should

pub fn projection_filters_discovery_and_rejects_direct_tool_calls_in_both_versions_test() {
  let invoked = process.new_subject()
  let app =
    support.app()
    |> server.register_context_tool_descriptor(
      tool("visible", None),
      fn(_, _, _) { Ok(tool_helpers.text_result("visible")) },
    )
    |> server.register_context_tool_descriptor(
      tool("hidden", None),
      fn(_, _, _) {
        process.send(invoked, Nil)
        Ok(tool_helpers.text_result("hidden"))
      },
    )
    |> server.with_server_projection(fn(app, _) {
      server.filter_tools(app, fn(tool) { tool.name != "hidden" })
    })
  let session = support.ready_session(app, support.empty_capabilities())
  let contexts = [
    #(support.context(session), None),
    #(server.modern_request_context(None, "modern", None), modern_meta()),
  ]
  list.each(contexts, fn(entry) {
    let #(_, listed) =
      server.handle_request_with_context(
        app,
        entry.0,
        jsonrpc.Request(
          jsonrpc.StringId("tools"),
          mcp.method_list_tools,
          Some(
            actions.ClientRequestListTools(actions.PaginatedRequestParams(
              None,
              entry.1,
            )),
          ),
        ),
      )
    let assert jsonrpc.ResultResponse(_, actions.ClientResultListTools(result)) =
      listed
    should.equal(list.map(result.tools, fn(tool) { tool.name }), ["visible"])
    let #(_, hidden) =
      server.handle_request_with_context(
        app,
        entry.0,
        jsonrpc.Request(
          jsonrpc.StringId("hidden"),
          mcp.method_call_tool,
          Some(
            actions.ClientRequestCallTool(actions.CallToolRequestParams(
              "hidden",
              None,
              None,
              entry.1,
            )),
          ),
        ),
      )
    let assert jsonrpc.ErrorResponse(_, error) = hidden
    should.equal(error.code, jsonrpc.invalid_params_error_code)
  })
  process.receive(invoked, 0) |> should.be_error
  server.close_session(app, session)
}

pub fn session_close_cancels_anonymous_task_workers_and_calls_application_cleanup_test() {
  let started = process.new_subject()
  let closed = process.new_subject()
  let app =
    support.app()
    |> server.register_context_tool_descriptor(
      tool("wait", Some(actions.TaskOptional)),
      fn(_, _, _) {
        process.send(started, process.self())
        process.sleep_forever()
        Ok(tool_helpers.text_result("unreachable"))
      },
    )
    |> server.with_tool_task_options("wait", Some(300_000), 1000)
    |> server.with_tool_task_lifecycle(
      "wait",
      task_store.TaskLifecycle(Some("Registered before work"), None, None),
    )
    |> server.with_session_close_handler(fn(id) { process.send(closed, id) })
  let session = support.ready_session(app, support.empty_capabilities())
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(
        jsonrpc.StringId("wait"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "wait",
            None,
            Some(actions.TaskMetadata(Some(10))),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created)) =
    response
  should.equal(created.task.ttl_ms, Some(300_000))
  should.equal(created.task.poll_interval_ms, Some(1000))
  should.equal(created.task.status_message, Some("Registered before work"))
  let worker = process.receive(started, 1000) |> should.be_ok
  let monitor = process.monitor(worker)
  let waiter = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(waiter, server.task_result(app, created.task.task_id))
    })
  server.close_session(app, session)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  process.selector_receive(down, 1000) |> should.be_ok
  process.receive(waiter, 1000) |> should.be_ok |> should.be_error
  should.equal(process.receive(closed, 1000), Ok(session))
  server.task_result(app, created.task.task_id) |> should.be_error
}

pub fn task_store_scope_cleanup_releases_waiters_without_deleting_other_owners_test() {
  let tasks = task_store.new()
  let owner = Some("session:closing")
  let first =
    task_store.create_scoped_with_poll_interval(tasks, Some(1000), owner, 1000)
  let other = task_store.create_scoped(tasks, None, Some("principal:durable"))
  let waiter = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(waiter, task_store.result(tasks, first.task_id))
    })
  task_store.close_scope(tasks, owner)
  process.receive(waiter, 1000) |> should.be_ok |> should.be_error
  task_store.get(tasks, first.task_id) |> should.be_error
  should.equal(task_store.get(tasks, other.task_id), Ok(other))
  task_store.close_scope(tasks, Some("principal:durable"))
}

pub fn resource_subscription_accessor_and_close_cleanup_are_scoped_test() {
  let app =
    support.app()
    |> server.register_resource_descriptor(
      actions.Resource(
        "file:///resource",
        "resource",
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
  subscribe(app, first)
  should.equal(server.resource_subscriptions(app, first), ["file:///resource"])
  should.equal(server.resource_subscriptions(app, second), [])
  server.close_session(app, first)
  should.equal(server.resource_subscriptions(app, first), [])
  server.close_session(app, second)
}

pub fn outgoing_task_methods_preserve_parent_correlation_and_existing_metadata_test() {
  let app = support.app()
  let caps =
    actions.ClientCapabilities(
      ..support.empty_capabilities(),
      tasks: Some(actions.ClientTasksCapabilities(
        None,
        Some(jsonrpc.VObject([])),
        None,
      )),
    )
  let session = support.ready_session(app, caps)
  let listener = support.listen(app, session)
  let original =
    Some(actions.RequestMeta(
      Some(jsonrpc.IntId(99)),
      Some(
        actions.Meta(
          dict.from_list([#("custom", jsonrpc.VString("preserved"))]),
        ),
      ),
    ))
  let params = actions.TaskIdParamsWithMeta("child", original)
  let cases = [
    #(
      mcp.method_get_task,
      actions.ServerRequestGetTask(params),
      actions.ServerResultGetTask(actions.GetTaskResult(
        support.task("child", actions.Completed),
        None,
      )),
    ),
    #(
      mcp.method_get_task_result,
      actions.ServerRequestGetTaskResult(params),
      actions.ServerResultTaskResult(
        actions.TaskElicit(actions.ElicitResult(
          actions.ElicitAccept,
          None,
          None,
        )),
      ),
    ),
    #(
      mcp.method_cancel_task,
      actions.ServerRequestCancelTask(params),
      actions.ServerResultCancelTask(actions.CancelTaskResult(
        support.task("child", actions.Cancelled),
        None,
      )),
    ),
  ]
  list.each(cases, fn(entry) {
    let done = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          done,
          server.send_request(
            app,
            server.RequestContext(Some(session), Some("parent")),
            jsonrpc.Request(jsonrpc.StringId(entry.0), entry.0, Some(entry.1)),
          ),
        )
      })
    let assert Ok(store.DeliverRequest(request)) =
      process.receive(listener, 1000)
    let params = case support.action(request) {
      Some(actions.ServerRequestGetTask(params))
      | Some(actions.ServerRequestGetTaskResult(params))
      | Some(actions.ServerRequestCancelTask(params)) -> params
      _ -> panic as "Expected task method"
    }
    should.equal(actions.task_id(params), "child")
    let meta = actions.task_id_meta(params) |> should.be_some
    should.equal(meta.progress_token, Some(jsonrpc.IntId(99)))
    let actions.Meta(fields) = meta.extra |> should.be_some
    should.equal(dict.get(fields, "custom"), Ok(jsonrpc.VString("preserved")))
    should.equal(
      dict.get(fields, "io.modelcontextprotocol/related-task"),
      Ok(jsonrpc.VObject([#("taskId", jsonrpc.VString("parent"))])),
    )
    support.respond(app, session, request, entry.2)
    process.receive(done, 1000) |> should.be_ok |> should.be_ok
  })
  server.close_session(app, session)
}

fn tool(name: String, task_support) -> actions.Tool {
  let tool =
    tool_helpers.descriptor(
      name,
      name,
      "test",
      tool_helpers.empty_schema(),
      None,
      tool_helpers.read_only_annotations(),
    )
  actions.Tool(
    ..tool,
    execution: option.then(task_support, fn(support) {
      Some(actions.ToolExecution(Some(support)))
    }),
  )
}

fn modern_meta() {
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #(
            "io.modelcontextprotocol/protocolVersion",
            jsonrpc.VString(jsonrpc.latest_protocol_version),
          ),
          #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
        ]),
      ),
    ),
  ))
}

fn subscribe(app: server.Server, id: String) -> Nil {
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(id),
      jsonrpc.Request(
        jsonrpc.StringId("subscribe"),
        mcp.method_subscribe_resource,
        Some(
          actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
            "file:///resource",
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = response
  Nil
}

pub fn closing_an_authenticated_transport_preserves_its_durable_owner_task_test() {
  let app =
    support.app()
    |> server.register_context_tool_descriptor(
      tool("durable", Some(actions.TaskOptional)),
      fn(_, _, _) {
        process.sleep(30)
        Ok(tool_helpers.text_result("completed after transport close"))
      },
    )
  let session =
    support.ready_identity_session(
      app,
      support.empty_capabilities(),
      Some("alice"),
    )
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(
        jsonrpc.StringId("durable"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "durable",
            None,
            Some(actions.TaskMetadata(Some(1000))),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created)) =
    response
  server.close_session(app, session)
  let assert actions.TaskCallTool(result) =
    server.task_result(app, created.task.task_id) |> should.be_ok
  should.equal(support.text(result), "completed after transport close")
}

pub fn context_logging_hook_alone_advertises_logging_and_receives_session_context_test() {
  let captured = process.new_subject()
  let app =
    server.new(
      actions.Implementation("logging-hook", "1.0", None, None, None, []),
    )
    |> server.set_context_logging_handler(fn(context, level) {
      process.send(captured, #(context, level))
      Ok(Nil)
    })
  server.advertised_capabilities(app).logging |> should.be_some
  let session = support.ready_session(app, support.empty_capabilities())
  let meta =
    Some(actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([#("custom", jsonrpc.VString("preserved"))]),
        ),
      ),
    ))
  let #(_, response) =
    server.handle_request_with_context(
      app,
      support.context(session),
      jsonrpc.Request(
        jsonrpc.StringId("level"),
        mcp.method_set_logging_level,
        Some(
          actions.ClientRequestSetLoggingLevel(actions.SetLevelRequestParams(
            actions.Warning,
            meta,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = response
  let #(context, level) = process.receive(captured, 1000) |> should.be_ok
  should.equal(level, actions.Warning)
  should.equal(server.session_id(context), Some(session))
  should.equal(server.request_meta(context), meta)
  let assert server.RequestContextWithMeta(_, _, request_id, _) = context
  should.equal(request_id, jsonrpc.StringId("level"))
  server.close_session(app, session)
}

pub fn resource_subscription_validator_accepts_dynamic_uris_and_rejects_without_mutation_test() {
  let captured = process.new_subject()
  let app =
    support.app()
    |> server.with_resource_subscription_handler(fn(context, uri, enabled) {
      process.send(captured, #(server.session_id(context), uri, enabled))
      case uri {
        "dynamic://allowed" -> Ok(Nil)
        _ -> Error(jsonrpc.invalid_params_error("Subscription denied"))
      }
    })
  let session = support.ready_session(app, support.empty_capabilities())
  let accepted = subscription_response(app, session, "dynamic://allowed", True)
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = accepted
  should.equal(
    process.receive(captured, 1000),
    Ok(#(Some(session), "dynamic://allowed", True)),
  )
  should.equal(server.resource_subscriptions(app, session), [
    "dynamic://allowed",
  ])

  let denied = subscription_response(app, session, "dynamic://denied", True)
  let assert jsonrpc.ErrorResponse(_, error) = denied
  should.equal(error.message, "Subscription denied")
  should.equal(
    process.receive(captured, 1000),
    Ok(#(Some(session), "dynamic://denied", True)),
  )
  should.equal(server.resource_subscriptions(app, session), [
    "dynamic://allowed",
  ])

  let removed = subscription_response(app, session, "dynamic://allowed", False)
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = removed
  should.equal(
    process.receive(captured, 1000),
    Ok(#(Some(session), "dynamic://allowed", False)),
  )
  should.equal(server.resource_subscriptions(app, session), [])
  server.close_session(app, session)

  // The application validator is opt-in; ordinary SDK servers retain the
  // registered-resource check even after subscription support is enabled.
  let ordinary = support.app() |> server.with_resource_subscriptions
  let ordinary_session =
    support.ready_session(ordinary, support.empty_capabilities())
  let unknown =
    subscription_response(ordinary, ordinary_session, "dynamic://allowed", True)
  let assert jsonrpc.ErrorResponse(_, unknown_error) = unknown
  should.equal(unknown_error.code, jsonrpc.invalid_params_error_code)
  should.equal(server.resource_subscriptions(ordinary, ordinary_session), [])
  server.close_session(ordinary, ordinary_session)
}

fn subscription_response(
  app: server.Server,
  id: String,
  uri: String,
  enabled: Bool,
) -> jsonrpc.Response(actions.ClientActionResult) {
  let action = case enabled {
    True ->
      actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
        uri,
        None,
      ))
    False ->
      actions.ClientRequestUnsubscribeResource(actions.UnsubscribeRequestParams(
        uri,
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
      support.context(id),
      jsonrpc.Request(
        jsonrpc.StringId("subscription-hook"),
        method,
        Some(action),
      ),
    )
  response
}
