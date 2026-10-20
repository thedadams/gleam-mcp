import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam_mcp/server/runtime
import gleam_mcp/server/streamable_http_store
import gleam_mcp/task_store
import gleeunit/should

pub fn supervised_task_store_survives_a_crash_test() {
  let name = process.new_name("task_store_supervision_test")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(task_store.supervised(name))
    |> static_supervisor.start
  let store = task_store.named(name)
  let _ = task_store.create(store, None)

  kill_and_await_restart(name)

  // The restarted store starts empty but is reachable through the same handle.
  task_store.list(store) |> should.equal([])
  let task = task_store.create(store, None)
  task_store.get(store, task.task_id) |> should.be_ok
}

pub fn supervised_http_store_survives_a_crash_test() {
  let name = process.new_name("http_store_supervision_test")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(streamable_http_store.supervised(name))
    |> static_supervisor.start
  let store = streamable_http_store.named(name)

  kill_and_await_restart(name)

  let id = streamable_http_store.ensure_session(store, None)
  streamable_http_store.has_session(store, id) |> should.be_true
}

pub fn supervised_runtime_survives_a_crash_test() {
  let name = process.new_name("runtime_supervision_test")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(runtime.supervised(name))
    |> static_supervisor.start
  let store: runtime.Store(Int) = runtime.named(name)

  kill_and_await_restart(name)

  runtime.subscribe(store, "session", "file:///a", True)
  runtime.subscribers(store, "file:///a") |> should.equal(["session"])
}

fn kill_and_await_restart(name: process.Name(message)) -> Nil {
  let assert Ok(pid) = process.named(name)
  process.kill(pid)
  await_new_pid(name, pid, 100)
}

fn await_new_pid(
  name: process.Name(message),
  old: process.Pid,
  attempts: Int,
) -> Nil {
  case process.named(name), attempts {
    Ok(pid), _ if pid != old -> Nil
    _, 0 -> panic as "Supervisor did not restart the store"
    _, _ -> {
      process.sleep(10)
      await_new_pid(name, old, attempts - 1)
    }
  }
}
