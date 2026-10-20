//// Periodically removes expired sessions and tasks from their stores, then
//// releases what this replica held for them. Expired records are already
//// unreadable, so sweeping only reclaims space and live resources.

import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/time/timestamp
import gleam_mcp/persistence

pub type Config {
  Config(
    sessions: persistence.SessionStore,
    tasks: persistence.TaskStore,
    interval_ms: Int,
    /// Called for each session removed by this sweep.
    session_expired: fn(String) -> Nil,
    /// Called with the tasks removed by this sweep.
    tasks_expired: fn(List(String)) -> Nil,
  )
}

pub opaque type Message {
  Sweep
}

pub fn start(
  name: process.Name(Message),
  config: Config,
) -> actor.StartResult(process.Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send_after(subject, config.interval_ms, Sweep)
    actor.initialised(#(subject, config))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(fn(state, message) {
    let #(subject, config) = state
    case message {
      Sweep -> {
        sweep(config)
        process.send_after(subject, config.interval_ms, Sweep)
        actor.continue(state)
      }
    }
  })
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  config: Config,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  supervision.worker(fn() { start(name, config) })
}

/// Sweep both stores once. A store that is unavailable is retried on the next
/// sweep.
pub fn sweep(config: Config) -> Nil {
  let now = timestamp.system_time()
  case config.sessions.delete_expired(now) {
    Ok(ids) -> list.each(ids, config.session_expired)
    Error(_) -> Nil
  }
  case config.tasks.delete_expired(now) {
    Ok([]) | Error(_) -> Nil
    Ok(ids) -> config.tasks_expired(ids)
  }
}
