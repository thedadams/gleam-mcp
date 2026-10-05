import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/jsonrpc

pub opaque type Store(a) {
  Store(process.Subject(Message(a)))
}

type Pending(a) {
  Pending(
    worker: process.Pid,
    monitor: process.Monitor,
    timer: process.Timer,
    reply: process.Subject(Result(a, jsonrpc.RpcError)),
  )
}

type Message(a) {
  Begin(
    Option(String),
    jsonrpc.RequestId,
    Int,
    fn() -> Result(a, jsonrpc.RpcError),
    process.Subject(Result(a, jsonrpc.RpcError)),
    process.Subject(Nil),
  )
  Ready(Option(String), jsonrpc.RequestId, process.Pid, process.Subject(Nil))
  Finished(
    Option(String),
    jsonrpc.RequestId,
    process.Pid,
    Result(a, jsonrpc.RpcError),
  )
  Timeout(Option(String), jsonrpc.RequestId, process.Pid)
  WorkerDown(process.Down)
  Abort(Option(String), jsonrpc.RequestId, String)
  Close(String, process.Subject(Nil))
  Subscribe(String, String, Bool, process.Subject(Nil))
  Subscribers(String, process.Subject(List(String)))
}

pub fn new() -> Store(a) {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(subject, dict.new(), dict.new())
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Store(subject)
}

/// Run each request in an isolated, cancellable Gleam worker.
pub fn run(
  store: Store(a),
  session: Option(String),
  id: jsonrpc.RequestId,
  timeout_ms: Int,
  work: fn() -> Result(a, jsonrpc.RpcError),
) -> Result(a, jsonrpc.RpcError) {
  start(store, session, id, timeout_ms, work) |> process.receive_forever
}

/// Start work and acknowledge its registration before returning a result
/// subject. The calling process owns the returned subject and must receive it.
pub fn start(
  store: Store(a),
  session: Option(String),
  id: jsonrpc.RequestId,
  timeout_ms: Int,
  work: fn() -> Result(a, jsonrpc.RpcError),
) -> process.Subject(Result(a, jsonrpc.RpcError)) {
  let reply = process.new_subject()
  start_with_reply(store, session, id, timeout_ms, work, reply)
  reply
}

/// Register work with a result subject owned by its eventual receiving process.
pub fn start_with_reply(
  store: Store(a),
  session: Option(String),
  id: jsonrpc.RequestId,
  timeout_ms: Int,
  work: fn() -> Result(a, jsonrpc.RpcError),
  reply: process.Subject(Result(a, jsonrpc.RpcError)),
) -> Nil {
  let Store(subject) = store
  let registered = process.new_subject()
  process.send(subject, Begin(session, id, timeout_ms, work, reply, registered))
  let assert Ok(Nil) = process.receive(registered, 1000)
  Nil
}

pub fn cancel(
  store: Store(a),
  session: Option(String),
  id: jsonrpc.RequestId,
) -> Nil {
  let Store(subject) = store
  process.send(subject, Abort(session, id, "Request cancelled"))
}

pub fn close(store: Store(a), session: String) -> Nil {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, Close(session, reply))
  let assert Ok(Nil) = process.receive(reply, 1000)
  Nil
}

pub fn subscribe(
  store: Store(a),
  session: String,
  uri: String,
  enabled: Bool,
) -> Nil {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, Subscribe(session, uri, enabled, reply))
  let assert Ok(Nil) = process.receive(reply, 1000)
  Nil
}

pub fn subscribers(store: Store(a), uri: String) -> List(String) {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, Subscribers(uri, reply))
  let assert Ok(sessions) = process.receive(reply, 1000)
  sessions
}

fn loop(
  subject: process.Subject(Message(a)),
  pending: dict.Dict(#(Option(String), jsonrpc.RequestId), Pending(a)),
  subscriptions: dict.Dict(String, List(String)),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(WorkerDown)
  case process.selector_receive_forever(selector) {
    Begin(session, id, timeout, work, reply, registered) -> {
      let key = #(session, id)
      case dict.has_key(pending, key) {
        True -> {
          process.send(
            reply,
            Error(jsonrpc.RpcError(-32_600, "Duplicate active request id", None)),
          )
          process.send(registered, Nil)
          loop(subject, pending, subscriptions)
        }
        False -> {
          let worker =
            process.spawn_unlinked(fn() {
              let ready = process.new_subject()
              process.send(subject, Ready(session, id, process.self(), ready))
              process.receive_forever(ready)
              process.send(
                subject,
                Finished(session, id, process.self(), work()),
              )
            })
          let monitor = process.monitor(worker)
          let timeout = case timeout < 1 {
            True -> 1
            False -> timeout
          }
          let timer =
            process.send_after(subject, timeout, Timeout(session, id, worker))
          process.send(registered, Nil)
          loop(
            subject,
            dict.insert(pending, key, Pending(worker, monitor, timer, reply)),
            subscriptions,
          )
        }
      }
    }
    Ready(session, id, worker, ready) -> {
      case dict.get(pending, #(session, id)) {
        Ok(entry) if entry.worker == worker -> process.send(ready, Nil)
        _ -> process.kill(worker)
      }
      loop(subject, pending, subscriptions)
    }
    Finished(session, id, worker, outcome) -> {
      let key = #(session, id)
      case dict.get(pending, key) {
        Ok(entry) if entry.worker == worker -> {
          release_tracking(entry)
          process.send(entry.reply, outcome)
          loop(subject, dict.delete(pending, key), subscriptions)
        }
        _ -> loop(subject, pending, subscriptions)
      }
    }
    Timeout(session, id, worker) -> {
      let key = #(session, id)
      case dict.get(pending, key) {
        Ok(entry) if entry.worker == worker -> {
          stop_pending(
            entry,
            jsonrpc.RpcError(-32_800, "Request timed out", None),
          )
          loop(subject, dict.delete(pending, key), subscriptions)
        }
        _ -> loop(subject, pending, subscriptions)
      }
    }
    WorkerDown(process.ProcessDown(_, worker, _)) -> {
      case
        list.find(dict.to_list(pending), fn(pair) { pair.1.worker == worker })
      {
        Ok(#(key, entry)) -> {
          release_tracking(entry)
          process.send(
            entry.reply,
            Error(jsonrpc.RpcError(
              -32_603,
              "Request worker exited before completing",
              None,
            )),
          )
          loop(subject, dict.delete(pending, key), subscriptions)
        }
        Error(Nil) -> loop(subject, pending, subscriptions)
      }
    }
    WorkerDown(process.PortDown(..)) -> loop(subject, pending, subscriptions)
    Abort(session, id, message) -> {
      let key = #(session, id)
      case dict.get(pending, key) {
        Ok(entry) -> {
          stop_pending(entry, jsonrpc.RpcError(-32_800, message, None))
        }
        Error(_) -> Nil
      }
      loop(subject, dict.delete(pending, key), subscriptions)
    }
    Close(session, reply) -> {
      let next =
        dict.filter(pending, fn(key, entry) {
          case key.0 == Some(session) {
            True -> {
              stop_pending(
                entry,
                jsonrpc.invalid_params_error("MCP session closed"),
              )
              False
            }
            False -> True
          }
        })
      process.send(reply, Nil)
      loop(subject, next, dict.delete(subscriptions, session))
    }
    Subscribe(session, uri, enabled, reply) -> {
      let current = case dict.get(subscriptions, session) {
        Ok(uris) -> uris
        Error(_) -> []
      }
      let next = case enabled {
        True ->
          case list.contains(current, uri) {
            True -> current
            False -> [uri, ..current]
          }
        False -> list.filter(current, fn(value) { value != uri })
      }
      process.send(reply, Nil)
      loop(subject, pending, dict.insert(subscriptions, session, next))
    }
    Subscribers(uri, reply) -> {
      process.send(
        reply,
        subscriptions
          |> dict.to_list
          |> list.filter_map(fn(entry) {
            case list.contains(entry.1, uri) {
              True -> Ok(entry.0)
              False -> Error(Nil)
            }
          }),
      )
      loop(subject, pending, subscriptions)
    }
  }
}

fn release_tracking(entry: Pending(a)) -> Nil {
  let _ = process.cancel_timer(entry.timer)
  process.demonitor_process(entry.monitor)
}

fn stop_pending(entry: Pending(a), error: jsonrpc.RpcError) -> Nil {
  release_tracking(entry)
  process.kill(entry.worker)
  process.send(entry.reply, Error(error))
}
