/// The reference example's deprecated HTTP+SSE transport. JSON-RPC results,
/// server requests, and notifications all share one persistent SSE connection.
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/uri
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import gleam_mcp/wire
import glisten/socket/options
import glisten/transport
import mist

const maximum_body_bytes = 4_194_304

pub opaque type Store {
  Store(app: server.Server, subject: process.Subject(StoreMessage))
}

type Listener {
  Listener(
    listener_id: String,
    subject: process.Subject(streamable_http_store.ListenerMessage),
    owner: process.Pid,
    monitor: process.Monitor,
  )
}

type StoreMessage {
  Attach(
    String,
    String,
    process.Subject(streamable_http_store.ListenerMessage),
    process.Subject(Nil),
  )
  Find(String, process.Subject(Option(Listener)))
  Remove(String, process.Subject(Nil))
  ListenerDown(process.Down)
  Stop
}

type SseState {
  SseState(
    store: Store,
    session_id: String,
    endpoint_sent: Bool,
    selector: process.Selector(streamable_http_store.ListenerMessage),
  )
}

pub fn handler(
  app: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_store(new(app))
}

pub fn handler_with_store(
  store: Store,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req: request.Request(mist.Connection)) {
    case req.method, req.path {
      http.Get, "/sse" ->
        case query_session(req) {
          Ok(None) ->
            mist.server_sent_events(
              request: req,
              initial_response: response.new(200)
                |> response.set_header(
                  "cache-control",
                  "no-cache, no-transform",
                ),
              init: fn(listener) {
                let session_id = attach(store, listener)
                // Mist selects only subject messages. Select socket closure as
                // well so an idle disconnect releases the session immediately.
                let selector =
                  process.new_selector()
                  |> process.select(listener)
                  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) {
                    streamable_http_store.CloseListener
                  })
                  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) {
                    streamable_http_store.CloseListener
                  })
                  |> process.select_record(atom.create("tcp_error"), 2, fn(_) {
                    streamable_http_store.CloseListener
                  })
                  |> process.select_record(atom.create("ssl_error"), 2, fn(_) {
                    streamable_http_store.CloseListener
                  })
                case
                  transport.set_opts(req.body.transport, req.body.socket, [
                    options.ActiveMode(options.Once),
                  ])
                {
                  Ok(_) -> Nil
                  Error(_) ->
                    process.send(listener, streamable_http_store.CloseListener)
                }
                SseState(store, session_id, False, selector)
              },
              loop: handle_sse_message,
            )
          _ -> plain_response(400, "GET /sse requires a new session")
        }
      http.Post, "/message" -> handle_post(store, req)
      _, "/sse" | _, "/message" -> plain_response(405, "Method Not Allowed")
      _, _ -> plain_response(404, "Not Found")
    }
  }
}

pub fn new(app: server.Server) -> Store {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      Ok(
        actor.initialised(dict.new())
        |> actor.returning(subject)
        |> actor.selecting(
          process.new_selector()
          |> process.select(subject)
          |> process.select_monitors(ListenerDown),
        ),
      )
    })
    |> actor.on_message(fn(state, message) {
      case message {
        Attach(id, listener_id, subject, reply) -> {
          let assert Ok(owner) = process.subject_owner(subject)
          let listener =
            Listener(listener_id, subject, owner, process.monitor(owner))
          process.send(reply, Nil)
          actor.continue(dict.insert(state, id, listener))
        }
        Find(id, reply) -> {
          let listener = dict.get(state, id) |> option_from_result
          case
            listener
            |> option.map(fn(value) {
              process.is_alive(value.owner)
              && server.has_streamable_http_session(app, id)
            })
          {
            Some(True) -> {
              process.send(reply, listener)
              actor.continue(state)
            }
            _ -> {
              let state = remove_listener(app, state, id)
              process.send(reply, None)
              actor.continue(state)
            }
          }
        }
        Remove(id, reply) -> {
          let state = remove_listener(app, state, id)
          process.send(reply, Nil)
          actor.continue(state)
        }
        ListenerDown(process.ProcessDown(_, pid, _)) ->
          state
          |> dict.fold(state, fn(next, id, listener) {
            case listener.owner == pid {
              True -> remove_listener(app, next, id)
              False -> next
            }
          })
          |> actor.continue
        ListenerDown(process.PortDown(..)) -> actor.continue(state)
        Stop -> {
          dict.each(state, fn(id, listener) {
            process.demonitor_process(listener.monitor)
            server.close_session(app, id)
          })
          actor.stop()
        }
      }
    })
    |> actor.start
  Store(app, started.data)
}

/// The listener's owning process is monitored independently of Mist's loop;
/// disconnect cleanup also runs when Mist terminates that process directly.
pub fn attach(
  store: Store,
  subject: process.Subject(streamable_http_store.ListenerMessage),
) -> String {
  let id = server.ensure_streamable_http_session(store.app, None)
  let assert True = server.bind_session(store.app, id, None)
  let listener_id = server.new_streamable_http_listener_id()
  let registered = process.new_subject()
  process.send(store.subject, Attach(id, listener_id, subject, registered))
  let assert Ok(Nil) = process.receive(registered, 1000)
  process.send(subject, streamable_http_store.DeliverResponse(""))
  server.register_streamable_http_listener(store.app, id, listener_id, subject)
  id
}

pub fn close_session(store: Store, id: String) -> Nil {
  actor.call(store.subject, 1000, fn(reply) { Remove(id, reply) })
}

pub fn stop(store: Store) -> Nil {
  process.send(store.subject, Stop)
}

pub fn endpoint(session_id: String) -> String {
  "/message?sessionId=" <> uri.percent_encode(session_id)
}

/// Handle a decoded HTTP body without a socket. Accepted requests are
/// registered before this function returns so a following cancellation cannot
/// race request registration. Their results are delivered asynchronously.
pub fn receive_message(
  store: Store,
  session_id: String,
  body: String,
) -> Result(Nil, #(Int, String)) {
  use listener <- result.try(
    case
      actor.call(store.subject, 1000, fn(reply) { Find(session_id, reply) })
    {
      Some(listener) -> Ok(listener)
      None -> Error(#(404, "Unknown SSE session"))
    },
  )
  let context = server.RequestContext(Some(session_id), None)
  case wire.claims_modern(body) {
    True -> Error(#(400, "Deprecated SSE transport requires legacy MCP"))
    False ->
      case codec_common.is_response(body) {
        True ->
          server.handle_server_sent_response(store.app, context, body)
          |> result.map_error(fn(error) { #(400, error.message) })
        False ->
          case codec.decode_message_with_error(body) {
            Error(error) ->
              case error.error.code == -32_602 {
                True -> {
                  case error.id {
                    Some(_) ->
                      deliver_response(
                        listener.subject,
                        jsonrpc.ErrorResponse(error.id, error.error),
                      )
                    None -> Nil
                  }
                  Ok(Nil)
                }
                False -> Error(#(400, error.error.message))
              }
            Ok(codec.ClientActionRequest(request)) ->
              case request {
                jsonrpc.Request(id, _, Some(action)) ->
                  case server.is_modern_action(action) {
                    True ->
                      Error(#(
                        400,
                        "Deprecated SSE transport requires legacy MCP",
                      ))
                    False -> {
                      start_request(
                        store.app,
                        context,
                        request,
                        id,
                        listener.subject,
                      )
                      Ok(Nil)
                    }
                  }
                _ -> Error(#(400, "Expected JSON-RPC request"))
              }
            Ok(codec.ActionNotification(notification)) ->
              server.handle_notification_with_context(
                store.app,
                context,
                notification,
              )
              |> result.map_error(fn(error) { #(400, error.message) })
            Ok(codec.UnknownRequest(id, method)) -> {
              deliver_response(
                listener.subject,
                jsonrpc.ErrorResponse(
                  Some(id),
                  jsonrpc.method_not_found_error(method),
                ),
              )
              Ok(Nil)
            }
            Ok(codec.UnknownNotification(_)) -> Ok(Nil)
          }
      }
  }
}

fn start_request(
  app: server.Server,
  context: server.RequestContext,
  request: jsonrpc.Request(actions.ClientActionRequest),
  id: jsonrpc.RequestId,
  listener: process.Subject(streamable_http_store.ListenerMessage),
) -> Nil {
  let registered = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      server.start_request_with_context(app, context, request, reply)
      process.send(registered, Nil)
      let response = case process.receive_forever(reply) {
        Ok(value) -> jsonrpc.ResultResponse(id, value)
        Error(error) -> jsonrpc.ErrorResponse(Some(id), error)
      }
      process.send(
        listener,
        streamable_http_store.DeliverResponse(codec.encode_response(response)),
      )
    })
  let assert Ok(Nil) = process.receive(registered, 1000)
  Nil
}

fn handle_post(
  store: Store,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case query_session(req) {
    Ok(Some(id)) ->
      case has_json_content_type(req) {
        True ->
          case mist.read_body(req, maximum_body_bytes) {
            Ok(body_request) ->
              case bit_array.to_string(body_request.body) {
                Ok(body) ->
                  case receive_message(store, id, body) {
                    Ok(Nil) -> plain_response(202, "Accepted")
                    Error(error) -> plain_response(error.0, error.1)
                  }
                Error(_) -> plain_response(400, "Request body must be UTF-8")
              }
            Error(_) -> plain_response(400, "Unable to read request body")
          }
        False -> plain_response(400, "Expected application/json request body")
      }
    _ -> plain_response(400, "Missing SSE session id")
  }
}

fn query_session(req: request.Request(body)) -> Result(Option(String), Nil) {
  use query <- result.try(request.get_query(req))
  Ok(dict.get(dict.from_list(query), "sessionId") |> option_from_result)
}

fn has_json_content_type(req: request.Request(body)) -> Bool {
  case request.get_header(req, "content-type") {
    Ok(value) ->
      value
      |> string.lowercase
      |> string.split(";")
      |> list.first
      |> result.map(string.trim)
      == Ok("application/json")
    Error(_) -> False
  }
}

fn handle_sse_message(
  state: SseState,
  message: streamable_http_store.ListenerMessage,
  connection: mist.SSEConnection,
) -> actor.Next(SseState, streamable_http_store.ListenerMessage) {
  let sent_endpoint = case state.endpoint_sent {
    True -> Ok(Nil)
    False ->
      mist.send_event(
        connection,
        mist.event(string_tree.from_string(endpoint(state.session_id)))
          |> mist.event_name("endpoint"),
      )
  }
  let state = SseState(..state, endpoint_sent: True)
  let outcome = case sent_endpoint {
    Error(_) -> Error(Nil)
    Ok(_) ->
      case message {
        streamable_http_store.DeliverRequest(request) ->
          send_message(connection, client_codec.encode_server_request(request))
        streamable_http_store.DeliverNotification(notification) ->
          send_message(
            connection,
            client_codec.encode_notification(notification),
          )
        streamable_http_store.DeliverResponse("") -> Ok(Nil)
        streamable_http_store.DeliverResponse(body) ->
          send_message(connection, body)
        streamable_http_store.DeliverReplay(id, body, close) -> {
          let result =
            mist.send_event(
              connection,
              mist.event(string_tree.from_string(body))
                |> mist.event_name("message")
                |> mist.event_id(id),
            )
          case close {
            True -> Error(Nil)
            False -> result
          }
        }
        streamable_http_store.CloseListener -> Error(Nil)
      }
  }
  case outcome {
    Ok(Nil) -> actor.continue(state) |> actor.with_selector(state.selector)
    Error(Nil) -> {
      close_session(state.store, state.session_id)
      actor.stop()
    }
  }
}

fn send_message(
  connection: mist.SSEConnection,
  body: String,
) -> Result(Nil, Nil) {
  mist.send_event(
    connection,
    mist.event(string_tree.from_string(body)) |> mist.event_name("message"),
  )
}

fn remove_listener(
  app: server.Server,
  state: dict.Dict(String, Listener),
  id: String,
) -> dict.Dict(String, Listener) {
  case dict.get(state, id) {
    Ok(listener) -> {
      process.demonitor_process(listener.monitor)
      server.close_session(app, id)
      server.unregister_streamable_http_listener(app, id, listener.listener_id)
      dict.delete(state, id)
    }
    Error(_) -> state
  }
}

fn deliver_response(
  subject: process.Subject(streamable_http_store.ListenerMessage),
  response: jsonrpc.Response(actions.ClientActionResult),
) -> Nil {
  process.send(
    subject,
    streamable_http_store.DeliverResponse(codec.encode_response(response)),
  )
}

fn plain_response(
  status: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn option_from_result(value: Result(a, b)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
