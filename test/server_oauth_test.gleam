import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleam_mcp/examples/example_server
import gleam_mcp/server
import gleam_mcp/server/oauth
import gleeunit/should
import server_test_support

const resource = "https://mcp.example.com/public/mcp"

const issuer = "https://auth.example.com/tenant"

pub fn main() {
  configuration_requires_https_issuers_and_safe_scopes_test()
  protected_resource_metadata_identifies_the_exact_resource_test()
  bearer_tokens_require_verified_issuer_audience_expiry_and_scopes_test()
}

pub fn configuration_requires_https_issuers_and_safe_scopes_test() {
  oauth.new("http://mcp.example.com", [issuer], [], verified)
  |> should.be_error
  oauth.new(resource, [], [], verified) |> should.be_error
  oauth.new(resource, ["http://auth.example.com"], [], verified)
  |> should.be_error
  oauth.new(resource, [issuer <> "?tenant=other"], [], verified)
  |> should.be_error
  oauth.new(resource <> "#fragment", [issuer], [], verified)
  |> should.be_error
  oauth.new(resource, [issuer], ["read\"\r\nInjected: yes"], verified)
  |> should.be_error
}

pub fn protected_resource_metadata_identifies_the_exact_resource_test() {
  let config = configured()
  should.equal(
    oauth.metadata_url(config),
    "https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp",
  )
  should.be_true(oauth.is_metadata_path(
    config,
    "/.well-known/oauth-protected-resource/public/mcp",
  ))
  let fields =
    json.parse(oauth.metadata(config), {
      use resource <- decode.field("resource", decode.string)
      use issuers <- decode.field(
        "authorization_servers",
        decode.list(decode.string),
      )
      use scopes <- decode.field("scopes_supported", decode.list(decode.string))
      decode.success(#(resource, issuers, scopes))
    })
    |> should.be_ok
  should.equal(fields, #(resource, [issuer], ["tools:read"]))
}

pub fn bearer_tokens_require_verified_issuer_audience_expiry_and_scopes_test() {
  let config = configured()
  should.equal(oauth.authorize(config, None), Error(oauth.MissingToken))
  should.equal(oauth.authorize(config, Some("Bearer valid")), Ok("alice"))
  should.equal(oauth.authorize(config, Some("bEaReR valid")), Ok("alice"))
  list.each(
    ["unverified", "wrong-audience", "expired", "wrong-issuer"],
    fn(token) {
      should.equal(
        oauth.authorize(config, Some("Bearer " <> token)),
        Error(oauth.InvalidToken),
      )
    },
  )
  should.equal(
    oauth.authorize(config, Some("Bearer insufficient")),
    Error(oauth.InsufficientScope(["tools:read"])),
  )
  list.each(
    ["Basic valid", "Bearer =", "Bearer valid\r\n", "Bearer a b"],
    fn(header) {
      should.equal(
        oauth.authorize(config, Some(header)),
        Error(oauth.MalformedAuthorization),
      )
    },
  )
}

pub fn http_metadata_challenges_and_scope_errors_are_exposed_test() {
  let app =
    example_server.sample_server()
    |> server.with_oauth_authorization(configured())
  let url = server_test_support.start_http_server_with_server(app)
  let metadata_url =
    string.replace(
      url,
      "/mcp",
      "/.well-known/oauth-protected-resource/public/mcp",
    )
  let metadata = raw(metadata_url, http.Get, [], "")
  should.equal(metadata.status, 200)
  should.be_true(string.contains(metadata.body, resource))
  let unauthorized = raw(url, http.Post, [], "{")
  should.equal(unauthorized.status, 401)
  let challenge =
    response.get_header(unauthorized, "www-authenticate") |> should.be_ok
  should.be_true(string.contains(
    challenge,
    "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource/public/mcp\"",
  ))
  should.be_true(string.contains(challenge, "scope=\"tools:read\""))
  list.each(
    ["unverified", "wrong-audience", "expired", "wrong-issuer"],
    fn(token) {
      let rejected =
        raw(url, http.Post, [#("authorization", "Bearer " <> token)], "{")
      should.equal(rejected.status, 401)
      let challenge =
        response.get_header(rejected, "www-authenticate") |> should.be_ok
      should.be_true(string.contains(challenge, "error=\"invalid_token\""))
    },
  )
  let insufficient =
    raw(url, http.Post, [#("authorization", "Bearer insufficient")], "{")
  should.equal(insufficient.status, 403)
  let challenge =
    response.get_header(insufficient, "www-authenticate") |> should.be_ok
  should.be_true(string.contains(challenge, "error=\"insufficient_scope\""))
  should.be_true(string.contains(challenge, "scope=\"tools:read\""))
  let malformed =
    raw(
      url <> "?access_token=valid",
      http.Post,
      [#("authorization", "Bearer valid")],
      "{",
    )
  should.equal(malformed.status, 400)
  let initialize =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"oauth-test\",\"version\":\"1\"}}}"
  let initialized =
    raw(url, http.Post, [#("authorization", "Bearer valid")], initialize)
  should.equal(initialized.status, 200)
  let session =
    response.get_header(initialized, "mcp-session-id") |> should.be_ok
  let foreign =
    raw(
      url,
      http.Post,
      [
        #("authorization", "Bearer bob"),
        #("mcp-session-id", session),
        #("mcp-protocol-version", "2025-11-25"),
      ],
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
    )
  should.equal(foreign.status, 404)
}

fn configured() -> oauth.Config {
  oauth.new(resource, [issuer], ["tools:read"], verified) |> should.be_ok
}

fn verified(token: String) -> Result(oauth.VerifiedToken, Nil) {
  let #(now, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let claims =
    oauth.VerifiedToken("alice", issuer, [resource], now + 3600, ["tools:read"])
  case token {
    "valid" -> Ok(claims)
    "bob" -> Ok(oauth.VerifiedToken(..claims, principal: "bob"))
    "wrong-audience" ->
      Ok(
        oauth.VerifiedToken(..claims, audiences: ["https://other.example.com"]),
      )
    "wrong-issuer" ->
      Ok(oauth.VerifiedToken(..claims, issuer: "https://evil.example.com"))
    "expired" -> Ok(oauth.VerifiedToken(..claims, expires_at: now - 1))
    "insufficient" -> Ok(oauth.VerifiedToken(..claims, scopes: []))
    _ -> Error(Nil)
  }
}

fn raw(
  url: String,
  method: http.Method,
  headers: List(#(String, String)),
  body: String,
) -> response.Response(String) {
  let req =
    request.to(url)
    |> should.be_ok
    |> request.set_method(method)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  httpc.configure()
  |> httpc.timeout(2000)
  |> httpc.dispatch(req)
  |> should.be_ok
}
