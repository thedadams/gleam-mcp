import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

pub type ListenerMessage {
  DeliverRequest(jsonrpc.Request(actions.ServerActionRequest))
  DeliverNotification(jsonrpc.Request(actions.ActionNotification))
  DeliverResponse(String)
  DeliverReplay(event_id: String, payload: String, close: Bool)
  CloseListener
}

pub type SessionMetadata {
  SessionMetadata(
    protocol_version: String,
    client_capabilities: actions.ClientCapabilities,
    initialized: Bool,
    ready: Bool,
    principal: Option(String),
  )
}

type Message {
  GetMetadata(String, process.Subject(Option(SessionMetadata)))
  SetMetadata(String, SessionMetadata, process.Subject(Nil))
  DeleteSession(String, process.Subject(Nil))
  EnsureSession(session_id: Option(String), reply_to: process.Subject(String))
  HasSession(session_id: String, reply_to: process.Subject(Bool))
  RegisterListener(
    session_id: String,
    listener_id: String,
    listener: process.Subject(ListenerMessage),
    reply_to: process.Subject(Nil),
  )
  UnregisterListener(
    session_id: String,
    listener_id: String,
    owner: Option(process.Pid),
    reply_to: process.Subject(Nil),
  )
  SendRequest(
    session_id: String,
    request: jsonrpc.Request(actions.ServerActionRequest),
    reply_to: process.Subject(
      Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
    ),
    timeout_ms: Int,
    record: Option(fn(String, String) -> String),
  )
  SendNotification(
    session_id: String,
    notification: jsonrpc.Request(actions.ActionNotification),
    record: Option(fn(String, String) -> String),
  )
  SendRecorded(String, String, String)
  SendStreamResponse(
    String,
    String,
    String,
    Option(fn(String, String) -> String),
  )
  ResolveResponse(
    session_id: String,
    body: String,
    reply_to: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  ExpireRequest(
    String,
    jsonrpc.RequestId,
    process.Subject(
      Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
    ),
  )
  CallerDown(process.Down)
}

type Session {
  Session(
    queued_requests: List(jsonrpc.Request(actions.ServerActionRequest)),
    pending_requests: Dict(String, PendingRequest),
    listener: List(Listener),
  )
}

type Listener {
  Listener(
    id: String,
    subject: process.Subject(ListenerMessage),
    owner: process.Pid,
    monitor: process.Monitor,
  )
}

type PendingRequest {
  PendingRequest(
    request: jsonrpc.Request(actions.ServerActionRequest),
    reply_to: process.Subject(
      Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
    ),
    caller: process.Pid,
    monitor: process.Monitor,
    timer: process.Timer,
    record: Option(fn(String, String) -> String),
  )
}

pub fn new() -> Store {
  let reply_to = process.new_subject()
  let _ = process.spawn(fn() { start_store(reply_to) })
  let subject = expect_ok(process.receive(reply_to, 1000))
  Store(subject)
}

fn start_store(reply_to: process.Subject(process.Subject(Message))) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  loop(subject, dict.new(), dict.new())
}

pub fn ensure_session(store: Store, session_id: Option(String)) -> String {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, EnsureSession(session_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn has_session(store: Store, session_id: String) -> Bool {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, HasSession(session_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn metadata(store: Store, session_id: String) -> Option(SessionMetadata) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, GetMetadata(session_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn set_metadata(
  store: Store,
  session_id: String,
  metadata: SessionMetadata,
) -> Nil {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, SetMetadata(session_id, metadata, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn delete_session(store: Store, session_id: String) -> Nil {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, DeleteSession(session_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn new_listener_id() -> String {
  uuid.v4_string()
}

pub fn register_listener(
  store: Store,
  session_id: String,
  listener_id: String,
  listener: process.Subject(ListenerMessage),
) -> Nil {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(
    subject,
    RegisterListener(session_id, listener_id, listener, reply_to),
  )
  expect_ok(process.receive(reply_to, 1000))
}

pub fn unregister_listener(
  store: Store,
  session_id: String,
  listener_id: String,
) -> Nil {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(
    subject,
    UnregisterListener(session_id, listener_id, None, reply_to),
  )
  expect_ok(process.receive(reply_to, 1000))
}

pub fn unregister_listener_owned(
  store: Store,
  session_id: String,
  listener_id: String,
  owner: process.Pid,
) -> Nil {
  let reply_to = process.new_subject()
  process.send(
    store.subject,
    UnregisterListener(session_id, listener_id, Some(owner), reply_to),
  )
  expect_ok(process.receive(reply_to, 1000))
}

pub fn send_request(
  store: Store,
  session_id: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  timeout_ms: Int,
) -> Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError) {
  send_request_with_recorder(store, session_id, request, timeout_ms, None)
}

pub fn send_request_with_recorder(
  store: Store,
  session_id: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  timeout_ms: Int,
  record: Option(fn(String, String) -> String),
) -> Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(
    subject,
    SendRequest(session_id, request, reply_to, timeout_ms, record),
  )

  case process.receive(reply_to, timeout_ms) {
    Ok(response) -> response
    Error(Nil) -> {
      process.send(
        subject,
        ExpireRequest(session_id, request_id(request), reply_to),
      )
      Error(jsonrpc.invalid_params_error(
        "Timed out waiting for a client response to server-sent request",
      ))
    }
  }
}

pub fn send_notification(
  store: Store,
  session_id: String,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Nil {
  send_notification_with_recorder(store, session_id, notification, None)
}

pub fn send_notification_with_recorder(
  store: Store,
  session_id: String,
  notification: jsonrpc.Request(actions.ActionNotification),
  record: Option(fn(String, String) -> String),
) -> Nil {
  process.send(
    store.subject,
    SendNotification(session_id, notification, record),
  )
}

pub fn send_stream_response(
  store: Store,
  session_id: String,
  stream_id: String,
  payload: String,
  record: Option(fn(String, String) -> String),
) -> Nil {
  process.send(
    store.subject,
    SendStreamResponse(session_id, stream_id, payload, record),
  )
}

pub fn send_recorded_event(
  store: Store,
  session_id: String,
  event_id: String,
  payload: String,
) -> Nil {
  let Store(subject) = store
  process.send(subject, SendRecorded(session_id, event_id, payload))
}

pub fn resolve_response(
  store: Store,
  session_id: String,
  body: String,
) -> Result(Nil, jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, ResolveResponse(session_id, body, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

fn loop(
  subject: process.Subject(Message),
  sessions: Dict(String, Session),
  metadata: Dict(String, SessionMetadata),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(CallerDown)
  case process.selector_receive_forever(selector) {
    GetMetadata(session_id, reply_to) -> {
      process.send(reply_to, case dict.get(metadata, session_id) {
        Ok(entry) -> Some(entry)
        Error(_) -> None
      })
      loop(subject, sessions, metadata)
    }
    SetMetadata(session_id, entry, reply_to) -> {
      process.send(reply_to, Nil)
      let next = case dict.has_key(sessions, session_id) {
        True -> dict.insert(metadata, session_id, entry)
        False -> metadata
      }
      loop(subject, sessions, next)
    }
    DeleteSession(session_id, reply_to) -> {
      case dict.get(sessions, session_id) {
        Ok(session) -> {
          session.listener
          |> list.each(fn(listener) {
            process.demonitor_process(listener.monitor)
            process.send(listener.subject, CloseListener)
          })
          session.pending_requests
          |> dict.values
          |> list.each(fn(pending) {
            release_pending(pending)
            process.send(
              pending.reply_to,
              Error(jsonrpc.invalid_params_error("MCP session closed")),
            )
          })
        }
        Error(_) -> Nil
      }
      process.send(reply_to, Nil)
      loop(
        subject,
        dict.delete(sessions, session_id),
        dict.delete(metadata, session_id),
      )
    }
    EnsureSession(session_id, reply_to) -> {
      let ensured = case session_id {
        Some(existing) -> existing
        None -> uuid.v4_string()
      }
      process.send(reply_to, ensured)
      loop(subject, ensure_session_entry(sessions, ensured), metadata)
    }
    HasSession(session_id, reply_to) -> {
      process.send(reply_to, case dict.get(sessions, session_id) {
        Ok(_) -> True
        Error(Nil) -> False
      })
      loop(subject, sessions, metadata)
    }
    RegisterListener(session_id, listener_id, listener, reply_to) -> {
      let next_sessions = case dict.has_key(sessions, session_id) {
        True -> attach_listener(sessions, session_id, listener_id, listener)
        False -> {
          process.send(listener, CloseListener)
          sessions
        }
      }
      process.send(reply_to, Nil)
      loop(subject, next_sessions, metadata)
    }
    UnregisterListener(session_id, listener_id, owner, reply_to) -> {
      let next_sessions =
        detach_listener_owned(sessions, session_id, listener_id, owner)
      process.send(reply_to, Nil)
      loop(subject, next_sessions, metadata)
    }
    SendRequest(session_id, request, reply_to, timeout_ms, record) -> {
      let next_sessions = case dict.has_key(sessions, session_id) {
        True ->
          enqueue_request(
            sessions,
            subject,
            session_id,
            request,
            reply_to,
            timeout_ms,
            record,
          )
        False -> {
          process.send(
            reply_to,
            Error(jsonrpc.invalid_params_error(
              "MCP session is closed or unknown",
            )),
          )
          sessions
        }
      }
      loop(subject, next_sessions, metadata)
    }
    SendNotification(session_id, notification, record) -> {
      let next_sessions =
        deliver_recorded_notification(
          sessions,
          session_id,
          notification,
          record,
        )
      loop(subject, next_sessions, metadata)
    }
    SendRecorded(session_id, event_id, payload) -> {
      let next =
        deliver_message(
          sessions,
          session_id,
          DeliverReplay(event_id, payload, False),
        )
      loop(subject, next, metadata)
    }
    SendStreamResponse(session_id, stream_id, payload, record) -> {
      let next =
        deliver_stream_response(
          sessions,
          session_id,
          stream_id,
          payload,
          record,
        )
      loop(subject, next, metadata)
    }
    ResolveResponse(session_id, body, reply_to) -> {
      let #(next_sessions, result) =
        resolve_pending_response(sessions, session_id, body)
      process.send(reply_to, result)
      loop(subject, next_sessions, metadata)
    }
    ExpireRequest(session_id, pending_id, reply_to) -> {
      let session = get_session(sessions, session_id)
      let next = case
        dict.get(session.pending_requests, request_id_key(pending_id))
      {
        Ok(pending) if pending.reply_to == reply_to ->
          expire_and_cancel(sessions, session_id, pending_id)
        _ -> sessions
      }
      loop(subject, next, metadata)
    }
    CallerDown(process.ProcessDown(_, caller, _)) -> {
      let sessions = remove_listener_owner(sessions, caller)
      let next =
        list.fold(dict.to_list(sessions), sessions, fn(current, entry) {
          list.fold(
            dict.values(entry.1.pending_requests),
            current,
            fn(current, pending) {
              case pending.caller == caller {
                True ->
                  expire_and_cancel(
                    current,
                    entry.0,
                    request_id(pending.request),
                  )
                False -> current
              }
            },
          )
        })
      loop(subject, next, metadata)
    }
    CallerDown(process.PortDown(..)) -> loop(subject, sessions, metadata)
  }
}

fn deliver_recorded_notification(
  sessions: Dict(String, Session),
  session_id: String,
  notification: jsonrpc.Request(actions.ActionNotification),
  record: Option(fn(String, String) -> String),
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Error(_) -> sessions
    Ok(session) -> {
      let listeners = live_listeners(session.listener)
      let chosen = list.first(listeners)
      let message = case record {
        None -> DeliverNotification(notification)
        Some(record) -> {
          let stream = case chosen {
            Ok(listener) -> listener.id
            Error(_) -> "notifications"
          }
          let payload = client_codec.encode_notification(notification)
          DeliverReplay(record(stream, payload), payload, False)
        }
      }
      case chosen {
        Ok(listener) -> process.send(listener.subject, message)
        Error(_) -> Nil
      }
      dict.insert(sessions, session_id, Session(..session, listener: listeners))
    }
  }
}

fn deliver_stream_response(
  sessions: Dict(String, Session),
  session_id: String,
  stream_id: String,
  payload: String,
  record: Option(fn(String, String) -> String),
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Error(_) -> sessions
    Ok(session) -> {
      let listeners = live_listeners(session.listener)
      let message = case record {
        Some(record) -> DeliverReplay(record(stream_id, payload), payload, True)
        None -> DeliverResponse(payload)
      }
      case list.find(listeners, fn(listener) { listener.id == stream_id }) {
        Ok(listener) -> process.send(listener.subject, message)
        Error(_) -> Nil
      }
      dict.insert(sessions, session_id, Session(..session, listener: listeners))
    }
  }
}

fn deliver_message(
  sessions: Dict(String, Session),
  session_id: String,
  message: ListenerMessage,
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Error(_) -> sessions
    Ok(session) -> {
      let listeners = live_listeners(session.listener)
      case list.first(listeners) {
        Ok(listener) -> process.send(listener.subject, message)
        Error(_) -> Nil
      }
      dict.insert(sessions, session_id, Session(..session, listener: listeners))
    }
  }
}

fn live_listeners(listeners: List(Listener)) -> List(Listener) {
  list.filter(listeners, fn(listener) {
    case process.is_alive(listener.owner) {
      True -> True
      False -> {
        process.demonitor_process(listener.monitor)
        False
      }
    }
  })
}

fn remove_listener_owner(
  sessions: Dict(String, Session),
  owner: process.Pid,
) -> Dict(String, Session) {
  dict.map_values(sessions, fn(_, session) {
    let listeners =
      list.filter(session.listener, fn(listener) {
        case listener.owner == owner {
          False -> True
          True -> {
            process.demonitor_process(listener.monitor)
            False
          }
        }
      })
    Session(..session, listener: listeners)
  })
}

fn ensure_session_entry(
  sessions: Dict(String, Session),
  session_id: String,
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Ok(_) -> sessions
    Error(Nil) -> dict.insert(sessions, session_id, Session([], dict.new(), []))
  }
}

fn attach_listener(
  sessions: Dict(String, Session),
  session_id: String,
  listener_id: String,
  listener: process.Subject(ListenerMessage),
) -> Dict(String, Session) {
  case process.subject_owner(listener) {
    Error(_) -> sessions
    Ok(owner) ->
      case process.is_alive(owner) {
        False -> sessions
        True -> {
          case dict.get(sessions, session_id) {
            Ok(session) ->
              session.listener
              |> list.filter(fn(old) { old.id == listener_id })
              |> list.each(fn(old) { process.send(old.subject, CloseListener) })
            Error(_) -> Nil
          }
          let sessions = detach_listener(sessions, session_id, listener_id)
          let Session(queued_requests, pending_requests, current_listener) =
            get_session(sessions, session_id)
          let listeners = live_listeners(current_listener)
          let monitor = process.monitor(owner)

          queued_requests
          |> list.each(fn(request) {
            let record = case
              dict.get(pending_requests, request_id_key(request_id(request)))
            {
              Ok(pending) -> pending.record
              Error(_) -> None
            }
            deliver_request(
              Listener(listener_id, listener, owner, monitor),
              request,
              record,
            )
          })

          dict.insert(
            sessions,
            session_id,
            Session([], pending_requests, [
              Listener(listener_id, listener, owner, monitor),
              ..listeners
            ]),
          )
        }
      }
  }
}

fn detach_listener(
  sessions: Dict(String, Session),
  session_id: String,
  listener_id: String,
) -> Dict(String, Session) {
  detach_listener_owned(sessions, session_id, listener_id, None)
}

fn detach_listener_owned(
  sessions: Dict(String, Session),
  session_id: String,
  listener_id: String,
  owner: Option(process.Pid),
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Ok(Session(queued_requests, pending_requests, current_listener)) -> {
      let next_listener =
        list.filter(current_listener, fn(listener) {
          let owned = case owner {
            None -> True
            Some(owner) -> listener.owner == owner
          }
          case listener.id == listener_id && owned {
            False -> True
            True -> {
              process.demonitor_process(listener.monitor)
              False
            }
          }
        })

      dict.insert(
        sessions,
        session_id,
        Session(queued_requests, pending_requests, next_listener),
      )
    }
    Error(Nil) -> sessions
  }
}

fn enqueue_request(
  sessions: Dict(String, Session),
  subject: process.Subject(Message),
  session_id: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  reply_to: process.Subject(
    Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
  ),
  timeout_ms: Int,
  record: Option(fn(String, String) -> String),
) -> Dict(String, Session) {
  let session = get_session(sessions, session_id)
  let Session(queued_requests, pending_requests, current_listener) = session
  let listener = live_listeners(current_listener)

  case dict.has_key(pending_requests, request_id_key(request_id(request))) {
    True -> {
      process.send(
        reply_to,
        Error(jsonrpc.RpcError(
          -32_600,
          "Duplicate active server request id",
          None,
        )),
      )
      sessions
    }
    False -> {
      let assert Ok(caller) = process.subject_owner(reply_to)
      let monitor = process.monitor(caller)
      let timeout = case timeout_ms < 1 {
        True -> 1
        False -> timeout_ms
      }
      let timer =
        process.send_after(
          subject,
          timeout,
          ExpireRequest(session_id, request_id(request), reply_to),
        )
      case list.first(listener) {
        Ok(listener) -> deliver_request(listener, request, record)
        Error(_) -> Nil
      }

      let next_queue = case list.first(listener) {
        Ok(_) -> queued_requests
        Error(_) -> list.append(queued_requests, [request])
      }

      let next_session =
        Session(
          next_queue,
          dict.insert(
            pending_requests,
            request_id_key(request_id(request)),
            PendingRequest(request, reply_to, caller, monitor, timer, record),
          ),
          listener,
        )

      dict.insert(sessions, session_id, next_session)
    }
  }
}

fn deliver_request(
  listener: Listener,
  request: jsonrpc.Request(actions.ServerActionRequest),
  record: Option(fn(String, String) -> String),
) -> Nil {
  let message = case record {
    None -> DeliverRequest(request)
    Some(record) -> {
      let payload = client_codec.encode_server_request(request)
      DeliverReplay(record(listener.id, payload), payload, False)
    }
  }
  process.send(listener.subject, message)
}

fn resolve_pending_response(
  sessions: Dict(String, Session),
  session_id: String,
  body: String,
) -> #(Dict(String, Session), Result(Nil, jsonrpc.RpcError)) {
  case extract_response_id(body) {
    Error(error) -> #(sessions, Error(error))
    Ok(response_id) -> {
      let response_key = request_id_key(response_id)

      case dict.get(sessions, session_id) {
        Ok(Session(queued_requests, pending_requests, listener)) ->
          case dict.get(pending_requests, response_key) {
            Ok(pending) -> {
              let request = pending.request
              let waiting_reply = pending.reply_to
              release_pending(pending)
              case client_codec.decode_server_response(body, request) {
                Ok(response) -> {
                  process.send(waiting_reply, Ok(response))
                  #(
                    dict.insert(
                      sessions,
                      session_id,
                      Session(
                        queued_requests,
                        dict.delete(pending_requests, response_key),
                        listener,
                      ),
                    ),
                    Ok(Nil),
                  )
                }
                Error(message) -> {
                  let error = jsonrpc.invalid_params_error(message)
                  process.send(waiting_reply, Error(error))
                  #(
                    dict.insert(
                      sessions,
                      session_id,
                      Session(
                        queued_requests,
                        dict.delete(pending_requests, response_key),
                        listener,
                      ),
                    ),
                    Error(error),
                  )
                }
              }
            }
            Error(Nil) -> #(
              sessions,
              Error(jsonrpc.invalid_params_error(
                "Unknown server-sent request response id",
              )),
            )
          }
        Error(Nil) -> #(
          sessions,
          Error(jsonrpc.invalid_params_error(
            "Unknown session for server-sent request response",
          )),
        )
      }
    }
  }
}

fn release_pending(pending: PendingRequest) -> Nil {
  let _ = process.cancel_timer(pending.timer)
  process.demonitor_process(pending.monitor)
}

fn expire_and_cancel(
  sessions: Dict(String, Session),
  session_id: String,
  pending_id: jsonrpc.RequestId,
) -> Dict(String, Session) {
  let session = get_session(sessions, session_id)
  case dict.get(session.pending_requests, request_id_key(pending_id)) {
    Error(_) -> sessions
    Ok(pending) -> {
      release_pending(pending)
      process.send(
        pending.reply_to,
        Error(jsonrpc.invalid_params_error(
          "Server-sent request timed out or its caller stopped",
        )),
      )
      let next =
        dict.insert(
          sessions,
          session_id,
          Session(
            drop_request(session.queued_requests, pending_id),
            dict.delete(session.pending_requests, request_id_key(pending_id)),
            session.listener,
          ),
        )
      deliver_recorded_notification(
        next,
        session_id,
        jsonrpc.Notification(
          mcp.method_notify_cancelled,
          Some(
            actions.NotifyCancelled(actions.CancelledNotificationParams(
              Some(pending_id),
              Some("Request caller stopped or timed out"),
              related_notification_meta(pending.request),
            )),
          ),
        ),
        pending.record,
      )
    }
  }
}

fn related_notification_meta(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> Option(actions.NotificationMeta) {
  let meta = case request {
    jsonrpc.Request(_, _, Some(actions.ServerRequestPing(meta)))
    | jsonrpc.Request(_, _, Some(actions.ServerRequestListRoots(meta))) -> meta
    jsonrpc.Request(_, _, Some(actions.ServerRequestCreateMessage(params))) ->
      params.meta
    jsonrpc.Request(
      _,
      _,
      Some(actions.ServerRequestElicit(actions.ElicitRequestForm(params))),
    ) -> params.meta
    jsonrpc.Request(
      _,
      _,
      Some(actions.ServerRequestElicit(actions.ElicitRequestUrl(params))),
    ) -> actions.elicit_url_meta(params)
    jsonrpc.Request(_, _, Some(actions.ServerRequestListTasks(params))) ->
      params.meta
    _ -> None
  }
  use meta <- option.then(meta)
  use extra <- option.then(meta.extra)
  case dict.get(extra.fields, "io.modelcontextprotocol/related-task") {
    Ok(related) ->
      Some(
        actions.NotificationMeta(
          Some(
            actions.Meta(
              dict.from_list([
                #("io.modelcontextprotocol/related-task", related),
              ]),
            ),
          ),
        ),
      )
    Error(_) -> None
  }
}

fn drop_request(
  requests: List(jsonrpc.Request(actions.ServerActionRequest)),
  pending_id: jsonrpc.RequestId,
) -> List(jsonrpc.Request(actions.ServerActionRequest)) {
  case requests {
    [] -> []
    [request, ..rest] ->
      case request_id(request) == pending_id {
        True -> rest
        False -> [request, ..drop_request(rest, pending_id)]
      }
  }
}

fn extract_response_id(
  body: String,
) -> Result(jsonrpc.RequestId, jsonrpc.RpcError) {
  json.parse(body, response_id_decoder())
  |> result.map_error(fn(_error) {
    jsonrpc.invalid_params_error(
      "Server-sent request response was missing a valid JSON-RPC id",
    )
  })
}

fn request_id_decoder() -> decode.Decoder(jsonrpc.RequestId) {
  decode.one_of(decode.map(decode.string, jsonrpc.StringId), or: [
    decode.map(decode.int, jsonrpc.IntId),
  ])
}

fn response_id_decoder() -> decode.Decoder(jsonrpc.RequestId) {
  decode.then(decode.at(["id"], request_id_decoder()), fn(id) {
    decode.success(id)
  })
}

fn get_session(sessions: Dict(String, Session), session_id: String) -> Session {
  case dict.get(sessions, session_id) {
    Ok(session) -> session
    Error(Nil) -> Session([], dict.new(), [])
  }
}

fn request_id(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> jsonrpc.RequestId {
  case request {
    jsonrpc.Request(id, _, _) -> id
    jsonrpc.Notification(_, _) ->
      panic as "Server-sent requests must be JSON-RPC requests"
  }
}

fn request_id_key(id: jsonrpc.RequestId) -> String {
  case id {
    jsonrpc.IntId(value) -> "int:" <> int.to_string(value)
    jsonrpc.StringId(value) -> "string:" <> value
  }
}

fn expect_ok(value: Result(a, Nil)) -> a {
  case value {
    Ok(inner) -> inner
    Error(Nil) -> panic as "Timed out waiting for streamable HTTP store"
  }
}
