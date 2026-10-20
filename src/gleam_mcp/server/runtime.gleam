import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server/streamable_http_store

pub opaque type Store(a) {
  Store(process.Subject(Message(a)))
}

type State(a) {
  State(
    subject: process.Subject(Message(a)),
    pending: dict.Dict(#(Option(String), jsonrpc.RequestId), Pending(a)),
  )
}

type Pending(a) {
  Pending(
    worker: process.Pid,
    monitor: process.Monitor,
    timer: process.Timer,
    reply: process.Subject(Result(a, jsonrpc.RpcError)),
  )
}

pub opaque type Message(a) {
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
}

/// Start an unsupervised request store linked to the calling process.
pub fn new() -> Store(a) {
  let assert Ok(actor.Started(data: store, ..)) =
    start_store(process.new_name("gleam_mcp_runtime"))
  store
}

/// Start the request store registered under `name`, so that a supervisor can
/// restart it without invalidating the handles returned by `named`.
pub fn start_store(
  name: process.Name(Message(a)),
) -> actor.StartResult(Store(a)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(WorkerDown)
    actor.initialised(State(subject, dict.new()))
    |> actor.selecting(selector)
    |> actor.returning(Store(subject))
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message(a)),
) -> supervision.ChildSpecification(Store(a)) {
  supervision.worker(fn() { start_store(name) })
}

/// A handle to the request store registered under `name`.
pub fn named(name: process.Name(Message(a))) -> Store(a) {
  Store(process.named_subject(name))
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
  process.call(subject, 1000, fn(registered) {
    Begin(session, id, timeout_ms, work, reply, registered)
  })
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
  process.call(subject, 1000, fn(reply) { Active(scope, id, reply) })
}

pub fn active_worker(
  store: Store(a),
  scope: Option(String),
  id: jsonrpc.RequestId,
  worker: process.Pid,
) -> Bool {
  let Store(subject) = store
  process.call(subject, 1000, fn(reply) {
    ActiveWorker(scope, id, worker, reply)
  })
}

pub fn close(store: Store(a), session: String) -> Nil {
  let Store(subject) = store
  process.call(subject, 1000, fn(reply) { Close(session, reply) })
}

fn handle_message(
  state: State(a),
  message: Message(a),
) -> actor.Next(State(a), Message(a)) {
  let State(subject:, pending:) = state
  case message {
    Begin(session, id, timeout, work, reply, registered) -> {
      let key = #(session, id)
      case dict.has_key(pending, key) {
        True -> {
          process.send(
            reply,
            Error(jsonrpc.RpcError(-32_600, "Duplicate active request id", None)),
          )
          process.send(registered, Nil)
          continue(subject, pending)
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
          continue(
            subject,
            dict.insert(pending, key, Pending(worker, monitor, timer, reply)),
          )
        }
      }
    }
    Ready(session, id, worker, ready) -> {
      case dict.get(pending, #(session, id)) {
        Ok(entry) if entry.worker == worker -> process.send(ready, Nil)
        _ -> process.kill(worker)
      }
      continue(subject, pending)
    }
    Finished(session, id, worker, outcome) -> {
      let key = #(session, id)
      case dict.get(pending, key) {
        Ok(entry) if entry.worker == worker -> {
          release_tracking(entry)
          process.send(entry.reply, outcome)
          continue(subject, dict.delete(pending, key))
        }
        _ -> continue(subject, pending)
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
          continue(subject, dict.delete(pending, key))
        }
        _ -> continue(subject, pending)
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
          continue(subject, dict.delete(pending, key))
        }
        Error(Nil) -> continue(subject, pending)
      }
    }
    WorkerDown(process.PortDown(..)) -> continue(subject, pending)
    Abort(session, id, message) -> {
      let key = #(session, id)
      case dict.get(pending, key) {
        Ok(entry) -> {
          stop_pending(entry, jsonrpc.RpcError(-32_800, message, None))
        }
        Error(_) -> Nil
      }
      continue(subject, dict.delete(pending, key))
    }
    ActiveWorker(scope, id, worker, reply) -> {
      process.send(reply, case dict.get(pending, #(scope, id)) {
        Ok(entry) -> entry.worker == worker
        Error(_) -> False
      })
      continue(subject, pending)
    }
    Active(scope, id, reply) -> {
      process.send(reply, dict.has_key(pending, #(scope, id)))
      continue(subject, pending)
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
      continue(subject, next)
    }
  }
}

fn continue(
  subject: process.Subject(Message(a)),
  pending: dict.Dict(#(Option(String), jsonrpc.RequestId), Pending(a)),
) -> actor.Next(State(a), Message(a)) {
  actor.continue(State(subject, pending))
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

pub opaque type SubscriptionMessage {
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

/// Start an unsupervised subscription store linked to the calling process.
pub fn new_subscriptions() -> SubscriptionStore {
  let assert Ok(actor.Started(data: store, ..)) =
    start_subscriptions(process.new_name("gleam_mcp_subscriptions"))
  store
}

pub fn start_subscriptions(
  name: process.Name(SubscriptionMessage),
) -> actor.StartResult(SubscriptionStore) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(ListenerDown)
    actor.initialised(dict.new())
    |> actor.selecting(selector)
    |> actor.returning(SubscriptionStore(subject))
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle_subscription_message)
  |> actor.start
}

pub fn supervised_subscriptions(
  name: process.Name(SubscriptionMessage),
) -> supervision.ChildSpecification(SubscriptionStore) {
  supervision.worker(fn() { start_subscriptions(name) })
}

pub fn named_subscriptions(
  name: process.Name(SubscriptionMessage),
) -> SubscriptionStore {
  SubscriptionStore(process.named_subject(name))
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
  process.call(subject, 1000, fn(reply) {
    Listen(
      scope,
      id,
      listener,
      accepts,
      correlate,
      acknowledgment,
      closing,
      reply,
    )
  })
}

pub fn subscription_active(
  store: SubscriptionStore,
  scope: String,
  id: jsonrpc.RequestId,
) -> Bool {
  let SubscriptionStore(subject) = store
  process.call(subject, 1000, fn(reply) { SubscriptionActive(scope, id, reply) })
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
  process.call(subject, 1000, fn(reply) { EndSubscription(scope, id, reply) })
}

pub fn close_subscription_scope(
  store: SubscriptionStore,
  scope: String,
) -> Nil {
  let SubscriptionStore(subject) = store
  process.call(subject, 1000, fn(reply) { EndScope(scope, reply) })
}

type Subscriptions =
  dict.Dict(#(String, jsonrpc.RequestId), ModernSubscription)

fn handle_subscription_message(
  subscriptions: Subscriptions,
  message: SubscriptionMessage,
) -> actor.Next(Subscriptions, SubscriptionMessage) {
  case message {
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
          actor.continue(subscriptions)
        }
        False, Error(_) -> {
          process.send(
            reply,
            Error(jsonrpc.invalid_params_error(
              "Subscription listener has no owner",
            )),
          )
          actor.continue(subscriptions)
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
              actor.continue(subscriptions)
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
              actor.continue(dict.insert(
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
              ))
            }
          }
        }
      }
    }
    SubscriptionActive(scope, id, reply) -> {
      process.send(reply, dict.has_key(subscriptions, #(scope, id)))
      actor.continue(subscriptions)
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
      actor.continue(subscriptions)
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
      actor.continue(dict.delete(subscriptions, key))
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
      actor.continue(subscriptions)
    }
    ListenerDown(process.ProcessDown(_, owner, _)) -> {
      actor.continue(
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
    ListenerDown(process.PortDown(..)) -> actor.continue(subscriptions)
  }
}
