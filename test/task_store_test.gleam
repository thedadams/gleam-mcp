import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/order
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/task_store
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn update_status_updates_non_terminal_task_test() {
  let store = task_store.new()
  let task = task_store.create(store, Some(1000))

  let updated =
    task_store.update_status(
      store,
      task.task_id,
      actions.InputRequired,
      Some("Waiting for user input"),
    )
    |> should.be_ok

  should.equal(updated.task_id, task.task_id)
  should.equal(updated.status, actions.InputRequired)
  should.equal(updated.status_message, Some("Waiting for user input"))
  should.equal(updated.created_at, task.created_at)
  should.equal(updated.ttl_ms, task.ttl_ms)
  should.equal(updated.poll_interval_ms, task.poll_interval_ms)
}

pub fn update_status_does_not_override_terminal_task_test() {
  let store = task_store.new()
  let task = task_store.create(store, Some(1000))
  let completed =
    task_store.complete(store, task.task_id, Ok(sample_task_result()))
    |> should.be_ok

  let updated =
    task_store.update_status(
      store,
      task.task_id,
      actions.Working,
      Some("Back to work"),
    )
    |> should.be_ok

  should.equal(updated, completed)
  should.equal(updated.status, actions.Completed)
}

pub fn update_status_returns_error_for_missing_task_test() {
  let error =
    task_store.update_status(
      task_store.new(),
      "missing-task",
      actions.InputRequired,
      Some("Waiting for input"),
    )
    |> should.be_error

  should.equal(error.code, jsonrpc.invalid_params_error_code)
  should.equal(error.message, "Failed to retrieve task: missing-task")
}

pub fn task_timestamps_describe_creation_and_updates_test() {
  let before = timestamp.system_time()
  let store = task_store.new()
  let task = task_store.create(store, None)
  let created = timestamp.parse_rfc3339(task.created_at) |> should.be_ok
  let after = timestamp.system_time()
  should.be_true(timestamp.compare(created, before) != order.Lt)
  should.be_true(timestamp.compare(created, after) != order.Gt)
  process.sleep(2)
  let updated =
    task_store.update_status(store, task.task_id, actions.InputRequired, None)
    |> should.be_ok
  let updated_at =
    timestamp.parse_rfc3339(updated.last_updated_at) |> should.be_ok
  should.equal(updated.created_at, task.created_at)
  should.equal(timestamp.compare(updated_at, created), order.Gt)
}

pub fn task_results_include_related_task_and_preserve_metadata_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  let result =
    actions.CallToolResult(
      [],
      None,
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #("custom", jsonrpc.VString("preserved")),
          ]),
        ),
      ),
    )
  let _ =
    task_store.complete(store, task.task_id, Ok(actions.TaskCallTool(result)))
    |> should.be_ok
  let assert actions.TaskCallTool(value) =
    task_store.result(store, task.task_id) |> should.be_ok
  let actions.Meta(fields) = value.meta |> should.be_some
  should.equal(dict.get(fields, "custom"), Ok(jsonrpc.VString("preserved")))
  should.equal(
    dict.get(fields, "io.modelcontextprotocol/related-task"),
    Ok(
      jsonrpc.VObject([
        #("taskId", jsonrpc.VString(task.task_id)),
      ]),
    ),
  )
}

pub fn scoped_task_access_does_not_expose_other_requestors_test() {
  let store = task_store.new()
  let owner = Some("owner")
  let other = Some("other")
  let task = task_store.create_scoped(store, None, owner)
  should.equal(task_store.list_scoped(store, owner), [task])
  should.equal(task_store.list_scoped(store, other), [])
  task_store.get_scoped(store, task.task_id, other) |> should.be_error
  task_store.cancel_scoped(store, task.task_id, other) |> should.be_error
  task_store.result_scoped(store, task.task_id, other) |> should.be_error
  task_store.complete(store, task.task_id, Ok(sample_task_result()))
  |> should.be_ok
  task_store.result_scoped(store, task.task_id, owner) |> should.be_ok
}

pub fn sampling_and_elicitation_task_results_preserve_their_payloads_test() {
  let store = task_store.new()
  let meta =
    Some(
      actions.Meta(
        dict.from_list([
          #("custom", jsonrpc.VString("preserved")),
        ]),
      ),
    )
  let message =
    actions.CreateMessageResult(
      actions.SamplingMessage(
        actions.Assistant,
        actions.SingleSamplingContent(
          actions.SamplingText(actions.TextContent("sampled", None, None)),
        ),
        None,
      ),
      "model",
      Some("endTurn"),
      meta,
    )
  let elicited =
    actions.ElicitResult(
      actions.ElicitAccept,
      Some(dict.from_list([#("confirmed", actions.ElicitBool(True))])),
      meta,
    )
  let message_task = task_store.create(store, None)
  task_store.complete(
    store,
    message_task.task_id,
    Ok(actions.TaskCreateMessage(message)),
  )
  |> should.be_ok
  let assert actions.TaskCreateMessage(restored) =
    task_store.result(store, message_task.task_id) |> should.be_ok
  should.equal(restored.message, message.message)
  should.equal(restored.model, message.model)
  should.equal(restored.stop_reason, message.stop_reason)
  assert_task_metadata(restored.meta, message_task.task_id)
  let elicitation_task = task_store.create(store, None)
  task_store.complete(
    store,
    elicitation_task.task_id,
    Ok(actions.TaskElicit(elicited)),
  )
  |> should.be_ok
  let assert actions.TaskElicit(restored) =
    task_store.result(store, elicitation_task.task_id) |> should.be_ok
  should.equal(restored.action, elicited.action)
  should.equal(restored.content, elicited.content)
  assert_task_metadata(restored.meta, elicitation_task.task_id)
}

fn assert_task_metadata(meta, task_id) {
  let actions.Meta(fields) = meta |> should.be_some
  should.equal(dict.get(fields, "custom"), Ok(jsonrpc.VString("preserved")))
  should.equal(
    dict.get(fields, "io.modelcontextprotocol/related-task"),
    Ok(jsonrpc.VObject([#("taskId", jsonrpc.VString(task_id))])),
  )
}

pub fn cancellation_stops_a_resumed_modern_worker_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  let running = process.new_subject()
  task_store.start_modern_worker(store, task.task_id, fn() {
    Ok(
      task_store.ModernInputRequired(
        dict.from_list([#("confirm", jsonrpc.VObject([]))]),
        fn(inputs) {
          should.equal(dict.get(inputs, "confirm"), Ok(jsonrpc.VBool(True)))
          process.send(running, process.self())
          process.sleep_forever()
          Ok(task_store.ModernComplete(jsonrpc.VObject([])))
        },
      ),
    )
  })
  |> should.be_ok
  await_task_status(store, task.task_id, actions.InputRequired, 100)
  task_store.submit_inputs_scoped(
    store,
    task.task_id,
    None,
    dict.from_list([#("confirm", jsonrpc.VBool(True))]),
  )
  |> should.be_ok
  let worker = process.receive(running, 1000) |> should.be_ok
  let snapshot =
    task_store.snapshot_scoped(store, task.task_id, None) |> should.be_ok
  should.equal(snapshot.task.status, actions.Working)
  should.equal(snapshot.inputs, dict.new())
  let monitor = process.monitor(worker)
  let cancelled = task_store.cancel(store, task.task_id) |> should.be_ok
  should.equal(cancelled.status, actions.Cancelled)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  process.selector_receive(selector, 1000) |> should.be_ok
  should.be_false(process.is_alive(worker))
  task_store.result(store, task.task_id) |> should.be_error
}

fn await_task_status(store, id, expected, attempts) -> Nil {
  let task = task_store.get(store, id) |> should.be_ok
  case task.status == expected {
    True -> Nil
    False -> {
      should.be_true(attempts > 0)
      process.sleep(1)
      await_task_status(store, id, expected, attempts - 1)
    }
  }
}

pub fn terminal_status_cannot_be_set_without_a_result_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  task_store.update_status(store, task.task_id, actions.Completed, None)
  |> should.be_error
  task_store.update_status(store, task.task_id, actions.Failed, None)
  |> should.be_error
  let current = task_store.get(store, task.task_id) |> should.be_ok
  should.equal(current.status, actions.Working)
}

pub fn cancellation_status_update_releases_result_waiters_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(reply, task_store.result(store, task.task_id))
    })
  let cancelled =
    task_store.update_status(store, task.task_id, actions.Cancelled, None)
    |> should.be_ok
  should.equal(cancelled.status, actions.Cancelled)
  process.receive(reply, 1000) |> should.be_ok |> should.be_error
}

pub fn task_cancellation_stops_registered_worker_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  let started = process.new_subject()
  task_store.start_worker(store, task.task_id, fn() {
    process.send(started, process.self())
    process.sleep_forever()
    Ok(sample_task_result())
  })
  |> should.be_ok
  let pid = process.receive(started, 1000) |> should.be_ok
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let cancelled = task_store.cancel(store, task.task_id) |> should.be_ok
  should.equal(cancelled.status, actions.Cancelled)
  process.selector_receive(selector, 1000) |> should.be_ok
  should.be_false(process.is_alive(pid))
  task_store.result(store, task.task_id) |> should.be_error
}

pub fn manual_completion_stops_registered_worker_test() {
  let store = task_store.new()
  let created = task_store.create(store, None)
  let started = process.new_subject()
  task_store.start_worker(store, created.task_id, fn() {
    let blocked = process.new_subject()
    process.send(started, process.self())
    process.receive_forever(blocked)
    panic as "Manually completed task kept running"
  })
  |> should.be_ok
  let worker = process.receive(started, 1000) |> should.be_ok
  let monitor = process.monitor(worker)
  task_store.complete(
    store,
    created.task_id,
    Ok(actions.TaskCallTool(actions.CallToolResult([], None, None, None))),
  )
  |> should.be_ok
  let selector =
    process.new_selector() |> process.select_monitors(fn(down) { down })
  let assert process.ProcessDown(reference, pid, _) =
    process.selector_receive(selector, 1000) |> should.be_ok
  should.equal(reference, monitor)
  should.equal(pid, worker)
  let completed = task_store.get(store, created.task_id) |> should.be_ok
  should.equal(completed.status, actions.Completed)
}

pub fn expired_tasks_release_waiters_and_stop_workers_test() {
  let store = task_store.new()
  let task = task_store.create(store, Some(25))
  task_store.start_worker(store, task.task_id, fn() {
    process.sleep_forever()
    Ok(sample_task_result())
  })
  |> should.be_ok
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(reply, task_store.result(store, task.task_id))
    })
  process.receive(reply, 1000) |> should.be_ok |> should.be_error
  should.equal(task_store.list(store), [])
  task_store.get(store, task.task_id) |> should.be_error
}

pub fn completed_task_result_cannot_be_overwritten_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  task_store.complete(store, task.task_id, Ok(sample_task_result()))
  |> should.be_ok
  task_store.complete(
    store,
    task.task_id,
    Error(jsonrpc.invalid_params_error("late failure")),
  )
  |> should.be_ok
  task_store.result(store, task.task_id) |> should.be_ok
  let completed = task_store.get(store, task.task_id) |> should.be_ok
  should.equal(completed.status, actions.Completed)
}

pub fn finite_task_retention_is_capped_test() {
  let task =
    task_store.create(task_store.new(), Some(task_store.maximum_ttl_ms + 1))
  should.equal(task.ttl_ms, Some(task_store.maximum_ttl_ms))
}

pub fn worker_exit_marks_task_failed_and_releases_waiters_test() {
  let store = task_store.new()
  let task = task_store.create(store, None)
  task_store.start_worker(store, task.task_id, fn() {
    process.kill(process.self())
    Ok(sample_task_result())
  })
  |> should.be_ok
  let error = task_store.result(store, task.task_id) |> should.be_error
  should.equal(error.code, -32_603)
  let failed = task_store.get(store, task.task_id) |> should.be_ok
  should.equal(failed.status, actions.Failed)
}

fn sample_task_result() -> actions.TaskResult {
  actions.TaskCallTool(actions.CallToolResult(
    content: [],
    structured_content: None,
    is_error: Some(False),
    meta: None,
  ))
}

pub fn application_task_lifecycle_preserves_initial_and_final_stage_messages_test() {
  let store = task_store.new()
  let task =
    task_store.create_scoped_with_lifecycle(
      store,
      Some(1000),
      Some("owner"),
      1000,
      Some(task_store.TaskLifecycle(Some("Gathering sources..."), None, None)),
    )
  should.equal(task.status_message, Some("Gathering sources..."))
  task_store.update_status(
    store,
    task.task_id,
    actions.Working,
    Some("Generating report..."),
  )
  |> should.be_ok
  let completed =
    task_store.complete(store, task.task_id, Ok(sample_task_result()))
    |> should.be_ok
  should.equal(completed.status, actions.Completed)
  should.equal(completed.status_message, Some("Generating report..."))
  task_store.result_scoped(store, task.task_id, Some("owner")) |> should.be_ok
}

pub fn configured_cancellation_payload_is_owner_checked_and_defaults_remain_unchanged_test() {
  let store = task_store.new()
  let lifecycle =
    task_store.TaskLifecycle(
      Some("Working..."),
      Some("Client cancelled task execution."),
      Some(actions.Meta(dict.new())),
    )
  let task =
    task_store.create_scoped_with_lifecycle(
      store,
      Some(1000),
      Some("owner"),
      1000,
      Some(lifecycle),
    )
  task_store.cancel_result_scoped(store, task.task_id, Some("other"))
  |> should.be_error
  let unchanged = task_store.get(store, task.task_id) |> should.be_ok
  should.equal(unchanged.status, actions.Working)
  let cancelled =
    task_store.cancel_result_scoped(store, task.task_id, Some("owner"))
    |> should.be_ok
  should.equal(cancelled.task.status, actions.Cancelled)
  should.equal(
    cancelled.task.status_message,
    Some("Client cancelled task execution."),
  )
  should.equal(cancelled.meta, Some(actions.Meta(dict.new())))

  let ordinary = task_store.create(store, Some(1000))
  let default_result =
    task_store.cancel_result(store, ordinary.task_id) |> should.be_ok
  should.equal(
    default_result.task.status_message,
    Some("The task was cancelled by request."),
  )
  should.equal(default_result.meta, None)
}
