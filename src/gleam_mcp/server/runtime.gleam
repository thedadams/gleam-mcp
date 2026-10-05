import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server/streamable_http_store

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
  Active(Option(String), jsonrpc.RequestId, process.Subject(Bool))
  ActiveWorker(
    Option(String),
    jsonrpc.RequestId,
    process.Pid,
    process.Subject(Bool),
  )
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

pub fn active(
  store: Store(a),
  scope: Option(String),
  id: jsonrpc.RequestId,
) -> Bool {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, Active(scope, id, reply))
  let assert Ok(active) = process.receive(reply, 1000)
  active
}

pub fn active_worker(
  store: Store(a),
  scope: Option(String),
  id: jsonrpc.RequestId,
  worker: process.Pid,
) -> Bool {
  let Store(subject) = store
  let reply = process.new_subject()
  process.send(subject, ActiveWorker(scope, id, worker, reply))
  let assert Ok(active) = process.receive(reply, 1000)
  active
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
    ActiveWorker(scope, id, worker, reply) -> {
      process.send(reply, case dict.get(pending, #(scope, id)) {
        Ok(entry) -> entry.worker == worker
        Error(_) -> False
      })
      loop(subject, pending, subscriptions)
    }
    Active(scope, id, reply) -> {
      process.send(reply, dict.has_key(pending, #(scope, id)))
      loop(subject, pending, subscriptions)
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

/// Modern subscriptions belong to the listen request and the receiving
/// process, independently of any legacy session registry.
pub opaque type SubscriptionStore {
  SubscriptionStore(process.Subject(SubscriptionMessage))
}

type ModernSubscription {
  ModernSubscription(
    owner: process.Pid,
    monitor: process.Monitor,
    listener: process.Subject(streamable_http_store.ListenerMessage),
    accepts: fn(jsonrpc.Request(actions.ActionNotification)) -> Bool,
    correlate: fn(jsonrpc.Request(actions.ActionNotification)) ->
      jsonrpc.Request(actions.ActionNotification),
    closing: String,
  )
}

type SubscriptionMessage {
  Listen(
    String,
    jsonrpc.RequestId,
    process.Subject(streamable_http_store.ListenerMessage),
    fn(jsonrpc.Request(actions.ActionNotification)) -> Bool,
    fn(jsonrpc.Request(actions.ActionNotification)) ->
      jsonrpc.Request(actions.ActionNotification),
    jsonrpc.Request(actions.ActionNotification),
    String,
    process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  SubscriptionActive(String, jsonrpc.RequestId, process.Subject(Bool))
  Publish(jsonrpc.Request(actions.ActionNotification))
  EndSubscription(String, jsonrpc.RequestId, process.Subject(Nil))
  EndScope(String, process.Subject(Nil))
  ListenerDown(process.Down)
}

pub fn new_subscriptions() -> SubscriptionStore {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      subscription_loop(subject, dict.new())
    })
  SubscriptionStore(process.receive(ready, 1000) |> expect_ok)
}

pub fn listen_request(
  store: SubscriptionStore,
  scope: String,
  id: jsonrpc.RequestId,
  listener: process.Subject(streamable_http_store.ListenerMessage),
  accepts: fn(jsonrpc.Request(actions.ActionNotification)) -> Bool,
  correlate: fn(jsonrpc.Request(actions.ActionNotification)) ->
    jsonrpc.Request(actions.ActionNotification),
  acknowledgment: jsonrpc.Request(actions.ActionNotification),
  closing: String,
) -> Result(Nil, jsonrpc.RpcError) {
  let SubscriptionStore(subject) = store
  let reply = process.new_subject()
  process.send(
    subject,
    Listen(
      scope,
      id,
      listener,
      accepts,
      correlate,
      acknowledgment,
      closing,
      reply,
    ),
  )
  process.receive(reply, 1000) |> expect_ok
}

pub fn subscription_active(
  store: SubscriptionStore,
  scope: String,
  id: jsonrpc.RequestId,
) -> Bool {
  let SubscriptionStore(subject) = store
  let reply = process.new_subject()
  process.send(subject, SubscriptionActive(scope, id, reply))
  process.receive(reply, 1000) |> expect_ok
}

pub fn publish(
  store: SubscriptionStore,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Nil {
  let SubscriptionStore(subject) = store
  process.send(subject, Publish(notification))
}

pub fn cancel_subscription(
  store: SubscriptionStore,
  scope: String,
  id: jsonrpc.RequestId,
) -> Nil {
  let SubscriptionStore(subject) = store
  let reply = process.new_subject()
  process.send(subject, EndSubscription(scope, id, reply))
  process.receive(reply, 1000) |> expect_ok
}

pub fn close_subscription_scope(
  store: SubscriptionStore,
  scope: String,
) -> Nil {
  let SubscriptionStore(subject) = store
  let reply = process.new_subject()
  process.send(subject, EndScope(scope, reply))
  process.receive(reply, 1000) |> expect_ok
}

fn subscription_loop(
  subject: process.Subject(SubscriptionMessage),
  subscriptions: dict.Dict(#(String, jsonrpc.RequestId), ModernSubscription),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(ListenerDown)
  case process.selector_receive_forever(selector) {
    Listen(
      scope,
      id,
      listener,
      accepts,
      correlate,
      acknowledgment,
      closing,
      reply,
    ) -> {
      let key = #(scope, id)
      case dict.has_key(subscriptions, key), process.subject_owner(listener) {
        True, _ -> {
          process.send(
            reply,
            Error(jsonrpc.RpcError(
              -32_600,
              "Duplicate active subscription id",
              None,
            )),
          )
          subscription_loop(subject, subscriptions)
        }
        False, Error(_) -> {
          process.send(
            reply,
            Error(jsonrpc.invalid_params_error(
              "Subscription listener has no owner",
            )),
          )
          subscription_loop(subject, subscriptions)
        }
        False, Ok(owner) -> {
          case process.is_alive(owner) {
            False -> {
              process.send(
                reply,
                Error(jsonrpc.invalid_params_error(
                  "Subscription listener is closed",
                )),
              )
              subscription_loop(subject, subscriptions)
            }
            True -> {
              let monitor = process.monitor(owner)
              // The acknowledgment is delivered before the registration can
              // receive any subsequent broadcast.
              process.send(
                listener,
                streamable_http_store.DeliverNotification(correlate(
                  acknowledgment,
                )),
              )
              process.send(reply, Ok(Nil))
              subscription_loop(
                subject,
                dict.insert(
                  subscriptions,
                  key,
                  ModernSubscription(
                    owner,
                    monitor,
                    listener,
                    accepts,
                    correlate,
                    closing,
                  ),
                ),
              )
            }
          }
        }
      }
    }
    SubscriptionActive(scope, id, reply) -> {
      process.send(reply, dict.has_key(subscriptions, #(scope, id)))
      subscription_loop(subject, subscriptions)
    }
    Publish(notification) -> {
      let subscriptions =
        dict.filter(subscriptions, fn(_, subscription) {
          case process.is_alive(subscription.owner) {
            False -> {
              process.demonitor_process(subscription.monitor)
              False
            }
            True -> {
              case subscription.accepts(notification) {
                True ->
                  process.send(
                    subscription.listener,
                    streamable_http_store.DeliverNotification(
                      subscription.correlate(notification),
                    ),
                  )
                False -> Nil
              }
              True
            }
          }
        })
      subscription_loop(subject, subscriptions)
    }
    EndSubscription(scope, id, reply) -> {
      let key = #(scope, id)
      case dict.get(subscriptions, key) {
        Ok(subscription) -> {
          process.demonitor_process(subscription.monitor)
          process.send(
            subscription.listener,
            streamable_http_store.DeliverResponse(subscription.closing),
          )
        }
        Error(_) -> Nil
      }
      process.send(reply, Nil)
      subscription_loop(subject, dict.delete(subscriptions, key))
    }
    EndScope(scope, reply) -> {
      let subscriptions =
        dict.filter(subscriptions, fn(key, subscription) {
          case key.0 == scope {
            True -> {
              process.demonitor_process(subscription.monitor)
              process.send(
                subscription.listener,
                streamable_http_store.DeliverResponse(subscription.closing),
              )
              False
            }
            False -> True
          }
        })
      process.send(reply, Nil)
      subscription_loop(subject, subscriptions)
    }
    ListenerDown(process.ProcessDown(_, owner, _)) -> {
      subscription_loop(
        subject,
        dict.filter(subscriptions, fn(_, subscription) {
          case subscription.owner == owner {
            True -> {
              process.demonitor_process(subscription.monitor)
              False
            }
            False -> True
          }
        }),
      )
    }
    ListenerDown(process.PortDown(..)) ->
      subscription_loop(subject, subscriptions)
  }
}

fn expect_ok(result: Result(a, b)) -> a {
  let assert Ok(value) = result
  value
}
