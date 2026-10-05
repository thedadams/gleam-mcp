//// OAuth conformance application adapter. Credential provisioning and the
//// automatic browser redirect are fixture conveniences; discovery, PKCE,
//// callback checks, token exchange, and token attachment use the SDK APIs.

import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec
import gleam_mcp/client/oauth as sdk_oauth
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc

const redirect_uri = "http://localhost:3000/callback"

const metadata_client_id = "https://conformance-test.local/client-metadata.json"

type Credentials {
  Credentials(
    issuer: String,
    client_id: String,
    secret: Option(String),
    cimd: Bool,
  )
}

type State {
  State(
    endpoint: transport.HttpConfig,
    context: jsonrpc.Value,
    credentials: Option(Credentials),
    tokens: Option(sdk_oauth.Tokens),
  )
}

type Message {
  Current(
    process.Subject(Result(transport.HttpConfig, transport.TransportError)),
  )
  Authorize(
    Option(String),
    process.Subject(Result(transport.HttpConfig, transport.TransportError)),
  )
  Stop
}

pub fn run(
  server_url: String,
  _scenario: String,
  protocol_version: String,
  context: jsonrpc.Value,
) -> Result(Nil, String) {
  let endpoint = transport.HttpConfig(server_url, [], Some(15_000))
  use started <- result.try(
    actor.new(State(endpoint, context, None, None))
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(string.inspect),
  )
  let auth = started.data
  let base = transport.default_runners()
  let runners =
    transport.Runners(
      ..base,
      streamable_request: fn(config, session, version, caps, message) {
        with_authorization(
          auth,
          fn(authorized) {
            base.streamable_request(authorized, session, version, caps, message)
          },
          config,
        )
      },
      streamable_notification: fn(config, session, version, caps, message) {
        with_authorization(
          auth,
          fn(authorized) {
            base.streamable_notification(
              authorized,
              session,
              version,
              caps,
              message,
            )
          },
          config,
        )
      },
    )
  let configured =
    client.new_with_runners(
      transport.Http(endpoint),
      runners,
      capabilities.none(),
    )
    |> client.with_protocol_version(protocol_version)
    |> client.with_request_timeout(20_000)
  let connected = case protocol_version == jsonrpc.legacy_protocol_version {
    True ->
      client.initialize(configured, implementation())
      |> result.map(fn(pair) { pair.0 })
    False ->
      client.connect(configured, implementation())
      |> result.map(fn(pair) { pair.0 })
  }
  let outcome = case connected {
    Error(error) -> {
      let _ = client.close(configured)
      Error(string.inspect(error))
    }
    Ok(connected) -> {
      let #(listed, listing) = client.list_tools(connected, None)
      let #(finished, operation) = case listing {
        Error(error) -> #(listed, Error(error))
        Ok(_) -> {
          let #(called, called_result) =
            client.call_tool(
              listed,
              actions.CallToolRequestParams(
                "test-tool",
                Some(dict.new()),
                None,
                None,
              ),
            )
          #(called, result.map(called_result, fn(_) { Nil }))
        }
      }
      // The SDK's explicit close sends DELETE outside the request runners.
      // Supply the current resource-bound headers for that final request too.
      let closing = case process.call(auth, 20_000, Current) {
        Ok(authorized) ->
          client.Client(
            ..finished,
            transport_config: transport.Http(authorized),
          )
        Error(_) -> finished
      }
      let _ = client.close(closing)
      operation |> result.map_error(string.inspect)
    }
  }
  process.send(auth, Stop)
  outcome
}

fn implementation() -> actions.Implementation {
  actions.Implementation(
    "gleam-mcp-conformance-auth",
    "1.0.0",
    None,
    None,
    None,
    [],
  )
}

fn with_authorization(
  auth: process.Subject(Message),
  operation: fn(transport.HttpConfig) -> Result(a, transport.TransportError),
  _config: transport.HttpConfig,
) -> Result(a, transport.TransportError) {
  use config <- result.try(process.call(auth, 20_000, Current))
  case operation(config) {
    Error(transport.AuthorizationRequired(_, challenge)) -> {
      use authorized <- result.try(
        process.call(auth, 20_000, fn(reply) { Authorize(challenge, reply) }),
      )
      // One authorization retry per operation bounds repeated 403 challenges.
      operation(authorized)
    }
    outcome -> outcome
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Current(reply) -> {
      process.send(reply, current_config(state))
      actor.continue(state)
    }
    Authorize(header, reply) -> {
      case authorize(state, header) {
        Ok(next) -> {
          process.send(reply, current_config(next))
          actor.continue(next)
        }
        Error(error) -> {
          process.send(reply, Error(transport.HttpError("OAuth: " <> error)))
          actor.continue(state)
        }
      }
    }
    Stop -> actor.stop()
  }
}

fn current_config(
  state: State,
) -> Result(transport.HttpConfig, transport.TransportError) {
  case state.tokens {
    None -> Ok(state.endpoint)
    Some(tokens) ->
      sdk_oauth.authorize_http(state.endpoint, tokens)
      |> result.map_error(fn(error) {
        transport.HttpError(string.inspect(error))
      })
  }
}

fn authorize(state: State, header: Option(String)) -> Result(State, String) {
  use challenge <- result.try(case header {
    None -> Ok(None)
    Some(header) ->
      sdk_oauth.parse_challenge(header)
      |> result.map(Some)
      |> result.map_error(string.inspect)
  })
  let challenge = union_scopes(challenge, state.tokens)
  let probe =
    sdk_oauth.new(state.endpoint.base_url, "fixture-discovery", redirect_uri)
    |> sdk_oauth.allow_localhost_http
    |> sdk_oauth.with_timeout(10_000)
  // Preserve the raw, SDK-validated AS document only to provision fixture
  // credentials from its registration_endpoint (not exposed by the SDK type).
  let metadata_inbox = process.new_subject()
  let sender = fn(req) {
    let sent = send(req)
    case sent {
      Ok(res) if res.status == 200 && req.method == http.Get -> {
        case json.parse(res.body, codec.value_decoder()) {
          Ok(jsonrpc.VObject(fields) as value) ->
            case list.key_find(fields, "issuer") {
              Ok(jsonrpc.VString(_)) -> process.send(metadata_inbox, value)
              _ -> Nil
            }
          _ -> Nil
        }
      }
      _ -> Nil
    }
    sent
  }
  use discovery <- result.try(
    sdk_oauth.discover_with_sender(probe, challenge, sender)
    |> result.map_error(string.inspect),
  )
  use metadata <- result.try(
    process.receive(metadata_inbox, 0)
    |> result.replace_error("SDK discovery did not return AS metadata"),
  )
  use credentials <- result.try(credentials(state, discovery, metadata))
  let configured =
    sdk_oauth.new(state.endpoint.base_url, credentials.client_id, redirect_uri)
    |> sdk_oauth.allow_localhost_http
    |> sdk_oauth.with_timeout(10_000)
  let configured = case credentials.cimd {
    True -> sdk_oauth.with_client_metadata_document(configured)
    False -> sdk_oauth.with_issuer(configured, credentials.issuer)
  }
  let configured = case credentials.secret {
    Some(secret) -> sdk_oauth.with_client_secret(configured, secret)
    None -> configured
  }
  use pending <- result.try(
    sdk_oauth.begin(configured, discovery) |> result.map_error(string.inspect),
  )
  use browser <- result.try(
    request.to(sdk_oauth.authorization_url(pending))
    |> result.replace_error("Invalid authorization URL"),
  )
  use redirected <- result.try(
    send(browser |> request.set_body(""))
    |> result.map_error(string.inspect),
  )
  use location <- result.try(
    response.get_header(redirected, "location")
    |> result.replace_error("Authorization server did not redirect"),
  )
  use tokens <- result.try(
    sdk_oauth.exchange_from_redirect_with_sender(pending, location, send)
    |> result.map_error(string.inspect),
  )
  Ok(State(..state, credentials: Some(credentials), tokens: Some(tokens)))
}

fn union_scopes(
  challenge: Option(sdk_oauth.Challenge),
  tokens: Option(sdk_oauth.Tokens),
) -> Option(sdk_oauth.Challenge) {
  case challenge, tokens {
    Some(challenge), Some(tokens) -> {
      case challenge.scopes {
        Some(scopes) ->
          Some(
            sdk_oauth.Challenge(
              ..challenge,
              scopes: Some(
                list.unique(list.append(
                  sdk_oauth.granted_scopes(tokens),
                  scopes,
                )),
              ),
            ),
          )
        None -> Some(challenge)
      }
    }
    _, _ -> challenge
  }
}

fn credentials(
  state: State,
  discovery: sdk_oauth.Discovery,
  metadata: jsonrpc.Value,
) -> Result(Credentials, String) {
  let issuer = discovery.authorization_server.issuer
  case value_string(state.context, "client_id") {
    Some(id) -> {
      use binding <- result.try(
        value_string(state.context, "issuer")
        |> option.to_result("Pre-registered credentials require their issuer"),
      )
      case binding == issuer {
        False -> Error("Pre-registered credentials belong to another issuer")
        True ->
          Ok(Credentials(
            issuer,
            id,
            value_string(state.context, "client_secret"),
            False,
          ))
      }
    }
    None -> {
      case state.credentials {
        Some(credentials) if credentials.issuer == issuer -> Ok(credentials)
        _ ->
          case
            discovery.authorization_server.client_id_metadata_document_supported
          {
            True -> Ok(Credentials(issuer, metadata_client_id, None, True))
            False -> provision_credentials(issuer, discovery, metadata)
          }
      }
    }
  }
}

fn provision_credentials(
  issuer: String,
  discovery: sdk_oauth.Discovery,
  metadata: jsonrpc.Value,
) -> Result(Credentials, String) {
  use endpoint <- result.try(
    value_string(metadata, "registration_endpoint")
    |> option.to_result("Fixture does not advertise credential provisioning"),
  )
  let methods =
    discovery.authorization_server.token_endpoint_auth_methods_supported
    |> option.unwrap(["client_secret_basic"])
  let method = case list.contains(methods, "none") {
    True -> "none"
    False ->
      case list.contains(methods, "client_secret_basic") {
        True -> "client_secret_basic"
        False -> "client_secret_post"
      }
  }
  use req <- result.try(
    request.to(endpoint)
    |> result.replace_error("Invalid registration endpoint"),
  )
  let body =
    json.object([
      #("client_name", json.string("gleam-mcp-conformance-auth")),
      #("redirect_uris", json.array([redirect_uri], json.string)),
      #(
        "grant_types",
        json.array(["authorization_code", "refresh_token"], json.string),
      ),
      #("response_types", json.array(["code"], json.string)),
      #("application_type", json.string("native")),
      #("token_endpoint_auth_method", json.string(method)),
    ])
    |> json.to_string
  use res <- result.try(
    send(
      req
      |> request.set_method(http.Post)
      |> request.set_header("content-type", "application/json")
      |> request.set_body(body),
    )
    |> result.map_error(string.inspect),
  )
  case res.status == 200 || res.status == 201 {
    False -> Error("Fixture credential provisioning failed")
    True -> {
      use value <- result.try(
        json.parse(res.body, codec.value_decoder())
        |> result.replace_error("Invalid fixture credentials"),
      )
      use id <- result.try(
        value_string(value, "client_id")
        |> option.to_result("Fixture credentials omitted client_id"),
      )
      let secret = case method {
        "none" -> None
        _ -> value_string(value, "client_secret")
      }
      Ok(Credentials(issuer, id, secret, False))
    }
  }
}

fn value_string(value: jsonrpc.Value, key: String) -> Option(String) {
  case value {
    jsonrpc.VObject(fields) ->
      case list.key_find(fields, key) {
        Ok(jsonrpc.VString(value)) -> Some(value)
        _ -> None
      }
    _ -> None
  }
}

fn send(
  req: request.Request(String),
) -> Result(response.Response(String), sdk_oauth.Error) {
  httpc.dispatch(
    httpc.configure() |> httpc.timeout(10_000),
    req |> request.set_header("connection", "close"),
  )
  |> result.replace_error(sdk_oauth.HttpFailure)
}
