//// MCP HTTP authorization for 2026-07-28 and 2025-11-25. Applications open the authorization URL,
//// receive the redirect, and securely persist tokens; this module performs
//// discovery, PKCE request construction, code exchange, and token refresh.

import flwr_oauth2/authentication
import flwr_oauth2/authorization_grant
import flwr_oauth2/common
import flwr_oauth2/pkce
import flwr_oauth2/response as oauth_response
import flwr_oauth2/token_request
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import gleam_mcp/client/transport

pub type Error {
  InvalidConfiguration(String)
  InvalidChallenge(String)
  DiscoveryFailed(String)
  InvalidMetadata(String)
  PkceUnsupported
  StateMismatch
  IssuerMismatch
  CallbackIssuerRequired
  RedirectMismatch
  TokenRejected(status: Int, error: String)
  InvalidTokenResponse
  RefreshUnavailable
  TokenExpired
  ResourceMismatch
  HttpFailure
}

/// A sender receives credential-free discovery requests or token endpoint
/// requests. Keep redirects disabled to avoid forwarding credentials.
pub type Sender =
  fn(request.Request(String)) -> Result(response.Response(String), Error)

pub opaque type Config {
  Config(
    resource: String,
    client_id: String,
    redirect_uri: String,
    client_secret: Option(String),
    issuer: Option(String),
    credentials_issuer: Option(String),
    scopes: Option(List(String)),
    metadata_client: Bool,
    allow_loopback_http: Bool,
    timeout_ms: Int,
  )
}

pub type Challenge {
  Challenge(
    resource_metadata: Option(String),
    scopes: Option(List(String)),
    error: Option(String),
    error_description: Option(String),
  )
}

pub type ResourceMetadata {
  ResourceMetadata(
    resource: String,
    authorization_servers: List(String),
    scopes_supported: Option(List(String)),
    bearer_methods_supported: Option(List(String)),
  )
}

pub type AuthorizationServerMetadata {
  AuthorizationServerMetadata(
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    code_challenge_methods_supported: List(String),
    token_endpoint_auth_methods_supported: Option(List(String)),
    client_id_metadata_document_supported: Bool,
    authorization_response_iss_parameter_supported: Bool,
  )
}

pub type Discovery {
  Discovery(
    resource: ResourceMetadata,
    authorization_server: AuthorizationServerMetadata,
    scopes: Option(List(String)),
  )
}

pub opaque type PendingAuthorization {
  PendingAuthorization(
    config: Config,
    discovery: Discovery,
    authorization_url: String,
    state: String,
    verifier: String,
  )
}

/// Resource and issuer binding travel with tokens so a token cannot be attached
/// to another MCP endpoint through this API.
pub opaque type Tokens {
  Tokens(
    resource: String,
    issuer: String,
    client_id: String,
    access_token: String,
    refresh_token: Option(String),
    scopes: List(String),
    expires_at: Option(Int),
  )
}

pub fn new(
  resource: String,
  client_id: String,
  redirect_uri: String,
) -> Config {
  Config(
    resource,
    client_id,
    redirect_uri,
    None,
    None,
    None,
    None,
    False,
    False,
    30_000,
  )
}

pub fn with_client_secret(config: Config, secret: String) -> Config {
  Config(..config, client_secret: Some(secret))
}

/// Select an issuer and bind pre-registered credentials to it. Changing the
/// selected issuer preserves the original credential binding; use a fresh
/// configuration with the new issuer's credentials when re-registering.
pub fn with_issuer(config: Config, issuer: String) -> Config {
  let credentials_issuer = case
    config.credentials_issuer,
    config.metadata_client
  {
    None, False -> Some(issuer)
    binding, _ -> binding
  }
  Config(..config, issuer: Some(issuer), credentials_issuer: credentials_issuer)
}

/// Key persisted pre-registered credentials by this issuer. Metadata-document
/// client IDs are portable and have no registration issuer.
pub fn credentials_issuer(config: Config) -> Option(String) {
  config.credentials_issuer
}

pub fn with_scopes(config: Config, scopes: List(String)) -> Config {
  Config(..config, scopes: Some(scopes))
}

/// Use an HTTPS client ID metadata document hosted by the application.
pub fn with_client_metadata_document(config: Config) -> Config {
  Config(..config, metadata_client: True, credentials_issuer: None)
}

/// JSON to host at the HTTPS client ID URL. The document identifies a public
/// client and exactly matches the registered redirect URI used by this config.
pub fn client_metadata_document(
  config: Config,
  client_name: String,
) -> Result(String, Error) {
  use _ <- result.try(validate_config(config))
  use _ <- result.try(validate_client_metadata_url(config.client_id))
  case client_name == "" || config.client_secret != None {
    True ->
      Error(InvalidConfiguration(
        "Client metadata requires a name and a public client",
      ))
    False ->
      Ok(
        json.object([
          #("client_id", json.string(config.client_id)),
          #("client_name", json.string(client_name)),
          #("redirect_uris", json.array([config.redirect_uri], json.string)),
          #(
            "grant_types",
            json.array(["authorization_code", "refresh_token"], json.string),
          ),
          #("response_types", json.array(["code"], json.string)),
          #("token_endpoint_auth_method", json.string("none")),
        ])
        |> json.to_string,
      )
  }
}

pub fn with_timeout(config: Config, timeout_ms: Int) -> Config {
  Config(..config, timeout_ms: timeout_ms)
}

/// Explicit development opt-in. Only localhost/loopback HTTP endpoints qualify.
pub fn allow_localhost_http(config: Config) -> Config {
  Config(..config, allow_loopback_http: True)
}

pub fn authorization_url(pending: PendingAuthorization) -> String {
  pending.authorization_url
}

pub fn authorization_state(pending: PendingAuthorization) -> String {
  pending.state
}

pub fn granted_scopes(tokens: Tokens) -> List(String) {
  tokens.scopes
}

pub fn expires_at(tokens: Tokens) -> Option(Int) {
  tokens.expires_at
}

pub fn can_refresh(tokens: Tokens) -> Bool {
  tokens.refresh_token != None
}

/// Canonicalize scheme/host and the conventional root trailing slash. Reject
/// fragments, userinfo and URLs that are not absolute HTTP resources.
pub fn canonical_resource(value: String) -> Result(String, Error) {
  use parsed <- result.try(
    uri.parse(value)
    |> result.replace_error(InvalidConfiguration("Invalid resource URI")),
  )
  let scheme = option.map(parsed.scheme, string.lowercase)
  let host = option.map(parsed.host, string.lowercase)
  case scheme, host {
    Some("https"), Some(host) | Some("http"), Some(host) if host != "" -> {
      case parsed.fragment != None || parsed.userinfo != None {
        True ->
          Error(InvalidConfiguration(
            "Resource URI cannot contain a fragment or userinfo",
          ))
        False -> {
          let canonical = uri.Uri(..parsed, scheme: scheme, host: Some(host))
          use origin <- result.try(
            uri.origin(canonical)
            |> result.replace_error(InvalidConfiguration(
              "Invalid resource origin",
            )),
          )
          let path = case parsed.path {
            "/" -> ""
            _ -> parsed.path
          }
          let query = case parsed.query {
            Some(query) -> "?" <> query
            None -> ""
          }
          Ok(origin <> path <> query)
        }
      }
    }
    _, _ ->
      Error(InvalidConfiguration("Resource URI must be an absolute HTTP URI"))
  }
}

/// Parse comma-separated authentication challenges, including escaped quotes
/// and commas inside quoted values. Select the Bearer challenge.
pub fn parse_challenge(header: String) -> Result(Challenge, Error) {
  use parts <- result.try(split_challenge(
    string.to_graphemes(header),
    "",
    [],
    False,
    False,
  ))
  use parameters <- result.try(bearer_parameters(parts, False, dict.new()))
  let value = fn(key) { dict.get(parameters, key) |> option.from_result }
  Ok(Challenge(
    value("resource_metadata"),
    option.map(value("scope"), common.parse_scope),
    value("error"),
    value("error_description"),
  ))
}

pub fn challenge_from_response(
  res: response.Response(body),
) -> Result(Challenge, Error) {
  res.headers
  |> list.filter(fn(header) { string.lowercase(header.0) == "www-authenticate" })
  |> list.map(fn(header) { header.1 })
  |> string.join(", ")
  |> parse_challenge
}

fn split_challenge(
  chars: List(String),
  current: String,
  parts: List(String),
  quoted: Bool,
  escaped: Bool,
) -> Result(List(String), Error) {
  case chars {
    [] if quoted || escaped ->
      Error(InvalidChallenge("Unterminated quoted challenge parameter"))
    [] -> Ok(list.reverse([string.trim(current), ..parts]))
    [char, ..rest] ->
      case escaped, char {
        True, _ -> split_challenge(rest, current <> char, parts, quoted, False)
        False, "\\" if quoted ->
          split_challenge(rest, current <> char, parts, quoted, True)
        False, "\"" ->
          split_challenge(rest, current <> char, parts, !quoted, False)
        False, "," if !quoted ->
          split_challenge(
            rest,
            "",
            [string.trim(current), ..parts],
            False,
            False,
          )
        _, _ -> split_challenge(rest, current <> char, parts, quoted, False)
      }
  }
}

fn bearer_parameters(
  parts: List(String),
  active: Bool,
  parameters: dict.Dict(String, String),
) -> Result(dict.Dict(String, String), Error) {
  case parts {
    [] if active -> Ok(parameters)
    [] -> Error(InvalidChallenge("No Bearer challenge"))
    [part, ..rest] -> {
      let words = string.split_once(part, " ")
      let scheme = case words {
        Ok(#(scheme, _)) -> string.lowercase(scheme)
        _ -> ""
      }
      let starts_value = case words {
        Ok(#(_, value)) -> string.starts_with(string.trim_start(value), "=")
        _ -> False
      }
      let is_scheme =
        scheme != "" && !string.contains(scheme, "=") && !starts_value
      case words, scheme, is_scheme {
        Ok(#(_, parameters_part)), "bearer", _ -> {
          use parsed <- result.try(parse_parameter(parameters_part, parameters))
          bearer_parameters(rest, True, parsed)
        }
        Ok(_), _, True -> {
          case active {
            True -> Ok(parameters)
            False -> bearer_parameters(rest, False, parameters)
          }
        }
        _, _, _ ->
          case string.lowercase(part), active {
            "bearer", _ -> bearer_parameters(rest, True, parameters)
            _, True -> {
              use parsed <- result.try(parse_parameter(part, parameters))
              bearer_parameters(rest, True, parsed)
            }
            _, False -> bearer_parameters(rest, False, parameters)
          }
      }
    }
  }
}

fn parse_parameter(
  value: String,
  parameters: dict.Dict(String, String),
) -> Result(dict.Dict(String, String), Error) {
  use #(key, value) <- result.try(
    string.split_once(value, "=")
    |> result.replace_error(InvalidChallenge(
      "Invalid Bearer challenge parameter",
    )),
  )
  let key = string.lowercase(string.trim(key))
  case key == "" || dict.has_key(parameters, key) {
    True -> Error(InvalidChallenge("Duplicate or empty Bearer parameter"))
    False -> {
      use value <- result.try(unquote(string.trim(value)))
      Ok(dict.insert(parameters, key, value))
    }
  }
}

fn unquote(value: String) -> Result(String, Error) {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    True ->
      unescape(
        string.to_graphemes(value |> string.drop_start(1) |> string.drop_end(1)),
        "",
        False,
      )
    False ->
      case string.contains(value, "\"") || string.contains(value, " ") {
        True -> Error(InvalidChallenge("Invalid challenge parameter value"))
        False -> Ok(value)
      }
  }
}

fn unescape(
  chars: List(String),
  value: String,
  escaped: Bool,
) -> Result(String, Error) {
  case chars, escaped {
    [], False -> Ok(value)
    [], True -> Error(InvalidChallenge("Invalid quoted escape"))
    [char, ..rest], True -> unescape(rest, value <> char, False)
    ["\\", ..rest], False -> unescape(rest, value, True)
    ["\"", ..], False -> Error(InvalidChallenge("Unescaped quote"))
    [char, ..rest], False -> unescape(rest, value <> char, False)
  }
}

pub fn discover(
  config: Config,
  challenge: Option(Challenge),
) -> Result(Discovery, Error) {
  discover_with_sender(config, challenge, default_sender(config))
}

pub fn discover_with_sender(
  config: Config,
  challenge: Option(Challenge),
  send: Sender,
) -> Result(Discovery, Error) {
  use resource <- result.try(validate_config(config))
  let hinted = case challenge {
    Some(challenge) -> challenge.resource_metadata
    None -> None
  }
  let urls = case hinted {
    Some(url) -> [url]
    None -> resource_metadata_urls(resource)
  }
  use metadata <- result.try(fetch_resource_metadata(
    config,
    resource,
    urls,
    hinted != None,
    send,
  ))
  use issuer <- result.try(select_issuer(config, metadata.authorization_servers))
  use _ <- result.try(validate_issuer(config, issuer))
  use authorization_server <- result.try(fetch_authorization_metadata(
    config,
    issuer,
    authorization_metadata_urls(issuer),
    send,
  ))
  let scopes = case challenge, config.scopes {
    Some(Challenge(scopes: Some(scopes), ..)), _ -> Some(scopes)
    _, Some(scopes) -> Some(scopes)
    _, None -> metadata.scopes_supported
  }
  Ok(Discovery(metadata, authorization_server, scopes))
}

/// Send a credential-free request to obtain the server's authentication
/// challenge. This never sends existing access tokens to discovery endpoints.
pub fn discover_from_server(config: Config) -> Result(Discovery, Error) {
  let send = default_sender(config)
  use resource <- result.try(validate_config(config))
  use req <- result.try(
    request.to(resource)
    |> result.replace_error(InvalidConfiguration("Invalid MCP resource")),
  )
  use res <- result.try(send(
    req
    |> request.set_body("")
    |> request.set_header("accept", "application/json, text/event-stream"),
  ))
  let challenge = case res.status {
    401 | 403 -> challenge_from_response(res) |> option.from_result
    _ -> None
  }
  discover_with_sender(config, challenge, send)
}

pub fn resource_metadata_urls(resource: String) -> List(String) {
  well_known_urls(resource, "oauth-protected-resource", False)
}

pub fn authorization_metadata_urls(issuer: String) -> List(String) {
  let oauth = well_known_urls(issuer, "oauth-authorization-server", True)
  let oidc = well_known_urls(issuer, "openid-configuration", True)
  case uri.parse(issuer) {
    Error(_) -> []
    Ok(parsed) ->
      case parsed.path == "" || parsed.path == "/" {
        True -> list.append(oauth, oidc)
        False ->
          list.append(list.append(oauth, oidc), [
            issuer <> "/.well-known/openid-configuration",
          ])
      }
  }
}

fn well_known_urls(url: String, kind: String, issuer: Bool) -> List(String) {
  case uri.parse(url) {
    Error(_) -> []
    Ok(parsed) ->
      case uri.origin(parsed) {
        Error(_) -> []
        Ok(origin) -> {
          let base = origin <> "/.well-known/" <> kind
          let query = case issuer, parsed.query {
            False, Some(query) -> "?" <> query
            _, _ -> ""
          }
          case parsed.path == "" || parsed.path == "/" {
            True -> [base <> query]
            False if issuer -> [base <> parsed.path]
            False -> [base <> parsed.path <> query, base <> query]
          }
        }
      }
  }
}

fn fetch_resource_metadata(
  config: Config,
  resource: String,
  urls: List(String),
  hinted: Bool,
  send: Sender,
) -> Result(ResourceMetadata, Error) {
  case urls {
    [] -> Error(DiscoveryFailed("Protected resource metadata unavailable"))
    [url, ..rest] -> {
      use _ <- result.try(validate_endpoint(config, url))
      case fetch_json(url, send) {
        Error(DiscoveryFailed(_)) | Error(HttpFailure) ->
          fetch_resource_metadata(config, resource, rest, hinted, send)
        Error(error) -> Error(error)
        Ok(body) -> {
          use metadata <- result.try(
            json.parse(body, resource_decoder())
            |> result.replace_error(InvalidMetadata(
              "Invalid protected resource metadata",
            )),
          )
          use claimed <- result.try(canonical_resource(metadata.resource))
          // A root well-known fallback describes the origin resource. A
          // challenge URL instead describes the exact endpoint challenged.
          let expected = case hinted {
            True -> resource
            False -> metadata_resource_for_url(resource, url)
          }
          case claimed != expected || metadata.authorization_servers == [] {
            True ->
              Error(InvalidMetadata(
                "Resource mismatch or missing authorization servers",
              ))
            False ->
              case metadata.bearer_methods_supported {
                Some(methods) ->
                  case list.contains(methods, "header") {
                    False ->
                      Error(InvalidMetadata(
                        "Resource does not support Bearer headers",
                      ))
                    True -> Ok(metadata)
                  }
                None -> Ok(metadata)
              }
          }
        }
      }
    }
  }
}

fn metadata_resource_for_url(resource: String, url: String) -> String {
  let assert Ok(parsed) = uri.parse(resource)
  let assert Ok(origin) = uri.origin(parsed)
  let query = case parsed.query {
    Some(query) -> "?" <> query
    None -> ""
  }
  case url == origin <> "/.well-known/oauth-protected-resource" <> query {
    True -> origin <> query
    False -> resource
  }
}

fn valid_discovery_resource(endpoint: String, advertised: String) -> Bool {
  let assert Ok(parsed) = uri.parse(endpoint)
  let assert Ok(origin) = uri.origin(parsed)
  let query = case parsed.query {
    Some(query) -> "?" <> query
    None -> ""
  }
  advertised == endpoint || advertised == origin <> query
}

fn select_issuer(
  config: Config,
  issuers: List(String),
) -> Result(String, Error) {
  case config.issuer {
    Some(issuer) ->
      case list.contains(issuers, issuer) {
        True -> Ok(issuer)
        False ->
          Error(InvalidMetadata(
            "Configured issuer is not advertised by the resource",
          ))
      }
    None ->
      list.first(issuers)
      |> result.replace_error(InvalidMetadata("Missing authorization server"))
  }
}

fn fetch_authorization_metadata(
  config: Config,
  issuer: String,
  urls: List(String),
  send: Sender,
) -> Result(AuthorizationServerMetadata, Error) {
  use _ <- result.try(validate_issuer(config, issuer))
  case urls {
    [] -> Error(DiscoveryFailed("Authorization server metadata unavailable"))
    [url, ..rest] -> {
      use _ <- result.try(validate_endpoint(config, url))
      case fetch_json(url, send) {
        Error(DiscoveryFailed(_)) | Error(HttpFailure) ->
          fetch_authorization_metadata(config, issuer, rest, send)
        Error(error) -> Error(error)
        Ok(body) -> {
          use metadata <- result.try(
            json.parse(body, authorization_decoder())
            |> result.replace_error(InvalidMetadata(
              "Invalid authorization server metadata",
            )),
          )
          use _ <- result.try(validate_endpoint(
            config,
            metadata.authorization_endpoint,
          ))
          use _ <- result.try(validate_endpoint(config, metadata.token_endpoint))
          case metadata.issuer == issuer {
            True -> Ok(metadata)
            False ->
              Error(InvalidMetadata("Authorization server issuer mismatch"))
          }
        }
      }
    }
  }
}

fn fetch_json(url: String, send: Sender) -> Result(String, Error) {
  use req <- result.try(
    request.to(url)
    |> result.replace_error(InvalidMetadata("Invalid discovery URL")),
  )
  use res <- result.try(send(
    req
    |> request.set_body("")
    |> request.set_header("accept", "application/json")
    |> request.set_header("connection", "close"),
  ))
  case res.status {
    200 ->
      case response.get_header(res, "content-type") {
        Ok(value) ->
          case string.starts_with(string.lowercase(value), "application/json") {
            True -> Ok(res.body)
            False ->
              Error(InvalidMetadata("Metadata response must contain JSON"))
          }
        _ -> Error(InvalidMetadata("Metadata response must contain JSON"))
      }
    _ -> Error(DiscoveryFailed("Metadata endpoint unavailable"))
  }
}

pub fn begin(
  config: Config,
  discovery: Discovery,
) -> Result(PendingAuthorization, Error) {
  use resource <- result.try(validate_config(config))
  use _ <- result.try(validate_discovery(config, discovery, resource))
  use resource <- result.try(canonical_resource(discovery.resource.resource))
  let metadata = discovery.authorization_server
  use _ <- result.try(client_authentication(config, metadata))
  use _ <- result.try(
    case
      list.length(discovery.resource.authorization_servers) > 1
      && !metadata.authorization_response_iss_parameter_supported
    {
      True -> Error(CallbackIssuerRequired)
      False -> Ok(Nil)
    },
  )
  case list.contains(metadata.code_challenge_methods_supported, "S256") {
    False -> Error(PkceUnsupported)
    True -> {
      let verifier =
        crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
      let challenge = pkce.to_challenge(pkce.Verifier(verifier)).value
      let state =
        crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
      let assert Ok(endpoint) = uri.parse(metadata.authorization_endpoint)
      let assert Ok(redirect) = uri.parse(config.redirect_uri)
      let authorization =
        authorization_grant.AuthorizationCodeGrantRequest(
          endpoint,
          authorization_grant.Code,
          Some(redirect),
          common.ClientId(config.client_id),
          option.unwrap(discovery.scopes, []),
          Some(authorization_grant.State(state)),
          Some(challenge),
          Some(authorization_grant.S256),
        )
        |> authorization_grant.make_redirect_uri
      let existing =
        endpoint.query
        |> option.map(uri.parse_query)
        |> option.unwrap(Ok([]))
        |> result.unwrap([])
      let generated =
        authorization.query
        |> option.map(uri.parse_query)
        |> option.unwrap(Ok([]))
        |> result.unwrap([])
      let generated = case discovery.scopes {
        None -> list.filter(generated, fn(pair) { pair.0 != "scope" })
        Some(_) -> generated
      }
      let reserved = [
        "response_type",
        "client_id",
        "redirect_uri",
        "state",
        "scope",
        "code_challenge",
        "code_challenge_method",
        "resource",
      ]
      let query =
        list.append(
          list.filter(existing, fn(pair) { !list.contains(reserved, pair.0) }),
          [#("resource", resource), ..generated],
        )
      let url =
        uri.to_string(
          uri.Uri(..authorization, query: Some(uri.query_to_string(query))),
        )
      Ok(PendingAuthorization(config, discovery, url, state, verifier))
    }
  }
}

pub fn exchange(
  pending: PendingAuthorization,
  code: String,
  returned_state: String,
) -> Result(Tokens, Error) {
  exchange_with_sender(
    pending,
    code,
    returned_state,
    default_sender(pending.config),
  )
}

pub fn exchange_with_sender(
  pending: PendingAuthorization,
  code: String,
  returned_state: String,
  send: Sender,
) -> Result(Tokens, Error) {
  case
    pending.discovery.authorization_server.authorization_response_iss_parameter_supported
    || list.length(pending.discovery.resource.authorization_servers) > 1
  {
    True -> Error(CallbackIssuerRequired)
    False -> exchange_verified(pending, code, returned_state, send)
  }
}

/// Verify the complete authorization callback before exchanging its code.
/// `iss` is mandatory for advertised issuer support and multiple issuers.
pub fn exchange_from_redirect(
  pending: PendingAuthorization,
  callback_uri: String,
) -> Result(Tokens, Error) {
  exchange_from_redirect_with_sender(
    pending,
    callback_uri,
    default_sender(pending.config),
  )
}

pub fn exchange_from_redirect_with_sender(
  pending: PendingAuthorization,
  callback_uri: String,
  send: Sender,
) -> Result(Tokens, Error) {
  use received <- result.try(
    uri.parse(callback_uri) |> result.replace_error(RedirectMismatch),
  )
  let assert Ok(expected) = uri.parse(pending.config.redirect_uri)
  case
    uri.Uri(..received, query: expected.query) == expected
    && received.fragment == None
  {
    False -> Error(RedirectMismatch)
    True -> {
      use pairs <- result.try(
        uri.parse_query(option.unwrap(received.query, ""))
        |> result.replace_error(RedirectMismatch),
      )
      use expected_pairs <- result.try(
        uri.parse_query(option.unwrap(expected.query, ""))
        |> result.replace_error(RedirectMismatch),
      )
      let unique =
        list.all(["code", "state", "iss", "error"], fn(key) {
          list.length(list.filter(pairs, fn(pair) { pair.0 == key })) <= 1
        })
      let matches_redirect =
        list.all(expected_pairs, fn(pair) { list.contains(pairs, pair) })
      case unique && matches_redirect {
        False -> Error(RedirectMismatch)
        True -> {
          let params = dict.from_list(pairs)
          let needs_issuer =
            pending.discovery.authorization_server.authorization_response_iss_parameter_supported
            || list.length(pending.discovery.resource.authorization_servers) > 1
          use _ <- result.try(case dict.get(params, "iss") {
            Ok(issuer)
              if issuer == pending.discovery.authorization_server.issuer
            -> Ok(Nil)
            Ok(_) -> Error(IssuerMismatch)
            Error(_) if needs_issuer -> Error(CallbackIssuerRequired)
            Error(_) -> Ok(Nil)
          })
          use state <- result.try(
            dict.get(params, "state") |> result.replace_error(StateMismatch),
          )
          case dict.get(params, "error") {
            Ok(error) ->
              case
                crypto.secure_compare(
                  bit_array.from_string(state),
                  bit_array.from_string(pending.state),
                )
              {
                True -> Error(TokenRejected(400, error))
                False -> Error(StateMismatch)
              }
            Error(_) -> {
              use code <- result.try(
                dict.get(params, "code") |> result.replace_error(StateMismatch),
              )
              exchange_verified(pending, code, state, send)
            }
          }
        }
      }
    }
  }
}

fn exchange_verified(
  pending: PendingAuthorization,
  code: String,
  returned_state: String,
  send: Sender,
) -> Result(Tokens, Error) {
  case
    crypto.secure_compare(
      bit_array.from_string(pending.state),
      bit_array.from_string(returned_state),
    )
    && code != ""
  {
    False -> Error(StateMismatch)
    True -> {
      let config = pending.config
      use resource <- result.try(validate_config(config))
      use _ <- result.try(validate_discovery(
        config,
        pending.discovery,
        resource,
      ))
      use resource <- result.try(canonical_resource(
        pending.discovery.resource.resource,
      ))
      let assert Ok(endpoint) =
        uri.parse(pending.discovery.authorization_server.token_endpoint)
      let assert Ok(redirect) = uri.parse(config.redirect_uri)
      use auth <- result.try(client_authentication(
        config,
        pending.discovery.authorization_server,
      ))
      use req <- result.try(
        token_request.to_http_request_with_modifiers(
          token_request.AuthorizationCodeGrantTokenRequest(
            endpoint,
            auth,
            Some(redirect),
            code,
          ),
          [
            fn(req) {
              Ok(
                request.set_body(req, [
                  #("code_verifier", pending.verifier),
                  #("resource", resource),
                  ..req.body
                ]),
              )
            },
          ],
        )
        |> result.replace_error(InvalidConfiguration(
          "Unable to build token request",
        )),
      )
      use res <- result.try(send(
        req |> request.set_header("connection", "close"),
      ))
      parse_tokens(
        config,
        pending.discovery,
        res,
        None,
        option.unwrap(pending.discovery.scopes, []),
      )
    }
  }
}

pub fn refresh(
  config: Config,
  discovery: Discovery,
  tokens: Tokens,
) -> Result(Tokens, Error) {
  refresh_with_sender(config, discovery, tokens, default_sender(config))
}

pub fn refresh_with_sender(
  config: Config,
  discovery: Discovery,
  tokens: Tokens,
  send: Sender,
) -> Result(Tokens, Error) {
  use resource <- result.try(validate_config(config))
  use _ <- result.try(validate_discovery(config, discovery, resource))
  case
    tokens.resource == resource
    && tokens.issuer == discovery.authorization_server.issuer
    && tokens.client_id == config.client_id
  {
    False -> Error(ResourceMismatch)
    True -> {
      use refresh_token <- result.try(option.to_result(
        tokens.refresh_token,
        RefreshUnavailable,
      ))
      use auth <- result.try(client_authentication(
        config,
        discovery.authorization_server,
      ))
      let assert Ok(endpoint) =
        uri.parse(discovery.authorization_server.token_endpoint)
      use audience <- result.try(canonical_resource(discovery.resource.resource))
      use req <- result.try(
        token_request.to_http_request_with_modifiers(
          token_request.RefreshTokenGrantRequest(
            endpoint,
            auth,
            refresh_token,
            tokens.scopes,
          ),
          [
            fn(req) {
              Ok(request.set_body(req, [#("resource", audience), ..req.body]))
            },
          ],
        )
        |> result.replace_error(InvalidConfiguration(
          "Unable to build refresh request",
        )),
      )
      use res <- result.try(send(
        req |> request.set_header("connection", "close"),
      ))
      parse_tokens(config, discovery, res, tokens.refresh_token, tokens.scopes)
    }
  }
}

/// Replace previous authorization headers. The transport applies these headers
/// to every POST, GET/reconnect and DELETE belonging to this HTTP config.
pub fn authorize_http(
  config: transport.HttpConfig,
  tokens: Tokens,
) -> Result(transport.HttpConfig, Error) {
  use resource <- result.try(canonical_resource(config.base_url))
  let now = unix_seconds()
  case resource == tokens.resource {
    False -> Error(ResourceMismatch)
    True ->
      case tokens.expires_at {
        Some(expiry) if now >= expiry -> Error(TokenExpired)
        _ ->
          Ok(
            transport.HttpConfig(..config, headers: [
              #("authorization", "Bearer " <> tokens.access_token),
              ..list.filter(config.headers, fn(pair) {
                string.lowercase(pair.0) != "authorization"
              })
            ]),
          )
      }
  }
}

fn parse_tokens(
  config: Config,
  discovery: Discovery,
  res: response.Response(String),
  previous_refresh: Option(String),
  previous_scopes: List(String),
) -> Result(Tokens, Error) {
  use token <- result.try(
    oauth_response.parse_token_response(res)
    |> result.map_error(fn(error) {
      case error {
        oauth_response.ErrorResponse(status, error, _, _) ->
          TokenRejected(status, error)
        oauth_response.ParseError(_) -> InvalidTokenResponse
      }
    }),
  )
  case
    string.lowercase(token.token_type) != "bearer"
    || token.access_token == ""
    || string.contains(token.access_token, "\r")
    || string.contains(token.access_token, "\n")
  {
    True -> Error(InvalidTokenResponse)
    False -> {
      use resource <- result.try(canonical_resource(config.resource))
      let expiry = case token.expires_in {
        Some(seconds) if seconds >= 0 -> Some(unix_seconds() + seconds)
        None -> None
        _ -> Some(unix_seconds())
      }
      let scopes = case
        json.parse(res.body, {
          use scope <- decode.optional_field(
            "scope",
            None,
            decode.optional(decode.string),
          )
          decode.success(scope)
        })
      {
        Ok(Some(_)) -> token.scope
        _ -> previous_scopes
      }
      let refresh = case token.refresh_token {
        Some(value) -> Some(value)
        None -> previous_refresh
      }
      Ok(Tokens(
        resource,
        discovery.authorization_server.issuer,
        config.client_id,
        token.access_token,
        refresh,
        scopes,
        expiry,
      ))
    }
  }
}

fn client_authentication(
  config: Config,
  metadata: AuthorizationServerMetadata,
) -> Result(authentication.ClientAuthentication, Error) {
  let client_id = common.ClientId(config.client_id)
  let methods = metadata.token_endpoint_auth_methods_supported
  case config.client_secret {
    None ->
      case
        option.map(methods, fn(methods) { list.contains(methods, "none") })
        |> option.unwrap(False)
      {
        False ->
          Error(InvalidMetadata(
            "Authorization server does not support public clients",
          ))
        True -> Ok(authentication.PublicAuthentication(client_id))
      }
    Some(secret) ->
      case
        option.map(methods, fn(methods) {
          list.contains(methods, "client_secret_basic")
        })
        |> option.unwrap(True)
      {
        False ->
          case
            option.map(methods, fn(methods) {
              list.contains(methods, "client_secret_post")
            })
            |> option.unwrap(False)
          {
            True ->
              Ok(authentication.ClientSecretPost(
                client_id,
                common.Secret(secret),
              ))
            False ->
              Error(InvalidMetadata(
                "Unsupported token endpoint authentication method",
              ))
          }
        True ->
          Ok(authentication.ClientSecretBasic(client_id, common.Secret(secret)))
      }
  }
}

fn validate_config(config: Config) -> Result(String, Error) {
  use resource <- result.try(canonical_resource(config.resource))
  use _ <- result.try(validate_endpoint(config, resource))
  use redirect <- result.try(
    uri.parse(config.redirect_uri)
    |> result.replace_error(InvalidConfiguration("Invalid redirect URI")),
  )
  let secure_redirect =
    redirect.scheme == Some("https")
    || redirect.scheme == Some("http")
    && is_loopback(redirect.host)
  case
    config.client_id == ""
    || config.timeout_ms <= 0
    || !secure_redirect
    || redirect.fragment != None
    || redirect.userinfo != None
    || redirect.host == None
  {
    True ->
      Error(InvalidConfiguration("Invalid client ID, timeout or redirect URI"))
    False -> Ok(resource)
  }
}

fn validate_endpoint(config: Config, url: String) -> Result(Nil, Error) {
  use parsed <- result.try(
    uri.parse(url)
    |> result.replace_error(InvalidMetadata("Invalid OAuth endpoint URI")),
  )
  let secure =
    parsed.scheme == Some("https")
    || config.allow_loopback_http
    && parsed.scheme == Some("http")
    && is_loopback(parsed.host)
  case
    secure
    && parsed.host != None
    && parsed.fragment == None
    && parsed.userinfo == None
  {
    True -> Ok(Nil)
    False -> Error(InvalidMetadata("OAuth endpoints require HTTPS"))
  }
}

fn is_loopback(host: Option(String)) -> Bool {
  case host {
    Some("localhost") | Some("127.0.0.1") | Some("::1") | Some("[::1]") -> True
    _ -> False
  }
}

fn validate_issuer(config: Config, issuer: String) -> Result(Nil, Error) {
  use _ <- result.try(validate_endpoint(config, issuer))
  let assert Ok(parsed) = uri.parse(issuer)
  case parsed.query == None {
    True -> Ok(Nil)
    False ->
      Error(InvalidMetadata(
        "Authorization server issuer cannot contain a query",
      ))
  }
}

fn validate_discovery(
  config: Config,
  discovery: Discovery,
  resource: String,
) -> Result(Nil, Error) {
  use advertised <- result.try(canonical_resource(discovery.resource.resource))
  use _ <- result.try(validate_issuer(
    config,
    discovery.authorization_server.issuer,
  ))
  use _ <- result.try(validate_endpoint(
    config,
    discovery.authorization_server.authorization_endpoint,
  ))
  use _ <- result.try(validate_endpoint(
    config,
    discovery.authorization_server.token_endpoint,
  ))
  let wrong_issuer =
    option.map(config.issuer, fn(issuer) {
      issuer != discovery.authorization_server.issuer
    })
    |> option.unwrap(False)
  case
    !valid_discovery_resource(resource, advertised)
    || wrong_issuer
    || !list.contains(
      discovery.resource.authorization_servers,
      discovery.authorization_server.issuer,
    )
  {
    True -> Error(ResourceMismatch)
    False ->
      case config.metadata_client {
        False ->
          case config.credentials_issuer {
            Some(issuer) if issuer == discovery.authorization_server.issuer ->
              Ok(Nil)
            Some(_) -> Error(IssuerMismatch)
            None ->
              Error(InvalidConfiguration(
                "Pre-registered credentials require their issuer; use with_issuer",
              ))
          }
        True -> {
          use _ <- result.try(validate_client_metadata_url(config.client_id))
          case
            config.client_secret == None
            && discovery.authorization_server.client_id_metadata_document_supported
          {
            True -> Ok(Nil)
            False ->
              Error(InvalidConfiguration(
                "Unsupported or invalid client metadata document URL",
              ))
          }
        }
      }
  }
}

fn validate_client_metadata_url(value: String) -> Result(Nil, Error) {
  use parsed <- result.try(
    uri.parse(value)
    |> result.replace_error(InvalidConfiguration(
      "Invalid client metadata document URL",
    )),
  )
  case
    parsed.scheme == Some("https")
    && parsed.host != None
    && parsed.host != Some("")
    && parsed.path != ""
    && parsed.path != "/"
    && parsed.fragment == None
    && parsed.userinfo == None
    && !string.contains(value, "\r")
    && !string.contains(value, "\n")
  {
    True -> Ok(Nil)
    False ->
      Error(InvalidConfiguration(
        "Client metadata URL requires HTTPS and a path",
      ))
  }
}

fn default_sender(config: Config) -> Sender {
  fn(req) {
    httpc.dispatch(httpc.configure() |> httpc.timeout(config.timeout_ms), req)
    |> result.replace_error(HttpFailure)
  }
}

fn unix_seconds() -> Int {
  timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time()).0
}

fn resource_decoder() -> decode.Decoder(ResourceMetadata) {
  use resource <- decode.field("resource", decode.string)
  use issuers <- decode.field(
    "authorization_servers",
    decode.list(decode.string),
  )
  use scopes <- decode.optional_field(
    "scopes_supported",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use methods <- decode.optional_field(
    "bearer_methods_supported",
    None,
    decode.optional(decode.list(decode.string)),
  )
  decode.success(ResourceMetadata(resource, issuers, scopes, methods))
}

fn authorization_decoder() -> decode.Decoder(AuthorizationServerMetadata) {
  use issuer <- decode.field("issuer", decode.string)
  use authorization <- decode.field("authorization_endpoint", decode.string)
  use token <- decode.field("token_endpoint", decode.string)
  use pkce <- decode.optional_field(
    "code_challenge_methods_supported",
    [],
    decode.list(decode.string),
  )
  use methods <- decode.optional_field(
    "token_endpoint_auth_methods_supported",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use metadata_client <- decode.optional_field(
    "client_id_metadata_document_supported",
    False,
    decode.bool,
  )
  use response_issuer <- decode.optional_field(
    "authorization_response_iss_parameter_supported",
    False,
    decode.bool,
  )
  decode.success(AuthorizationServerMetadata(
    issuer,
    authorization,
    token,
    pkce,
    methods,
    metadata_client,
    response_issuer,
  ))
}
