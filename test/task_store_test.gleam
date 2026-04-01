import gleam/option.{None, Some}
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

fn sample_task_result() -> actions.TaskResult {
  actions.TaskCallTool(actions.CallToolResult(
    content: [],
    structured_content: None,
    is_error: Some(False),
    meta: None,
  ))
}
