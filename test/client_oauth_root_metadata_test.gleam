import gleam/dict
import gleam/http/response
import gleam/json
import gleam/option.{None, Some}
import gleam/uri
import gleam_mcp/client/oauth
import gleam_mcp/client/transport
import gleeunit/should

const endpoint = "https://mcp.example.test/mcp"

const audience = "https://mcp.example.test"

const issuer = "https://auth.example.test"

const redirect = "http://localhost:3000/callback"

pub fn main() {
  root_well_known_resource_is_used_as_oauth_audience_test()
  challenge_metadata_requires_exact_challenged_resource_test()
  root_fallback_does_not_accept_a_different_resource_test()
}

pub fn root_well_known_resource_is_used_as_oauth_audience_test() {
  let config =
    oauth.new(endpoint, "client", redirect) |> oauth.with_issuer(issuer)
  let discovery =
    oauth.discover_with_sender(config, None, fn(req) {
      case req.host, req.path {
        "mcp.example.test", "/.well-known/oauth-protected-resource/mcp" ->
          Ok(response.new(404) |> response.set_body(""))
        "mcp.example.test", "/.well-known/oauth-protected-resource" ->
          Ok(resource_metadata(audience))
        "auth.example.test", "/.well-known/oauth-authorization-server" ->
          Ok(authorization_metadata())
        _, _ -> panic as "Unexpected discovery request"
      }
    })
    |> should.be_ok
  let pending = oauth.begin(config, discovery) |> should.be_ok
  let parsed = uri.parse(oauth.authorization_url(pending)) |> should.be_ok
  let query =
    uri.parse_query(parsed.query |> should.be_some)
    |> should.be_ok
    |> dict.from_list
  should.equal(dict.get(query, "resource"), Ok(audience))
  let tokens =
    oauth.exchange_with_sender(
      pending,
      "code",
      oauth.authorization_state(pending),
      fn(req) {
        let form = uri.parse_query(req.body) |> should.be_ok |> dict.from_list
        should.equal(dict.get(form, "resource"), Ok(audience))
        Ok(
          response.new(200)
          |> response.set_body(
            "{\"access_token\":\"bound-token\",\"token_type\":\"Bearer\"}",
          ),
        )
      },
    )
    |> should.be_ok
  oauth.authorize_http(transport.HttpConfig(endpoint, [], None), tokens)
  |> should.be_ok
  oauth.authorize_http(transport.HttpConfig(audience, [], None), tokens)
  |> should.be_error
  oauth.authorize_http(
    transport.HttpConfig(audience <> "/other", [], None),
    tokens,
  )
  |> should.be_error
}

pub fn challenge_metadata_requires_exact_challenged_resource_test() {
  let config =
    oauth.new(endpoint, "client", redirect) |> oauth.with_issuer(issuer)
  let challenge =
    oauth.Challenge(
      Some(audience <> "/.well-known/oauth-protected-resource"),
      None,
      None,
      None,
    )
  oauth.discover_with_sender(config, Some(challenge), fn(_req) {
    Ok(resource_metadata(audience))
  })
  |> should.be_error
}

pub fn root_fallback_does_not_accept_a_different_resource_test() {
  let config =
    oauth.new(endpoint, "client", redirect) |> oauth.with_issuer(issuer)
  oauth.discover_with_sender(config, None, fn(req) {
    case req.path {
      "/.well-known/oauth-protected-resource/mcp" ->
        Ok(response.new(404) |> response.set_body(""))
      _ -> Ok(resource_metadata("https://attacker.example.test"))
    }
  })
  |> should.be_error
}

fn resource_metadata(resource: String) -> response.Response(String) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    json.object([
      #("resource", json.string(resource)),
      #("authorization_servers", json.array([issuer], json.string)),
    ])
    |> json.to_string,
  )
}

fn authorization_metadata() -> response.Response(String) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    json.object([
      #("issuer", json.string(issuer)),
      #("authorization_endpoint", json.string(issuer <> "/authorize")),
      #("token_endpoint", json.string(issuer <> "/token")),
      #("code_challenge_methods_supported", json.array(["S256"], json.string)),
      #(
        "token_endpoint_auth_methods_supported",
        json.array(["none"], json.string),
      ),
    ])
    |> json.to_string,
  )
}
