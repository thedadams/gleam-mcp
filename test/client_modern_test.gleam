import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec
import gleam_mcp/client/stdio_manager
import gleam_mcp/client/subscriptions
import gleam_mcp/client/transport
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc
import gleam_mcp/wire
import gleeunit/should
import mist

pub fn modern_http_preserves_rpc_error_on_http_400_test() {
  let url =
    start_wire_server(fn(_) {
      response.new(400)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "{\"jsonrpc\":\"2.0\",\"id\":\"modern-1\",\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol\",\"data\":{\"supported\":[\"2025-11-25\"],\"requested\":\"2026-07-28\"}}}",
        )),
      )
    })
  let response = modern_request(url) |> should.be_ok
  case response.response {
    jsonrpc.ErrorResponse(_, error) -> should.equal(error.code, -32_022)
    _ -> should.fail()
  }
  should.equal(response.session_id, None)
}

pub fn modern_http_plain_400_retains_status_for_fallback_test() {
  let url =
    start_wire_server(fn(_) {
      response.new(400)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Initialize first")),
      )
    })
  should.equal(
    modern_request(url),
    Error(transport.ProtocolHttpError(400, "Initialize first")),
  )
}

pub fn modern_http_does_not_resume_sse_or_send_session_headers_test() {
  let seen = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      process.send(seen, req.method)
      should.equal(request.get_header(req, "mcp-method"), Ok("ping"))
      request.get_header(req, "mcp-session-id") |> should.be_error
      request.get_header(req, "last-event-id") |> should.be_error
      response.new(200)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "id: forbidden-resume\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"p\",\"progress\":1}}\n\n",
        )),
      )
    })
  case modern_request(url) {
    Error(transport.UnexpectedResponse(_)) -> Nil
    _ -> should.fail()
  }
  should.equal(process.receive(seen, 0), Ok(http.Post))
  should.equal(process.receive(seen, 50), Error(Nil))
}

pub fn modern_http_rejects_reverse_requests_test() {
  let seen = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      process.send(seen, req.method)
      response.new(200)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "data: {\"jsonrpc\":\"2.0\",\"id\":\"server-id\",\"method\":\"roots/list\"}\n\n",
        )),
      )
    })
  modern_request(url) |> should.be_error
  should.equal(process.receive(seen, 0), Ok(http.Post))
  should.equal(process.receive(seen, 50), Error(Nil))
}

pub fn modern_headers_cannot_be_overridden_by_transport_configuration_test() {
  let config =
    transport.HttpConfig(
      "http://localhost/mcp",
      [
        #("MCP-Session-Id", "old"),
        #("Last-Event-ID", "old"),
        #("Mcp-Method", "wrong"),
        #("Mcp-Name", "wrong"),
        #("MCP-Protocol-Version", "wrong"),
        #("Mcp-Param-X", "wrong"),
        #("Authorization", "Bearer credential"),
      ],
      None,
    )
  let headers =
    transport.modern_headers(
      config,
      "2026-07-28",
      "{\"method\":\"tools/call\",\"params\":{\"name\":\"météo\"}}",
      [#("mcp-param-x", "correct")],
    )
  should.equal(list_key(headers, "mcp-method"), Some("tools/call"))
  should.equal(list_key(headers, "mcp-name"), Some("=?base64?bcOpdMOpbw==?="))
  should.equal(list_key(headers, "mcp-param-x"), Some("correct"))
  should.equal(list_key(headers, "authorization"), Some("Bearer credential"))
  should.equal(list_key(headers, "mcp-session-id"), None)
}

pub fn automatic_http_discovery_falls_back_from_legacy_404_test() {
  let seen = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      let assert Ok(req) = mist.read_body(req, 1_048_576)
      let assert Ok(body) = bit_array.to_string(req.body)
      let assert Ok(method) =
        json.parse(body, decode.at(["method"], decode.string))
      process.send(seen, method)
      case method {
        "notifications/initialized" ->
          response.new(202) |> response.set_body(mist.Bytes(bytes_tree.new()))
        _ -> {
          let assert Ok(id) =
            json.parse(body, decode.at(["id"], codec.value_decoder()))
          let payload = case method {
            "server/discover" ->
              jsonrpc.VObject([
                #("jsonrpc", jsonrpc.VString("2.0")),
                #("id", id),
                #(
                  "error",
                  jsonrpc.VObject([
                    #("code", jsonrpc.VInt(-32_601)),
                    #("message", jsonrpc.VString("Unknown method")),
                  ]),
                ),
              ])
            "initialize" ->
              jsonrpc.VObject([
                #("jsonrpc", jsonrpc.VString("2.0")),
                #("id", id),
                #(
                  "result",
                  jsonrpc.VObject([
                    #(
                      "protocolVersion",
                      jsonrpc.VString(jsonrpc.legacy_protocol_version),
                    ),
                    #("capabilities", jsonrpc.VObject([])),
                    #(
                      "serverInfo",
                      jsonrpc.VObject([
                        #("name", jsonrpc.VString("legacy fixture")),
                        #("version", jsonrpc.VString("1")),
                      ]),
                    ),
                  ]),
                ),
              ])
            _ -> panic as "Unexpected method"
          }
          json_response(
            case method {
              "server/discover" -> 404
              _ -> 200
            },
            payload,
          )
        }
      }
    })
  let app =
    client.new(
      transport.Http(transport.HttpConfig(url, [], Some(1000))),
      capabilities.none(),
    )
  let #(app, info) = client.connect(app, implementation()) |> should.be_ok
  case info {
    client.Legacy(_) -> Nil
    _ -> should.fail()
  }
  should.equal(app.protocol_version, jsonrpc.legacy_protocol_version)
  should.equal(process.receive(seen, 0), Ok("server/discover"))
  should.equal(process.receive(seen, 0), Ok("initialize"))
  should.equal(process.receive(seen, 0), Ok("notifications/initialized"))
  let #(_, result) = client.close(app)
  result |> should.be_ok
}

pub fn automatic_http_discovery_keeps_explicit_modern_unknown_method_error_test() {
  let seen = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      let assert Ok(req) = mist.read_body(req, 1_048_576)
      let assert Ok(body) = bit_array.to_string(req.body)
      let assert Ok(method) =
        json.parse(body, decode.at(["method"], decode.string))
      process.send(seen, method)
      let assert Ok(id) =
        json.parse(body, decode.at(["id"], codec.value_decoder()))
      json_response(
        404,
        jsonrpc.VObject([
          #("jsonrpc", jsonrpc.VString("2.0")),
          #("id", id),
          #(
            "error",
            jsonrpc.VObject([
              #("code", jsonrpc.VInt(-32_601)),
              #("message", jsonrpc.VString("Unknown method")),
            ]),
          ),
        ]),
      )
      |> response.set_header("MCP-Protocol-Version", "2026-07-28")
    })
  let app =
    client.new(
      transport.Http(transport.HttpConfig(url, [], Some(500))),
      capabilities.none(),
    )
  case client.connect(app, implementation()) {
    Error(client.Rpc(error)) -> should.equal(error.code, -32_601)
    _ -> should.fail()
  }
  should.equal(process.receive(seen, 0), Ok("server/discover"))
  should.equal(process.receive(seen, 50), Error(Nil))
  let #(_, result) = client.close(app)
  result |> should.be_ok
}

pub fn automatic_http_discovery_keeps_explicit_modern_invalid_http_400_test() {
  let seen = process.new_subject()
  let url =
    start_wire_server(fn(_) {
      process.send(seen, Nil)
      response.new(400)
      |> response.set_header("MCP-Protocol-Version", "2026-07-28")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("invalid modern body")),
      )
    })
  let app =
    client.new(
      transport.Http(transport.HttpConfig(url, [], Some(500))),
      capabilities.none(),
    )
  case client.connect(app, implementation()) {
    Error(client.Transport(transport.VersionedProtocolHttpError(
      400,
      "invalid modern body",
      "2026-07-28",
    ))) -> Nil
    _ -> should.fail()
  }
  should.equal(process.receive(seen, 0), Ok(Nil))
  should.equal(process.receive(seen, 50), Error(Nil))
  let #(_, result) = client.close(app)
  result |> should.be_ok
}

pub fn automatic_http_discovery_does_not_downgrade_authorization_or_broken_modern_servers_test() {
  list.each([401, 403, 503, 200], fn(status) {
    let requests = process.new_subject()
    let url =
      start_wire_server(fn(_) {
        process.send(requests, Nil)
        response.new(status)
        |> response.set_header("content-type", "application/json")
        |> response.set_body(
          mist.Bytes(bytes_tree.from_string("{\"unexpected\":true}")),
        )
      })
    let app =
      client.new(
        transport.Http(transport.HttpConfig(url, [], Some(300))),
        capabilities.none(),
      )
    client.connect(app, implementation()) |> should.be_error
    should.equal(process.receive(requests, 0), Ok(Nil))
    should.equal(process.receive(requests, 50), Error(Nil))
    let #(_, result) = client.close(app)
    result |> should.be_ok
  })
}

pub fn pinned_modern_discovery_never_initializes_legacy_test() {
  let called = process.new_subject()
  let app =
    mocked_client(capabilities.none(), fn(_, request) {
      let assert jsonrpc.Request(id, method, _) = request
      process.send(called, method)
      Ok(transport.TransportResponse(
        jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.RpcError(
            -32_022,
            "Unsupported",
            Some(
              jsonrpc.VObject([
                #(
                  "supported",
                  jsonrpc.VArray([
                    jsonrpc.VString(jsonrpc.legacy_protocol_version),
                  ]),
                ),
              ]),
            ),
          ),
        ),
        None,
      ))
    })
    |> client.with_protocol_version(jsonrpc.latest_protocol_version)
  client.connect(app, implementation()) |> should.be_error
  should.equal(process.receive(called, 0), Ok("server/discover"))
  should.equal(process.receive(called, 0), Error(Nil))
}

pub fn modern_discovery_retries_supported_version_once_with_fresh_id_test() {
  let reject = process.new_subject()
  let ids = process.new_subject()
  process.send(reject, Nil)
  let app =
    mocked_client(capabilities.none(), fn(_, request) {
      let assert jsonrpc.Request(id, method, _) = request
      should.equal(method, "server/discover")
      process.send(ids, id)
      let response = case process.receive(reject, 0) {
        Ok(_) -> jsonrpc.ErrorResponse(Some(id), supported_modern_error())
        Error(_) ->
          jsonrpc.ResultResponse(
            id,
            actions.ClientResultDiscover(actions.DiscoverResult(
              [jsonrpc.latest_protocol_version],
              dict.new(),
              None,
              None,
            )),
          )
      }
      Ok(transport.TransportResponse(response, None))
    })
    |> client.with_protocol_version(jsonrpc.latest_protocol_version)
  let #(app, _) = client.connect(app, implementation()) |> should.be_ok
  let first = process.receive(ids, 0) |> should.be_ok
  let second = process.receive(ids, 0) |> should.be_ok
  should.be_true(first != second)
  should.equal(process.receive(ids, 0), Error(Nil))
  let #(_, result) = client.close(app)
  result |> should.be_ok
}

pub fn modern_discovery_never_retries_version_rejection_indefinitely_test() {
  let ids = process.new_subject()
  let app =
    mocked_client(capabilities.none(), fn(_, request) {
      let assert jsonrpc.Request(id, _, _) = request
      process.send(ids, id)
      Ok(transport.TransportResponse(
        jsonrpc.ErrorResponse(Some(id), supported_modern_error()),
        None,
      ))
    })
    |> client.with_protocol_version(jsonrpc.latest_protocol_version)
  client.connect(app, implementation()) |> should.be_error
  process.receive(ids, 0) |> should.be_ok
  process.receive(ids, 0) |> should.be_ok
  should.equal(process.receive(ids, 0), Error(Nil))
}

fn supported_modern_error() {
  jsonrpc.RpcError(
    -32_022,
    "Unsupported",
    Some(
      jsonrpc.VObject([
        #(
          "supported",
          jsonrpc.VArray([jsonrpc.VString(jsonrpc.latest_protocol_version)]),
        ),
        #("requested", jsonrpc.VString(jsonrpc.latest_protocol_version)),
      ]),
    ),
  )
}

pub fn mrtr_state_only_rounds_are_bounded_and_use_new_ids_test() {
  let called = process.new_subject()
  let app =
    mocked_client(capabilities.none(), fn(_, request) {
      let assert jsonrpc.Request(id, _, Some(action)) = request
      process.send(called, id)
      let metadata = actions.request_meta(action) |> should.be_some
      let extra = metadata.extra |> should.be_some
      should.equal(
        dict.get(extra.fields, "io.modelcontextprotocol/protocolVersion"),
        Ok(jsonrpc.VString(jsonrpc.latest_protocol_version)),
      )
      Ok(transport.TransportResponse(
        jsonrpc.ResultResponse(
          id,
          actions.ClientResultInputRequired(actions.InputRequiredResult(
            None,
            Some("opaque"),
            None,
          )),
        ),
        None,
      ))
    })
    |> client.with_maximum_input_rounds(3)
  let #(_, result) =
    client.get_prompt(app, actions.GetPromptRequestParams("prompt", None, None))
  result |> should.be_error
  let ids =
    list.repeat(Nil, 4)
    |> list.map(fn(_) { process.receive(called, 0) |> should.be_ok })
  should.equal(list.length(list.unique(ids)), 4)
  should.equal(process.receive(called, 0), Error(Nil))
}

pub fn mrtr_inputs_and_opaque_state_apply_only_to_the_current_retry_test() {
  let count = process.new_subject()
  process.send(count, 0)
  let roots =
    capabilities.none() |> capabilities.with_list_roots(fn(_) { Ok([]) })
  let app =
    mocked_client(roots, fn(_, request) {
      let assert jsonrpc.Request(id, method, Some(action)) = request
      should.equal(method, "prompts/get")
      let original = actions.request_without_input(action)
      let assert actions.ClientRequestGetPrompt(params) = original
      should.equal(params.name, "original")
      should.equal(
        params.arguments,
        Some(dict.from_list([#("unchanged", "value")])),
      )
      let step = process.receive_forever(count)
      process.send(count, step + 1)
      let result = case step {
        0 ->
          actions.ClientResultInputRequired(actions.InputRequiredResult(
            Some(
              dict.from_list([
                #(
                  "root-input",
                  jsonrpc.VObject([#("method", jsonrpc.VString("roots/list"))]),
                ),
              ]),
            ),
            Some("\u{0000}opaque / do not parse"),
            None,
          ))
        1 -> {
          should.equal(
            actions.request_state(action),
            Some("\u{0000}opaque / do not parse"),
          )
          let inputs = actions.input_responses(action) |> should.be_some
          should.equal(
            dict.get(inputs, "root-input"),
            Ok(jsonrpc.VObject([#("roots", jsonrpc.VArray([]))])),
          )
          actions.ClientResultInputRequired(actions.InputRequiredResult(
            Some(dict.new()),
            None,
            None,
          ))
        }
        _ -> {
          should.equal(actions.request_state(action), None)
          should.equal(actions.input_responses(action), Some(dict.new()))
          actions.ClientResultWithCache(
            actions.ClientResultGetPrompt(actions.GetPromptResult(
              None,
              [],
              None,
            )),
            actions.CacheHint(5000, actions.Private),
          )
        }
      }
      Ok(transport.TransportResponse(jsonrpc.ResultResponse(id, result), None))
    })
  let #(app, result) =
    client.get_prompt(
      app,
      actions.GetPromptRequestParams(
        "original",
        Some(dict.from_list([#("unchanged", "value")])),
        None,
      ),
    )
  result |> should.be_ok
  should.equal(
    client.last_cache_hint(app),
    Some(actions.CacheHint(5000, actions.Private)),
  )
  should.equal(process.receive(count, 0), Ok(3))
}

pub fn mrtr_callback_is_cancelled_at_the_original_operation_deadline_test() {
  let finished = process.new_subject()
  let roots =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) {
      process.sleep(250)
      process.send(finished, Nil)
      Ok([])
    })
  let app =
    mocked_client(roots, fn(_, request) {
      let assert jsonrpc.Request(id, _, _) = request
      Ok(transport.TransportResponse(
        jsonrpc.ResultResponse(
          id,
          actions.ClientResultInputRequired(actions.InputRequiredResult(
            Some(
              dict.from_list([
                #(
                  "roots",
                  jsonrpc.VObject([#("method", jsonrpc.VString("roots/list"))]),
                ),
              ]),
            ),
            None,
            None,
          )),
        ),
        None,
      ))
    })
    |> client.with_request_timeout(40)
  let #(_, result) =
    client.get_prompt(app, actions.GetPromptRequestParams("prompt", None, None))
  should.equal(result, Error(client.Transport(transport.TimeoutError)))
  should.equal(process.receive(finished, 300), Error(Nil))
}

fn implementation() {
  actions.Implementation("modern test", "1", None, None, None, [])
}

fn mocked_client(
  caps,
  handler: fn(
    transport.HttpConfig,
    jsonrpc.Request(actions.ClientActionRequest),
  ) ->
    Result(
      transport.TransportResponse(actions.ClientActionResult),
      transport.TransportError,
    ),
) {
  client.new_with_runners(
    transport.Http(transport.HttpConfig(
      "http://invalid.test/mcp",
      [],
      Some(1000),
    )),
    transport.Runners(
      stdio_request: fn(_, _, _, _) { Error(transport.ProcessError("unused")) },
      stdio_notification: fn(_, _, _, _) {
        Error(transport.ProcessError("unused"))
      },
      stdio_listen: fn(_, _, _) { Error(transport.ProcessError("unused")) },
      streamable_request: fn(config, _, _, _, request) {
        handler(config, request)
      },
      streamable_notification: fn(_, _, _, _, _) {
        Error(transport.HttpError("unused"))
      },
    ),
    caps,
  )
}

fn json_response(status, payload) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    payload
    |> codec_common.encode_value
    |> json.to_string
    |> bytes_tree.from_string,
  ))
}

fn list_key(headers, key) {
  case headers {
    [] -> None
    [#(name, value), ..rest] ->
      case name == key {
        True -> Some(value)
        False -> list_key(rest, key)
      }
  }
}

fn modern_request(url: String) {
  let message = jsonrpc.Request(jsonrpc.StringId("modern-1"), "ping", None)
  transport.streamable_http_request(
    transport.HttpConfig(url, [], Some(1000)),
    Some("legacy-session"),
    "2026-07-28",
    capabilities.none(),
    message,
    fn(_) {
      "{\"jsonrpc\":\"2.0\",\"id\":\"modern-1\",\"method\":\"ping\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
    },
    codec.decode_response,
  )
}

fn start_wire_server(
  handler: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
) -> String {
  let started = process.new_subject()
  let _ =
    process.spawn(fn() {
      let assert Ok(_) =
        mist.new(handler)
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(port, _, _) { process.send(started, port) })
        |> mist.start
      process.sleep_forever()
    })
  let port = process.receive(started, 1000) |> should.be_ok
  "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
}

pub fn modern_stdio_accepts_error_without_id_test() {
  let error =
    "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32020,\"message\":\"Header mismatch\"}}"
  let manager = stdio_manager.start()
  let config =
    raw_stdio_config(
      "IFS= read -r frame; printf '%s\\n' '"
      <> error
      <> "'; while IFS= read -r frame; do :; done",
    )
  let assert Ok(#(received, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      capabilities.none(),
      modern_stdio_ping("ping"),
    )
  should.equal(received, error)
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("ping"),
      "ping",
      Some(actions.ClientRequestPing(None)),
    )
  case
    wire.decode_response(received, request, jsonrpc.latest_protocol_version)
    |> should.be_ok
  {
    jsonrpc.ErrorResponse(None, error) -> should.equal(error.code, -32_020)
    _ -> should.fail()
  }
  stdio_manager.close(manager, session) |> should.be_ok
}

pub fn modern_stdio_rejects_reverse_request_after_response_test() {
  let response =
    "{\"jsonrpc\":\"2.0\",\"id\":\"first\",\"result\":{\"resultType\":\"complete\"}}"
  let reverse =
    "{\"jsonrpc\":\"2.0\",\"id\":\"reverse\",\"method\":\"roots/list\"}"
  let next_response =
    "{\"jsonrpc\":\"2.0\",\"id\":\"second\",\"result\":{\"resultType\":\"complete\"}}"
  let manager = stdio_manager.start()
  let config =
    raw_stdio_config(
      "IFS= read -r frame; printf '%s\\n' '"
      <> response
      <> "'; sleep 0.05; printf '%s\\n' '"
      <> reverse
      <> "'; IFS= read -r frame; IFS= read -r frame; printf '%s\\n' '"
      <> next_response
      <> "'; while IFS= read -r frame; do :; done",
    )
  let assert Ok(#(_, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      capabilities.none(),
      modern_stdio_ping("first"),
    )
  process.sleep(150)
  stdio_manager.request(
    manager,
    config,
    session,
    capabilities.none(),
    modern_stdio_ping("second"),
  )
  |> should.be_error
  stdio_manager.close(manager, session) |> should.be_ok
}

pub fn modern_stdio_demultiplexes_subscription_ids_test() {
  let manager = stdio_manager.start()
  let initial =
    "{\"jsonrpc\":\"2.0\",\"id\":\"ping\",\"result\":{\"resultType\":\"complete\"}}"
  let wrong =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"other\"}}}"
  let correct =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"subscription\"}}}"
  let config =
    raw_stdio_config(
      "IFS= read -r frame; printf '%s\\n' '"
      <> initial
      <> "'; IFS= read -r frame; printf '%s\\n' '"
      <> wrong
      <> "' '"
      <> correct
      <> "'; while IFS= read -r frame; do :; done",
    )
  let assert Ok(#(_, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      capabilities.none(),
      modern_stdio_ping("ping"),
    )
  let events = process.new_subject()
  let payload =
    "{\"jsonrpc\":\"2.0\",\"id\":\"subscription\",\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"
  stdio_manager.subscribe(manager, config, session, payload, events)
  |> should.be_ok
  should.equal(process.receive(events, 500), Ok(Ok(correct)))
  should.equal(process.receive(events, 20), Error(Nil))
  stdio_manager.close(manager, session) |> should.be_ok
}

fn modern_stdio_ping(id: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\""
  <> id
  <> "\",\"method\":\"ping\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"
}

fn raw_stdio_config(script: String) -> stdio_manager.Config {
  stdio_manager.Config("/bin/sh", ["-c", script], [], None, Some(300))
}

pub fn modern_subscription_ack_requires_notifications_object_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("subscription"),
      "subscriptions/listen",
      Some(
        actions.ClientRequestSubscriptionsListen(
          actions.SubscriptionsListenParams(Some(jsonrpc.VObject([])), None),
        ),
      ),
    )
  let validator = subscriptions.new(request, Some(jsonrpc.VObject([])))
  list.each(
    ["", "\"notifications\":null,", "\"notifications\":true,"],
    fn(field) {
      let payload =
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{"
        <> field
        <> "\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"subscription\"}}}"
      subscriptions.event(validator, payload) |> should.be_error
    },
  )
  subscriptions.stop(validator)
}

pub fn stdio_busy_request_retains_subprocess_handle_test() {
  let manager = stdio_manager.start()
  let first_started = process.new_subject()
  let first_finished = process.new_subject()
  let caps =
    capabilities.none()
    |> capabilities.with_notify_progress(fn(_) {
      process.send(first_started, Nil)
      Ok(Nil)
    })
  let warm =
    "{\"jsonrpc\":\"2.0\",\"id\":\"warm\",\"result\":{\"resultType\":\"complete\"}}"
  let first =
    "{\"jsonrpc\":\"2.0\",\"id\":\"first\",\"result\":{\"resultType\":\"complete\"}}"
  let third =
    "{\"jsonrpc\":\"2.0\",\"id\":\"third\",\"result\":{\"resultType\":\"complete\"}}"
  let progress =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"first\",\"progress\":1}}"
  let config =
    raw_stdio_config(
      "IFS= read -r frame; printf '%s\\n' '"
      <> warm
      <> "'; IFS= read -r frame; printf '%s\\n' '"
      <> progress
      <> "'; sleep 0.15; printf '%s\\n' '"
      <> first
      <> "'; IFS= read -r frame; printf '%s\\n' '"
      <> third
      <> "'; while IFS= read -r frame; do :; done",
    )
  let assert Ok(#(_, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      caps,
      modern_stdio_ping("warm"),
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        first_finished,
        stdio_manager.request(
          manager,
          config,
          session,
          caps,
          modern_stdio_ping("first"),
        ),
      )
    })
  process.receive(first_started, 300) |> should.be_ok
  should.equal(
    stdio_manager.request(
      manager,
      config,
      session,
      caps,
      modern_stdio_ping("busy"),
    ),
    Error("Stdio transport is busy"),
  )
  let assert Ok(Ok(#(actual, first_session))) =
    process.receive(first_finished, 500)
  should.equal(actual, first)
  should.equal(first_session, session)
  let assert Ok(#(actual, third_session)) =
    stdio_manager.request(
      manager,
      config,
      session,
      caps,
      modern_stdio_ping("third"),
    )
  should.equal(actual, third)
  should.equal(third_session, session)
  stdio_manager.close(manager, session) |> should.be_ok
}
