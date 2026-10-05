import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/streamable_http_store
import gleam_mcp/wire
import stdin
import youid/uuid

type Message {
  InputLine(String)
  InputClosed
  RequestFinished(String, String, jsonrpc.Response(actions.ClientActionResult))
  DrainDeadline
}

type Event {
  Input(Message)
  Outgoing(streamable_http_store.ListenerMessage)
}

type State {
  State(
    app_server: server.Server,
    context: server.RequestContext,
    session_id: String,
    listener_id: String,
    workers: dict.Dict(String, process.Pid),
    outgoing_requests: List(jsonrpc.Request(actions.ServerActionRequest)),
    input_closed: Bool,
    write: fn(String) -> Nil,
    outgoing: process.Subject(streamable_http_store.ListenerMessage),
  )
}

pub fn serve(server: server.Server) {
  serve_with_lines(server, stdin.read_lines())
}

pub fn serve_with_lines(server: server.Server, lines: yielder.Yielder(String)) {
  serve_with_writer(server, lines, io.println)
}

/// Run the same bidirectional transport with a supplied newline-message sink.
/// Useful for embedding the transport and for inspecting actual wire messages.
pub fn serve_with_writer(
  app_server: server.Server,
  lines: yielder.Yielder(String),
  write: fn(String) -> Nil,
) -> Nil {
  let input = process.new_subject()
  let outgoing = process.new_subject()
  let session_id = server.ensure_streamable_http_session(app_server, None)
  let _ = server.bind_session(app_server, session_id, None)
  let listener_id = server.new_streamable_http_listener_id()
  server.register_streamable_http_listener(
    app_server,
    session_id,
    listener_id,
    outgoing,
  )
  let reader =
    process.spawn_unlinked(fn() {
      yielder.each(lines, fn(line) { process.send(input, InputLine(line)) })
      process.send(input, InputClosed)
    })
  let selector =
    process.new_selector()
    |> process.select_map(input, Input)
    |> process.select_map(outgoing, Outgoing)
  let state =
    State(
      app_server,
      server.RequestContext(Some(session_id), None),
      session_id,
      listener_id,
      dict.new(),
      [],
      False,
      write,
      outgoing,
    )
  loop(state, input, selector)
  process.kill(reader)
}

fn loop(
  state: State,
  input: process.Subject(Message),
  selector: process.Selector(Event),
) -> Nil {
  case state.input_closed && dict.size(state.workers) == 0 {
    True -> finish(state, selector)
    False -> {
      let next = case process.selector_receive_forever(selector) {
        Input(InputLine(line)) -> handle_line(state, input, line)
        Input(InputClosed) -> {
          // No further client responses can arrive. Resolve outstanding
          // callbacks so their originating handlers can finish normally.
          list.each(state.outgoing_requests, fn(request) {
            reject_outgoing(state, request)
          })
          let _ = process.send_after(input, 5000, DrainDeadline)
          State(..state, input_closed: True, outgoing_requests: [])
        }
        Input(RequestFinished(worker_id, version, response)) -> {
          state.write(wire.encode_response(
            response,
            version,
            server.implementation(state.app_server),
          ))
          State(..state, workers: dict.delete(state.workers, worker_id))
        }
        Input(DrainDeadline) -> {
          list.each(dict.values(state.workers), process.kill)
          State(..state, workers: dict.new())
        }
        Outgoing(message) -> handle_outgoing(state, message)
      }
      loop(next, input, selector)
    }
  }
}

fn handle_line(
  state: State,
  input: process.Subject(Message),
  line: String,
) -> State {
  case codec_common.is_response(line) {
    True -> {
      let _ =
        server.handle_server_sent_response(
          state.app_server,
          state.context,
          line,
        )
      let remaining =
        list.filter(state.outgoing_requests, fn(request) {
          case client_codec.decode_server_response(line, request) {
            Ok(_) -> False
            Error(_) -> True
          }
        })
      State(..state, outgoing_requests: remaining)
    }
    False ->
      case
        case wire.claims_modern(line) {
          True ->
            wire.decode_message_with_error(
              line,
              jsonrpc.latest_protocol_version,
            )
          False -> codec.decode_message_with_error(line)
        }
      {
        Ok(codec.ClientActionRequest(request)) ->
          case request {
            jsonrpc.Request(
              id,
              _,
              Some(actions.ClientRequestSubscriptionsListen(params)),
            ) -> {
              let context =
                server.modern_request_context(
                  None,
                  state.session_id,
                  Some(state.outgoing),
                )
                |> server.request_context(id, params.meta)
              case
                server.listen_subscription(state.app_server, context, params)
              {
                Ok(_) -> Nil
                Error(error) ->
                  state.write(wire.encode_response(
                    jsonrpc.ErrorResponse(Some(id), error),
                    jsonrpc.latest_protocol_version,
                    server.implementation(state.app_server),
                  ))
              }
              state
            }
            jsonrpc.Request(_, method, _) if method == mcp.method_initialize -> {
              // Establish negotiated state before reading the client's
              // initialized notification; normal handlers run concurrently.
              let #(_, response) =
                server.handle_request_with_context(
                  state.app_server,
                  state.context,
                  request,
                )
              state.write(codec.encode_response(response))
              state
            }
            _ -> {
              let modern =
                wire.claims_modern(line)
                || case request {
                  jsonrpc.Request(_, _, Some(action)) ->
                    server.is_modern_action(action)
                  _ -> False
                }
              let context = case modern {
                True ->
                  server.modern_request_context(
                    None,
                    state.session_id,
                    Some(state.outgoing),
                  )
                False -> state.context
              }
              let version = case server.is_modern_context(context) {
                True -> jsonrpc.latest_protocol_version
                False -> jsonrpc.legacy_protocol_version
              }
              let worker_id = uuid.v4_string()
              let registered = process.new_subject()
              let worker =
                process.spawn_unlinked(fn() {
                  let reply = process.new_subject()
                  process.send(registered, reply)
                  let result = process.receive_forever(reply)
                  let assert jsonrpc.Request(id, _, _) = request
                  let response = case result {
                    Ok(result) -> jsonrpc.ResultResponse(id, result)
                    Error(error) -> jsonrpc.ErrorResponse(Some(id), error)
                  }
                  process.send(
                    input,
                    RequestFinished(worker_id, version, response),
                  )
                })
              let reply = process.receive_forever(registered)
              server.start_request_with_context(
                state.app_server,
                context,
                request,
                reply,
              )
              State(
                ..state,
                workers: dict.insert(state.workers, worker_id, worker),
              )
            }
          }
        Ok(codec.ActionNotification(notification)) -> {
          let _ =
            server.handle_notification_with_context(
              state.app_server,
              state.context,
              notification,
            )
          state
        }
        Ok(codec.UnknownRequest(id, method)) -> {
          state.write(
            codec.encode_response(jsonrpc.ErrorResponse(
              Some(id),
              jsonrpc.method_not_found_error(method),
            )),
          )
          state
        }
        Ok(codec.UnknownNotification(_)) -> state
        Error(error) -> {
          case codec_common.is_notification(line) {
            True -> Nil
            False ->
              state.write(wire.encode_response(
                jsonrpc.ErrorResponse(error.id, error.error),
                case wire.claims_modern(line) {
                  True -> jsonrpc.latest_protocol_version
                  False -> jsonrpc.legacy_protocol_version
                },
                server.implementation(state.app_server),
              ))
          }
          state
        }
      }
  }
}

fn handle_outgoing(
  state: State,
  message: streamable_http_store.ListenerMessage,
) -> State {
  case message {
    streamable_http_store.DeliverRequest(request) ->
      case state.input_closed {
        True -> {
          reject_outgoing(state, request)
          state
        }
        False -> {
          state.write(client_codec.encode_server_request(request))
          State(..state, outgoing_requests: [request, ..state.outgoing_requests])
        }
      }
    streamable_http_store.DeliverNotification(notification) -> {
      state.write(client_codec.encode_notification(notification))
      state
    }
    streamable_http_store.DeliverResponse(payload) -> {
      state.write(payload)
      state
    }
    streamable_http_store.DeliverReplay(_, payload, _) -> {
      state.write(payload)
      state
    }
    streamable_http_store.CloseListener -> state
  }
}

fn reject_outgoing(
  state: State,
  request: jsonrpc.Request(actions.ServerActionRequest),
) {
  case request {
    jsonrpc.Request(id, _, _) -> {
      let payload =
        codec.encode_server_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.RpcError(-32_603, "Client input closed", None),
        ))
      let _ =
        server.handle_server_sent_response(
          state.app_server,
          state.context,
          payload,
        )
      Nil
    }
    _ -> Nil
  }
}

fn finish(state: State, selector: process.Selector(Event)) -> Nil {
  // The store call forms a barrier for queued outgoing messages; flush those
  // before closing the session and its pending server-originated requests.
  server.unregister_streamable_http_listener(
    state.app_server,
    state.session_id,
    state.listener_id,
  )
  flush_output(state, selector)
  server.close_session(state.app_server, state.session_id)
}

fn flush_output(state: State, selector: process.Selector(Event)) -> Nil {
  case process.selector_receive(selector, 0) {
    Ok(Outgoing(message)) -> {
      let next = handle_outgoing(state, message)
      flush_output(next, selector)
    }
    Ok(_) -> flush_output(state, selector)
    Error(_) -> Nil
  }
}
