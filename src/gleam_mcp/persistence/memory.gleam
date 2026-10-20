//// In-memory stores for a single replica. State is lost when the replica
//// stops, so use a database-backed store when sessions or tasks must survive
//// restarts or be shared between replicas.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}
import gleam_mcp/persistence.{
  type SessionRecord, type SessionStore, type StoreError, type TaskRecord,
  type TaskScope, type TaskStore,
}

const call_timeout_ms = 1000

pub opaque type SessionMessage {
  PutSession(SessionRecord, process.Subject(Nil))
  GetSession(String, process.Subject(Option(SessionRecord)))
  DeleteSession(String, process.Subject(Nil))
  SetSubscription(String, String, Bool, process.Subject(Nil))
  Subscribers(String, process.Subject(List(String)))
  Subscriptions(String, process.Subject(List(String)))
  DeleteExpiredSessions(Timestamp, process.Subject(List(String)))
}

type Sessions {
  Sessions(
    records: Dict(String, SessionRecord),
    subscriptions: Dict(String, Set(String)),
  )
}

pub fn start_sessions(
  name: process.Name(SessionMessage),
) -> actor.StartResult(SessionStore) {
  actor.new(Sessions(dict.new(), dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle_session_message)
  |> actor.start
  |> map_started(fn(_) { sessions(name) })
}

pub fn supervised_sessions(
  name: process.Name(SessionMessage),
) -> supervision.ChildSpecification(SessionStore) {
  supervision.worker(fn() { start_sessions(name) })
}

/// The session store registered under `name`.
pub fn sessions(name: process.Name(SessionMessage)) -> SessionStore {
  let subject = process.named_subject(name)
  persistence.SessionStore(
    put: fn(record) { call(subject, PutSession(record, _)) },
    get: fn(id) { call(subject, GetSession(id, _)) },
    delete: fn(id) { call(subject, DeleteSession(id, _)) },
    set_subscription: fn(id, uri, enabled) {
      call(subject, SetSubscription(id, uri, enabled, _))
    },
    subscribers: fn(uri) { call(subject, Subscribers(uri, _)) },
    subscriptions: fn(id) { call(subject, Subscriptions(id, _)) },
    delete_expired: fn(now) { call(subject, DeleteExpiredSessions(now, _)) },
  )
}

fn handle_session_message(
  state: Sessions,
  message: SessionMessage,
) -> actor.Next(Sessions, SessionMessage) {
  case message {
    PutSession(record, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        Sessions(
          ..state,
          records: dict.insert(state.records, record.id, record),
        ),
      )
    }
    GetSession(id, reply) -> {
      process.send(reply, option.from_result(dict.get(state.records, id)))
      actor.continue(state)
    }
    DeleteSession(id, reply) -> {
      process.send(reply, Nil)
      actor.continue(delete_sessions(state, [id]))
    }
    SetSubscription(id, uri, enabled, reply) -> {
      process.send(reply, Nil)
      let current =
        dict.get(state.subscriptions, id)
        |> option.from_result
        |> option.lazy_unwrap(set.new)
      let next = case enabled {
        True -> set.insert(current, uri)
        False -> set.delete(current, uri)
      }
      actor.continue(
        Sessions(
          ..state,
          subscriptions: dict.insert(state.subscriptions, id, next),
        ),
      )
    }
    Subscribers(uri, reply) -> {
      process.send(
        reply,
        state.subscriptions
          |> dict.to_list
          |> list.filter_map(fn(entry) {
            case set.contains(entry.1, uri) {
              True -> Ok(entry.0)
              False -> Error(Nil)
            }
          }),
      )
      actor.continue(state)
    }
    Subscriptions(id, reply) -> {
      process.send(reply, case dict.get(state.subscriptions, id) {
        Ok(uris) -> set.to_list(uris)
        Error(Nil) -> []
      })
      actor.continue(state)
    }
    DeleteExpiredSessions(now, reply) -> {
      let expired =
        state.records
        |> dict.values
        |> list.filter(fn(record) { not_after(record.expires_at, now) })
        |> list.map(fn(record) { record.id })
      process.send(reply, expired)
      actor.continue(delete_sessions(state, expired))
    }
  }
}

fn delete_sessions(state: Sessions, ids: List(String)) -> Sessions {
  Sessions(
    records: dict.drop(state.records, ids),
    subscriptions: dict.drop(state.subscriptions, ids),
  )
}

pub opaque type TaskMessage {
  InsertTask(TaskRecord, process.Subject(Nil))
  GetTask(String, process.Subject(Option(TaskRecord)))
  ListTasks(TaskScope, process.Subject(List(TaskRecord)))
  ReplaceTask(TaskRecord, process.Subject(Bool))
  DeleteTask(String, process.Subject(Nil))
  DeleteTaskScope(Option(String), process.Subject(List(String)))
  DeleteExpiredTasks(Timestamp, process.Subject(List(String)))
}

pub fn start_tasks(
  name: process.Name(TaskMessage),
) -> actor.StartResult(TaskStore) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(handle_task_message)
  |> actor.start
  |> map_started(fn(_) { tasks(name) })
}

pub fn supervised_tasks(
  name: process.Name(TaskMessage),
) -> supervision.ChildSpecification(TaskStore) {
  supervision.worker(fn() { start_tasks(name) })
}

/// The task store registered under `name`.
pub fn tasks(name: process.Name(TaskMessage)) -> TaskStore {
  let subject = process.named_subject(name)
  persistence.TaskStore(
    insert: fn(record) { call(subject, InsertTask(record, _)) },
    get: fn(id) { call(subject, GetTask(id, _)) },
    list: fn(scope) { call(subject, ListTasks(scope, _)) },
    replace: fn(record) { call(subject, ReplaceTask(record, _)) },
    delete: fn(id) { call(subject, DeleteTask(id, _)) },
    delete_scope: fn(scope) { call(subject, DeleteTaskScope(scope, _)) },
    delete_expired: fn(now) { call(subject, DeleteExpiredTasks(now, _)) },
  )
}

fn handle_task_message(
  records: Dict(String, TaskRecord),
  message: TaskMessage,
) -> actor.Next(Dict(String, TaskRecord), TaskMessage) {
  case message {
    InsertTask(record, reply) -> {
      process.send(reply, Nil)
      actor.continue(dict.insert(records, record.task.task_id, record))
    }
    GetTask(id, reply) -> {
      process.send(reply, option.from_result(dict.get(records, id)))
      actor.continue(records)
    }
    ListTasks(scope, reply) -> {
      process.send(
        reply,
        records
          |> dict.values
          |> list.filter(fn(record) {
            case scope {
              persistence.AnyScope -> True
              persistence.Scope(scope) -> record.scope == scope
            }
          }),
      )
      actor.continue(records)
    }
    ReplaceTask(record, reply) -> {
      let id = record.task.task_id
      case dict.get(records, id) {
        Ok(current) if current.version + 1 == record.version -> {
          process.send(reply, True)
          actor.continue(dict.insert(records, id, record))
        }
        _ -> {
          process.send(reply, False)
          actor.continue(records)
        }
      }
    }
    DeleteTask(id, reply) -> {
      process.send(reply, Nil)
      actor.continue(dict.delete(records, id))
    }
    DeleteTaskScope(scope, reply) -> {
      let ids = matching_ids(records, fn(record) { record.scope == scope })
      process.send(reply, ids)
      actor.continue(dict.drop(records, ids))
    }
    DeleteExpiredTasks(now, reply) -> {
      let ids =
        matching_ids(records, fn(record) {
          case record.expires_at {
            Some(expires_at) -> not_after(expires_at, now)
            None -> False
          }
        })
      process.send(reply, ids)
      actor.continue(dict.drop(records, ids))
    }
  }
}

fn matching_ids(
  records: Dict(String, TaskRecord),
  keep: fn(TaskRecord) -> Bool,
) -> List(String) {
  records
  |> dict.values
  |> list.filter(keep)
  |> list.map(fn(record) { record.task.task_id })
}

fn not_after(time: Timestamp, now: Timestamp) -> Bool {
  timestamp.compare(time, now) != order.Gt
}

fn call(
  subject: process.Subject(message),
  make: fn(process.Subject(reply)) -> message,
) -> Result(reply, StoreError) {
  Ok(process.call(subject, call_timeout_ms, make))
}

fn map_started(
  result: actor.StartResult(a),
  with: fn(a) -> b,
) -> actor.StartResult(b) {
  case result {
    Ok(actor.Started(pid:, data:)) -> Ok(actor.Started(pid:, data: with(data)))
    Error(error) -> Error(error)
  }
}
