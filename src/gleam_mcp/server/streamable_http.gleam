import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
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
import gleam_mcp/server/oauth
import gleam_mcp/server/streamable_http_store
import mist

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
      case valid_protocol_header(req) {
        False -> plain_response(400, "Unsupported MCP protocol version")
        True ->
          case req.method {
            http.Get -> handle_get(server, req, principal)
            http.Post ->
              handle_post(server, req, max_body_bytes, middleware, principal)
            http.Delete ->
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
    Ok(version) -> version == jsonrpc.latest_protocol_version
    // The specification's legacy default is unsupported by this SDK. Allow
    // initial handshakes without the header; sessions always require it.
    Error(_) -> request_session_id(req) == None
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
            jsonrpc.latest_protocol_version,
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
  case request_session_id(req) {
    Some(id) ->
      case require_existing_session(server, Some(id), principal) {
        Error(error) -> plain_response(error.0, error.1)
        Ok(_) ->
          handle_post_checked(
            server,
            req,
            max_body_bytes,
            middleware,
            principal,
          )
      }
    None ->
      handle_post_checked(server, req, max_body_bytes, middleware, principal)
  }
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
  case codec.decode_message_with_error(body) {
    Ok(message) -> {
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
    Error(diagnostic) -> {
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
        jsonrpc.latest_protocol_version,
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
    jsonrpc.latest_protocol_version,
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
    jsonrpc.latest_protocol_version,
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
