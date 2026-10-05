import gleam/http/request
import gleam/json
import gleam/option.{None, Some}
import gleam/uri
import gleam_mcp/client/oauth
import gleeunit/should

const resource = "https://mcp.example.test/mcp"

const issuer = "https://auth.example.test"

const other_issuer = "https://other-auth.example.test"

const redirect = "http://127.0.0.1:8080/callback"

pub fn pre_registered_credentials_require_an_issuer_test() {
  let config = oauth.new(resource, "registered-client", redirect)
  let discovery = discovery(issuer)
  oauth.begin(config, discovery) |> should.be_error
  let bound = config |> oauth.with_issuer(issuer)
  should.equal(oauth.credentials_issuer(bound), Some(issuer))
  oauth.begin(bound, discovery) |> should.be_ok
}

pub fn changing_issuer_does_not_rebind_registered_credentials_test() {
  let config =
    oauth.new(resource, "registered-client", redirect)
    |> oauth.with_issuer(issuer)
    |> oauth.with_client_secret("issuer-specific-secret")
    |> oauth.with_issuer(other_issuer)
  should.equal(oauth.credentials_issuer(config), Some(issuer))
  should.equal(
    oauth.begin(config, discovery(other_issuer)),
    Error(oauth.IssuerMismatch),
  )
}

pub fn metadata_client_ids_are_portable_across_issuers_test() {
  let config =
    oauth.new(resource, "https://app.example.test/client.json", redirect)
    |> oauth.with_client_metadata_document
  should.equal(oauth.credentials_issuer(config), None)
  oauth.begin(config, discovery(issuer)) |> should.be_ok
  oauth.begin(config, discovery(other_issuer)) |> should.be_ok
  config
  |> oauth.with_client_secret("not-portable")
  |> oauth.begin(discovery(issuer))
  |> should.be_error
}

pub fn metadata_document_has_matching_identity_and_redirect_test() {
  let client_id = "https://app.example.test/client.json"
  let config =
    oauth.new(resource, client_id, redirect)
    |> oauth.with_client_metadata_document
  let actual =
    oauth.client_metadata_document(config, "Example app") |> should.be_ok
  let expected =
    json.object([
      #("client_id", json.string(client_id)),
      #("client_name", json.string("Example app")),
      #("redirect_uris", json.array([redirect], json.string)),
      #(
        "grant_types",
        json.array(["authorization_code", "refresh_token"], json.string),
      ),
      #("response_types", json.array(["code"], json.string)),
      #("token_endpoint_auth_method", json.string("none")),
    ])
    |> json.to_string
  should.equal(actual, expected)
  oauth.client_metadata_document(config, "") |> should.be_error
  oauth.client_metadata_document(
    oauth.new(resource, "https://app.example.test/", redirect),
    "App",
  )
  |> should.be_error
  oauth.client_metadata_document(
    oauth.new(resource, "http://app.example.test/client.json", redirect),
    "App",
  )
  |> should.be_error
}

pub fn present_callback_issuer_is_checked_without_advertised_issuer_support_test() {
  let config =
    oauth.new(resource, "registered-client", redirect)
    |> oauth.with_issuer(issuer)
  let pending = oauth.begin(config, discovery(issuer)) |> should.be_ok
  let callback =
    redirect
    <> "?code=code&state="
    <> oauth.authorization_state(pending)
    <> "&iss="
    <> uri.percent_encode(other_issuer)
  let send = fn(_: request.Request(String)) {
    should.fail()
    Error(oauth.HttpFailure)
  }
  should.equal(
    oauth.exchange_from_redirect_with_sender(pending, callback, send),
    Error(oauth.IssuerMismatch),
  )
}

fn discovery(issuer: String) -> oauth.Discovery {
  oauth.Discovery(
    oauth.ResourceMetadata(resource, [issuer], None, Some(["header"])),
    oauth.AuthorizationServerMetadata(
      issuer,
      issuer <> "/authorize",
      issuer <> "/token",
      ["S256"],
      Some(["none", "client_secret_basic"]),
      True,
      False,
    ),
    None,
  )
}
