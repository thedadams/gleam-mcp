//// OAuth protected-resource support for HTTP servers. Token verification is
//// application supplied so JWT and opaque tokens can use their issuer's own
//// signature verification or introspection mechanism.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri

/// Claims returned only after the application has verified the token's
/// authenticity, signature/introspection result, and access-token type.
/// The SDK additionally checks issuer, audience, expiry, and required scopes.
pub type VerifiedToken {
  VerifiedToken(
    principal: String,
    issuer: String,
    audiences: List(String),
    expires_at: Int,
    scopes: List(String),
  )
}

pub type AuthorizationError {
  MissingToken
  InvalidToken
  MalformedAuthorization
  InsufficientScope(required: List(String))
}

pub opaque type Config {
  Config(
    resource: String,
    issuers: List(String),
    scopes: List(String),
    verify: fn(String) -> Result(VerifiedToken, Nil),
    metadata_url: String,
    metadata_path: String,
  )
}

/// Configure a public HTTPS resource identifier and its trusted issuers. The
/// verifier must reject tokens whose authenticity or access-token type cannot
/// be established; decoding unverified JWT claims is insufficient.
pub fn new(
  resource: String,
  authorization_servers: List(String),
  required_scopes: List(String),
  verify: fn(String) -> Result(VerifiedToken, Nil),
) -> Result(Config, String) {
  use parsed <- result.try(https_uri(resource))
  case authorization_servers {
    [] -> Error("OAuth requires at least one authorization server")
    _ -> {
      use issuers <- result.try(list.try_map(authorization_servers, https_uri))
      use _ <- result.try(
        case list.all(issuers, fn(issuer) { issuer.query == None }) {
          True -> Ok(Nil)
          False -> Error("OAuth issuer URLs cannot contain a query")
        },
      )
      case list.all(required_scopes, valid_scope) {
        False -> Error("Invalid OAuth scope")
        True -> {
          let path = case parsed.path {
            "/" -> ""
            path -> path
          }
          let metadata_path = "/.well-known/oauth-protected-resource" <> path
          Ok(Config(
            resource,
            authorization_servers,
            required_scopes,
            verify,
            uri.to_string(uri.Uri(..parsed, path: metadata_path)),
            metadata_path,
          ))
        }
      }
    }
  }
}

pub fn resource(config: Config) -> String {
  config.resource
}

pub fn metadata_url(config: Config) -> String {
  config.metadata_url
}

pub fn is_metadata_path(config: Config, path: String) -> Bool {
  path == config.metadata_path
}

/// RFC 9728 metadata; the resource field exactly matches the configured
/// canonical identifier. Empty optional scope sets are omitted.
pub fn metadata(config: Config) -> String {
  let fields = [
    #("resource", json.string(config.resource)),
    #("authorization_servers", json.array(config.issuers, json.string)),
    #("bearer_methods_supported", json.array(["header"], json.string)),
  ]
  let fields = case config.scopes {
    [] -> fields
    scopes -> [#("scopes_supported", json.array(scopes, json.string)), ..fields]
  }
  json.object(fields) |> json.to_string
}

pub fn authorize(
  config: Config,
  authorization: Option(String),
) -> Result(String, AuthorizationError) {
  case authorization {
    None -> Error(MissingToken)
    Some(header) -> {
      use token <- result.try(bearer_token(header))
      use claims <- result.try(
        config.verify(token)
        |> result.map_error(fn(_) { InvalidToken }),
      )
      let #(now, _) =
        timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
      case
        claims.principal != ""
        && list.contains(config.issuers, claims.issuer)
        && list.contains(claims.audiences, config.resource)
        && claims.expires_at > now
      {
        False -> Error(InvalidToken)
        True ->
          case list.all(config.scopes, list.contains(claims.scopes, _)) {
            True -> Ok(claims.principal)
            False -> Error(InsufficientScope(config.scopes))
          }
      }
    }
  }
}

pub fn error_status(error: AuthorizationError) -> Int {
  case error {
    MissingToken | InvalidToken -> 401
    MalformedAuthorization -> 400
    InsufficientScope(_) -> 403
  }
}

/// Bearer challenges include discovery and authoritative scope guidance.
pub fn challenge(config: Config, error: AuthorizationError) -> String {
  let error_parameter = case error {
    MissingToken -> ""
    InvalidToken -> ", error=\"invalid_token\""
    MalformedAuthorization -> ", error=\"invalid_request\""
    InsufficientScope(_) -> ", error=\"insufficient_scope\""
  }
  let scopes = case error {
    InsufficientScope(scopes) -> scopes
    _ -> config.scopes
  }
  let scope_parameter = case scopes {
    [] -> ""
    scopes -> ", scope=\"" <> string.join(scopes, " ") <> "\""
  }
  "Bearer resource_metadata=\""
  <> quoted(config.metadata_url)
  <> "\""
  <> error_parameter
  <> scope_parameter
}

fn https_uri(value: String) -> Result(uri.Uri, String) {
  use parsed <- result.try(
    uri.parse(value)
    |> result.map_error(fn(_) { "Invalid OAuth URL" }),
  )
  case
    parsed.scheme == Some("https")
    && parsed.host != None
    && parsed.host != Some("")
    && parsed.userinfo == None
    && parsed.fragment == None
    && !string.contains(value, "\r")
    && !string.contains(value, "\n")
  {
    True -> Ok(parsed)
    False -> Error("OAuth URLs must use HTTPS without credentials or fragments")
  }
}

fn valid_scope(scope: String) -> Bool {
  scope != "" && valid_scope_bytes(<<scope:utf8>>)
}

fn valid_scope_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>>
      if byte == 0x21
      || { byte >= 0x23 && byte <= 0x5B }
      || { byte >= 0x5D && byte <= 0x7E }
    -> valid_scope_bytes(rest)
    _ -> False
  }
}

fn bearer_token(header: String) -> Result(String, AuthorizationError) {
  case string.split(header, " ") |> list.filter(fn(part) { part != "" }) {
    [scheme, token] ->
      case string.lowercase(scheme) == "bearer" && valid_token(<<token:utf8>>) {
        True -> Ok(token)
        False -> Error(MalformedAuthorization)
      }
    _ -> Error(MalformedAuthorization)
  }
}

fn valid_token(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> False
    <<0x3D, _:bytes>> -> False
    _ -> valid_token_bytes(bytes, False)
  }
}

fn valid_token_bytes(bytes: BitArray, padding: Bool) -> Bool {
  case bytes {
    <<>> -> True
    <<0x3D, rest:bytes>> -> valid_token_bytes(rest, True)
    <<byte, rest:bytes>> if !padding ->
      case
        { byte >= 0x41 && byte <= 0x5A }
        || { byte >= 0x61 && byte <= 0x7A }
        || { byte >= 0x30 && byte <= 0x39 }
        || list.contains([0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F], byte)
      {
        True -> valid_token_bytes(rest, False)
        False -> False
      }
    _ -> False
  }
}

fn quoted(value: String) -> String {
  value |> string.replace("\\", "\\\\") |> string.replace("\"", "\\\"")
}
