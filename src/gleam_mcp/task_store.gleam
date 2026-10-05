import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

type Entry {
  Entry(
    task: actions.Task,
    outcome: Option(Result(actions.TaskResult, jsonrpc.RpcError)),
    waiters: List(process.Subject(Result(actions.TaskResult, jsonrpc.RpcError))),
    scope: Option(String),
    worker: Option(TrackedWorker),
    inputs: Dict(String, jsonrpc.Value),
    resume: Option(
      fn(Dict(String, jsonrpc.Value)) -> Result(ModernOutcome, jsonrpc.RpcError),
    ),
  )
}

type TrackedWorker {
  TrackedWorker(pid: process.Pid, monitor: process.Monitor)
}

/// Modern tasks can wait for MRTR input before resuming their monitored worker.
pub type ModernOutcome {
  ModernComplete(jsonrpc.Value)
  ModernInputRequired(
    inputs: Dict(String, jsonrpc.Value),
    resume: fn(Dict(String, jsonrpc.Value)) ->
      Result(ModernOutcome, jsonrpc.RpcError),
  )
}

pub type Snapshot {
  Snapshot(
    task: actions.Task,
    outcome: Option(Result(actions.TaskResult, jsonrpc.RpcError)),
    inputs: Dict(String, jsonrpc.Value),
  )
}

type Access {
  Unscoped
  Scoped(Option(String))
}

type Message {
  Create(
    ttl_ms: Option(Int),
    scope: Option(String),
    reply_to: process.Subject(actions.Task),
  )
  UpdateStatus(
    task_id: String,
    status: actions.TaskStatus,
    status_message: Option(String),
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  Complete(
    task_id: String,
    outcome: Result(actions.TaskResult, jsonrpc.RpcError),
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  StartWorker(
    task_id: String,
    worker: fn() -> Result(actions.TaskResult, jsonrpc.RpcError),
    reply_to: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  WorkerReady(task_id: String, pid: process.Pid, ready: process.Subject(Nil))
  WorkerFinished(
    task_id: String,
    pid: process.Pid,
    outcome: Result(actions.TaskResult, jsonrpc.RpcError),
  )
  StartModern(
    task_id: String,
    worker: fn() -> Result(ModernOutcome, jsonrpc.RpcError),
    reply: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  ModernFinished(
    task_id: String,
    pid: process.Pid,
    outcome: Result(ModernOutcome, jsonrpc.RpcError),
  )
  Peek(
    task_id: String,
    access: Access,
    reply: process.Subject(Result(Snapshot, jsonrpc.RpcError)),
  )
  SubmitInputs(
    task_id: String,
    access: Access,
    inputs: Dict(String, jsonrpc.Value),
    reply: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  WorkerDown(process.Down)
  Expire(task_id: String)
  List(access: Access, reply_to: process.Subject(List(actions.Task)))
  Get(
    task_id: String,
    access: Access,
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  Result(
    task_id: String,
    access: Access,
    reply_to: process.Subject(Result(actions.TaskResult, jsonrpc.RpcError)),
  )
  Cancel(
    task_id: String,
    access: Access,
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
}

const default_poll_interval_ms = 5000

/// Finite retention requests are limited to one day. A missing TTL remains
/// unlimited; applications can apply their own default before creating a task.
pub const maximum_ttl_ms = 86_400_000

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

pub fn create(store: Store, ttl_ms: Option(Int)) -> actions.Task {
  create_scoped(store, ttl_ms, None)
}

pub fn create_scoped(
  store: Store,
  ttl_ms: Option(Int),
  scope: Option(String),
) -> actions.Task {
  call(store, fn(reply_to) { Create(ttl_ms, scope, reply_to) })
}

/// Run a task worker with cancellation managed by the store. The worker is
/// registered before any cancellation can race with its execution.
pub fn start_worker(
  store: Store,
  task_id: String,
  worker: fn() -> Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply_to) { StartWorker(task_id, worker, reply_to) })
}

pub fn start_modern_worker(
  store: Store,
  task_id: String,
  worker: fn() -> Result(ModernOutcome, jsonrpc.RpcError),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply) { StartModern(task_id, worker, reply) })
}

/// Read status and a final payload without blocking. Ownership is checked even
/// for completed tasks, and an unknown task reveals no other caller's state.
pub fn snapshot_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(Snapshot, jsonrpc.RpcError) {
  call(store, fn(reply) { Peek(task_id, Scoped(scope), reply) })
}

pub fn submit_inputs_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
  inputs: Dict(String, jsonrpc.Value),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply) { SubmitInputs(task_id, Scoped(scope), inputs, reply) })
}

pub fn complete(
  store: Store,
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Complete(task_id, outcome, reply_to) })
}

pub fn update_status(
  store: Store,
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    UpdateStatus(task_id, status, status_message, reply_to)
  })
}

pub fn list(store: Store) -> List(actions.Task) {
  call(store, fn(reply_to) { List(Unscoped, reply_to) })
}

pub fn list_scoped(store: Store, scope: Option(String)) -> List(actions.Task) {
  call(store, fn(reply_to) { List(Scoped(scope), reply_to) })
}

pub fn get(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Get(task_id, Unscoped, reply_to) })
}

pub fn get_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Get(task_id, Scoped(scope), reply_to) })
}

pub fn result(
  store: Store,
  task_id: String,
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  result_with_access(store, task_id, Unscoped)
}

pub fn result_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  result_with_access(store, task_id, Scoped(scope))
}

fn result_with_access(
  store: Store,
  task_id: String,
  access: Access,
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, Result(task_id, access, reply_to))
  process.receive_forever(reply_to)
}

pub fn cancel(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Cancel(task_id, Unscoped, reply_to) })
}

pub fn cancel_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Cancel(task_id, Scoped(scope), reply_to) })
}

fn call(store: Store, message: fn(process.Subject(reply)) -> Message) -> reply {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, message(reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

fn loop(
  subject: process.Subject(Message),
  entries: Dict(String, Entry),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(WorkerDown)
  case process.selector_receive_forever(selector) {
    Create(requested_ttl_ms, scope, reply_to) -> {
      let ttl_ms = actual_ttl(requested_ttl_ms)
      let task =
        new_task(
          uuid.v4_string(),
          actions.Working,
          None,
          ttl_ms,
          Some(default_poll_interval_ms),
        )
      process.send(reply_to, task)
      case ttl_ms {
        Some(ttl) -> {
          let _ = process.send_after(subject, ttl, Expire(task.task_id))
          Nil
        }
        None -> Nil
      }
      loop(
        subject,
        dict.insert(
          entries,
          task.task_id,
          Entry(task, None, [], scope, None, dict.new(), None),
        ),
      )
    }
    UpdateStatus(task_id, status, status_message, reply_to) -> {
      let #(next_entries, response) =
        update_task_status(entries, task_id, status, status_message)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
    Complete(task_id, outcome, reply_to) -> {
      let #(next_entries, response, waiters, task_result) =
        complete_task(entries, task_id, outcome)
      process.send(reply_to, response)
      notify_waiters(waiters, task_result)
      loop(subject, next_entries)
    }
    StartWorker(task_id, worker, reply_to) -> {
      let #(next_entries, response) =
        start_task_worker(entries, task_id, subject, worker)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
    StartModern(task_id, worker, reply) -> {
      let #(next, response) =
        start_modern_task(entries, task_id, subject, worker)
      process.send(reply, response)
      loop(subject, next)
    }
    Peek(task_id, access, reply) -> {
      process.send(reply, case find_entry(entries, task_id, access) {
        Ok(entry) -> Ok(Snapshot(entry.task, entry.outcome, entry.inputs))
        Error(_) -> Error(task_not_found_error(task_id))
      })
      loop(subject, entries)
    }
    SubmitInputs(task_id, access, inputs, reply) -> {
      case find_entry(entries, task_id, access) {
        Error(_) -> {
          process.send(reply, Error(task_not_found_error(task_id)))
          loop(subject, entries)
        }
        Ok(entry) -> {
          case entry.resume, entry.task.status {
            Some(resume), actions.InputRequired -> {
              // Unknown and already consumed keys are ignored. Retain missing
              // inputs until a later update supplies them all.
              let supplied =
                dict.filter(inputs, fn(key, _) {
                  dict.has_key(entry.inputs, key)
                })
              let remaining =
                dict.filter(entry.inputs, fn(key, _) {
                  !dict.has_key(supplied, key)
                })
              case dict.size(supplied) > 0 {
                False -> {
                  process.send(reply, Ok(Nil))
                  loop(subject, entries)
                }
                True -> {
                  let next_resume = fn(more) {
                    resume(dict.merge(supplied, more))
                  }
                  let entry =
                    Entry(..entry, inputs: remaining, resume: Some(next_resume))
                  let entries = dict.insert(entries, task_id, entry)
                  case dict.size(remaining) == 0 {
                    False -> {
                      process.send(reply, Ok(Nil))
                      loop(subject, entries)
                    }
                    True -> {
                      let #(next, response) =
                        start_modern_task(entries, task_id, subject, fn() {
                          next_resume(dict.new())
                        })
                      process.send(reply, response)
                      loop(subject, next)
                    }
                  }
                }
              }
            }
            _, _ -> {
              process.send(reply, Ok(Nil))
              loop(subject, entries)
            }
          }
        }
      }
    }
    ModernFinished(task_id, pid, outcome) -> {
      case dict.get(entries, task_id) {
        Ok(Entry(worker: Some(TrackedWorker(pid: worker, ..)), ..) as entry)
          if worker == pid
        -> {
          release_worker_monitor(entry.worker)
          let entry = Entry(..entry, worker: None)
          let entries = dict.insert(entries, task_id, entry)
          case outcome {
            Ok(ModernInputRequired(inputs, resume)) -> {
              case dict.size(inputs) > 0 {
                True -> {
                  let entry =
                    Entry(
                      ..entry,
                      task: set_task_status(
                        entry.task,
                        actions.InputRequired,
                        None,
                      ),
                      inputs: inputs,
                      resume: Some(resume),
                    )
                  loop(subject, dict.insert(entries, task_id, entry))
                }
                False -> {
                  let #(next, _, waiters, outcome) =
                    complete_task(
                      entries,
                      task_id,
                      Error(jsonrpc.invalid_params_error(
                        "Task input requests must not be empty",
                      )),
                    )
                  notify_waiters(waiters, outcome)
                  loop(subject, next)
                }
              }
            }
            outcome -> {
              let outcome = case outcome {
                Ok(ModernComplete(value)) -> Ok(actions.TaskResultModern(value))
                Ok(ModernInputRequired(..)) ->
                  Error(jsonrpc.invalid_params_error(
                    "Task input requests must not be empty",
                  ))
                Error(error) -> Error(error)
              }
              let #(next, _, waiters, result) =
                complete_task(entries, task_id, outcome)
              notify_waiters(waiters, result)
              loop(subject, next)
            }
          }
        }
        _ -> loop(subject, entries)
      }
    }
    WorkerReady(task_id, pid, ready) -> {
      case dict.get(entries, task_id) {
        Ok(Entry(worker: Some(TrackedWorker(pid: worker, ..)), ..))
          if worker == pid
        -> process.send(ready, Nil)
        _ -> process.kill(pid)
      }
      loop(subject, entries)
    }
    WorkerFinished(task_id, pid, outcome) -> {
      case dict.get(entries, task_id) {
        Ok(Entry(worker: Some(TrackedWorker(pid: worker, ..)), ..) as entry)
          if worker == pid
        -> {
          release_worker_monitor(entry.worker)
          let entries =
            dict.insert(entries, task_id, Entry(..entry, worker: None))
          let #(next_entries, _, waiters, task_result) =
            complete_task(entries, task_id, outcome)
          notify_waiters(waiters, task_result)
          loop(subject, next_entries)
        }
        _ -> loop(subject, entries)
      }
    }
    WorkerDown(process.ProcessDown(_, pid, _)) -> {
      case
        list.find(dict.to_list(entries), fn(pair) {
          case pair.1.worker {
            Some(worker) -> worker.pid == pid
            None -> False
          }
        })
      {
        Ok(#(task_id, _)) -> {
          let error =
            jsonrpc.RpcError(
              -32_603,
              "Task worker exited before completing",
              None,
            )
          let #(next_entries, _, waiters, task_result) =
            complete_task(entries, task_id, Error(error))
          notify_waiters(waiters, task_result)
          loop(subject, next_entries)
        }
        Error(Nil) -> loop(subject, entries)
      }
    }
    WorkerDown(process.PortDown(..)) -> loop(subject, entries)
    Expire(task_id) -> {
      case dict.get(entries, task_id) {
        Ok(entry) -> {
          stop_worker(entry.worker)
          notify_waiters(entry.waiters, Error(task_expired_error(task_id)))
        }
        Error(Nil) -> Nil
      }
      loop(subject, dict.delete(entries, task_id))
    }
    List(access, reply_to) -> {
      process.send(
        reply_to,
        entries
          |> dict.to_list
          |> list.filter(fn(pair) { can_access(pair.1, access) })
          |> list.map(fn(entry) {
            let #(_, Entry(task:, ..)) = entry
            task
          }),
      )
      loop(subject, entries)
    }
    Get(task_id, access, reply_to) -> {
      let #(next_entries, response) = get_task(entries, task_id, access)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
    Result(task_id, access, reply_to) -> {
      let #(next_entries, response) =
        get_result(entries, task_id, access, reply_to)
      case response {
        Some(value) -> process.send(reply_to, value)
        None -> Nil
      }
      loop(subject, next_entries)
    }
    Cancel(task_id, access, reply_to) -> {
      let #(next_entries, response) = cancel_task(entries, task_id, access)
      process.send(reply_to, response)
      loop(subject, next_entries)
    }
  }
}

fn start_task_worker(
  entries: Dict(String, Entry),
  task_id: String,
  subject: process.Subject(Message),
  worker: fn() -> Result(actions.TaskResult, jsonrpc.RpcError),
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  start_worker_entry(
    entries,
    task_id,
    subject,
    fn(pid) { WorkerFinished(task_id, pid, worker()) },
    fn(entry) { entry },
  )
}

fn start_modern_task(
  entries: Dict(String, Entry),
  task_id: String,
  subject: process.Subject(Message),
  worker: fn() -> Result(ModernOutcome, jsonrpc.RpcError),
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  start_worker_entry(
    entries,
    task_id,
    subject,
    fn(pid) { ModernFinished(task_id, pid, worker()) },
    fn(entry) {
      Entry(
        ..entry,
        task: set_task_status(entry.task, actions.Working, None),
        inputs: dict.new(),
        resume: None,
      )
    },
  )
}

fn start_worker_entry(
  entries: Dict(String, Entry),
  task_id: String,
  subject: process.Subject(Message),
  finish: fn(process.Pid) -> Message,
  prepare: fn(Entry) -> Entry,
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  case dict.get(entries, task_id) {
    Ok(entry) ->
      case is_terminal(entry.task.status), entry.worker {
        False, None -> {
          let pid =
            process.spawn_unlinked(fn() {
              let ready = process.new_subject()
              process.send(subject, WorkerReady(task_id, process.self(), ready))
              process.receive_forever(ready)
              process.send(subject, finish(process.self()))
            })
          let monitor = process.monitor(pid)
          let entry = prepare(entry)
          #(
            dict.insert(
              entries,
              task_id,
              Entry(..entry, worker: Some(TrackedWorker(pid, monitor))),
            ),
            Ok(Nil),
          )
        }
        _, _ -> #(
          entries,
          Error(jsonrpc.invalid_params_error("Task cannot start another worker")),
        )
      }
    Error(_) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn update_task_status(
  entries: Dict(String, Entry),
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  case dict.get(entries, task_id) {
    Ok(entry) -> {
      case is_terminal(entry.task.status), status {
        True, _ -> #(entries, Ok(entry.task))
        False, actions.Completed | False, actions.Failed -> #(
          entries,
          Error(jsonrpc.invalid_params_error(
            "A completed or failed task must have a final result",
          )),
        )
        False, actions.Cancelled -> cancel_task(entries, task_id, Unscoped)
        False, _ -> {
          let updated = set_task_status(entry.task, status, status_message)
          #(
            dict.insert(entries, task_id, Entry(..entry, task: updated)),
            Ok(updated),
          )
        }
      }
    }
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn get_task(
  entries: Dict(String, Entry),
  task_id: String,
  access: Access,
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  case find_entry(entries, task_id, access) {
    Ok(entry) -> #(entries, Ok(entry.task))
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn get_result(
  entries: Dict(String, Entry),
  task_id: String,
  access: Access,
  reply_to: process.Subject(Result(actions.TaskResult, jsonrpc.RpcError)),
) -> #(
  Dict(String, Entry),
  Option(Result(actions.TaskResult, jsonrpc.RpcError)),
) {
  case find_entry(entries, task_id, access) {
    Ok(entry) ->
      case entry.outcome {
        Some(result) -> #(
          entries,
          Some(result_for_task(entry.task, task_id, result)),
        )
        None -> {
          case entry.task.status {
            actions.Cancelled -> #(
              entries,
              Some(Error(cancelled_task_error(task_id))),
            )
            actions.Completed | actions.Failed -> #(
              entries,
              Some(Error(task_not_found_error(task_id))),
            )
            _ -> {
              let waiting_entry =
                Entry(..entry, waiters: [reply_to, ..entry.waiters])
              #(dict.insert(entries, task_id, waiting_entry), None)
            }
          }
        }
      }
    Error(Nil) -> #(entries, Some(Error(task_not_found_error(task_id))))
  }
}

fn cancel_task(
  entries: Dict(String, Entry),
  task_id: String,
  access: Access,
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  case find_entry(entries, task_id, access) {
    Ok(entry) ->
      case is_terminal(entry.task.status) {
        True -> #(entries, Error(cannot_cancel_error(entry.task)))
        False -> {
          let cancelled =
            set_task_status(
              entry.task,
              actions.Cancelled,
              Some("The task was cancelled by request."),
            )
          let next_entry =
            Entry(..entry, task: cancelled, waiters: [], worker: None)
          stop_worker(entry.worker)
          notify_waiters(entry.waiters, Error(cancelled_task_error(task_id)))
          #(dict.insert(entries, task_id, next_entry), Ok(cancelled))
        }
      }
    Error(Nil) -> #(entries, Error(task_not_found_error(task_id)))
  }
}

fn complete_task(
  entries: Dict(String, Entry),
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> #(
  Dict(String, Entry),
  Result(actions.Task, jsonrpc.RpcError),
  List(process.Subject(Result(actions.TaskResult, jsonrpc.RpcError))),
  Result(actions.TaskResult, jsonrpc.RpcError),
) {
  case dict.get(entries, task_id) {
    Ok(entry) -> {
      stop_worker(entry.worker)
      let task = terminal_task(entry.task, outcome)
      let final_outcome = case is_terminal(entry.task.status), entry.outcome {
        True, Some(previous) -> previous
        True, None -> Error(cancelled_task_error(task_id))
        False, _ -> outcome
      }
      let next_entry =
        Entry(
          ..entry,
          task: task,
          outcome: Some(final_outcome),
          waiters: [],
          worker: None,
        )
      #(
        dict.insert(entries, task_id, next_entry),
        Ok(task),
        entry.waiters,
        result_for_task(task, task_id, final_outcome),
      )
    }
    Error(Nil) -> #(
      entries,
      Error(task_not_found_error(task_id)),
      [],
      Error(task_not_found_error(task_id)),
    )
  }
}

fn terminal_task(
  task: actions.Task,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> actions.Task {
  case is_terminal(task.status) {
    True -> task
    False -> {
      let #(status, status_message) = terminal_status(outcome)
      set_task_status(task, status, status_message)
    }
  }
}

fn new_task(
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
  ttl_ms: Option(Int),
  poll_interval_ms: Option(Int),
) -> actions.Task {
  let now = current_timestamp()
  actions.Task(
    task_id: task_id,
    status: status,
    status_message: status_message,
    created_at: now,
    last_updated_at: now,
    ttl_ms: ttl_ms,
    poll_interval_ms: poll_interval_ms,
  )
}

fn set_task_status(
  task: actions.Task,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> actions.Task {
  actions.Task(
    task_id: task.task_id,
    status: status,
    status_message: status_message,
    created_at: task.created_at,
    last_updated_at: current_timestamp(),
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

fn result_for_task(
  task: actions.Task,
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  case task.status {
    actions.Cancelled -> Error(cancelled_task_error(task_id))
    _ ->
      case outcome {
        Ok(result) -> Ok(with_related_task(result, task_id))
        Error(error) -> Error(error)
      }
  }
}

fn current_timestamp() -> String {
  timestamp.system_time() |> timestamp.to_rfc3339(duration.seconds(0))
}

fn actual_ttl(requested: Option(Int)) -> Option(Int) {
  case requested {
    Some(ttl) if ttl < 0 -> Some(0)
    Some(ttl) if ttl > maximum_ttl_ms -> Some(maximum_ttl_ms)
    ttl -> ttl
  }
}

fn can_access(entry: Entry, access: Access) -> Bool {
  case access {
    Unscoped -> True
    Scoped(scope) -> entry.scope == scope
  }
}

fn find_entry(
  entries: Dict(String, Entry),
  task_id: String,
  access: Access,
) -> Result(Entry, Nil) {
  case dict.get(entries, task_id) {
    Ok(entry) ->
      case can_access(entry, access) {
        True -> Ok(entry)
        False -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

fn stop_worker(worker: Option(TrackedWorker)) -> Nil {
  release_worker_monitor(worker)
  case worker {
    Some(worker) -> process.kill(worker.pid)
    None -> Nil
  }
}

fn release_worker_monitor(worker: Option(TrackedWorker)) -> Nil {
  case worker {
    Some(worker) -> process.demonitor_process(worker.monitor)
    None -> Nil
  }
}

fn with_related_task(
  result: actions.TaskResult,
  task_id: String,
) -> actions.TaskResult {
  case result {
    actions.TaskResultModern(_) -> result
    actions.TaskCallTool(value) ->
      actions.TaskCallTool(
        actions.CallToolResult(
          ..value,
          meta: Some(related_task_meta(value.meta, task_id)),
        ),
      )
    actions.TaskCreateMessage(value) ->
      actions.TaskCreateMessage(
        actions.CreateMessageResult(
          ..value,
          meta: Some(related_task_meta(value.meta, task_id)),
        ),
      )
    actions.TaskElicit(value) ->
      actions.TaskElicit(
        actions.ElicitResult(
          ..value,
          meta: Some(related_task_meta(value.meta, task_id)),
        ),
      )
  }
}

fn related_task_meta(
  meta: Option(actions.Meta),
  task_id: String,
) -> actions.Meta {
  let fields = case meta {
    Some(actions.Meta(fields)) -> fields
    None -> dict.new()
  }
  actions.Meta(dict.insert(
    fields,
    "io.modelcontextprotocol/related-task",
    jsonrpc.VObject([
      #("taskId", jsonrpc.VString(task_id)),
    ]),
  ))
}

fn task_expired_error(task_id: String) -> jsonrpc.RpcError {
  jsonrpc.invalid_params_error("Task has expired: " <> task_id)
}

fn notify_waiters(
  waiters: List(process.Subject(Result(actions.TaskResult, jsonrpc.RpcError))),
  result: Result(actions.TaskResult, jsonrpc.RpcError),
) -> Nil {
  case waiters {
    [] -> Nil
    [waiter, ..rest] -> {
      process.send(waiter, result)
      notify_waiters(rest, result)
    }
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
