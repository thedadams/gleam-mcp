import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
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
import gleam_mcp/http_headers
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/codec
import gleam_mcp/server/oauth
import gleam_mcp/server/streamable_http_store
import gleam_mcp/wire
import glisten/socket/options
import glisten/transport as socket_transport
import mist
import youid/uuid

// 1 MiB
const default_max_body_bytes = 1_048_576

pub type ClientActionMiddleware =
  fn(
    server.Server,
    server.RequestContext,
    String,
    jsonrpc.Request(actions.ClientActionRequest),
  ) -> MiddlewareDecision

pub type MiddlewareDecision {
  Continue
  RespondRpc(jsonrpc.Response(actions.ClientActionResult))
  RespondAccepted
  RespondPlain(status: Int, body: String)
}

pub fn handler(
  server: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body(server, default_max_body_bytes)
}

pub fn handler_with_middleware(
  server: server.Server,
  middleware: ClientActionMiddleware,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body_and_middleware(
    server,
    default_max_body_bytes,
    middleware,
  )
}

pub fn handler_with_max_body(
  server: server.Server,
  max_body_bytes: Int,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  handler_with_max_body_and_middleware(server, max_body_bytes, fn(_, _, _, _) {
    Continue
  })
}

pub fn handler_with_max_body_and_middleware(
  server: server.Server,
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) { handle(server, req, max_body_bytes, middleware) }
}

fn handle(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case valid_origin(server, req) {
    False -> plain_response(403, "Forbidden Origin")
    True ->
      case protected_metadata_response(server, req) {
        Some(metadata) -> metadata
        None -> handle_authorized(server, req, max_body_bytes, middleware)
      }
  }
}

fn handle_authorized(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  case authorize_request(server, req) {
    Error(error) -> authorization_error_response(server, error)
    Ok(principal) ->
      case req.method == http.Post || valid_protocol_header(req) {
        False -> plain_response(400, "Unsupported MCP protocol version")
        True ->
          case req.method {
            http.Get ->
              case modern_header(req) {
                True -> plain_response(405, "Method Not Allowed")
                False -> handle_get(server, req, principal)
              }
            http.Post ->
              handle_post(server, req, max_body_bytes, middleware, principal)
            http.Delete ->
              case modern_header(req) {
                True -> plain_response(405, "Method Not Allowed")
                False ->
                  case
                    require_existing_session(
                      server,
                      request_session_id(req),
                      principal,
                    )
                  {
                    Ok(id) -> {
                      server.close_session(server, id)
                      response.new(204)
                      |> response.set_body(mist.Bytes(bytes_tree.new()))
                    }
                    Error(error) -> plain_response(error.0, error.1)
                  }
              }
            _ -> plain_response(405, "Method Not Allowed")
          }
      }
  }
}

fn protected_metadata_response(
  app: server.Server,
  req: request.Request(mist.Connection),
) -> Option(response.Response(mist.ResponseData)) {
  case server.header_authorization(app) {
    Some(server.OAuthAuthorization(config)) ->
      case req.method == http.Get && oauth.is_metadata_path(config, req.path) {
        True ->
          Some(
            response.new(200)
            |> response.set_header("content-type", "application/json")
            |> response.set_body(
              mist.Bytes(bytes_tree.from_string(oauth.metadata(config))),
            ),
          )
        False -> None
      }
    _ -> None
  }
}

fn authorization_error_response(
  app: server.Server,
  error: oauth.AuthorizationError,
) -> response.Response(mist.ResponseData) {
  case server.header_authorization(app) {
    Some(server.OAuthAuthorization(config)) ->
      plain_response(oauth.error_status(error), "OAuth authorization failed")
      |> response.set_header("www-authenticate", oauth.challenge(config, error))
    _ -> plain_response(401, "Unauthorized")
  }
}

fn valid_origin(server: server.Server, req: request.Request(body)) -> Bool {
  case request.get_header(req, "origin") {
    Error(_) -> True
    Ok(origin) -> {
      let same = case uri.parse(origin) {
        Ok(parsed) if parsed.path == "" || parsed.path == "/" -> {
          let loopback =
            parsed.host == Some("127.0.0.1")
            || parsed.host == Some("localhost")
            || parsed.host == Some("[::1]")
            || parsed.host == Some("::1")
          parsed.userinfo == None
          && loopback
          && parsed.query == None
          && parsed.fragment == None
          && uri.origin(parsed) == uri.origin(request.to_uri(req))
        }
        _ -> False
      }
      same || list.contains(server.allowed_origins(server), origin)
    }
  }
}

fn valid_protocol_header(req: request.Request(body)) -> Bool {
  case request.get_header(req, "mcp-protocol-version") {
    Ok(value) -> {
      let version = http_headers.trim_ows(value)
      version == jsonrpc.latest_protocol_version
      || version == jsonrpc.legacy_protocol_version
    }
    // The specification's legacy default is unsupported by this SDK. Allow
    // initial handshakes without the header; sessions always require it.
    Error(_) -> request_session_id(req) == None
  }
}

fn modern_header(req: request.Request(body)) -> Bool {
  case request.get_header(req, "mcp-protocol-version") {
    Ok(version) ->
      http_headers.trim_ows(version) != jsonrpc.legacy_protocol_version
    Error(_) -> False
  }
}

fn authorize_request(
  server: server.Server,
  req: request.Request(mist.Connection),
) -> Result(Option(String), oauth.AuthorizationError) {
  case server.header_authorization(server) {
    None -> Ok(None)
    Some(server.HeaderAuthorization(header, validate)) -> {
      use value <- result.try(
        request.get_header(req, header)
        |> result.map_error(fn(_) { oauth.MissingToken }),
      )
      case validate(value) {
        True -> {
          let fingerprint =
            crypto.hash(crypto.Sha256, <<value:utf8>>)
            |> bit_array.base16_encode
          Ok(Some("credential:" <> fingerprint))
        }
        False -> Error(oauth.InvalidToken)
      }
    }
    Some(server.IdentityAuthorization(header, validate)) -> {
      use value <- result.try(
        request.get_header(req, header)
        |> result.map_error(fn(_) { oauth.MissingToken }),
      )
      case validate(value) {
        Some(principal) -> Ok(Some(principal))
        None -> Error(oauth.InvalidToken)
      }
    }
    Some(server.OAuthAuthorization(config)) -> {
      let headers =
        list.filter(req.headers, fn(header) {
          string.lowercase(header.0) == "authorization"
        })
      let query_token =
        req.query
        |> option.map(fn(query) {
          uri.parse_query(query)
          |> result.unwrap([])
          |> list.any(fn(parameter) { parameter.0 == "access_token" })
        })
        |> option.unwrap(False)
      case list.length(headers) > 1 || query_token {
        True -> Error(oauth.MalformedAuthorization)
        False ->
          oauth.authorize(
            config,
            request.get_header(req, "authorization") |> option.from_result,
          )
          |> result.map(Some)
      }
    }
  }
}

fn handle_get(
  server: server.Server,
  req: request.Request(mist.Connection),
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  case require_existing_session(server, request_session_id(req), principal) {
    Ok(session_id) -> {
      let listener_id = server.new_streamable_http_listener_id()

      mist.server_sent_events(
        request: req,
        initial_response: response.new(200)
          |> response.set_header(
            "mcp-protocol-version",
            jsonrpc.legacy_protocol_version,
          )
          |> response.set_header("mcp-session-id", session_id),
        init: fn(listener) {
          server.register_streamable_http_listener(
            server,
            session_id,
            listener_id,
            listener,
          )
          SseState(server, session_id, listener_id)
        },
        loop: handle_sse_message,
      )
    }
    Error(error) -> plain_response(error.0, error.1)
  }
}

fn handle_post(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  handle_post_checked(server, req, max_body_bytes, middleware, principal)
}

fn handle_post_checked(
  server: server.Server,
  req: request.Request(mist.Connection),
  max_body_bytes: Int,
  middleware: ClientActionMiddleware,
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  case has_json_content_type(req) {
    False -> plain_response(415, "Expected application/json request body")
    True ->
      case mist.read_body(req, max_body_bytes) {
        Ok(body_request) ->
          case bit_array.to_string(body_request.body) {
            Ok(body) ->
              handle_post_body(
                server,
                req,
                body,
                request_session_id(req),
                accepts_sse(req),
                middleware,
                principal,
              )
            Error(_) -> plain_response(400, "Request body was not valid UTF-8")
          }
        Error(_) -> plain_response(400, "Unable to read request body")
      }
  }
}

fn handle_post_body(
  server: server.Server,
  req: request.Request(mist.Connection),
  body: String,
  requested_session_id: Option(String),
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  let decoded = case modern_header(req) || wire.claims_modern(body) {
    True ->
      codec.decode_message_with_error_for_version(
        body,
        jsonrpc.latest_protocol_version,
      )
    False -> codec.decode_message_with_error(body)
  }
  case decoded {
    Ok(message) -> {
      case
        modern_header(req)
        || wire.claims_modern(body)
        || is_modern_message(message)
      {
        True ->
          handle_modern_message(
            server,
            req,
            body,
            message,
            accepts_sse_response,
            middleware,
            principal,
          )
        False ->
          handle_legacy_message(
            server,
            req,
            message,
            requested_session_id,
            accepts_sse_response,
            middleware,
            principal,
          )
      }
    }
    Error(diagnostic) -> {
      case modern_header(req) || wire.claims_modern(body) {
        True ->
          modern_json_response(
            server,
            modern_response_status(jsonrpc.ErrorResponse(
              diagnostic.id,
              diagnostic.error,
            )),
            jsonrpc.ErrorResponse(diagnostic.id, diagnostic.error),
          )
        False ->
          handle_invalid_legacy_message(
            server,
            body,
            diagnostic,
            requested_session_id,
            principal,
          )
      }
    }
  }
}

fn is_modern_message(message: codec.Message) -> Bool {
  case message {
    codec.ClientActionRequest(jsonrpc.Request(_, _, Some(action))) ->
      server.is_modern_action(action)
    _ -> False
  }
}

fn handle_modern_message(
  app: server.Server,
  req: request.Request(mist.Connection),
  body: String,
  message: codec.Message,
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  let context = server.modern_request_context(principal, uuid.v4_string(), None)
  case message {
    codec.ClientActionRequest(request) -> {
      let assert jsonrpc.Request(id, method, params) = request
      let context =
        server.request_context(
          context,
          id,
          params |> option.then(server.action_meta),
        )
      let validation =
        validate_modern_headers(app, req, method, params)
        |> result.try(fn(_) {
          case params {
            Some(action) -> server.validate_modern_request(app, context, action)
            None ->
              Error(jsonrpc.invalid_params_error("Missing request parameters"))
          }
        })
      case validation {
        Error(error) ->
          modern_json_response(
            app,
            case error.code {
              -32_601 -> 404
              _ -> 400
            },
            jsonrpc.ErrorResponse(Some(id), error),
          )
        Ok(_) ->
          case middleware(app, context, "", request) {
            Continue -> {
              case accepts_sse_response {
                True ->
                  handle_modern_streamed_request(app, req, context, request)
                False -> {
                  let #(_, rpc) =
                    server.handle_request_with_context(app, context, request)
                  modern_json_response(app, modern_response_status(rpc), rpc)
                }
              }
            }
            RespondRpc(rpc) ->
              modern_json_response(app, modern_response_status(rpc), rpc)
            RespondAccepted -> accepted_response(None)
            RespondPlain(status, body) -> plain_response(status, body)
          }
      }
    }
    codec.UnknownRequest(id, method) -> {
      case
        wire.request_meta(body)
        |> result.try(fn(_) {
          validate_standard_headers(req, method, None, None)
        })
      {
        Error(error) ->
          modern_json_response(app, 400, jsonrpc.ErrorResponse(Some(id), error))
        Ok(_) ->
          modern_json_response(
            app,
            404,
            jsonrpc.ErrorResponse(
              Some(id),
              jsonrpc.method_not_found_error(method),
            ),
          )
      }
    }
    // Modern HTTP has no client-to-server core notifications or responses.
    _ -> plain_response(400, "Unexpected modern client message: " <> body)
  }
}

fn modern_response_status(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> Int {
  case response {
    jsonrpc.ErrorResponse(_, error) if error.code == -32_601 -> 404
    jsonrpc.ErrorResponse(_, error)
      if error.code == -32_602
      || error.code == -32_020
      || error.code == -32_021
      || error.code == -32_022
    -> 400
    _ -> 200
  }
}

type ModernSseState {
  ModernSseState(
    app: server.Server,
    context: server.RequestContext,
    listener: process.Subject(streamable_http_store.ListenerMessage),
  )
}

type ModernBridgeMessage {
  ResultReady(Result(actions.ClientActionResult, jsonrpc.RpcError))
  EventReady(streamable_http_store.ListenerMessage)
  ConnectionClosed
}

type ModernOpening {
  OpeningError(jsonrpc.RpcError)
  OpeningStream(process.Subject(ModernAttachment))
}

type ModernAttachment {
  AttachModernListener(
    process.Subject(streamable_http_store.ListenerMessage),
    process.Subject(Nil),
  )
  ActivateModernListener
}

type ModernAttachmentMessage {
  Attached(ModernAttachment)
  AttachmentOwnerClosed
}

type ModernOpeningMessage {
  Opened(ModernOpening)
  OpeningBridgeClosed
  OpeningConnectionClosed
}

fn handle_modern_streamed_request(
  app: server.Server,
  req: request.Request(mist.Connection),
  context: server.RequestContext,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> response.Response(mist.ResponseData) {
  let assert jsonrpc.Request(id, _, _) = request
  let opening = process.new_subject()
  let registered = process.new_subject()
  let owner = process.self()
  let bridge =
    process.spawn_unlinked(fn() {
      start_modern_bridge(app, context, request, owner, opening, registered)
    })
  let monitor = process.monitor(bridge)
  // A cancellation must follow runtime registration. Once the request has
  // registered, enable close events even while this connection's handler waits
  // for the first result, before any response headers have been written.
  let registration =
    process.new_selector()
    |> process.select_map(registered, fn(_) { True })
    |> process.select_specific_monitor(monitor, fn(_) { False })
    |> process.selector_receive_forever
  let selector =
    process.new_selector()
    |> process.select_map(opening, Opened)
    |> process.select_specific_monitor(monitor, fn(_) { OpeningBridgeClosed })
    |> process.select_record(atom.create("tcp_closed"), 1, fn(_) {
      OpeningConnectionClosed
    })
    |> process.select_record(atom.create("ssl_closed"), 1, fn(_) {
      OpeningConnectionClosed
    })
    |> process.select_record(atom.create("tcp_error"), 2, fn(_) {
      OpeningConnectionClosed
    })
    |> process.select_record(atom.create("ssl_error"), 2, fn(_) {
      OpeningConnectionClosed
    })
  let first = case registration {
    False -> OpeningBridgeClosed
    True -> {
      case
        socket_transport.set_opts(req.body.transport, req.body.socket, [
          options.ActiveMode(options.Once),
        ])
      {
        Ok(_) -> process.selector_receive_forever(selector)
        Error(_) -> OpeningConnectionClosed
      }
    }
  }
  process.demonitor_process(monitor)
  case first {
    Opened(OpeningError(error)) ->
      modern_json_response(
        app,
        modern_response_status(jsonrpc.ErrorResponse(Some(id), error)),
        jsonrpc.ErrorResponse(Some(id), error),
      )
    OpeningBridgeClosed -> {
      server.cancel_incoming_request(app, context, id)
      modern_json_response(
        app,
        200,
        jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.RpcError(-32_603, "Response bridge stopped", None),
        ),
      )
    }
    OpeningConnectionClosed -> {
      server.cancel_incoming_request(app, context, id)
      process.kill(bridge)
      response.new(204) |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    Opened(OpeningStream(attachment)) ->
      modern_sse_response(app, req, context, id, attachment)
  }
}

// Wait before committing SSE's HTTP 200. A handler may discover a missing
// capability while constructing its result, after request validation succeeded.
// Notifications and successful final results still use the streaming response.
fn start_modern_bridge(
  app: server.Server,
  context: server.RequestContext,
  request: jsonrpc.Request(actions.ClientActionRequest),
  owner: process.Pid,
  opening: process.Subject(ModernOpening),
  registered: process.Subject(Nil),
) -> Nil {
  let assert jsonrpc.Request(id, _, _) = request
  let listener = process.new_subject()
  let reply = process.new_subject()
  let attachment = process.new_subject()
  let owner_monitor = process.monitor(owner)
  let assert server.ModernRequestContext(..) = context
  let context =
    server.ModernRequestContext(..context, notifications: Some(listener))
  case request {
    jsonrpc.Request(
      _,
      _,
      Some(actions.ClientRequestSubscriptionsListen(params)),
    ) -> {
      case server.listen_subscription(app, context, params) {
        Ok(_) -> Nil
        Error(error) -> process.send(reply, Error(error))
      }
    }
    _ -> server.start_request_with_context(app, context, request, reply)
  }
  process.send(registered, Nil)
  let selector =
    process.new_selector()
    |> process.select_map(reply, ResultReady)
    |> process.select_map(listener, EventReady)
    |> process.select_specific_monitor(owner_monitor, fn(_) { ConnectionClosed })
  await_modern_opening(
    app,
    context,
    id,
    opening,
    attachment,
    selector,
    owner_monitor,
  )
}

fn await_modern_opening(
  app: server.Server,
  context: server.RequestContext,
  id: jsonrpc.RequestId,
  opening: process.Subject(ModernOpening),
  attachment: process.Subject(ModernAttachment),
  selector: process.Selector(ModernBridgeMessage),
  owner_monitor: process.Monitor,
) -> Nil {
  case process.selector_receive_forever(selector) {
    ConnectionClosed -> server.cancel_incoming_request(app, context, id)
    ResultReady(Error(error)) -> {
      process.demonitor_process(owner_monitor)
      process.send(opening, OpeningError(error))
    }
    ResultReady(Ok(value)) -> {
      let first = modern_result_event(app, id, Ok(value))
      process.send(opening, OpeningStream(attachment))
      attach_modern_bridge(
        app,
        context,
        id,
        attachment,
        selector,
        owner_monitor,
        first,
      )
    }
    EventReady(streamable_http_store.DeliverRequest(_))
    | EventReady(streamable_http_store.DeliverResponse("")) ->
      await_modern_opening(
        app,
        context,
        id,
        opening,
        attachment,
        selector,
        owner_monitor,
      )
    EventReady(streamable_http_store.CloseListener) -> {
      process.demonitor_process(owner_monitor)
      process.send(
        opening,
        OpeningError(jsonrpc.RpcError(-32_603, "Request cancelled", None)),
      )
      server.cancel_incoming_request(app, context, id)
    }
    EventReady(first) -> {
      process.send(opening, OpeningStream(attachment))
      attach_modern_bridge(
        app,
        context,
        id,
        attachment,
        selector,
        owner_monitor,
        first,
      )
    }
  }
}

// The bridge owns notification/result subjects throughout the handoff, so
// messages sent before the SSE actor exists remain in its mailbox in order.
fn attach_modern_bridge(
  app: server.Server,
  context: server.RequestContext,
  id: jsonrpc.RequestId,
  attachment: process.Subject(ModernAttachment),
  selector: process.Selector(ModernBridgeMessage),
  owner_monitor: process.Monitor,
  first: streamable_http_store.ListenerMessage,
) -> Nil {
  let attachments =
    process.new_selector()
    |> process.select_map(attachment, Attached)
    |> process.select_specific_monitor(owner_monitor, fn(_) {
      AttachmentOwnerClosed
    })
  case process.selector_receive(attachments, 1000) {
    Ok(Attached(AttachModernListener(listener, ready))) -> {
      process.demonitor_process(owner_monitor)
      let assert Ok(owner) = process.subject_owner(listener)
      let monitor = process.monitor(owner)
      let selector =
        selector
        |> process.deselect_specific_monitor(owner_monitor)
        |> process.select_specific_monitor(monitor, fn(_) { ConnectionClosed })
      process.send(ready, Nil)
      // Mist transfers the socket after its actor's initialiser returns. Do
      // not deliver a final result until that transfer has completed: the actor
      // may stop as soon as it receives the result.
      let activation =
        process.new_selector()
        |> process.select_map(attachment, Attached)
        |> process.select_specific_monitor(monitor, fn(_) {
          AttachmentOwnerClosed
        })
      case process.selector_receive(activation, 1000) {
        Ok(Attached(ActivateModernListener)) -> {
          process.send(listener, first)
          case first {
            streamable_http_store.DeliverResponse(_) ->
              process.demonitor_process(monitor)
            _ ->
              forward_modern_bridge(
                app,
                context,
                id,
                listener,
                selector,
                monitor,
              )
          }
        }
        _ -> {
          process.demonitor_process(monitor)
          server.cancel_incoming_request(app, context, id)
        }
      }
    }
    _ -> {
      process.demonitor_process(owner_monitor)
      server.cancel_incoming_request(app, context, id)
    }
  }
}

fn forward_modern_bridge(
  app: server.Server,
  context: server.RequestContext,
  id: jsonrpc.RequestId,
  listener: process.Subject(streamable_http_store.ListenerMessage),
  selector: process.Selector(ModernBridgeMessage),
  monitor: process.Monitor,
) -> Nil {
  case process.selector_receive_forever(selector) {
    ConnectionClosed -> server.cancel_incoming_request(app, context, id)
    ResultReady(outcome) -> {
      process.demonitor_process(monitor)
      process.send(listener, modern_result_event(app, id, outcome))
    }
    EventReady(message) -> {
      process.send(listener, message)
      case message {
        streamable_http_store.DeliverResponse(payload) if payload != "" ->
          process.demonitor_process(monitor)
        streamable_http_store.CloseListener -> {
          process.demonitor_process(monitor)
          server.cancel_incoming_request(app, context, id)
        }
        _ ->
          forward_modern_bridge(app, context, id, listener, selector, monitor)
      }
    }
  }
}

fn modern_result_event(
  app: server.Server,
  id: jsonrpc.RequestId,
  outcome: Result(actions.ClientActionResult, jsonrpc.RpcError),
) -> streamable_http_store.ListenerMessage {
  let rpc = case outcome {
    Ok(value) -> jsonrpc.ResultResponse(id, value)
    Error(error) -> jsonrpc.ErrorResponse(Some(id), error)
  }
  streamable_http_store.DeliverResponse(wire.encode_response(
    rpc,
    jsonrpc.latest_protocol_version,
    server.implementation(app),
  ))
}

fn modern_sse_response(
  app: server.Server,
  req: request.Request(mist.Connection),
  context: server.RequestContext,
  id: jsonrpc.RequestId,
  attachment: process.Subject(ModernAttachment),
) -> response.Response(mist.ResponseData) {
  let response =
    mist.server_sent_events(
      req,
      response.new(200)
        |> response.set_header(
          "mcp-protocol-version",
          jsonrpc.latest_protocol_version,
        )
        |> response.set_header("x-accel-buffering", "no"),
      fn(listener) {
        let ready = process.new_subject()
        process.send(attachment, AttachModernListener(listener, ready))
        let assert Ok(Nil) = process.receive(ready, 1000)
        let _ =
          process.send_after(
            listener,
            1000,
            streamable_http_store.DeliverResponse(""),
          )
        ModernSseState(app, context, listener)
      },
      fn(state, message, connection) {
        case message {
          streamable_http_store.DeliverRequest(_) -> actor.continue(state)
          streamable_http_store.DeliverNotification(notification) -> {
            case
              mist.send_event(
                connection,
                mist.event(
                  client_codec.encode_notification(notification)
                  |> string_tree.from_string,
                ),
              )
            {
              Ok(_) -> actor.continue(state)
              Error(_) -> {
                server.cancel_incoming_request(state.app, state.context, id)
                actor.stop()
              }
            }
          }
          streamable_http_store.DeliverResponse("") -> {
            case mist.send_event(connection, mist.event(string_tree.new())) {
              Ok(_) -> {
                let _ =
                  process.send_after(
                    state.listener,
                    1000,
                    streamable_http_store.DeliverResponse(""),
                  )
                actor.continue(state)
              }
              Error(_) -> {
                server.cancel_incoming_request(state.app, state.context, id)
                actor.stop()
              }
            }
          }
          streamable_http_store.DeliverResponse(payload) -> {
            let _ =
              mist.send_event(
                connection,
                mist.event(string_tree.from_string(payload)),
              )
            server.cancel_incoming_request(state.app, state.context, id)
            actor.stop()
          }
          streamable_http_store.CloseListener -> {
            server.cancel_incoming_request(state.app, state.context, id)
            actor.stop()
          }
        }
      },
    )
  process.send(attachment, ActivateModernListener)
  response
}

fn modern_json_response(
  app: server.Server,
  status: Int,
  rpc: jsonrpc.Response(actions.ClientActionResult),
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> response.set_body(
    mist.Bytes(
      bytes_tree.from_string(wire.encode_response(
        rpc,
        jsonrpc.latest_protocol_version,
        server.implementation(app),
      )),
    ),
  )
}

fn validate_modern_headers(
  app: server.Server,
  req: request.Request(body),
  method: String,
  action: Option(actions.ClientActionRequest),
) -> Result(Nil, jsonrpc.RpcError) {
  let action = action |> option.map(actions.request_without_input)
  let meta = action |> option.then(server.action_meta)
  let name = case action {
    Some(actions.ClientRequestCallTool(params)) -> Some(params.name)
    Some(actions.ClientRequestReadResource(params)) -> Some(params.uri)
    Some(actions.ClientRequestGetPrompt(params)) -> Some(params.name)
    Some(actions.ClientRequestGetTask(params))
    | Some(actions.ClientRequestCancelTask(params)) ->
      Some(actions.task_id(params))
    Some(actions.ClientRequestUpdateTask(params)) -> Some(params.task_id)
    _ -> None
  }
  use _ <- result.try(validate_standard_headers(
    req,
    method,
    name,
    server.protocol_version(meta),
  ))
  case action {
    Some(actions.ClientRequestCallTool(params)) -> {
      case server.tool_descriptor(app, params.name) {
        None -> Ok(Nil)
        Some(tool) -> {
          let arguments =
            params.arguments
            |> option.map(fn(fields) { jsonrpc.VObject(dict.to_list(fields)) })
            |> option.unwrap(jsonrpc.VObject([]))
          http_headers.validate_parameters(
            req.headers,
            tool.input_schema,
            arguments,
          )
          |> result.map_error(header_error)
        }
      }
    }
    _ -> Ok(Nil)
  }
}

fn validate_standard_headers(
  req: request.Request(body),
  method: String,
  name: Option(String),
  version: Option(String),
) -> Result(Nil, jsonrpc.RpcError) {
  http_headers.validate_standard(
    req.headers,
    option.unwrap(version, jsonrpc.latest_protocol_version),
    method,
    name,
  )
  |> result.map_error(header_error)
}

fn header_error(message: String) -> jsonrpc.RpcError {
  jsonrpc.RpcError(-32_020, "Header mismatch: " <> message, None)
}

fn handle_legacy_message(
  server: server.Server,
  req: request.Request(mist.Connection),
  message: codec.Message,
  requested_session_id: Option(String),
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  case valid_protocol_header(req) {
    False ->
      plain_response(400, "Unsupported or missing MCP protocol version header")
    True -> {
      let session = case requested_session_id, is_initialize_message(message) {
        None, True -> {
          let id = server.ensure_streamable_http_session(server, None)
          let _ = server.bind_session(server, id, principal)
          Ok(id)
        }
        _, _ ->
          require_existing_session(server, requested_session_id, principal)
      }
      case session {
        Ok(id) ->
          handle_decoded_message(
            server,
            req,
            id,
            message,
            accepts_sse_response,
            middleware,
          )
        Error(error) -> plain_response(error.0, error.1)
      }
    }
  }
}

fn handle_invalid_legacy_message(
  server: server.Server,
  body: String,
  diagnostic: codec_common.MessageDecodeError,
  requested_session_id: Option(String),
  principal: Option(String),
) -> response.Response(mist.ResponseData) {
  let valid_session = case requested_session_id {
    None -> Ok(Nil)
    Some(_) ->
      require_existing_session(server, requested_session_id, principal)
      |> result.map(fn(_) { Nil })
  }
  case valid_session {
    Error(error) -> plain_response(error.0, error.1)
    Ok(_) -> {
      case codec_common.is_response(body) {
        True ->
          case
            require_existing_session(server, requested_session_id, principal)
          {
            Ok(id) ->
              case
                server.handle_server_sent_response(
                  server,
                  server.RequestContext(Some(id), None),
                  body,
                )
              {
                Ok(Nil) -> accepted_response(Some(id))
                Error(error) -> plain_response(400, error.message)
              }
            Error(error) -> plain_response(error.0, error.1)
          }
        False ->
          case codec_common.is_notification(body) {
            True ->
              case
                require_existing_session(
                  server,
                  requested_session_id,
                  principal,
                )
              {
                Ok(_) -> plain_response(400, "Invalid MCP notification")
                Error(error) -> plain_response(error.0, error.1)
              }
            False ->
              json_response(
                400,
                codec.encode_response(jsonrpc.ErrorResponse(
                  diagnostic.id,
                  diagnostic.error,
                )),
                requested_session_id,
              )
          }
      }
    }
  }
}

fn handle_decoded_message(
  server: server.Server,
  req: request.Request(mist.Connection),
  session_id: String,
  message: codec.Message,
  accepts_sse_response: Bool,
  middleware: ClientActionMiddleware,
) -> response.Response(mist.ResponseData) {
  let context = server.RequestContext(Some(session_id), None)
  case message {
    codec.ClientActionRequest(message) ->
      case middleware(server, context, session_id, message) {
        Continue ->
          case accepts_sse_response && should_stream_request_response(message) {
            True -> handle_streamed_request(server, req, session_id, message)
            False -> {
              let #(_, rpc_response) =
                server.handle_request_with_context(server, context, message)
              json_response(
                200,
                codec.encode_response(rpc_response),
                Some(session_id),
              )
            }
          }
        RespondRpc(rpc_response) ->
          json_response(
            200,
            codec.encode_response(rpc_response),
            Some(session_id),
          )
        RespondAccepted -> accepted_response(Some(session_id))
        RespondPlain(status, body) -> plain_response(status, body)
      }
    codec.ActionNotification(notification) ->
      case
        server.handle_notification_with_context(server, context, notification)
      {
        Ok(_) -> accepted_response(Some(session_id))
        Error(error) -> plain_response(400, error.message)
      }
    codec.UnknownRequest(id, method) ->
      json_response(
        200,
        codec.encode_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        )),
        Some(session_id),
      )
    codec.UnknownNotification(_) -> accepted_response(Some(session_id))
  }
}

fn require_existing_session(
  server: server.Server,
  requested_session_id: Option(String),
  principal: Option(String),
) -> Result(String, #(Int, String)) {
  case requested_session_id {
    None -> Error(#(400, "Missing MCP session id"))
    Some(id) ->
      case server.has_streamable_http_session(server, id) {
        False -> Error(#(404, "Unknown MCP session"))
        True ->
          case server.bind_session(server, id, principal) {
            True -> Ok(id)
            False -> Error(#(404, "Unknown MCP session"))
          }
      }
  }
}

fn is_initialize_message(message: codec.Message) -> Bool {
  case message {
    codec.ClientActionRequest(jsonrpc.Request(
      _,
      _,
      Some(actions.ClientRequestInitialize(_)),
    )) -> True
    _ -> False
  }
}

fn handle_streamed_request(
  server: server.Server,
  req: request.Request(mist.Connection),
  session_id: String,
  message: jsonrpc.Request(actions.ClientActionRequest),
) -> response.Response(mist.ResponseData) {
  let listener_id = server.new_streamable_http_listener_id()
  let context = server.RequestContext(Some(session_id), None)
  mist.server_sent_events(
    request: req,
    initial_response: response.new(200)
      |> response.set_header(
        "mcp-protocol-version",
        jsonrpc.legacy_protocol_version,
      )
      |> response.set_header("mcp-session-id", session_id),
    init: fn(listener) {
      server.register_streamable_http_listener(
        server,
        session_id,
        listener_id,
        listener,
      )
      let _ =
        process.spawn_unlinked(fn() {
          let #(_, rpc_response) =
            server.handle_request_with_context(server, context, message)
          process.send(
            listener,
            streamable_http_store.DeliverResponse(codec.encode_response(
              rpc_response,
            )),
          )
          Nil
        })
      SseState(server, session_id, listener_id)
    },
    loop: handle_sse_message,
  )
}

fn should_stream_request_response(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> Bool {
  case request {
    jsonrpc.Request(_, _, Some(actions.ClientRequestGetTaskResult(_)))
    | jsonrpc.Request(_, _, Some(actions.ClientRequestCallTool(_))) -> True
    _ -> False
  }
}

fn accepts_sse(req: request.Request(body)) -> Bool {
  case request.get_header(req, "accept") {
    Ok(value) -> string.contains(value, "text/event-stream")
    Error(_) -> False
  }
}

fn has_json_content_type(req: request.Request(body)) -> Bool {
  case request.get_header(req, "content-type") {
    Ok(value) -> string.starts_with(value, "application/json")
    Error(_) -> False
  }
}

fn json_response(
  status: Int,
  body: String,
  session_id: Option(String),
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.legacy_protocol_version,
  )
  |> prepend_session_id_header(session_id)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn accepted_response(
  session_id: Option(String),
) -> response.Response(mist.ResponseData) {
  response.new(202)
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.legacy_protocol_version,
  )
  |> prepend_session_id_header(session_id)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
}

fn plain_response(
  status: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn prepend_session_id_header(
  response: response.Response(body),
  session_id: Option(String),
) -> response.Response(body) {
  case session_id {
    Some(value) -> response.set_header(response, "mcp-session-id", value)
    None -> response
  }
}

fn request_session_id(req: request.Request(body)) -> Option(String) {
  case request.get_header(req, "mcp-session-id") {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

type SseState {
  SseState(server: server.Server, session_id: String, listener_id: String)
}

fn handle_sse_message(
  state: SseState,
  message: streamable_http_store.ListenerMessage,
  connection: mist.SSEConnection,
) -> actor.Next(SseState, streamable_http_store.ListenerMessage) {
  let SseState(server: app_server, session_id:, listener_id:) = state

  case message {
    streamable_http_store.DeliverRequest(request) -> {
      case
        mist.send_event(
          connection,
          mist.event(
            client_codec.encode_server_request(request)
            |> string_tree.from_string,
          ),
        )
      {
        Ok(Nil) -> actor.continue(state)
        Error(Nil) -> {
          server.unregister_streamable_http_listener(
            app_server,
            session_id,
            listener_id,
          )
          actor.stop()
        }
      }
    }
    streamable_http_store.DeliverNotification(notification) ->
      case
        mist.send_event(
          connection,
          mist.event(
            client_codec.encode_notification(notification)
            |> string_tree.from_string,
          ),
        )
      {
        Ok(Nil) -> actor.continue(state)
        Error(Nil) -> {
          server.unregister_streamable_http_listener(
            app_server,
            session_id,
            listener_id,
          )
          actor.stop()
        }
      }
    streamable_http_store.DeliverResponse(payload) -> {
      let _ =
        server.unregister_streamable_http_listener(
          app_server,
          session_id,
          listener_id,
        )

      case
        mist.send_event(
          connection,
          mist.event(payload |> string_tree.from_string),
        )
      {
        Ok(Nil) -> actor.stop()
        Error(Nil) -> actor.stop()
      }
    }
    streamable_http_store.CloseListener -> {
      server.unregister_streamable_http_listener(
        app_server,
        session_id,
        listener_id,
      )
      actor.stop()
    }
  }
}
