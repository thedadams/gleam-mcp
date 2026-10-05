import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/examples/example_server
import gleam_mcp/server
import gleeunit/should
import server_test_support

const initialize_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"wire-test\",\"version\":\"1\"}}}"

pub fn origin_and_version_headers_are_checked_before_dispatch_test() {
  let url = server_test_support.start_http_server()
  raw(
    url,
    http.Post,
    [#("origin", "https://attacker.example")],
    initialize_body,
  ).status
  |> should.equal(403)
  raw(url, http.Post, [#("mcp-protocol-version", "future")], initialize_body).status
  |> should.equal(400)
  raw(url, http.Post, [], initialize_body).status |> should.equal(200)
}

pub fn explicit_browser_origin_is_accepted_test() {
  let url =
    server_test_support.start_http_server_with_server(
      example_server.sample_server()
      |> server.with_allowed_origins(["https://app.example"]),
    )
  raw(url, http.Post, [#("origin", "https://app.example")], initialize_body).status
  |> should.equal(200)
}

pub fn origin_validation_does_not_trust_a_spoofed_host_test() {
  let url = server_test_support.start_http_server()
  raw(
    url,
    http.Post,
    [#("origin", "http://attacker.example"), #("host", "attacker.example")],
    initialize_body,
  ).status
  |> should.equal(403)
}

pub fn malformed_requests_return_jsonrpc_errors_and_notifications_stay_silent_test() {
  let url = server_test_support.start_http_server()
  let parse_error = raw(url, http.Post, [], "{")
  parse_error.status |> should.equal(400)
  string.contains(parse_error.body, "-32700") |> should.be_true
  string.contains(parse_error.body, "\"id\":null") |> should.be_true
  let invalid =
    raw(
      url,
      http.Post,
      [],
      "{\"jsonrpc\":\"1.0\",\"id\":23,\"method\":\"ping\"}",
    )
  string.contains(invalid.body, "-32600") |> should.be_true
  string.contains(invalid.body, "\"id\":23") |> should.be_true
  let initialized = raw(url, http.Post, [], initialize_body)
  let assert Ok(id) = response.get_header(initialized, "mcp-session-id")
  let notification =
    raw(
      url,
      http.Post,
      [#("mcp-session-id", id), #("mcp-protocol-version", "2025-11-25")],
      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":[]}",
    )
  notification.status |> should.equal(400)
  string.contains(notification.body, "\"jsonrpc\"") |> should.be_false
}

pub fn session_is_bound_to_identity_and_delete_releases_it_test() {
  let app_server =
    example_server.sample_server()
    |> server.with_identity_authorization("authorization", fn(value) {
      case value {
        "Bearer alice" -> Some("alice")
        "Bearer bob" -> Some("bob")
        _ -> None
      }
    })
  let url = server_test_support.start_http_server_with_server(app_server)
  let initialized =
    raw(url, http.Post, [#("authorization", "Bearer alice")], initialize_body)
  let assert Ok(id) = response.get_header(initialized, "mcp-session-id")
  let headers = [
    #("authorization", "Bearer alice"),
    #("mcp-session-id", id),
    #("mcp-protocol-version", "2025-11-25"),
  ]
  raw(
    url,
    http.Post,
    [
      #("authorization", "Bearer bob"),
      #("mcp-session-id", id),
      #("mcp-protocol-version", "2025-11-25"),
    ],
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
  ).status
  |> should.equal(404)
  raw(
    url,
    http.Post,
    [
      #("authorization", "Bearer bob"),
      #("mcp-session-id", id),
      #("mcp-protocol-version", "2025-11-25"),
    ],
    "{",
  ).status
  |> should.equal(404)
  raw(
    url,
    http.Post,
    [#("authorization", "Bearer alice"), #("mcp-session-id", id)],
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
  ).status
  |> should.equal(400)
  raw(url, http.Delete, headers, "").status |> should.equal(204)
  server.has_streamable_http_session(app_server, id) |> should.be_false
  raw(
    url,
    http.Post,
    headers,
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}",
  ).status
  |> should.equal(404)
  raw(url, http.Post, headers, "{").status |> should.equal(404)
}

fn raw(
  url: String,
  method: http.Method,
  headers: List(#(String, String)),
  body: String,
) -> response.Response(String) {
  let assert Ok(req) = request.to(url)
  let req =
    req
    |> request.set_method(method)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  let assert Ok(res) =
    httpc.configure() |> httpc.timeout(2000) |> httpc.dispatch(req)
  res
}
