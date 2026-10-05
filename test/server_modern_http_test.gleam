import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleeunit/should
import server_test_support

pub fn modern_http_is_stateless_and_versions_all_results_test() {
  let url = server_test_support.start_http_server_with_server(app())
  let body =
    body(
      "server/discover",
      actions.ClientRequestDiscover(meta(jsonrpc.latest_protocol_version)),
    )
  let res =
    raw(
      url,
      http.Post,
      [
        #("mcp-method", "server/discover"),
        #("mcp-session-id", "irrelevant-old-session"),
      ],
      body,
    )
  should.equal(res.status, 200)
  should.equal(response.get_header(res, "mcp-session-id"), Error(Nil))
  should.equal(
    response.get_header(res, "mcp-protocol-version"),
    Ok(jsonrpc.latest_protocol_version),
  )
  should.be_true(string.contains(res.body, "resultType"))
  should.be_true(string.contains(res.body, "complete"))
  should.be_true(string.contains(res.body, "serverInfo"))
  should.be_true(string.contains(res.body, "ttlMs"))
  should.equal(raw(url, http.Get, [], "").status, 405)
  should.equal(raw(url, http.Delete, [], "").status, 405)
}

pub fn modern_header_mismatches_fail_before_tool_execution_test() {
  let called = process.new_subject()
  let app =
    server.add_tool(
      app(),
      "echo",
      "echo",
      jsonrpc.VObject([
        #("type", jsonrpc.VString("object")),
        #(
          "properties",
          jsonrpc.VObject([
            #(
              "user",
              jsonrpc.VObject([
                #("type", jsonrpc.VString("string")),
                #("x-mcp-header", jsonrpc.VString("user")),
              ]),
            ),
          ]),
        ),
      ]),
      fn(_) {
        process.send(called, Nil)
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
  let url = server_test_support.start_http_server_with_server(app)
  let call =
    body(
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("user", jsonrpc.VString("alice"))])),
        None,
        meta(jsonrpc.latest_protocol_version),
      )),
    )
  let headers = [
    #("mcp-method", "tools/call"),
    #("mcp-name", "echo"),
    #("mcp-param-user", "mallory"),
  ]
  let denied = raw(url, http.Post, headers, call)
  should.equal(denied.status, 400)
  should.be_true(string.contains(denied.body, "-32020"))
  should.equal(process.receive(called, 10), Error(Nil))
  let accepted =
    raw(
      url,
      http.Post,
      [
        #("mcp-method", "tools/call"),
        #("mcp-name", "echo"),
        #("mcp-param-user", "alice"),
      ],
      call,
    )
  should.equal(accepted.status, 200)
  should.equal(process.receive(called, 1000), Ok(Nil))
  let mismatch =
    body(
      "server/discover",
      actions.ClientRequestDiscover(meta(jsonrpc.legacy_protocol_version)),
    )
  let denied =
    raw(url, http.Post, [#("mcp-method", "server/discover")], mismatch)
  should.equal(denied.status, 400)
  should.be_true(string.contains(denied.body, "-32020"))
}

pub fn modern_unknown_and_removed_methods_use_http_404_test() {
  let url = server_test_support.start_http_server_with_server(app())
  let ping =
    body(
      "ping",
      actions.ClientRequestPing(meta(jsonrpc.latest_protocol_version)),
    )
  let removed = raw(url, http.Post, [#("mcp-method", "ping")], ping)
  should.equal(removed.status, 404)
  should.be_true(string.contains(removed.body, "-32601"))
  let unknown =
    string.replace(
      body(
        "server/discover",
        actions.ClientRequestDiscover(meta(jsonrpc.latest_protocol_version)),
      ),
      "server/discover",
      "future/method",
    )
  let unknown = raw(url, http.Post, [#("mcp-method", "future/method")], unknown)
  should.equal(unknown.status, 404)
  should.be_true(string.contains(unknown.body, "-32601"))
}

fn app() {
  server.new(actions.Implementation("modern-http", "1", None, None, None, []))
}

fn meta(version) {
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #("io.modelcontextprotocol/protocolVersion", jsonrpc.VString(version)),
          #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
        ]),
      ),
    ),
  ))
}

fn body(method, action) {
  codec.encode_request(jsonrpc.Request(jsonrpc.IntId(1), method, Some(action)))
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
    |> request.set_header(
      "mcp-protocol-version",
      jsonrpc.latest_protocol_version,
    )
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  httpc.configure()
  |> httpc.timeout(3000)
  |> httpc.dispatch(req)
  |> should.be_ok
}
