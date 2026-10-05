import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec as client_codec
import gleam_mcp/client/oauth
import gleam_mcp/client/stdio_manager
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleeunit
import gleeunit/should
import mist

pub fn main() {
  gleeunit.main()
}

pub fn transport_stdio_mode_uses_stdio_runner_test() {
  let request = jsonrpc.Notification("ping", None)
  let config = transport.Stdio(transport.StdioConfig("cmd", [], [], None, None))

  let result =
    transport.send_request(
      config,
      None,
      jsonrpc.legacy_protocol_version,
      capabilities.none(),
      request,
      fn(stdio_config, session_id, _capabilities, incoming_request) {
        should.equal(
          stdio_config,
          transport.StdioConfig("cmd", [], [], None, None),
        )
        should.equal(incoming_request, request)
        should.equal(session_id, None)
        transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("stdio"), Nil))
      },
      fn(_, _, _, _, _) { Error(transport.UnexpectedResponse("wrong runner")) },
    )

  result
  |> should.equal(
    transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("stdio"), Nil)),
  )
}

pub fn transport_http_mode_uses_streamable_runner_test() {
  let request = jsonrpc.Notification("ping", None)
  let config =
    transport.Http(transport.HttpConfig("https://example.com", [], Some(5000)))

  let result =
    transport.send_request(
      config,
      Some("session-1"),
      jsonrpc.legacy_protocol_version,
      capabilities.none(),
      request,
      fn(_, _, _, _) { Error(transport.UnexpectedResponse("wrong runner")) },
      fn(
        http_config,
        session_id,
        protocol_version,
        _capabilities,
        incoming_request,
      ) {
        should.equal(
          http_config,
          transport.HttpConfig("https://example.com", [], Some(5000)),
        )
        should.equal(session_id, Some("session-1"))
        should.equal(protocol_version, jsonrpc.legacy_protocol_version)
        should.equal(incoming_request, request)
        transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("http"), Nil))
      },
    )

  result
  |> should.equal(
    transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("http"), Nil)),
  )
}

pub fn client_new_uses_protocol_defaults_test() {
  let transport_config =
    transport.Stdio(transport.StdioConfig("cmd", [], [], None, None))
  let config = capabilities.none()

  let created = client.new(transport_config, config)

  let client.Client(
    transport_config: created_transport_config,
    capabilities: created_capabilities,
    protocol_version: created_protocol_version,
    session_id: created_session_id,
    ..,
  ) = created

  should.equal(created_transport_config, transport_config)
  should.equal(created_capabilities, config)
  should.equal(created_protocol_version, jsonrpc.latest_protocol_version)
  should.equal(created_session_id, None)
}

pub fn initialize_sends_requests_and_notification_test() {
  let client =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.ClientRequestInitialize(params)),
            ) -> {
              should.equal(method, mcp.method_initialize)
              let actions.InitializeRequestParams(
                request_protocol_version,
                request_capabilities,
                request_client_info,
                request_meta,
              ) = params
              should.equal(
                request_protocol_version,
                jsonrpc.legacy_protocol_version,
              )
              should.equal(
                request_capabilities,
                capabilities.to_initialize_capabilities(capabilities.none()),
              )
              should.equal(request_client_info, sample_implementation())
              should.equal(request_meta, None)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ClientResultInitialize(sample_initialize_result()),
              ))
            }
            _ -> panic
          }
        },
        stdio_notification: fn(_, _, _, request) {
          case request {
            jsonrpc.Notification(method, params) -> {
              should.equal(method, mcp.method_initialized)
              should.equal(params, None)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("notif-1"),
                Nil,
              ))
            }
            _ -> panic
          }
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  let assert Ok(#(initialized_client, initialized_result)) =
    client.initialize(client, sample_implementation())
  should.equal(initialized_result, sample_initialize_result())
  should.equal(
    initialized_client.peer_capabilities,
    Some(sample_initialize_result().capabilities),
  )
  should.equal(initialized_client.client_info, Some(sample_implementation()))
  should.equal(initialized_client.generation, client.generation + 1)
}

pub fn initialize_persists_http_session_id_test() {
  let created =
    legacy_client_with_runners(
      transport.Http(transport.HttpConfig("https://example.com/mcp", [], None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        stdio_notification: fn(_, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, session_id, _, _, request) {
          should.equal(session_id, None)

          case request {
            jsonrpc.Request(_, method, Some(actions.ClientRequestInitialize(_))) -> {
              should.equal(method, mcp.method_initialize)
              Ok(transport.TransportResponse(
                response: jsonrpc.ResultResponse(
                  jsonrpc.StringId("req-1"),
                  actions.ClientResultInitialize(sample_initialize_result()),
                ),
                session_id: Some("session-1"),
              ))
            }
            _ -> panic
          }
        },
        streamable_notification: fn(_, session_id, _, _, request) {
          should.equal(session_id, Some("session-1"))

          case request {
            jsonrpc.Notification(method, None) -> {
              should.equal(method, mcp.method_initialized)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("notif-1"),
                Nil,
              ))
            }
            _ -> panic
          }
        },
      ),
      capabilities.none(),
    )

  let assert Ok(#(next_client, _)) =
    client.initialize(created, sample_implementation())

  let client.Client(session_id:, ..) = next_client
  should.equal(session_id, Some("session-1"))
}

pub fn initialize_keeps_http_session_id_when_notification_returns_none_test() {
  let created =
    legacy_client_with_runners(
      transport.Http(transport.HttpConfig("https://example.com/mcp", [], None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        stdio_notification: fn(_, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, session_id, _, _, request) {
          should.equal(session_id, None)

          case request {
            jsonrpc.Request(_, method, Some(actions.ClientRequestInitialize(_))) -> {
              should.equal(method, mcp.method_initialize)
              Ok(transport.TransportResponse(
                response: jsonrpc.ResultResponse(
                  jsonrpc.StringId("req-1"),
                  actions.ClientResultInitialize(sample_initialize_result()),
                ),
                session_id: Some("session-1"),
              ))
            }
            _ -> panic
          }
        },
        streamable_notification: fn(_, session_id, _, _, request) {
          should.equal(session_id, Some("session-1"))

          case request {
            jsonrpc.Notification(method, None) -> {
              should.equal(method, mcp.method_initialized)
              Ok(transport.TransportResponse(
                response: jsonrpc.ResultResponse(
                  jsonrpc.StringId("notif-1"),
                  Nil,
                ),
                session_id: None,
              ))
            }
            _ -> panic
          }
        },
      ),
      capabilities.none(),
    )

  let assert Ok(#(next_client, _)) =
    client.initialize(created, sample_implementation())

  let client.Client(session_id:, ..) = next_client
  should.equal(session_id, Some("session-1"))
}

pub fn initialize_returns_rpc_errors_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ErrorResponse(
            Some(jsonrpc.StringId("req-1")),
            jsonrpc.invalid_params_error("bad init"),
          ))
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.initialize(created, sample_implementation())
  |> should.equal(Error(client.Rpc(jsonrpc.invalid_params_error("bad init"))))
}

pub fn initialize_rejects_unexpected_result_variants_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultEmpty(None),
          ))
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.initialize(created, sample_implementation())
  |> should.equal(
    Error(
      client.Transport(transport.UnexpectedResponse(
        "Unexpected response to initialize request",
      )),
    ),
  )
}

pub fn initialize_surfaces_notification_errors_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultInitialize(sample_initialize_result()),
          ))
        },
        stdio_notification: fn(_, _, _, _) { Error(transport.TimeoutError) },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.initialize(created, sample_implementation())
  |> should.equal(Error(client.Transport(transport.TimeoutError)))
}

pub fn ping_returns_success_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(_, method, params) -> {
              should.equal(method, mcp.method_ping)
              should.equal(params, None)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ClientResultEmpty(None),
              ))
            }
            _ -> panic
          }
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.ping(created)
  |> should.equal(#(created, Ok(Nil)))
}

pub fn ping_returns_rpc_errors_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ErrorResponse(
            Some(jsonrpc.StringId("req-1")),
            jsonrpc.method_not_found_error("ping"),
          ))
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.ping(created)
  |> should.equal(#(
    created,
    Error(client.Rpc(jsonrpc.method_not_found_error("ping"))),
  ))
}

pub fn list_tools_returns_typed_result_test() {
  let params = actions.PaginatedRequestParams(None, None)
  let expected = sample_list_tools_result()
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.ClientRequestListTools(request_params)),
            ) -> {
              should.equal(method, mcp.method_list_tools)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ClientResultListTools(expected),
              ))
            }
            _ -> panic
          }
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  let #(updated, actual) = client.list_tools(created, Some(params))
  should.equal(actual, Ok(expected))
  should.equal(dict.values(updated.cached_tools), expected.tools)
}

pub fn list_tools_rejects_unexpected_result_variants_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultEmpty(None),
          ))
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.list_tools(created, Some(actions.PaginatedRequestParams(None, None)))
  |> should.equal(#(
    created,
    Error(
      client.Transport(transport.UnexpectedResponse(
        "Unexpected response to tools/list request",
      )),
    ),
  ))
}

pub fn set_logging_level_accepts_empty_results_test() {
  let params = actions.SetLevelRequestParams(actions.Info, None)
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.ClientRequestSetLoggingLevel(request_params)),
            ) -> {
              should.equal(method, mcp.method_set_logging_level)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ClientResultEmpty(None),
              ))
            }
            _ -> panic
          }
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.set_logging_level(created, params)
  |> should.equal(#(created, Ok(Nil)))
}

pub fn call_tool_accepts_regular_results_test() {
  let params = actions.CallToolRequestParams("weather", None, None, None)
  let expected = sample_call_tool_result()
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.ClientRequestCallTool(request_params)),
            ) -> {
              should.equal(method, mcp.method_call_tool)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ClientResultCallTool(expected),
              ))
            }
            _ -> panic
          }
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.call_tool(created, params)
  |> should.equal(#(created, Ok(actions.CallTool(expected))))
}

pub fn call_tool_accepts_task_results_test() {
  let params = actions.CallToolRequestParams("weather", None, None, None)
  let expected = sample_create_task_result()
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultCreateTask(expected),
          ))
        },
        stdio_notification: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(jsonrpc.StringId("notif-1"), Nil))
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.call_tool(created, params)
  |> should.equal(#(created, Ok(actions.CallToolTask(expected))))
}

pub fn progress_sends_notification_params_test() {
  let params =
    actions.ProgressNotificationParams(
      jsonrpc.StringId("progress-1"),
      0.5,
      Some(1.0),
      Some("Halfway there"),
      None,
    )
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultEmpty(None),
          ))
        },
        stdio_notification: fn(_, _, _, request) {
          case request {
            jsonrpc.Notification(
              method,
              Some(actions.NotifyProgress(request_params)),
            ) -> {
              should.equal(method, mcp.method_notify_progress)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("notif-1"),
                Nil,
              ))
            }
            _ -> panic
          }
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.progress(created, params)
  |> should.equal(#(created, Ok(Nil)))
}

pub fn roots_list_changed_sends_notification_test() {
  let created =
    legacy_client_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ClientResultEmpty(None),
          ))
        },
        stdio_notification: fn(_, _, _, request) {
          case request {
            jsonrpc.Notification(
              method,
              Some(actions.NotifyRootsListChanged(None)),
            ) -> {
              should.equal(method, mcp.method_notify_roots_list_changed)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("notif-1"),
                Nil,
              ))
            }
            _ -> panic
          }
        },
        stdio_listen: fn(_, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_request: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
        streamable_notification: fn(_, _, _, _, _) {
          Error(transport.UnexpectedResponse("wrong runner"))
        },
      ),
      capabilities.none(),
    )

  client.roots_list_changed(created)
  |> should.equal(#(created, Ok(Nil)))
}

pub fn first_sse_data_returns_first_non_empty_event_test() {
  transport.first_sse_data(
    ": ping\n\n"
    <> "id: 1\n"
    <> "data:\n\n"
    <> "id: 2\n"
    <> "data: {\"jsonrpc\":\"2.0\"}\n\n",
  )
  |> should.equal(Ok("{\"jsonrpc\":\"2.0\"}"))
}

pub fn first_sse_data_returns_error_when_stream_has_no_data_test() {
  transport.first_sse_data(": ping\n\n" <> "id: 1\n" <> "data:\n\n")
  |> should.equal(
    Error(transport.UnexpectedResponse(
      "SSE stream ended before a response was received",
    )),
  )
}

fn transport_ok(
  response: jsonrpc.Response(a),
) -> Result(transport.TransportResponse(a), b) {
  Ok(transport.TransportResponse(response: response, session_id: None))
}

fn sample_implementation() -> actions.Implementation {
  actions.Implementation(
    name: "test-client",
    version: "1.0.0",
    title: None,
    description: None,
    website_url: None,
    icons: [],
  )
}

fn sample_initialize_result() -> actions.InitializeResult {
  actions.InitializeResult(
    protocol_version: jsonrpc.legacy_protocol_version,
    capabilities: actions.ServerCapabilities(
      None,
      None,
      None,
      None,
      None,
      None,
      None,
    ),
    server_info: actions.Implementation(
      name: "test-server",
      version: "1.0.0",
      title: None,
      description: None,
      website_url: None,
      icons: [],
    ),
    instructions: None,
    meta: None,
  )
}

fn sample_list_tools_result() -> actions.ListToolsResult {
  actions.ListToolsResult(
    tools: [
      actions.Tool(
        name: "weather",
        title: Some("Weather"),
        description: Some("Get weather"),
        input_schema: jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
        execution: None,
        output_schema: None,
        annotations: None,
        icons: [],
        meta: None,
      ),
    ],
    page: actions.Page(None),
    meta: None,
  )
}

fn sample_call_tool_result() -> actions.CallToolResult {
  actions.CallToolResult(
    content: [
      actions.TextBlock(actions.TextContent("Sunny", None, None)),
    ],
    structured_content: None,
    is_error: Some(False),
    meta: None,
  )
}

fn sample_create_task_result() -> actions.CreateTaskResult {
  actions.CreateTaskResult(
    task: actions.Task(
      task_id: "task-1",
      status: actions.Working,
      status_message: Some("Working"),
      created_at: "2026-03-06T00:00:00Z",
      last_updated_at: "2026-03-06T00:00:00Z",
      ttl_ms: Some(1000),
      poll_interval_ms: Some(100),
    ),
    meta: None,
  )
}

// These fixtures deliberately implement raw HTTP/JSON-RPC rather than using
// the SDK server, so both sides cannot silently share the same wire mistake.
type WireChunkMessage {
  SendNextChunk
  EndChunks
}

pub fn http_task_result_accepts_json_response_test() {
  let url =
    start_wire_server(fn(req) {
      wire_chunks(
        req,
        "Application/JSON; charset=utf-8",
        [
          bit_array.from_string(
            "{\"jsonrpc\":\"2.0\",\"id\":\"wire-1\",\"result\":{}}",
          ),
        ],
        3000,
      )
    })
  let response = wire_request(url, "tasks/result", capabilities.none(), 1000)
  should.equal(
    response,
    Ok(transport.TransportResponse(
      jsonrpc.ResultResponse(
        jsonrpc.StringId("wire-1"),
        actions.ClientResultEmpty(None),
      ),
      Some("wire-session"),
    )),
  )
}

pub fn http_post_sse_handles_nested_request_before_stream_ends_test() {
  let url = nested_roots_server(False)
  let config =
    capabilities.none() |> capabilities.with_list_roots(fn(_) { Ok([]) })
  wire_request(url, "ping", config, 2000) |> should.be_ok
}

pub fn http_get_stream_does_not_block_json_post_test() {
  let connected = process.new_subject()
  let ready = process.new_subject()
  let finished = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      case req.method {
        http.Get -> {
          process.send(connected, Nil)
          wire_chunks(
            req,
            "text/event-stream",
            list.repeat(bit_array.from_string(": heartbeat\n\n"), 300),
            0,
          )
        }
        _ ->
          response.new(200)
          |> response.set_header("content-type", "application/json")
          |> response.set_header("mcp-session-id", "wire-session")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(
              "{\"jsonrpc\":\"2.0\",\"id\":\"wire-1\",\"result\":{}}",
            )),
          )
      }
    })
  let _ =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(ready, stop)
      let outcome =
        transport.streamable_http_listen_until_closed(
          transport.HttpConfig(url, [], Some(5000)),
          Some("wire-session"),
          jsonrpc.legacy_protocol_version,
          capabilities.none(),
          stop,
        )
      process.send(finished, outcome)
    })
  let stop = process.receive(ready, 1000) |> should.be_ok
  process.receive(connected, 1000) |> should.be_ok
  wire_request(url, "ping", capabilities.none(), 1000) |> should.be_ok
  process.send(stop, Nil)
  process.receive(finished, 1000) |> should.be_ok
}

pub fn http_capability_failures_return_jsonrpc_error_test() {
  let url = nested_roots_server(True)
  wire_request(url, "ping", capabilities.none(), 2000) |> should.be_ok
}

pub fn http_deadline_bounds_slow_capability_callbacks_test() {
  let url = nested_roots_server(False)
  let config =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) {
      process.sleep(1000)
      Ok([])
    })
  wire_request(url, "ping", config, 80)
  |> should.equal(Error(transport.TimeoutError))
}

fn nested_roots_server(expect_error: Bool) -> String {
  let response_to_nested = wire_response_relay()
  start_wire_server(fn(req) {
    let assert Ok(body_request) = mist.read_body(req, 1_048_576)
    let assert Ok(body) = bit_array.to_string(body_request.body)
    case string.contains(body, "\"method\":") {
      False -> {
        should.equal(
          request.get_header(req, "mcp-session-id"),
          Ok("wire-session"),
        )
        should.be_true(string.contains(body, "\"id\":\"roots-1\""))
        should.equal(string.contains(body, "\"error\":"), expect_error)
        process.send(response_to_nested, NestedResponse)
        response.new(202) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
      True ->
        mist.chunked(
          req,
          response.new(200)
            |> response.set_header("content-type", "text/event-stream")
            |> response.set_header("mcp-session-id", "wire-session"),
          fn(subject) {
            process.send(response_to_nested, RegisterNestedStream(subject))
            process.send(subject, SendNextChunk)
            False
          },
          fn(sent_request, _, connection) {
            case sent_request {
              False -> {
                let assert Ok(_) =
                  mist.send_chunk(
                    connection,
                    bit_array.from_string(
                      "data: {\"jsonrpc\":\"2.0\",\"id\":\"roots-1\",\"method\":\"roots/list\"}\n\n",
                    ),
                  )
                // The relay delivers the next message only when the nested
                // request's response has arrived on a separate HTTP POST.
                mist.chunk_continue(True)
              }
              True -> {
                let assert Ok(_) =
                  mist.send_chunk(
                    connection,
                    bit_array.from_string(
                      "data: {\"jsonrpc\":\"2.0\",\"id\":\"wire-1\",\"result\":{}}\n\n",
                    ),
                  )
                mist.chunk_stop()
              }
            }
          },
        )
    }
  })
}

pub fn http_sse_chunk_boundaries_preserve_utf8_and_crlf_test() {
  let url =
    start_wire_server(fn(req) {
      wire_chunks(
        req,
        "text/event-stream",
        [
          bit_array.from_string(
            "data: {\"jsonrpc\":\"2.0\",\"id\":\"wire-1\",\"result\":{\"text\":\"",
          ),
          <<0xc3>>,
          <<0xa9>>,
          bit_array.from_string("\"}}\r"),
          bit_array.from_string("\n\r"),
          bit_array.from_string("\n"),
        ],
        1000,
      )
    })
  wire_request(url, "ping", capabilities.none(), 500) |> should.be_ok
}

pub fn http_sse_resumes_post_with_cursor_and_retry_test() {
  let request_sequence = process.new_subject()
  let url =
    start_wire_server(fn(req) {
      case req.method {
        http.Post -> {
          process.send(request_sequence, "post")
          let _ = process.send_after(request_sequence, 100, "retry elapsed")
          wire_chunks(
            req,
            "text/event-stream",
            [
              bit_array.from_string("id: stream-a:1\nretry: 150\ndata:\n\n"),
            ],
            0,
          )
        }
        http.Get -> {
          process.send(request_sequence, "get")
          should.equal(
            request.get_header(req, "last-event-id"),
            Ok("stream-a:1"),
          )
          should.equal(
            request.get_header(req, "mcp-session-id"),
            Ok("wire-session"),
          )
          should.equal(
            request.get_header(req, "mcp-protocol-version"),
            Ok(jsonrpc.legacy_protocol_version),
          )
          wire_chunks(
            req,
            "text/event-stream",
            [
              bit_array.from_string(
                "id: stream-a:2\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"wire-1\",\"result\":{}}\n\n",
              ),
            ],
            3000,
          )
        }
        _ ->
          response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    })
  wire_request(url, "ping", capabilities.none(), 2000) |> should.be_ok
  process.receive(request_sequence, 0) |> should.equal(Ok("post"))
  process.receive(request_sequence, 0) |> should.equal(Ok("retry elapsed"))
  process.receive(request_sequence, 0) |> should.equal(Ok("get"))
}

pub fn http_response_deadline_is_not_extended_by_sse_heartbeats_test() {
  let url =
    start_wire_server(fn(req) {
      wire_chunks(
        req,
        "text/event-stream",
        list.repeat(bit_array.from_string(": heartbeat\n\n"), 50),
        1000,
      )
    })
  wire_request(url, "ping", capabilities.none(), 80)
  |> should.equal(Error(transport.TimeoutError))
}

pub fn http_session_404_is_typed_test() {
  let url =
    start_wire_server(fn(_) {
      response.new(404)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("Session expired")),
      )
    })
  let message = jsonrpc.Request(jsonrpc.StringId("wire-1"), "ping", None)
  transport.streamable_http_request(
    transport.HttpConfig(url, [], Some(300)),
    Some("expired"),
    jsonrpc.legacy_protocol_version,
    capabilities.none(),
    message,
    client_codec.encode_request,
    client_codec.decode_response,
  )
  |> should.equal(Error(transport.SessionExpired))
}

pub fn http_insufficient_scope_challenge_is_available_without_replay_test() {
  let seen = process.new_subject()
  let challenge =
    "Bearer resource_metadata=\"https://mcp.example.test/metadata\", error=\"insufficient_scope\", scope=\"tools:write\""
  let url =
    start_wire_server(fn(_) {
      process.send(seen, Nil)
      response.new(403)
      |> response.set_header("www-authenticate", challenge)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Forbidden")))
    })
  case wire_request(url, "ping", capabilities.none(), 1000) {
    Error(transport.AuthorizationRequired(403, Some(header))) -> {
      let parsed = oauth.parse_challenge(header) |> should.be_ok
      should.equal(parsed.scopes, Some(["tools:write"]))
      should.equal(parsed.error, Some("insufficient_scope"))
    }
    _ -> should.fail()
  }
  process.receive(seen, 0) |> should.equal(Ok(Nil))
  process.receive(seen, 100) |> should.equal(Error(Nil))
}

pub fn http_401_without_challenge_is_typed_test() {
  let url =
    start_wire_server(fn(_) {
      response.new(401)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Unauthorized")))
    })
  should.equal(
    wire_request(url, "ping", capabilities.none(), 1000),
    Error(transport.AuthorizationRequired(401, None)),
  )
  let app_client =
    client.new(
      transport.Http(transport.HttpConfig(url, [], Some(1000))),
      capabilities.none(),
    )
  case client.initialize(app_client, sample_implementation()) {
    Error(client.Transport(transport.AuthorizationRequired(401, None))) -> Nil
    other -> panic as string.inspect(other)
  }
}

pub fn http_listener_does_not_retry_405_test() {
  let url =
    start_wire_server(fn(_) {
      response.new(405) |> response.set_body(mist.Bytes(bytes_tree.new()))
    })
  case
    transport.streamable_http_listen(
      transport.HttpConfig(url, [], Some(300)),
      None,
      jsonrpc.legacy_protocol_version,
      capabilities.none(),
    )
  {
    Error(transport.UnexpectedResponse(message)) ->
      should.be_true(string.contains(message, "405"))
    _ -> should.fail()
  }
}

pub fn stdio_stderr_cannot_impersonate_jsonrpc_response_test() {
  let manager = stdio_manager.start()
  let wire_response = "{\"jsonrpc\":\"2.0\",\"id\":\"stdio\",\"result\":{}}"
  let diagnostic =
    "{\"jsonrpc\":\"2.0\",\"id\":\"wrong\",\"error\":{\"code\":-32603,\"message\":\"diagnostic\"}}"
  let config =
    stdio_manager.Config(
      "/bin/sh",
      [
        "-c",
        "IFS= read -r frame; printf '%s\\n' '"
          <> diagnostic
          <> "' >&2; printf '%s\\n' '"
          <> wire_response
          <> "'; while IFS= read -r frame; do :; done",
      ],
      [],
      None,
      Some(1000),
    )
  let assert Ok(#(response, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      capabilities.none(),
      "{\"jsonrpc\":\"2.0\",\"id\":\"stdio\",\"method\":\"ping\"}",
    )
  should.equal(response, wire_response)
  stdio_manager.close(manager, session) |> should.be_ok
}

pub fn stdio_reads_cancellation_while_capability_handler_is_running_test() {
  let manager = stdio_manager.start()
  let callback_finished = process.new_subject()
  let request =
    "{\"jsonrpc\":\"2.0\",\"id\":\"roots\",\"method\":\"roots/list\"}"
  let cancel =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"roots\"}}"
  let response = "{\"jsonrpc\":\"2.0\",\"id\":\"outer\",\"result\":{}}"
  let config =
    stdio_manager.Config(
      "/bin/sh",
      [
        "-c",
        "IFS= read -r frame; printf '%s\\n' '"
          <> request
          <> "' '"
          <> cancel
          <> "'; IFS= read -r reply; case \"$reply\" in *-32800*) printf '%s\\n' '"
          <> response
          <> "';; esac; while IFS= read -r frame; do :; done",
      ],
      [],
      None,
      Some(1000),
    )
  let capability_config =
    capabilities.none()
    |> capabilities.with_list_roots(fn(_) {
      process.sleep(500)
      process.send(callback_finished, Nil)
      Ok([])
    })
  let assert Ok(#(actual, session)) =
    stdio_manager.request(
      manager,
      config,
      None,
      capability_config,
      "{\"jsonrpc\":\"2.0\",\"id\":\"outer\",\"method\":\"ping\"}",
    )
  should.equal(actual, response)
  process.receive(callback_finished, 600) |> should.equal(Error(Nil))
  stdio_manager.close(manager, session) |> should.be_ok
}

fn wire_request(
  url: String,
  method: String,
  config: capabilities.Config,
  timeout: Int,
) {
  let message = jsonrpc.Request(jsonrpc.StringId("wire-1"), method, None)
  transport.streamable_http_request(
    transport.HttpConfig(url, [], Some(timeout)),
    None,
    jsonrpc.legacy_protocol_version,
    config,
    message,
    client_codec.encode_request,
    client_codec.decode_response,
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
  let assert Ok(port) = process.receive(started, 1000)
  "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
}

fn wire_chunks(
  req: request.Request(mist.Connection),
  content_type: String,
  chunks: List(BitArray),
  finish_delay: Int,
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_header("mcp-session-id", "wire-session"),
    fn(subject) {
      process.send(subject, SendNextChunk)
      #(subject, chunks)
    },
    fn(state, message, connection) {
      let #(subject, remaining) = state
      case message, remaining {
        EndChunks, _ -> mist.chunk_stop()
        SendNextChunk, [] -> mist.chunk_stop()
        SendNextChunk, [chunk, ..rest] -> {
          case mist.send_chunk(connection, chunk) {
            Ok(_) -> {
              let _ = case rest {
                [] -> process.send_after(subject, finish_delay, EndChunks)
                _ -> process.send_after(subject, 10, SendNextChunk)
              }
              mist.chunk_continue(#(subject, rest))
            }
            Error(_) -> mist.chunk_stop()
          }
        }
      }
    },
  )
}

type NestedWireMessage {
  RegisterNestedStream(process.Subject(WireChunkMessage))
  NestedResponse
}

fn wire_response_relay() -> process.Subject(NestedWireMessage) {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      nested_relay_loop(subject, None)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  subject
}

fn nested_relay_loop(
  subject: process.Subject(NestedWireMessage),
  stream: Option(process.Subject(WireChunkMessage)),
) {
  case process.receive_forever(subject) {
    RegisterNestedStream(stream) -> nested_relay_loop(subject, Some(stream))
    NestedResponse -> {
      case stream {
        Some(stream) -> process.send(stream, SendNextChunk)
        None -> Nil
      }
      nested_relay_loop(subject, stream)
    }
  }
}

fn legacy_client_with_runners(
  config: transport.Config,
  runners: transport.Runners,
  caps: capabilities.Config,
) -> client.Client {
  client.new_with_runners(config, runners, caps)
  |> client.with_protocol_version(jsonrpc.legacy_protocol_version)
}
