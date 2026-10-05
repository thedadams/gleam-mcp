import flwr_oauth2/pkce
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleam_mcp/client/oauth
import gleam_mcp/client/transport
import gleam_mcp/server/oauth as server_oauth
import gleeunit/should

const resource = "https://mcp.example.test/mcp"

const issuer = "https://auth.example.test/tenant"

const redirect = "http://127.0.0.1:8080/callback"

pub fn main() {
  bearer_challenge_parses_multiple_schemes_quotes_and_scopes_test()
  bearer_challenge_rejects_ambiguous_or_unterminated_parameters_test()
  challenge_parameters_allow_whitespace_around_equals_test()
  canonical_resource_normalizes_scheme_host_without_dropping_path_test()
  resource_and_oidc_discovery_follows_required_fallback_order_test()
  challenge_metadata_and_scopes_take_precedence_test()
  discovery_rejects_resource_and_issuer_substitution_test()
  pkce_is_mandatory_and_authorization_binds_resource_test()
  code_exchange_checks_state_and_sends_pkce_and_resource_test()
  refresh_includes_resource_and_preserves_rotated_refresh_token_test()
  expired_tokens_and_oauth_errors_are_explicit_test()
  insecure_endpoints_require_explicit_loopback_opt_in_test()
  server_metadata_and_challenge_are_consumed_by_client_test()
  discovery_preserves_resource_query_and_rejects_issuer_query_test()
  authorization_issuer_redirect_and_pin_are_verified_test()
  public_clients_require_declared_none_authentication_test()
}

pub fn bearer_challenge_parses_multiple_schemes_quotes_and_scopes_test() {
  let challenge =
    oauth.parse_challenge(
      "Basic realm=\"old\", bEaReR resource_metadata=\"https://mcp.example.test/metadata\", scope=\"custom:read write\", error=\"insufficient_scope\", error_description=\"Need a comma, and a \\\"quote\\\"\"",
    )
    |> should.be_ok
  should.equal(
    challenge.resource_metadata,
    Some("https://mcp.example.test/metadata"),
  )
  should.equal(challenge.scopes, Some(["custom:read", "write"]))
  should.equal(challenge.error, Some("insufficient_scope"))
  should.equal(
    challenge.error_description,
    Some("Need a comma, and a \"quote\""),
  )
}

pub fn bearer_challenge_rejects_ambiguous_or_unterminated_parameters_test() {
  oauth.parse_challenge("Bearer scope=\"one\", scope=\"two\"")
  |> should.be_error
  oauth.parse_challenge("Bearer scope=\"one") |> should.be_error
  oauth.parse_challenge("Basic realm=\"only\"") |> should.be_error
}

pub fn challenge_parameters_allow_whitespace_around_equals_test() {
  let challenge =
    oauth.parse_challenge(
      "Bearer resource_metadata = \"https://mcp.example.test/metadata\", scope = \"write\"",
    )
    |> should.be_ok
  should.equal(
    challenge.resource_metadata,
    Some("https://mcp.example.test/metadata"),
  )
  should.equal(challenge.scopes, Some(["write"]))
}

pub fn server_metadata_and_challenge_are_consumed_by_client_test() {
  let server_config =
    server_oauth.new(resource, [issuer], ["read"], fn(_) { Error(Nil) })
    |> should.be_ok
  let challenge =
    server_oauth.challenge(server_config, server_oauth.MissingToken)
    |> oauth.parse_challenge
    |> should.be_ok
  let discovery =
    oauth.discover_with_sender(
      oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer),
      Some(challenge),
      fn(req) {
        case req.host {
          "mcp.example.test" ->
            Ok(json_response(server_oauth.metadata(server_config)))
          _ -> Ok(json_response(authorization_document(issuer, ["S256"])))
        }
      },
    )
    |> should.be_ok
  should.equal(discovery.resource.resource, resource)
  should.equal(discovery.scopes, Some(["read"]))
}

pub fn discovery_preserves_resource_query_and_rejects_issuer_query_test() {
  should.equal(oauth.resource_metadata_urls(resource <> "?tenant=a"), [
    "https://mcp.example.test/.well-known/oauth-protected-resource/mcp?tenant=a",
    "https://mcp.example.test/.well-known/oauth-protected-resource?tenant=a",
  ])
  oauth.discover_with_sender(
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer),
    None,
    fn(_) {
      Ok(json_response(resource_document(resource, [issuer <> "?tenant=a"])))
    },
  )
  |> should.be_error
  should.equal(oauth.authorization_metadata_urls("https://auth.test:bad"), [])
  oauth.discover_with_sender(
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer),
    None,
    fn(_) {
      Ok(json_response(resource_document(resource, ["https://auth.test:bad"])))
    },
  )
  |> should.be_error
}

pub fn public_clients_require_declared_none_authentication_test() {
  let config =
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer)
  let discovery = discovered(config)
  let metadata =
    oauth.AuthorizationServerMetadata(
      ..discovery.authorization_server,
      token_endpoint_auth_methods_supported: None,
    )
  let discovery = oauth.Discovery(..discovery, authorization_server: metadata)
  oauth.begin(config, discovery) |> should.be_error
  oauth.begin(config |> oauth.with_client_secret("secret"), discovery)
  |> should.be_ok
}

pub fn authorization_issuer_redirect_and_pin_are_verified_test() {
  let config =
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer)
  let discovery = discovered(config)
  let other_issuer = "https://different.example.test"
  let resource_metadata =
    oauth.ResourceMetadata(..discovery.resource, authorization_servers: [
      issuer,
      other_issuer,
    ])
  let multiple = oauth.Discovery(..discovery, resource: resource_metadata)
  should.equal(
    oauth.begin(config, multiple),
    Error(oauth.CallbackIssuerRequired),
  )
  let metadata =
    oauth.AuthorizationServerMetadata(
      ..discovery.authorization_server,
      authorization_response_iss_parameter_supported: True,
    )
  let multiple = oauth.Discovery(..multiple, authorization_server: metadata)
  let pending = oauth.begin(config, multiple) |> should.be_ok
  let callback =
    redirect <> "?code=callback&state=" <> oauth.authorization_state(pending)
  let send = fn(_: request.Request(String)) {
    Ok(token_response("verified", None, None, 60))
  }
  should.equal(
    oauth.exchange_with_sender(
      pending,
      "code",
      oauth.authorization_state(pending),
      send,
    ),
    Error(oauth.CallbackIssuerRequired),
  )
  should.equal(
    oauth.exchange_from_redirect_with_sender(pending, callback, send),
    Error(oauth.CallbackIssuerRequired),
  )
  should.equal(
    oauth.exchange_from_redirect_with_sender(
      pending,
      callback <> "&iss=" <> uri.percent_encode(other_issuer),
      send,
    ),
    Error(oauth.IssuerMismatch),
  )
  let correct = callback <> "&iss=" <> uri.percent_encode(issuer)
  oauth.exchange_from_redirect_with_sender(pending, correct, send)
  |> should.be_ok
  oauth.exchange_from_redirect_with_sender(
    pending,
    correct <> "&code=duplicate",
    send,
  )
  |> should.be_error
  oauth.exchange_from_redirect_with_sender(
    pending,
    "http://127.0.0.1:8080/wrong?code=callback&state="
      <> oauth.authorization_state(pending)
      <> "&iss="
      <> uri.percent_encode(issuer),
    send,
  )
  |> should.be_error
  should.equal(
    oauth.begin(config |> oauth.with_issuer(other_issuer), multiple),
    Error(oauth.ResourceMismatch),
  )
}

pub fn canonical_resource_normalizes_scheme_host_without_dropping_path_test() {
  should.equal(
    oauth.canonical_resource("HTTPS://MCP.EXAMPLE.TEST/server/mcp"),
    Ok("https://mcp.example.test/server/mcp"),
  )
  should.equal(
    oauth.canonical_resource("https://mcp.example.test/"),
    Ok("https://mcp.example.test"),
  )
  oauth.canonical_resource("https://mcp.example.test/mcp#fragment")
  |> should.be_error
  oauth.canonical_resource("https://user@mcp.example.test/mcp")
  |> should.be_error
  oauth.canonical_resource("mcp.example.test") |> should.be_error
}

pub fn resource_and_oidc_discovery_follows_required_fallback_order_test() {
  let requests = process.new_subject()
  let config =
    oauth.new(resource, "public-client", redirect) |> oauth.with_issuer(issuer)
  let discovered =
    oauth.discover_with_sender(config, None, fn(req) {
      should.equal(req.method, http.Get)
      request.get_header(req, "authorization") |> should.be_error
      process.send(requests, uri.to_string(request.to_uri(req)))
      case req.path {
        "/.well-known/oauth-protected-resource" ->
          Ok(
            json_response(
              resource_document("https://mcp.example.test", [issuer]),
            ),
          )
        "/tenant/.well-known/openid-configuration" ->
          Ok(json_response(authorization_document(issuer, ["S256"])))
        _ -> Ok(response.new(404) |> response.set_body(""))
      }
    })
    |> should.be_ok
  should.equal(discovered.scopes, Some(["read"]))
  let urls =
    list.map(list.repeat(Nil, 5), fn(_) {
      process.receive(requests, 0) |> should.be_ok
    })
  should.equal(urls, [
    "https://mcp.example.test/.well-known/oauth-protected-resource/mcp",
    "https://mcp.example.test/.well-known/oauth-protected-resource",
    "https://auth.example.test/.well-known/oauth-authorization-server/tenant",
    "https://auth.example.test/.well-known/openid-configuration/tenant",
    "https://auth.example.test/tenant/.well-known/openid-configuration",
  ])
}

pub fn challenge_metadata_and_scopes_take_precedence_test() {
  let requests = process.new_subject()
  let challenge =
    oauth.parse_challenge(
      "Bearer resource_metadata=\"https://mcp.example.test/custom-metadata\", scope=\"special:scope\"",
    )
    |> should.be_ok
  let discovered =
    oauth.discover_with_sender(
      oauth.new(resource, "client", redirect)
        |> oauth.with_issuer(issuer)
        |> oauth.with_scopes(["ignored"]),
      Some(challenge),
      fn(req) {
        process.send(requests, req.path)
        case req.path {
          "/custom-metadata" ->
            Ok(json_response(resource_document(resource, [issuer])))
          _ -> Ok(json_response(authorization_document(issuer, ["S256"])))
        }
      },
    )
    |> should.be_ok
  should.equal(discovered.scopes, Some(["special:scope"]))
  should.equal(process.receive(requests, 0), Ok("/custom-metadata"))
  should.equal(
    process.receive(requests, 0),
    Ok("/.well-known/oauth-authorization-server/tenant"),
  )
}

pub fn discovery_rejects_resource_and_issuer_substitution_test() {
  let config =
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer)
  oauth.discover_with_sender(config, None, fn(_) {
    Ok(
      json_response(
        resource_document("https://other.example.test/mcp", [issuer]),
      ),
    )
  })
  |> should.be_error
  oauth.discover_with_sender(config, None, fn(req) {
    case req.host {
      "mcp.example.test" ->
        Ok(json_response(resource_document(resource, [issuer])))
      _ ->
        Ok(
          json_response(
            authorization_document("https://other.example.test", ["S256"]),
          ),
        )
    }
  })
  |> should.be_error
  oauth.discover_with_sender(
    config |> oauth.with_issuer("https://other.example.test"),
    None,
    fn(_) { Ok(json_response(resource_document(resource, [issuer]))) },
  )
  |> should.be_error
}

pub fn pkce_is_mandatory_and_authorization_binds_resource_test() {
  let config =
    oauth.new(resource, "public-client", redirect) |> oauth.with_issuer(issuer)
  let discovery = discovered(config)
  let unsupported =
    oauth.Discovery(
      ..discovery,
      authorization_server: oauth.AuthorizationServerMetadata(
        ..discovery.authorization_server,
        code_challenge_methods_supported: [],
      ),
    )
  should.equal(oauth.begin(config, unsupported), Error(oauth.PkceUnsupported))
  let pending = oauth.begin(config, discovery) |> should.be_ok
  let other = oauth.begin(config, discovery) |> should.be_ok
  let url = uri.parse(oauth.authorization_url(pending)) |> should.be_ok
  let query =
    uri.parse_query(url.query |> should.be_some)
    |> should.be_ok
    |> dict.from_list
  should.equal(dict.get(query, "resource"), Ok(resource))
  should.equal(dict.get(query, "response_type"), Ok("code"))
  should.equal(dict.get(query, "client_id"), Ok("public-client"))
  should.equal(dict.get(query, "redirect_uri"), Ok(redirect))
  should.equal(dict.get(query, "code_challenge_method"), Ok("S256"))
  should.equal(dict.get(query, "state"), Ok(oauth.authorization_state(pending)))
  should.equal(
    string.length(dict.get(query, "code_challenge") |> should.be_ok),
    43,
  )
  should.not_equal(
    oauth.authorization_state(pending),
    oauth.authorization_state(other),
  )
}

pub fn code_exchange_checks_state_and_sends_pkce_and_resource_test() {
  let config =
    oauth.new(resource, "public-client", redirect) |> oauth.with_issuer(issuer)
  let pending = oauth.begin(config, discovered(config)) |> should.be_ok
  let pending_url = uri.parse(oauth.authorization_url(pending)) |> should.be_ok
  let params =
    uri.parse_query(pending_url.query |> should.be_some)
    |> should.be_ok
    |> dict.from_list
  let sent = process.new_subject()
  let send = fn(req: request.Request(String)) {
    process.send(sent, Nil)
    should.equal(req.method, http.Post)
    should.equal(uri.to_string(request.to_uri(req)), issuer <> "/token")
    should.equal(
      request.get_header(req, "content-type"),
      Ok("application/x-www-form-urlencoded"),
    )
    let form = uri.parse_query(req.body) |> should.be_ok |> dict.from_list
    should.equal(dict.get(form, "resource"), Ok(resource))
    should.equal(dict.get(form, "grant_type"), Ok("authorization_code"))
    should.equal(dict.get(form, "client_id"), Ok("public-client"))
    should.equal(dict.get(form, "code"), Ok("callback-code"))
    should.equal(dict.get(form, "redirect_uri"), Ok(redirect))
    let verifier = dict.get(form, "code_verifier") |> should.be_ok
    should.equal(string.length(verifier), 43)
    should.equal(
      dict.get(params, "code_challenge"),
      Ok(pkce.to_challenge(pkce.Verifier(verifier)).value),
    )
    Ok(token_response("access", Some("refresh-1"), None, 60))
  }
  should.equal(
    oauth.exchange_with_sender(pending, "callback-code", "wrong", send),
    Error(oauth.StateMismatch),
  )
  process.receive(sent, 0) |> should.equal(Error(Nil))
  let tokens =
    oauth.exchange_with_sender(
      pending,
      "callback-code",
      oauth.authorization_state(pending),
      send,
    )
    |> should.be_ok
  should.be_true(oauth.can_refresh(tokens))
  should.equal(oauth.granted_scopes(tokens), ["read"])
  let http_config =
    oauth.authorize_http(
      transport.HttpConfig(
        resource,
        [#("Authorization", "old"), #("x-user", "present")],
        None,
      ),
      tokens,
    )
    |> should.be_ok
  should.equal(http_config.headers, [
    #("authorization", "Bearer access"),
    #("x-user", "present"),
  ])
  should.equal(
    oauth.authorize_http(
      transport.HttpConfig("https://other.example.test", [], None),
      tokens,
    ),
    Error(oauth.ResourceMismatch),
  )
}

pub fn refresh_includes_resource_and_preserves_rotated_refresh_token_test() {
  let config =
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer)
  let discovery = discovered(config)
  let pending = oauth.begin(config, discovery) |> should.be_ok
  let tokens =
    oauth.exchange_with_sender(
      pending,
      "code",
      oauth.authorization_state(pending),
      fn(_) {
        Ok(token_response("access", Some("refresh-1"), Some("read write"), 60))
      },
    )
    |> should.be_ok
  let rotated =
    oauth.refresh_with_sender(config, discovery, tokens, fn(req) {
      let form = uri.parse_query(req.body) |> should.be_ok |> dict.from_list
      should.equal(dict.get(form, "resource"), Ok(resource))
      should.equal(dict.get(form, "grant_type"), Ok("refresh_token"))
      should.equal(dict.get(form, "refresh_token"), Ok("refresh-1"))
      should.equal(dict.get(form, "scope"), Ok("read write"))
      Ok(token_response("new-access", Some("refresh-2"), None, 60))
    })
    |> should.be_ok
  should.equal(oauth.granted_scopes(rotated), ["read", "write"])
  oauth.refresh_with_sender(config, discovery, rotated, fn(req) {
    let form = uri.parse_query(req.body) |> should.be_ok |> dict.from_list
    should.equal(dict.get(form, "refresh_token"), Ok("refresh-2"))
    Ok(token_response("third-access", None, None, 60))
  })
  |> should.be_ok
  should.equal(
    oauth.refresh_with_sender(
      oauth.new(resource, "different-client", redirect)
        |> oauth.with_issuer(issuer),
      discovery,
      rotated,
      fn(_) { panic },
    ),
    Error(oauth.ResourceMismatch),
  )
}

pub fn expired_tokens_and_oauth_errors_are_explicit_test() {
  let config =
    oauth.new(resource, "client", redirect) |> oauth.with_issuer(issuer)
  let discovery = discovered(config)
  let pending = oauth.begin(config, discovery) |> should.be_ok
  let tokens =
    oauth.exchange_with_sender(
      pending,
      "code",
      oauth.authorization_state(pending),
      fn(_) { Ok(token_response("expired", None, None, 0)) },
    )
    |> should.be_ok
  should.equal(
    oauth.authorize_http(transport.HttpConfig(resource, [], None), tokens),
    Error(oauth.TokenExpired),
  )
  should.equal(
    oauth.refresh_with_sender(config, discovery, tokens, fn(_) { panic }),
    Error(oauth.RefreshUnavailable),
  )
  should.equal(
    oauth.exchange_with_sender(
      pending,
      "code",
      oauth.authorization_state(pending),
      fn(_) {
        Ok(
          response.new(400)
          |> response.set_body("{\"error\":\"invalid_grant\"}"),
        )
      },
    ),
    Error(oauth.TokenRejected(400, "invalid_grant")),
  )
}

pub fn insecure_endpoints_require_explicit_loopback_opt_in_test() {
  let local_resource = "http://127.0.0.1:1234/mcp"
  let local_issuer = "http://127.0.0.1:5678"
  let config =
    oauth.new(local_resource, "client", redirect)
    |> oauth.with_issuer(local_issuer)
  let sender = fn(req: request.Request(String)) {
    case req.port {
      Some(1234) ->
        Ok(json_response(resource_document(local_resource, [local_issuer])))
      _ -> Ok(json_response(authorization_document(local_issuer, ["S256"])))
    }
  }
  oauth.discover_with_sender(config, None, sender) |> should.be_error
  oauth.discover_with_sender(config |> oauth.allow_localhost_http, None, sender)
  |> should.be_ok
  oauth.discover_with_sender(
    oauth.new("http://remote.example.test/mcp", "client", redirect)
      |> oauth.allow_localhost_http,
    None,
    sender,
  )
  |> should.be_error
}

fn discovered(config: oauth.Config) -> oauth.Discovery {
  oauth.discover_with_sender(config, None, fn(req) {
    case req.host {
      "mcp.example.test" ->
        Ok(json_response(resource_document(resource, [issuer])))
      _ -> Ok(json_response(authorization_document(issuer, ["S256"])))
    }
  })
  |> should.be_ok
}

fn resource_document(resource: String, issuers: List(String)) -> String {
  json.object([
    #("resource", json.string(resource)),
    #("authorization_servers", json.array(issuers, json.string)),
    #("scopes_supported", json.array(["read"], json.string)),
    #("bearer_methods_supported", json.array(["header"], json.string)),
  ])
  |> json.to_string
}

fn authorization_document(
  issuer: String,
  pkce_methods: List(String),
) -> String {
  json.object([
    #("issuer", json.string(issuer)),
    #(
      "authorization_endpoint",
      json.string(issuer <> "/authorize?audience=preserved"),
    ),
    #("token_endpoint", json.string(issuer <> "/token")),
    #("code_challenge_methods_supported", json.array(pkce_methods, json.string)),
    #(
      "token_endpoint_auth_methods_supported",
      json.array(["none", "client_secret_basic"], json.string),
    ),
    #("client_id_metadata_document_supported", json.bool(True)),
  ])
  |> json.to_string
}

fn json_response(body: String) -> response.Response(String) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(body)
}

fn token_response(
  access: String,
  refresh: option.Option(String),
  scopes: option.Option(String),
  expires: Int,
) -> response.Response(String) {
  let fields = [
    #("access_token", json.string(access)),
    #("token_type", json.string("Bearer")),
    #("expires_in", json.int(expires)),
  ]
  let fields = case refresh {
    Some(value) -> [#("refresh_token", json.string(value)), ..fields]
    None -> fields
  }
  let fields = case scopes {
    Some(value) -> [#("scope", json.string(value)), ..fields]
    None -> fields
  }
  json_response(json.object(fields) |> json.to_string)
}
