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
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

pub type ListenerMessage {
  DeliverRequest(jsonrpc.Request(actions.ServerActionRequest))
  CloseListener
}

type Message {
  EnsureSession(session_id: Option(String), reply_to: process.Subject(String))
  RegisterListener(
    session_id: String,
    listener_id: String,
    listener: process.Subject(ListenerMessage),
    reply_to: process.Subject(Nil),
  )
  UnregisterListener(
    session_id: String,
    listener_id: String,
    reply_to: process.Subject(Nil),
  )
  SendRequest(
    session_id: String,
    request: jsonrpc.Request(actions.ServerActionRequest),
    reply_to: process.Subject(
      Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
    ),
  )
  ResolveResponse(
    session_id: String,
    body: String,
    reply_to: process.Subject(Result(Nil, jsonrpc.RpcError)),
  )
  ExpireRequest(session_id: String, request_id: jsonrpc.RequestId)
}

type Session {
  Session(
    queued_requests: List(jsonrpc.Request(actions.ServerActionRequest)),
    pending_requests: Dict(String, PendingRequest),
    listener: Option(Listener),
  )
}

type Listener {
  Listener(id: String, subject: process.Subject(ListenerMessage))
}

type PendingRequest {
  PendingRequest(
    request: jsonrpc.Request(actions.ServerActionRequest),
    reply_to: process.Subject(
      Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
    ),
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
  loop(subject, dict.new())
}

pub fn ensure_session(store: Store, session_id: Option(String)) -> String {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, EnsureSession(session_id, reply_to))
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
  process.send(subject, UnregisterListener(session_id, listener_id, reply_to))
  expect_ok(process.receive(reply_to, 1000))
}

pub fn send_request(
  store: Store,
  session_id: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  timeout_ms: Int,
) -> Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError) {
  let Store(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, SendRequest(session_id, request, reply_to))

  case process.receive(reply_to, timeout_ms) {
    Ok(response) -> response
    Error(Nil) -> {
      process.send(subject, ExpireRequest(session_id, request_id(request)))
      Error(jsonrpc.invalid_params_error(
        "Timed out waiting for a client response to server-sent request",
      ))
    }
  }
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
) -> Nil {
  case process.receive_forever(subject) {
    EnsureSession(session_id, reply_to) -> {
      let ensured = case session_id {
        Some(existing) -> existing
        None -> uuid.v4_string()
      }
      process.send(reply_to, ensured)
      loop(subject, ensure_session_entry(sessions, ensured))
    }
    RegisterListener(session_id, listener_id, listener, reply_to) -> {
      let next_sessions =
        sessions
        |> ensure_session_entry(session_id)
        |> attach_listener(session_id, listener_id, listener)
      process.send(reply_to, Nil)
      loop(subject, next_sessions)
    }
    UnregisterListener(session_id, listener_id, reply_to) -> {
      let next_sessions = detach_listener(sessions, session_id, listener_id)
      process.send(reply_to, Nil)
      loop(subject, next_sessions)
    }
    SendRequest(session_id, request, reply_to) -> {
      let next_sessions =
        sessions
        |> ensure_session_entry(session_id)
        |> enqueue_request(session_id, request, reply_to)
      loop(subject, next_sessions)
    }
    ResolveResponse(session_id, body, reply_to) -> {
      let #(next_sessions, result) =
        resolve_pending_response(sessions, session_id, body)
      process.send(reply_to, result)
      loop(subject, next_sessions)
    }
    ExpireRequest(session_id, pending_id) -> {
      loop(subject, expire_request(sessions, session_id, pending_id))
    }
  }
}

fn ensure_session_entry(
  sessions: Dict(String, Session),
  session_id: String,
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Ok(_) -> sessions
    Error(Nil) ->
      dict.insert(sessions, session_id, Session([], dict.new(), None))
  }
}

fn attach_listener(
  sessions: Dict(String, Session),
  session_id: String,
  listener_id: String,
  listener: process.Subject(ListenerMessage),
) -> Dict(String, Session) {
  let Session(queued_requests, pending_requests, current_listener) =
    get_session(sessions, session_id)

  case current_listener {
    Some(Listener(subject: current_subject, ..)) ->
      process.send(current_subject, CloseListener)
    None -> Nil
  }

  queued_requests
  |> list.each(fn(request) { process.send(listener, DeliverRequest(request)) })

  dict.insert(
    sessions,
    session_id,
    Session([], pending_requests, Some(Listener(listener_id, listener))),
  )
}

fn detach_listener(
  sessions: Dict(String, Session),
  session_id: String,
  listener_id: String,
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Ok(Session(queued_requests, pending_requests, current_listener)) -> {
      let next_listener = case current_listener {
        Some(Listener(id:, ..)) if id == listener_id -> None
        _ -> current_listener
      }

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
  session_id: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
  reply_to: process.Subject(
    Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError),
  ),
) -> Dict(String, Session) {
  let session = get_session(sessions, session_id)
  let Session(queued_requests, pending_requests, listener) = session

  case listener {
    Some(Listener(subject: listener_subject, ..)) ->
      process.send(listener_subject, DeliverRequest(request))
    None -> Nil
  }

  let next_queue = case listener {
    Some(_) -> queued_requests
    None -> list.append(queued_requests, [request])
  }

  let next_session =
    Session(
      next_queue,
      dict.insert(
        pending_requests,
        request_id_key(request_id(request)),
        PendingRequest(request, reply_to),
      ),
      listener,
    )

  dict.insert(sessions, session_id, next_session)
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
            Ok(PendingRequest(request, waiting_reply)) ->
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

fn expire_request(
  sessions: Dict(String, Session),
  session_id: String,
  pending_id: jsonrpc.RequestId,
) -> Dict(String, Session) {
  case dict.get(sessions, session_id) {
    Ok(Session(queued_requests, pending_requests, listener)) ->
      dict.insert(
        sessions,
        session_id,
        Session(
          drop_request(queued_requests, pending_id),
          dict.delete(pending_requests, request_id_key(pending_id)),
          listener,
        ),
      )
    Error(Nil) -> sessions
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
    Error(Nil) -> Session([], dict.new(), None)
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
