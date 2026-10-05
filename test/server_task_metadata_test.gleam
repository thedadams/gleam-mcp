import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store as store
import gleeunit/should
import server_test_support

pub fn main() {
  task_progress_preserves_token_and_existing_metadata_test()
  task_cancellation_and_elicitation_completion_are_associated_test()
  task_status_omits_related_task_and_non_task_notifications_stay_unchanged_test()
  task_augmentation_is_ignored_without_advertised_tool_task_support_test()
}

pub fn task_progress_preserves_token_and_existing_metadata_test() {
  let app = server.new(server_test_support.sample_client_info())
  let session = ready_session(app)
  let listener = listen(app, session)
  let token = jsonrpc.StringId("progress-token")
  let context =
    server.RequestContextWithMeta(
      Some(session),
      Some("parent-task"),
      jsonrpc.IntId(7),
      Some(actions.RequestMeta(Some(token), None)),
    )
  server.report_progress(app, context, 1.0, Some(10.0), Some("working"))
  |> should.be_ok
  let assert actions.NotifyProgress(progress) = receive_action(listener)
  should.equal(progress.progress_token, token)
  should.equal(progress.progress, 1.0)
  should.equal(progress.total, Some(10.0))
  assert_related(progress.meta, "parent-task")

  let existing = notification_meta("trace", "old-task")
  let explicit =
    actions.ProgressNotificationParams(
      token,
      2.0,
      None,
      Some("still working"),
      Some(existing),
    )
  server.send_notification(
    app,
    context,
    jsonrpc.Notification(
      mcp.method_notify_progress,
      Some(actions.NotifyProgress(explicit)),
    ),
  )
  |> should.be_ok
  let assert actions.NotifyProgress(updated) = receive_action(listener)
  should.equal(updated.progress_token, token)
  should.equal(updated.message, explicit.message)
  assert_related(updated.meta, "parent-task")
  assert_trace(updated.meta, "trace")
  server.close_session(app, session)
}

pub fn task_cancellation_and_elicitation_completion_are_associated_test() {
  let app = server.new(server_test_support.sample_client_info())
  let session = ready_session(app)
  let listener = listen(app, session)
  let context = server.RequestContext(Some(session), Some("parent-task"))
  server.cancel_request(app, context, jsonrpc.StringId("child"), Some("stop"))
  |> should.be_ok
  let assert actions.NotifyCancelled(cancelled) = receive_action(listener)
  should.equal(cancelled.request_id, Some(jsonrpc.StringId("child")))
  should.equal(cancelled.reason, Some("stop"))
  assert_related(cancelled.meta, "parent-task")
  server.send_notification(
    app,
    context,
    jsonrpc.Notification(
      mcp.method_notify_elicitation_complete,
      Some(
        actions.NotifyElicitationComplete(
          actions.ElicitationCompleteNotificationParamsWithMeta(
            "elicitation-id",
            Some(notification_meta("elicitation-trace", "old-task")),
          ),
        ),
      ),
    ),
  )
  |> should.be_ok
  let assert actions.NotifyElicitationComplete(complete) =
    receive_action(listener)
  should.equal(
    actions.elicitation_complete_notification_id(complete),
    "elicitation-id",
  )
  let meta = actions.elicitation_complete_notification_meta(complete)
  assert_related(meta, "parent-task")
  assert_trace(meta, "elicitation-trace")
  server.close_session(app, session)
}

pub fn task_status_omits_related_task_and_non_task_notifications_stay_unchanged_test() {
  let app =
    server.new(server_test_support.sample_client_info())
    |> server.with_capabilities(
      server_capabilities(
        Some(actions.ServerTasksCapabilities(None, None, None)),
      ),
    )
  let session = ready_session(app)
  let listener = listen(app, session)
  let status =
    actions.NotifyTaskStatus(actions.TaskStatusNotificationParams(
      actions.Task(
        "parent-task",
        actions.Working,
        None,
        "2026-10-04T00:00:00Z",
        "2026-10-04T00:00:00Z",
        None,
        None,
      ),
      None,
    ))
  server.send_notification(
    app,
    server.RequestContext(Some(session), Some("parent-task")),
    jsonrpc.Notification(mcp.method_notify_task_status, Some(status)),
  )
  |> should.be_ok
  should.equal(receive_action(listener), status)
  let complete =
    actions.NotifyElicitationComplete(
      actions.ElicitationCompleteNotificationParams("completed"),
    )
  server.send_notification(
    app,
    server.RequestContext(Some(session), None),
    jsonrpc.Notification(mcp.method_notify_elicitation_complete, Some(complete)),
  )
  |> should.be_ok
  should.equal(receive_action(listener), complete)
  server.close_session(app, session)
}

pub fn task_augmentation_is_ignored_without_advertised_tool_task_support_test() {
  list.each(
    [
      None,
      Some(actions.ServerTasksCapabilities(
        None,
        None,
        Some(actions.ServerTaskRequestCapabilities(None)),
      )),
    ],
    fn(tasks) {
      let called = process.new_subject()
      let app =
        server.new(server_test_support.sample_client_info())
        |> server.register_tool_descriptor(
          actions.Tool(
            "optional",
            None,
            None,
            jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
            Some(actions.ToolExecution(Some(actions.TaskOptional))),
            None,
            None,
            [],
            None,
          ),
          fn(_) {
            process.send(called, Nil)
            Ok(actions.CallToolResult([], None, Some(False), None))
          },
        )
        |> server.with_capabilities(server_capabilities(tasks))
      let session = ready_session(app)
      let #(_, response) =
        server.handle_request_with_context(
          app,
          server.RequestContext(Some(session), None),
          jsonrpc.Request(
            jsonrpc.StringId("call"),
            mcp.method_call_tool,
            Some(
              actions.ClientRequestCallTool(actions.CallToolRequestParams(
                "optional",
                None,
                Some(actions.TaskMetadata(None)),
                None,
              )),
            ),
          ),
        )
      let assert jsonrpc.ResultResponse(_, actions.ClientResultCallTool(result)) =
        response
      should.equal(result.is_error, Some(False))
      should.equal(process.receive(called, 100), Ok(Nil))
      should.equal(process.receive(called, 5), Error(Nil))
      server.close_session(app, session)
    },
  )
}

fn server_capabilities(
  tasks: Option(actions.ServerTasksCapabilities),
) -> actions.ServerCapabilities {
  actions.ServerCapabilities(
    None,
    None,
    None,
    None,
    None,
    Some(actions.ServerToolsCapabilities(None)),
    tasks,
  )
}

fn notification_meta(
  trace: String,
  related: String,
) -> actions.NotificationMeta {
  actions.NotificationMeta(
    Some(
      actions.Meta(
        dict.from_list([
          #("trace", jsonrpc.VString(trace)),
          #("io.modelcontextprotocol/related-task", related_value(related)),
        ]),
      ),
    ),
  )
}

fn related_value(task: String) -> jsonrpc.Value {
  jsonrpc.VObject([#("taskId", jsonrpc.VString(task))])
}

fn assert_related(meta: Option(actions.NotificationMeta), task: String) -> Nil {
  let assert Some(actions.NotificationMeta(Some(extra))) = meta
  should.equal(
    dict.get(extra.fields, "io.modelcontextprotocol/related-task"),
    Ok(related_value(task)),
  )
}

fn assert_trace(meta: Option(actions.NotificationMeta), trace: String) -> Nil {
  let assert Some(actions.NotificationMeta(Some(extra))) = meta
  should.equal(dict.get(extra.fields, "trace"), Ok(jsonrpc.VString(trace)))
}

fn ready_session(app: server.Server) -> String {
  let session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.bind_session(app, session, None))
  let context = server.RequestContext(Some(session), None)
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context,
      jsonrpc.Request(
        jsonrpc.StringId("initialize"),
        mcp.method_initialize,
        Some(
          actions.ClientRequestInitialize(actions.InitializeRequestParams(
            jsonrpc.legacy_protocol_version,
            actions.ClientCapabilities(None, None, None, None, None),
            server_test_support.sample_client_info(),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(_)) =
    response
  server.handle_notification_with_context(
    app,
    context,
    jsonrpc.Notification(
      mcp.method_initialized,
      Some(actions.NotifyInitialized(None)),
    ),
  )
  |> should.be_ok
  session
}

fn listen(
  app: server.Server,
  session: String,
) -> process.Subject(store.ListenerMessage) {
  let listener = process.new_subject()
  server.register_streamable_http_listener(
    app,
    session,
    server.new_streamable_http_listener_id(),
    listener,
  )
  listener
}

fn receive_action(
  listener: process.Subject(store.ListenerMessage),
) -> actions.ActionNotification {
  let assert store.DeliverNotification(jsonrpc.Notification(_, Some(action))) =
    process.receive(listener, 1000) |> should.be_ok
  action
}
