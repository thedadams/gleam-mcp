import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

type Entry {
  Entry(
    task: actions.Task,
    outcome: Result(actions.TaskResult, jsonrpc.RpcError),
  )
}

type Message {
  Create(
    outcome: Result(actions.TaskResult, jsonrpc.RpcError),
    ttl_ms: Option(Int),
    reply_to: process.Subject(actions.Task),
  )
  List(reply_to: process.Subject(List(actions.Task)))
  Get(
    task_id: String,
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  Result(
    task_id: String,
    reply_to: process.Subject(Result(actions.TaskResult, jsonrpc.RpcError)),
  )
  Cancel(
    task_id: String,
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
}

const default_poll_interval_ms = 100

const default_timestamp = "2026-03-20T00:00:00Z"

pub fn new() -> Store {
  let reply_to = process.new_subject()
  let _ = process.spawn(fn() { start_store(reply_to) })
  let subject = expect_ok(process.receive(reply_to, 1000))
  Store(subject)
}

fn start_store(reply_to: process.Subject(process.Subject(Message))) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  loop(subject, dict.new())
}

pub fn create(
  store: Store,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
  ttl_ms: Option(Int),
) -> actions.Task {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, Create(outcome, ttl_ms, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn list(store: Store) -> List(actions.Task) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, List(reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn get(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, Get(task_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn result(
  store: Store,
  task_id: String,
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, Result(task_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn cancel(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, Cancel(task_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

fn loop(subject: process.Subject(Message), entries: Dict(String, Entry)) -> Nil {
  case process.receive_forever(subject) {
    Create(outcome, ttl_ms, reply_to) -> {
      let task =
        actions.Task(
          task_id: uuid.v4_string(),
          status: actions.Working,
          status_message: None,
          created_at: default_timestamp,
          last_updated_at: default_timestamp,
          ttl_ms: ttl_ms,
          poll_interval_ms: Some(default_poll_interval_ms),
        )
      process.send(reply_to, task)
      loop(subject, dict.insert(entries, task.task_id, Entry(task, outcome)))
    }
    List(reply_to) -> {
      process.send(
        reply_to,
        entries
          |> dict.to_list
          |> list.map(fn(entry) {
            let #(_, Entry(task:, ..)) = entry
            task
          }),
      )
      loop(subject, entries)
    }
    Get(task_id, reply_to) -> {
      let #(next_entries, response) = get_task(entries, task_id)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
    Result(task_id, reply_to) -> {
      let #(next_entries, response) = get_result(entries, task_id)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
    Cancel(task_id, reply_to) -> {
      let #(next_entries, response) = cancel_task(entries, task_id)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
  }
}

fn get_task(
  entries: Dict(String, Entry),
  task_id: String,
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  case dict.get(entries, task_id) {
    Ok(entry) -> {
      let next_entry = settle_entry(entry)
      #(dict.insert(entries, task_id, next_entry), Ok(next_entry.task))
    }
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn get_result(
  entries: Dict(String, Entry),
  task_id: String,
) -> #(Dict(String, Entry), Result(actions.TaskResult, jsonrpc.RpcError)) {
  case dict.get(entries, task_id) {
    Ok(entry) -> {
      let next_entry = settle_entry(entry)
      let result = case next_entry.task.status {
        actions.Cancelled -> Error(cancelled_task_error(task_id))
        _ -> next_entry.outcome
      }
      #(dict.insert(entries, task_id, next_entry), result)
    }
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn cancel_task(
  entries: Dict(String, Entry),
  task_id: String,
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  case dict.get(entries, task_id) {
    Ok(Entry(task:, outcome: outcome)) ->
      case is_terminal(task.status) {
        True -> #(entries, Error(cannot_cancel_error(task)))
        False -> {
          let cancelled =
            actions.Task(
              task_id: task.task_id,
              status: actions.Cancelled,
              status_message: Some("The task was cancelled by request."),
              created_at: task.created_at,
              last_updated_at: default_timestamp,
              ttl_ms: task.ttl_ms,
              poll_interval_ms: task.poll_interval_ms,
            )
          let next_entry = Entry(cancelled, outcome)
          #(dict.insert(entries, task_id, next_entry), Ok(cancelled))
        }
      }
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn settle_entry(entry: Entry) -> Entry {
  let Entry(task, outcome) = entry
  case is_terminal(task.status) {
    True -> entry
    False -> Entry(settle_task(task, outcome), outcome)
  }
}

fn settle_task(
  task: actions.Task,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> actions.Task {
  let #(status, status_message) = terminal_status(outcome)
  actions.Task(
    task_id: task.task_id,
    status: status,
    status_message: status_message,
    created_at: task.created_at,
    last_updated_at: default_timestamp,
    ttl_ms: task.ttl_ms,
    poll_interval_ms: task.poll_interval_ms,
  )
}

fn terminal_status(
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> #(actions.TaskStatus, Option(String)) {
  case outcome {
    Ok(actions.TaskCallTool(actions.CallToolResult(is_error: Some(True), ..))) -> #(
      actions.Failed,
      Some("Tool execution returned an error result."),
    )
    Ok(_) -> #(actions.Completed, None)
    Error(jsonrpc.RpcError(message:, ..)) -> #(actions.Failed, Some(message))
  }
}

fn is_terminal(status: actions.TaskStatus) -> Bool {
  case status {
    actions.Completed | actions.Failed | actions.Cancelled -> True
    _ -> False
  }
}

fn cannot_cancel_error(task: actions.Task) -> jsonrpc.RpcError {
  jsonrpc.invalid_params_error(
    "Cannot cancel task: already in terminal status '"
    <> task_status_name(task.status)
    <> "'",
  )
}

fn task_not_found_error(task_id: String) -> jsonrpc.RpcError {
  jsonrpc.invalid_params_error("Failed to retrieve task: " <> task_id)
}

fn cancelled_task_error(task_id: String) -> jsonrpc.RpcError {
  jsonrpc.invalid_params_error("Task was cancelled: " <> task_id)
}

fn task_status_name(status: actions.TaskStatus) -> String {
  case status {
    actions.Working -> "working"
    actions.InputRequired -> "input_required"
    actions.Completed -> "completed"
    actions.Failed -> "failed"
    actions.Cancelled -> "cancelled"
  }
}

fn expect_ok(value: Result(a, Nil)) -> a {
  case value {
    Ok(inner) -> inner
    Error(Nil) -> panic as "Timed out waiting for task store"
  }
}
