import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/time/duration
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/persistence
import gleam_mcp/persistence/memory
import gleam_mcp/server/janitor
import gleam_mcp/task_store
import gleeunit/should

fn records() -> persistence.TaskStore {
  let assert Ok(actor.Started(data: records, ..)) =
    memory.start_tasks(process.new_name("task_records_test"))
  records
}

/// A task store for one replica, sharing `records` with the others.
fn replica(records: persistence.TaskStore) -> task_store.Store {
  let assert Ok(actor.Started(data: store, ..)) =
    task_store.start(process.new_name("task_replica_test"), records)
  store
}

fn sample_result() -> actions.TaskResult {
  actions.TaskResultModern(jsonrpc.VObject([#("done", jsonrpc.VBool(True))]))
}

pub fn replicas_read_and_cancel_each_others_tasks_test() {
  let shared = records()
  let first = replica(shared)
  let second = replica(shared)
  let task = task_store.create_scoped(first, Some(60_000), Some("alice"))

  task_store.get_scoped(second, task.task_id, Some("alice"))
  |> should.equal(Ok(task))
  task_store.get_scoped(second, task.task_id, Some("bob")) |> should.be_error
  task_store.list_scoped(second, Some("alice")) |> should.equal(Ok([task]))

  let cancelled =
    task_store.cancel_scoped(second, task.task_id, Some("alice"))
    |> should.be_ok
  should.equal(cancelled.status, actions.Cancelled)
  let seen = task_store.get(first, task.task_id) |> should.be_ok
  should.equal(seen.status, actions.Cancelled)
}

pub fn a_changed_record_wakes_waiters_and_stops_the_worker_test() {
  let shared = records()
  let owner = replica(shared)
  let other = replica(shared)
  let task = task_store.create(owner, None)
  let stopped = process.new_subject()
  task_store.start_worker(owner, task.task_id, fn() {
    let watcher = process.self()
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(watcher)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
      process.send(stopped, Nil)
    })
    process.sleep_forever()
    Ok(sample_result())
  })
  |> should.be_ok
  let waiting = process.new_subject()
  process.spawn(fn() {
    process.send(waiting, task_store.result(owner, task.task_id))
  })
  process.sleep(20)

  // The cancellation is written by another replica, which then announces it.
  task_store.cancel(other, task.task_id) |> should.be_ok
  task_store.changed(owner, task.task_id)

  process.receive(waiting, 1000) |> should.be_ok |> should.be_error
  process.receive(stopped, 1000) |> should.be_ok
}

pub fn a_completed_task_is_visible_to_other_replicas_test() {
  let shared = records()
  let owner = replica(shared)
  let other = replica(shared)
  let task = task_store.create(owner, None)
  task_store.complete(owner, task.task_id, Ok(sample_result())) |> should.be_ok
  task_store.result(other, task.task_id) |> should.be_ok
  let snapshot =
    task_store.snapshot_scoped(other, task.task_id, None) |> should.be_ok
  should.equal(snapshot.task.status, actions.Completed)
}

pub fn store_failures_become_errors_test() {
  let failing =
    persistence.TaskStore(..records(), get: fn(_) {
      Error(persistence.StoreError("down"))
    })
  let store = replica(failing)
  let task = task_store.create(store, None)
  let error = task_store.get(store, task.task_id) |> should.be_error
  should.equal(error.code, -32_603)
}

pub fn conflicting_writes_are_rejected_test() {
  let shared = records()
  let store = replica(shared)
  let task = task_store.create(store, None)
  let assert Ok(Some(record)) = shared.get(task.task_id)
  let next = persistence.TaskRecord(..record, version: record.version + 1)
  shared.replace(next) |> should.equal(Ok(True))
  shared.replace(next) |> should.equal(Ok(False))
}

pub fn expired_records_are_hidden_and_swept_test() {
  let shared = records()
  let store = replica(shared)
  let task = task_store.create(store, None)
  let assert Ok(Some(record)) = shared.get(task.task_id)
  let past = timestamp.add(timestamp.system_time(), duration.seconds(-1))
  let assert Ok(True) =
    shared.replace(
      persistence.TaskRecord(
        ..record,
        expires_at: Some(past),
        version: record.version + 1,
      ),
    )
  task_store.get(store, task.task_id) |> should.be_error

  let swept = process.new_subject()
  let assert Ok(sessions) =
    memory.start_sessions(process.new_name("janitor_sessions_test"))
  janitor.sweep(
    janitor.Config(
      sessions: sessions.data,
      tasks: shared,
      interval_ms: 60_000,
      session_expired: fn(_) { Nil },
      tasks_expired: fn(ids) { process.send(swept, ids) },
    ),
  )
  process.receive(swept, 100) |> should.equal(Ok([task.task_id]))
  shared.get(task.task_id) |> should.equal(Ok(None))
}

pub fn janitor_closes_expired_sessions_test() {
  let assert Ok(sessions) =
    memory.start_sessions(process.new_name("janitor_sessions_test"))
  let now = timestamp.system_time()
  let past = timestamp.add(now, duration.seconds(-1))
  let assert Ok(Nil) =
    sessions.data.put(persistence.SessionRecord("gone", None, past, past))
  let closed = process.new_subject()
  let assert Ok(_) =
    janitor.start(
      process.new_name("janitor_test"),
      janitor.Config(
        sessions: sessions.data,
        tasks: records(),
        interval_ms: 10,
        session_expired: fn(id) { process.send(closed, id) },
        tasks_expired: fn(_) { Nil },
      ),
    )
  process.receive(closed, 1000) |> should.equal(Ok("gone"))
}
