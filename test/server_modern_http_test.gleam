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
import gleam_mcp/client/http_stream_driver
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

pub fn modern_http_normalizes_ows_before_routing_and_parameter_validation_test() {
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
              "value",
              jsonrpc.VObject([
                #("type", jsonrpc.VString("string")),
                #("x-mcp-header", jsonrpc.VString("Value")),
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
        Some(dict.from_list([#("value", jsonrpc.VString("Hello"))])),
        None,
        meta(jsonrpc.latest_protocol_version),
      )),
    )
  list.each([" \tHello\t ", " \t=?base64?SGVsbG8=?=\t "], fn(value) {
    let accepted =
      raw(
        url,
        http.Post,
        [
          #("mcp-protocol-version", " \t2026-07-28\t "),
          #("mcp-method", " \ttools/call\t "),
          #("mcp-name", " \techo\t "),
          #("mcp-param-value", value),
        ],
        call,
      )
    should.equal(accepted.status, 200)
    should.equal(process.receive(called, 1000), Ok(Nil))
  })
  list.each(["=?base64?SGVsbG8?=", "=?base64?SGVs!!!bG8=?="], fn(value) {
    let denied =
      raw(
        url,
        http.Post,
        [
          #("mcp-method", "tools/call"),
          #("mcp-name", "echo"),
          #("mcp-param-value", value),
        ],
        call,
      )
    should.equal(denied.status, 400)
    should.be_true(string.contains(denied.body, "-32020"))
    should.equal(process.receive(called, 10), Error(Nil))
  })
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
  list.each(
    [
      "initialize",
      "logging/setLevel",
      "resources/subscribe",
      "resources/unsubscribe",
    ],
    fn(method) {
      let request =
        string.replace(
          body(
            "server/discover",
            actions.ClientRequestDiscover(meta(jsonrpc.latest_protocol_version)),
          ),
          "server/discover",
          method,
        )
      let denied = raw(url, http.Post, [#("mcp-method", method)], request)
      should.equal(denied.status, 404)
      should.be_true(string.contains(denied.body, "-32601"))
    },
  )
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

pub fn modern_handler_errors_choose_http_status_before_sse_headers_test() {
  let bridges = process.new_subject()
  let app =
    list.fold(["needs_roots", "unknown"], app(), fn(app, name) {
      server.add_tool(app, name, name, tool_schema(), fn(_) {
        panic as "Modern handler should dispatch this tool"
      })
    })
    |> server.with_modern_request_handler(fn(_, context, action) {
      let assert server.ModernRequestContext(notifications: Some(sink), ..) =
        context
      process.send(bridges, process.subject_owner(sink) |> should.be_ok)
      case actions.request_without_input(action) {
        actions.ClientRequestCallTool(params) if params.name == "needs_roots" ->
          Ok(
            actions.ClientResultInputRequired(actions.InputRequiredResult(
              Some(
                dict.from_list([
                  #(
                    "roots",
                    jsonrpc.VObject([
                      #("method", jsonrpc.VString("roots/list")),
                      #("params", jsonrpc.VObject([])),
                    ]),
                  ),
                ]),
              ),
              None,
              None,
            )),
          )
        _ -> Error(jsonrpc.method_not_found_error("Unknown handler method"))
      }
    })
  let url = server_test_support.start_http_server_with_server(app)
  let denied =
    raw_tool(url, "needs_roots", meta(jsonrpc.latest_protocol_version))
  should.equal(denied.status, 400)
  should.equal(
    response.get_header(denied, "content-type"),
    Ok("application/json"),
  )
  should.be_true(string.contains(denied.body, "-32021"))
  should.be_true(string.contains(denied.body, "requiredCapabilities"))
  should.be_true(string.contains(denied.body, "roots"))
  expect_bridge_closed(bridges)
  let unknown = raw_tool(url, "unknown", meta(jsonrpc.latest_protocol_version))
  should.equal(unknown.status, 404)
  should.be_true(string.contains(unknown.body, "-32601"))
  expect_bridge_closed(bridges)
}

fn expect_bridge_closed(bridges) {
  let bridge = process.receive(bridges, 1000) |> should.be_ok
  let monitor = process.monitor(bridge)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { True })
  process.selector_receive(selector, 1000) |> should.be_ok
  process.demonitor_process(monitor)
}

pub fn modern_deferred_headers_preserve_progress_logs_and_delayed_results_test() {
  let app =
    server.add_tool_with_context(
      app(),
      "streamed",
      "streamed",
      tool_schema(),
      fn(app, context, _) {
        server.report_progress(app, context, 0.0, Some(1.0), None)
        |> should.be_ok
        server.send_notification(
          app,
          context,
          jsonrpc.Notification(
            "notifications/message",
            Some(
              actions.NotifyLoggingMessage(
                actions.LoggingMessageNotificationParams(
                  actions.Info,
                  None,
                  jsonrpc.VString("stream opened"),
                  None,
                ),
              ),
            ),
          ),
        )
        |> should.be_ok
        process.sleep(30)
        server.report_progress(app, context, 1.0, Some(1.0), None)
        |> should.be_ok
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
  let app =
    server.add_tool(app, "delayed", "delayed", tool_schema(), fn(_) {
      process.sleep(30)
      Ok(actions.CallToolResult([], None, None, None))
    })
  let caps = server.advertised_capabilities(app)
  let app =
    server.with_capabilities(
      app,
      actions.ServerCapabilities(..caps, logging: Some(jsonrpc.VObject([]))),
    )
  let url = server_test_support.start_http_server_with_server(app)
  let assert Some(metadata) = meta(jsonrpc.latest_protocol_version)
  let assert Some(extra) = metadata.extra
  let metadata =
    Some(actions.RequestMeta(
      Some(jsonrpc.StringId("stream-progress")),
      Some(
        actions.Meta(dict.insert(
          extra.fields,
          "io.modelcontextprotocol/logLevel",
          jsonrpc.VString("info"),
        )),
      ),
    ))
  let streamed = raw_tool(url, "streamed", metadata)
  should.equal(streamed.status, 200)
  should.be_true(
    response.get_header(streamed, "content-type")
    |> should.be_ok
    |> string.contains("text/event-stream"),
  )
  should.be_true(string.contains(streamed.body, "notifications/progress"))
  should.be_true(string.contains(streamed.body, "stream-progress"))
  should.be_true(string.contains(streamed.body, "notifications/message"))
  should.be_true(string.contains(streamed.body, "stream opened"))
  let events = string.split(streamed.body, "data: ")
  let last = list.last(events) |> should.be_ok
  should.be_true(string.contains(last, "resultType"))
  should.be_true(string.contains(last, "complete"))
  let delayed = raw_tool(url, "delayed", meta(jsonrpc.latest_protocol_version))
  should.equal(delayed.status, 200)
  should.be_true(
    response.get_header(delayed, "content-type")
    |> should.be_ok
    |> string.contains("text/event-stream"),
  )
  should.be_true(string.contains(delayed.body, "resultType"))
}

pub fn modern_quiet_post_disconnect_cancels_before_any_headers_test() {
  let running = process.new_subject()
  let app =
    server.add_tool_with_context(
      app(),
      "quiet",
      "quiet",
      tool_schema(),
      fn(_, context, _) {
        let assert server.ModernRequestContext(notifications: Some(sink), ..) =
          context
        let bridge = process.subject_owner(sink) |> should.be_ok
        process.send(running, #(process.self(), bridge))
        process.sleep_forever()
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
  let url = server_test_support.start_http_server_with_server(app)
  let events = process.new_subject()
  let connection =
    http_stream_driver.start(
      http.Post,
      url,
      [
        #("content-type", "application/json"),
        #("accept", "application/json, text/event-stream"),
        #("mcp-protocol-version", jsonrpc.latest_protocol_version),
        #("mcp-method", "tools/call"),
        #("mcp-name", "quiet"),
      ],
      body(
        "tools/call",
        actions.ClientRequestCallTool(actions.CallToolRequestParams(
          "quiet",
          None,
          None,
          meta(jsonrpc.latest_protocol_version),
        )),
      ),
      3000,
      events,
      fn(event) { event },
    )
  let #(worker, bridge) = process.receive(running, 1000) |> should.be_ok
  let worker_monitor = process.monitor(worker)
  let bridge_monitor = process.monitor(bridge)
  // The handler has started but emitted no headers or events. Closing the
  // actual HTTP owner must cancel it without waiting for the handler deadline.
  should.equal(process.receive(events, 30), Error(Nil))
  http_stream_driver.stop(connection)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(worker_monitor, fn(_) { True })
  process.selector_receive(selector, 1000) |> should.be_ok
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(bridge_monitor, fn(_) { True })
  process.selector_receive(selector, 1000) |> should.be_ok
  process.demonitor_process(worker_monitor)
  process.demonitor_process(bridge_monitor)
}

fn raw_tool(url, name, meta) {
  raw(
    url,
    http.Post,
    [#("mcp-method", "tools/call"), #("mcp-name", name)],
    body(
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        name,
        None,
        None,
        meta,
      )),
    ),
  )
}

fn tool_schema() {
  jsonrpc.VObject([
    #("type", jsonrpc.VString("object")),
    #("properties", jsonrpc.VObject([])),
  ])
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
