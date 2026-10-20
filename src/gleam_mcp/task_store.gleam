//// Tasks are persisted as `persistence.TaskRecord`s, so any replica sharing
//// the record store can read, cancel or await them. The replica that runs a
//// task's worker keeps the parts that cannot be persisted: the worker itself,
//// local result waiters, the retention timer and the MRTR resume function.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/persistence.{type TaskRecord, TaskRecord}
import gleam_mcp/persistence/memory
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message), records: persistence.TaskStore)
}

type Waiter =
  process.Subject(Result(actions.TaskResult, jsonrpc.RpcError))

type Resume =
  fn(Dict(String, jsonrpc.Value)) -> Result(ModernOutcome, jsonrpc.RpcError)

/// What this replica holds for a task, alongside its persisted record.
type Entry {
  Entry(
    records: persistence.TaskStore,
    waiters: List(Waiter),
    worker: Option(TrackedWorker),
    retention: Option(process.Timer),
    resume: Option(Resume),
  )
}

type TrackedWorker {
  TrackedWorker(pid: process.Pid, monitor: process.Monitor)
}

/// Application-specific status text and cancellation metadata. Absent options
/// retain the store's ordinary creation/cancellation behavior.
pub type TaskLifecycle {
  TaskLifecycle(
    initial_status_message: Option(String),
    cancellation_status_message: Option(String),
    cancellation_meta: Option(actions.Meta),
  )
}

/// Modern tasks can wait for MRTR input before resuming their monitored worker.
pub type ModernOutcome {
  ModernComplete(jsonrpc.Value)
  ModernInputRequired(inputs: Dict(String, jsonrpc.Value), resume: Resume)
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

type Records =
  persistence.TaskStore

pub opaque type Message {
  Create(
    records: Records,
    ttl_ms: Option(Int),
    scope: Option(String),
    poll_interval_ms: Int,
    lifecycle: Option(TaskLifecycle),
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  UpdateStatus(
    records: Records,
    task_id: String,
    status: actions.TaskStatus,
    status_message: Option(String),
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  Complete(
    records: Records,
    task_id: String,
    outcome: Result(actions.TaskResult, jsonrpc.RpcError),
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  StartWorker(
    records: Records,
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
    records: Records,
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
    records: Records,
    task_id: String,
    access: Access,
    reply: process.Subject(Result(Snapshot, jsonrpc.RpcError)),
  )
  SubmitInputs(
    records: Records,
    task_id: String,
    access: Access,
    inputs: Dict(String, jsonrpc.Value),
    reply: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  WorkerDown(process.Down)
  Expire(records: Records, task_id: String)
  CloseScope(
    records: Records,
    scope: Option(String),
    reply: process.Subject(Nil),
  )
  List(
    records: Records,
    access: Access,
    reply_to: process.Subject(Result(List(actions.Task), jsonrpc.RpcError)),
  )
  Get(
    records: Records,
    task_id: String,
    access: Access,
    reply_to: process.Subject(Result(actions.Task, jsonrpc.RpcError)),
  )
  Result(records: Records, task_id: String, access: Access, reply_to: Waiter)
  Cancel(
    records: Records,
    task_id: String,
    access: Access,
    reply_to: process.Subject(
      Result(actions.CancelTaskResult, jsonrpc.RpcError),
    ),
  )
  Changed(task_id: String)
  Forget(task_ids: List(String), reason: jsonrpc.RpcError)
}

const default_poll_interval_ms = 5000

const update_attempts = 5

/// Finite retention requests are limited to one day. A missing TTL remains
/// unlimited; applications can apply their own default before creating a task.
pub const maximum_ttl_ms = 86_400_000

type State {
  State(subject: process.Subject(Message), entries: Dict(String, Entry))
}

/// Start an unsupervised task store, with in-memory records, linked to the
/// calling process.
pub fn new() -> Store {
  let assert Ok(actor.Started(data: records, ..)) =
    memory.start_tasks(process.new_name("gleam_mcp_task_records"))
  let assert Ok(actor.Started(data: store, ..)) =
    start(process.new_name("gleam_mcp_task_store"), records)
  store
}

/// Start the task store registered under `name`, so that a supervisor can
/// restart it without invalidating the handles returned by `named`.
pub fn start(
  name: process.Name(Message),
  records: persistence.TaskStore,
) -> actor.StartResult(Store) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(WorkerDown)
    actor.initialised(State(subject, dict.new()))
    |> actor.selecting(selector)
    |> actor.returning(Store(subject, records))
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  records: persistence.TaskStore,
) -> supervision.ChildSpecification(Store) {
  supervision.worker(fn() { start(name, records) })
}

/// A handle to the task store registered under `name`.
pub fn named(
  name: process.Name(Message),
  records: persistence.TaskStore,
) -> Store {
  Store(process.named_subject(name), records)
}

/// Persist tasks created through the returned handle in `records`.
pub fn with_records(store: Store, records: persistence.TaskStore) -> Store {
  Store(..store, records: records)
}

pub fn records(store: Store) -> persistence.TaskStore {
  store.records
}

/// Wake this replica's waiters and stop its worker after another replica
/// changed a task's record.
pub fn changed(store: Store, task_id: String) -> Nil {
  process.send(store.subject, Changed(task_id))
}

/// Release this replica's state for tasks whose records were removed.
pub fn forget(
  store: Store,
  task_ids: List(String),
  reason: jsonrpc.RpcError,
) -> Nil {
  process.send(store.subject, Forget(task_ids, reason))
}

pub fn create(store: Store, ttl_ms: Option(Int)) -> actions.Task {
  create_scoped(store, ttl_ms, None)
}

pub fn create_scoped(
  store: Store,
  ttl_ms: Option(Int),
  scope: Option(String),
) -> actions.Task {
  create_scoped_with_poll_interval(
    store,
    ttl_ms,
    scope,
    default_poll_interval_ms,
  )
}

pub fn create_scoped_with_poll_interval(
  store: Store,
  ttl_ms: Option(Int),
  scope: Option(String),
  poll_interval_ms: Int,
) -> actions.Task {
  let assert Ok(task) =
    create_scoped_with_lifecycle(store, ttl_ms, scope, poll_interval_ms, None)
  task
}

pub fn create_scoped_with_lifecycle(
  store: Store,
  ttl_ms: Option(Int),
  scope: Option(String),
  poll_interval_ms: Int,
  lifecycle: Option(TaskLifecycle),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    Create(
      store.records,
      ttl_ms,
      scope,
      int.max(poll_interval_ms, 0),
      lifecycle,
      reply_to,
    )
  })
}

/// Release tasks owned by a closing application/session scope. Other scopes,
/// including durable authenticated owners, are left to their own lifecycle.
pub fn close_scope(store: Store, scope: Option(String)) -> Nil {
  call(store, fn(reply) { CloseScope(store.records, scope, reply) })
}

/// Run a task worker with cancellation managed by the store. The worker is
/// registered before any cancellation can race with its execution.
pub fn start_worker(
  store: Store,
  task_id: String,
  worker: fn() -> Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    StartWorker(store.records, task_id, worker, reply_to)
  })
}

pub fn start_modern_worker(
  store: Store,
  task_id: String,
  worker: fn() -> Result(ModernOutcome, jsonrpc.RpcError),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply) { StartModern(store.records, task_id, worker, reply) })
}

/// Read status and a final payload without blocking. Ownership is checked even
/// for completed tasks, and an unknown task reveals no other caller's state.
pub fn snapshot_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(Snapshot, jsonrpc.RpcError) {
  call(store, fn(reply) { Peek(store.records, task_id, Scoped(scope), reply) })
}

pub fn submit_inputs_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
  inputs: Dict(String, jsonrpc.Value),
) -> Result(Nil, jsonrpc.RpcError) {
  call(store, fn(reply) {
    SubmitInputs(store.records, task_id, Scoped(scope), inputs, reply)
  })
}

pub fn complete(
  store: Store,
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    Complete(store.records, task_id, outcome, reply_to)
  })
}

pub fn update_status(
  store: Store,
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    UpdateStatus(store.records, task_id, status, status_message, reply_to)
  })
}

pub fn list(store: Store) -> Result(List(actions.Task), jsonrpc.RpcError) {
  call(store, fn(reply_to) { List(store.records, Unscoped, reply_to) })
}

pub fn list_scoped(
  store: Store,
  scope: Option(String),
) -> Result(List(actions.Task), jsonrpc.RpcError) {
  call(store, fn(reply_to) { List(store.records, Scoped(scope), reply_to) })
}

pub fn get(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) { Get(store.records, task_id, Unscoped, reply_to) })
}

pub fn get_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    Get(store.records, task_id, Scoped(scope), reply_to)
  })
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
  process.call_forever(store.subject, fn(reply_to) {
    Result(store.records, task_id, access, reply_to)
  })
}

pub fn cancel(
  store: Store,
  task_id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  cancel_result(store, task_id) |> result.map(fn(result) { result.task })
}

pub fn cancel_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  cancel_result_scoped(store, task_id, scope)
  |> result.map(fn(result) { result.task })
}

pub fn cancel_result(
  store: Store,
  task_id: String,
) -> Result(actions.CancelTaskResult, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    Cancel(store.records, task_id, Unscoped, reply_to)
  })
}

pub fn cancel_result_scoped(
  store: Store,
  task_id: String,
  scope: Option(String),
) -> Result(actions.CancelTaskResult, jsonrpc.RpcError) {
  call(store, fn(reply_to) {
    Cancel(store.records, task_id, Scoped(scope), reply_to)
  })
}

fn call(store: Store, message: fn(process.Subject(reply)) -> Message) -> reply {
  process.call(store.subject, 1000, message)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let State(subject:, entries:) = state
  let next = case message {
    Create(records, requested_ttl_ms, scope, poll_interval_ms, lifecycle, reply) -> {
      let ttl_ms = actual_ttl(requested_ttl_ms)
      let task =
        new_task(
          uuid.v4_string(),
          actions.Working,
          lifecycle
            |> option.then(fn(options) { options.initial_status_message }),
          ttl_ms,
          Some(poll_interval_ms),
        )
      let record =
        TaskRecord(
          task: task,
          scope: scope,
          outcome: None,
          inputs: dict.new(),
          cancellation_status_message: lifecycle
            |> option.then(fn(options) { options.cancellation_status_message }),
          cancellation_meta: lifecycle
            |> option.then(fn(options) { options.cancellation_meta }),
          expires_at: ttl_ms
            |> option.map(fn(ttl) {
              timestamp.add(timestamp.system_time(), duration.milliseconds(ttl))
            }),
          version: 0,
        )
      case records.insert(record) {
        Error(error) -> {
          process.send(reply, Error(store_error(error)))
          entries
        }
        Ok(Nil) -> {
          process.send(reply, Ok(task))
          case ttl_ms {
            Some(ttl) -> {
              let timer =
                process.send_after(subject, ttl, Expire(records, task.task_id))
              dict.insert(
                entries,
                task.task_id,
                Entry(..empty_entry(records), retention: Some(timer)),
              )
            }
            None -> entries
          }
        }
      }
    }
    UpdateStatus(records, task_id, status, status_message, reply) -> {
      let #(entries, response) = case status {
        actions.Cancelled -> {
          let #(entries, cancelled) =
            cancel_task(entries, records, task_id, Unscoped, True)
          #(entries, cancelled |> result.map(fn(result) { result.task }))
        }
        _ -> #(
          entries,
          update(records, task_id, fn(record) {
            case is_terminal(record.task.status), status {
              True, _ -> Ok(#(record, record.task))
              False, actions.Completed | False, actions.Failed ->
                Error(jsonrpc.invalid_params_error(
                  "A completed or failed task must have a final result",
                ))
              False, _ -> {
                let task = set_task_status(record.task, status, status_message)
                Ok(#(TaskRecord(..record, task: task), task))
              }
            }
          }),
        )
      }
      process.send(reply, response)
      entries
    }
    Complete(records, task_id, outcome, reply) -> {
      let #(entries, response) =
        complete_task(entries, records, task_id, outcome)
      process.send(reply, response)
      entries
    }
    StartWorker(records, task_id, worker, reply) -> {
      let #(entries, response) =
        start_worker_entry(
          entries,
          records,
          task_id,
          subject,
          fn(pid) { WorkerFinished(task_id, pid, worker()) },
          fn(record) { Ok(record) },
        )
      process.send(reply, response)
      entries
    }
    StartModern(records, task_id, worker, reply) -> {
      let #(entries, response) =
        start_modern_task(entries, records, task_id, subject, worker)
      process.send(reply, response)
      entries
    }
    Peek(records, task_id, access, reply) -> {
      process.send(
        reply,
        load(records, task_id, access)
          |> result.map(fn(record) {
            Snapshot(record.task, record.outcome, record.inputs)
          }),
      )
      entries
    }
    SubmitInputs(records, task_id, access, inputs, reply) -> {
      let #(entries, response) =
        submit_inputs(entries, records, task_id, access, inputs, subject)
      process.send(reply, response)
      entries
    }
    ModernFinished(task_id, pid, outcome) ->
      case running_entry(entries, task_id, pid) {
        Error(Nil) -> entries
        Ok(entry) -> {
          release_worker_monitor(entry.worker)
          let entries =
            dict.insert(entries, task_id, Entry(..entry, worker: None))
          case outcome {
            Ok(ModernInputRequired(inputs, resume)) ->
              case dict.size(inputs) > 0 {
                True -> await_inputs(entries, entry, task_id, inputs, resume)
                False ->
                  complete_task(
                    entries,
                    entry.records,
                    task_id,
                    Error(jsonrpc.invalid_params_error(
                      "Task input requests must not be empty",
                    )),
                  ).0
              }
            Ok(ModernComplete(value)) ->
              complete_task(
                entries,
                entry.records,
                task_id,
                Ok(actions.TaskResultModern(value)),
              ).0
            Error(error) ->
              complete_task(entries, entry.records, task_id, Error(error)).0
          }
        }
      }
    WorkerReady(task_id, pid, ready) -> {
      case running_entry(entries, task_id, pid) {
        Ok(_) -> process.send(ready, Nil)
        Error(Nil) -> process.kill(pid)
      }
      entries
    }
    WorkerFinished(task_id, pid, outcome) ->
      case running_entry(entries, task_id, pid) {
        Error(Nil) -> entries
        Ok(entry) -> {
          release_worker_monitor(entry.worker)
          let entries =
            dict.insert(entries, task_id, Entry(..entry, worker: None))
          complete_task(entries, entry.records, task_id, outcome).0
        }
      }
    WorkerDown(process.ProcessDown(_, pid, _)) ->
      case
        list.find(dict.to_list(entries), fn(pair) {
          case pair.1.worker {
            Some(worker) -> worker.pid == pid
            None -> False
          }
        })
      {
        Ok(#(task_id, entry)) -> {
          let error =
            jsonrpc.RpcError(
              -32_603,
              "Task worker exited before completing",
              None,
            )
          complete_task(entries, entry.records, task_id, Error(error)).0
        }
        Error(Nil) -> entries
      }
    WorkerDown(process.PortDown(..)) -> entries
    CloseScope(records, scope, reply) -> {
      let entries = case records.delete_scope(scope) {
        Ok(ids) ->
          release_entries(
            entries,
            ids,
            jsonrpc.invalid_params_error("Task scope was closed"),
          )
        Error(_) -> entries
      }
      process.send(reply, Nil)
      entries
    }
    Expire(records, task_id) -> {
      let _ = records.delete(task_id)
      release_entries(entries, [task_id], task_expired_error(task_id))
    }
    Forget(task_ids, reason) -> release_entries(entries, task_ids, reason)
    Changed(task_id) ->
      case dict.get(entries, task_id) {
        Error(Nil) -> entries
        Ok(entry) ->
          case load(entry.records, task_id, Unscoped) {
            Ok(record) -> settle(entries, task_id, entry, record)
            // The record is gone, so nothing will ever complete it.
            Error(error) -> release_entries(entries, [task_id], error)
          }
      }
    List(records, access, reply) -> {
      let scope = case access {
        Unscoped -> persistence.AnyScope
        Scoped(scope) -> persistence.Scope(scope)
      }
      process.send(
        reply,
        records.list(scope)
          |> result.map_error(store_error)
          |> result.map(fn(found) {
            found
            |> list.filter(fn(record) { !expired(record) })
            |> list.map(fn(record) { record.task })
          }),
      )
      entries
    }
    Get(records, task_id, access, reply) -> {
      process.send(
        reply,
        load(records, task_id, access) |> result.map(fn(record) { record.task }),
      )
      entries
    }
    Result(records, task_id, access, reply) ->
      case load(records, task_id, access) {
        Error(error) -> {
          process.send(reply, Error(error))
          entries
        }
        Ok(record) ->
          case final_result(record) {
            Some(outcome) -> {
              process.send(reply, outcome)
              entries
            }
            None -> {
              let entry = local_entry(entries, task_id, records)
              dict.insert(
                entries,
                task_id,
                Entry(..entry, waiters: [reply, ..entry.waiters]),
              )
            }
          }
      }
    Cancel(records, task_id, access, reply) -> {
      let #(entries, response) =
        cancel_task(entries, records, task_id, access, False)
      process.send(reply, response)
      entries
    }
  }
  actor.continue(State(subject, next))
}

fn empty_entry(records: Records) -> Entry {
  Entry(records, [], None, None, None)
}

fn local_entry(
  entries: Dict(String, Entry),
  task_id: String,
  records: Records,
) -> Entry {
  case dict.get(entries, task_id) {
    Ok(entry) -> entry
    Error(Nil) -> empty_entry(records)
  }
}

fn running_entry(
  entries: Dict(String, Entry),
  task_id: String,
  pid: process.Pid,
) -> Result(Entry, Nil) {
  case dict.get(entries, task_id) {
    Ok(Entry(worker: Some(TrackedWorker(pid: worker, ..)), ..) as entry)
      if worker == pid
    -> Ok(entry)
    _ -> Error(Nil)
  }
}

/// Drop local state that no longer serves a purpose.
fn tidy(entries: Dict(String, Entry), task_id: String) -> Dict(String, Entry) {
  case dict.get(entries, task_id) {
    Ok(Entry(waiters: [], worker: None, retention: None, resume: None, ..)) ->
      dict.delete(entries, task_id)
    _ -> entries
  }
}

/// The result `tasks/result` returns once a task has reached a final state.
fn final_result(
  record: TaskRecord,
) -> Option(Result(actions.TaskResult, jsonrpc.RpcError)) {
  let task_id = record.task.task_id
  case record.outcome, record.task.status {
    Some(outcome), _ -> Some(result_for_task(record.task, task_id, outcome))
    None, actions.Cancelled -> Some(Error(cancelled_task_error(task_id)))
    None, actions.Completed | None, actions.Failed ->
      Some(Error(task_not_found_error(task_id)))
    None, _ -> None
  }
}

/// Bring local state in line with a record another writer may have changed.
fn settle(
  entries: Dict(String, Entry),
  task_id: String,
  entry: Entry,
  record: TaskRecord,
) -> Dict(String, Entry) {
  case final_result(record) {
    None -> entries
    Some(outcome) -> {
      stop_worker(entry.worker)
      notify_waiters(entry.waiters, outcome)
      dict.insert(
        entries,
        task_id,
        Entry(..entry, waiters: [], worker: None, resume: None),
      )
      |> tidy(task_id)
    }
  }
}

fn release_entries(
  entries: Dict(String, Entry),
  task_ids: List(String),
  reason: jsonrpc.RpcError,
) -> Dict(String, Entry) {
  list.fold(task_ids, entries, fn(entries, task_id) {
    case dict.get(entries, task_id) {
      Ok(entry) -> {
        stop_worker(entry.worker)
        case entry.retention {
          Some(timer) -> {
            let _ = process.cancel_timer(timer)
            Nil
          }
          None -> Nil
        }
        notify_waiters(entry.waiters, Error(reason))
        dict.delete(entries, task_id)
      }
      Error(Nil) -> entries
    }
  })
}

fn start_modern_task(
  entries: Dict(String, Entry),
  records: Records,
  task_id: String,
  subject: process.Subject(Message),
  worker: fn() -> Result(ModernOutcome, jsonrpc.RpcError),
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  start_worker_entry(
    entries,
    records,
    task_id,
    subject,
    fn(pid) { ModernFinished(task_id, pid, worker()) },
    fn(record) {
      Ok(
        TaskRecord(
          ..record,
          task: set_task_status(
            record.task,
            actions.Working,
            case record.task.status {
              actions.Working -> record.task.status_message
              _ -> None
            },
          ),
          inputs: dict.new(),
        ),
      )
    },
  )
}

fn start_worker_entry(
  entries: Dict(String, Entry),
  records: Records,
  task_id: String,
  subject: process.Subject(Message),
  finish: fn(process.Pid) -> Message,
  prepare: fn(TaskRecord) -> Result(TaskRecord, jsonrpc.RpcError),
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  let entry = local_entry(entries, task_id, records)
  let prepared =
    update(records, task_id, fn(record) {
      case is_terminal(record.task.status), entry.worker {
        False, None ->
          prepare(record) |> result.map(fn(record) { #(record, Nil) })
        _, _ ->
          Error(jsonrpc.invalid_params_error("Task cannot start another worker"))
      }
    })
  case prepared {
    Error(error) -> #(entries, Error(error))
    Ok(Nil) -> {
      let pid =
        process.spawn_unlinked(fn() {
          let ready = process.new_subject()
          process.send(subject, WorkerReady(task_id, process.self(), ready))
          process.receive_forever(ready)
          process.send(subject, finish(process.self()))
        })
      let monitor = process.monitor(pid)
      #(
        dict.insert(
          entries,
          task_id,
          Entry(
            ..entry,
            records: records,
            worker: Some(TrackedWorker(pid, monitor)),
            resume: None,
          ),
        ),
        Ok(Nil),
      )
    }
  }
}

fn await_inputs(
  entries: Dict(String, Entry),
  entry: Entry,
  task_id: String,
  inputs: Dict(String, jsonrpc.Value),
  resume: Resume,
) -> Dict(String, Entry) {
  let awaiting =
    update(entry.records, task_id, fn(record) {
      case is_terminal(record.task.status) {
        True -> Ok(#(record, False))
        False ->
          Ok(#(
            TaskRecord(
              ..record,
              task: set_task_status(record.task, actions.InputRequired, None),
              inputs: inputs,
            ),
            True,
          ))
      }
    })
  case awaiting {
    Ok(True) ->
      dict.insert(
        entries,
        task_id,
        Entry(..entry, worker: None, resume: Some(resume)),
      )
    Ok(False) -> tidy(entries, task_id)
    Error(error) ->
      complete_task(entries, entry.records, task_id, Error(error)).0
  }
}

fn submit_inputs(
  entries: Dict(String, Entry),
  records: Records,
  task_id: String,
  access: Access,
  inputs: Dict(String, jsonrpc.Value),
  subject: process.Subject(Message),
) -> #(Dict(String, Entry), Result(Nil, jsonrpc.RpcError)) {
  case load(records, task_id, access), dict.get(entries, task_id) {
    Error(error), _ -> #(entries, Error(error))
    Ok(TaskRecord(task: actions.Task(status: actions.InputRequired, ..), ..)),
      Ok(Entry(resume: Some(resume), ..) as entry)
    -> {
      // Unknown and already consumed keys are ignored. Retain missing inputs
      // until a later update supplies them all.
      let supplied =
        update(records, task_id, fn(record) {
          let supplied =
            dict.filter(inputs, fn(key, _) { dict.has_key(record.inputs, key) })
          let remaining =
            dict.filter(record.inputs, fn(key, _) {
              !dict.has_key(supplied, key)
            })
          Ok(#(
            TaskRecord(..record, inputs: remaining),
            #(supplied, dict.size(remaining) == 0),
          ))
        })
      case supplied {
        Error(error) -> #(entries, Error(error))
        Ok(#(supplied, complete)) ->
          case dict.size(supplied) > 0 {
            False -> #(entries, Ok(Nil))
            True -> {
              let next_resume = fn(more) { resume(dict.merge(supplied, more)) }
              let entries =
                dict.insert(
                  entries,
                  task_id,
                  Entry(..entry, resume: Some(next_resume)),
                )
              case complete {
                False -> #(entries, Ok(Nil))
                True ->
                  start_modern_task(entries, records, task_id, subject, fn() {
                    next_resume(dict.new())
                  })
              }
            }
          }
      }
    }
    Ok(_), _ -> #(entries, Ok(Nil))
  }
}

fn cancel_task(
  entries: Dict(String, Entry),
  records: Records,
  task_id: String,
  access: Access,
  // Status updates report an already terminal task instead of failing.
  lenient: Bool,
) -> #(Dict(String, Entry), Result(actions.CancelTaskResult, jsonrpc.RpcError)) {
  let cancelled = case load(records, task_id, access) {
    Error(error) -> Error(error)
    Ok(_) ->
      update(records, task_id, fn(record) {
        case is_terminal(record.task.status), lenient {
          True, True ->
            Ok(#(record, actions.CancelTaskResult(record.task, None)))
          True, False -> Error(cannot_cancel_error(record.task))
          False, _ -> {
            let task =
              set_task_status(
                record.task,
                actions.Cancelled,
                record.cancellation_status_message
                  |> option.or(Some("The task was cancelled by request.")),
              )
            Ok(#(
              TaskRecord(..record, task: task),
              actions.CancelTaskResult(task, record.cancellation_meta),
            ))
          }
        }
      })
  }
  case cancelled, dict.get(entries, task_id) {
    Ok(_), Ok(entry) -> {
      stop_worker(entry.worker)
      notify_waiters(entry.waiters, Error(cancelled_task_error(task_id)))
      #(
        dict.insert(
          entries,
          task_id,
          Entry(..entry, waiters: [], worker: None, resume: None),
        )
          |> tidy(task_id),
        cancelled,
      )
    }
    _, _ -> #(entries, cancelled)
  }
}

fn complete_task(
  entries: Dict(String, Entry),
  records: Records,
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> #(Dict(String, Entry), Result(actions.Task, jsonrpc.RpcError)) {
  let completed =
    update(records, task_id, fn(record) {
      let final_outcome = case is_terminal(record.task.status), record.outcome {
        True, Some(previous) -> previous
        True, None -> Error(cancelled_task_error(task_id))
        False, _ -> outcome
      }
      let task = terminal_task(record.task, outcome)
      Ok(#(
        TaskRecord(
          ..record,
          task: task,
          outcome: Some(final_outcome),
          inputs: dict.new(),
        ),
        #(task, result_for_task(task, task_id, final_outcome)),
      ))
    })
  case completed, dict.get(entries, task_id) {
    Ok(#(task, result)), Ok(entry) -> {
      stop_worker(entry.worker)
      notify_waiters(entry.waiters, result)
      #(
        dict.insert(
          entries,
          task_id,
          Entry(..entry, waiters: [], worker: None, resume: None),
        )
          |> tidy(task_id),
        Ok(task),
      )
    }
    Ok(#(task, _)), Error(Nil) -> #(entries, Ok(task))
    Error(error), Ok(entry) -> {
      // The record is unreachable, so release whoever is waiting on it.
      stop_worker(entry.worker)
      notify_waiters(entry.waiters, Error(error))
      #(
        dict.insert(
          entries,
          task_id,
          Entry(..entry, waiters: [], worker: None, resume: None),
        )
          |> tidy(task_id),
        Error(error),
      )
    }
    Error(error), Error(Nil) -> #(entries, Error(error))
  }
}

fn load(
  records: Records,
  task_id: String,
  access: Access,
) -> Result(TaskRecord, jsonrpc.RpcError) {
  case records.get(task_id) {
    Error(error) -> Error(store_error(error))
    Ok(Some(record)) ->
      case expired(record), can_access(record, access) {
        False, True -> Ok(record)
        _, _ -> Error(task_not_found_error(task_id))
      }
    Ok(None) -> Error(task_not_found_error(task_id))
  }
}

/// Apply a change to a task's record, retrying when another writer changed
/// the record first.
fn update(
  records: Records,
  task_id: String,
  apply: fn(TaskRecord) -> Result(#(TaskRecord, a), jsonrpc.RpcError),
) -> Result(a, jsonrpc.RpcError) {
  update_attempt(records, task_id, apply, update_attempts)
}

fn update_attempt(
  records: Records,
  task_id: String,
  apply: fn(TaskRecord) -> Result(#(TaskRecord, a), jsonrpc.RpcError),
  attempts: Int,
) -> Result(a, jsonrpc.RpcError) {
  use record <- result.try(load(records, task_id, Unscoped))
  use #(next, value) <- result.try(apply(record))
  case next == record {
    True -> Ok(value)
    False ->
      case records.replace(TaskRecord(..next, version: record.version + 1)) {
        Ok(True) -> Ok(value)
        Ok(False) if attempts > 1 ->
          update_attempt(records, task_id, apply, attempts - 1)
        Ok(False) ->
          Error(jsonrpc.RpcError(
            -32_603,
            "Task was changed concurrently: " <> task_id,
            None,
          ))
        Error(error) -> Error(store_error(error))
      }
  }
}

fn expired(record: TaskRecord) -> Bool {
  case record.expires_at {
    Some(expires_at) ->
      timestamp.compare(expires_at, timestamp.system_time()) != order.Gt
    None -> False
  }
}

fn can_access(record: TaskRecord, access: Access) -> Bool {
  case access {
    Unscoped -> True
    Scoped(scope) -> record.scope == scope
  }
}

fn store_error(error: persistence.StoreError) -> jsonrpc.RpcError {
  jsonrpc.RpcError(-32_603, "Task store unavailable: " <> error.message, None)
}

fn terminal_task(
  task: actions.Task,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> actions.Task {
  case is_terminal(task.status) {
    True -> task
    False -> {
      let #(status, status_message) = terminal_status(outcome)
      set_task_status(
        task,
        status,
        status_message |> option.or(task.status_message),
      )
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
