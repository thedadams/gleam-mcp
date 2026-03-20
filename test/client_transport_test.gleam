import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleeunit
import gleeunit/should

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
      jsonrpc.latest_protocol_version,
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
      jsonrpc.latest_protocol_version,
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
        should.equal(protocol_version, jsonrpc.latest_protocol_version)
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(_, method, Some(actions.RequestInitialize(params))) -> {
              should.equal(method, mcp.method_initialize)
              let actions.InitializeRequestParams(
                request_protocol_version,
                request_capabilities,
                request_client_info,
                request_meta,
              ) = params
              should.equal(
                request_protocol_version,
                jsonrpc.latest_protocol_version,
              )
              should.equal(
                request_capabilities,
                capabilities.to_initialize_capabilities(capabilities.none()),
              )
              should.equal(request_client_info, sample_implementation())
              should.equal(request_meta, None)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ResultInitialize(sample_initialize_result()),
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

  client.initialize(client, sample_implementation())
  |> should.equal(Ok(#(client, sample_initialize_result())))
}

pub fn initialize_persists_http_session_id_test() {
  let created =
    client.new_with_runners(
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
            jsonrpc.Request(_, method, Some(actions.RequestInitialize(_))) -> {
              should.equal(method, mcp.method_initialize)
              Ok(transport.TransportResponse(
                response: jsonrpc.ResultResponse(
                  jsonrpc.StringId("req-1"),
                  actions.ResultInitialize(sample_initialize_result()),
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
    client.new_with_runners(
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
            jsonrpc.Request(_, method, Some(actions.RequestInitialize(_))) -> {
              should.equal(method, mcp.method_initialize)
              Ok(transport.TransportResponse(
                response: jsonrpc.ResultResponse(
                  jsonrpc.StringId("req-1"),
                  actions.ResultInitialize(sample_initialize_result()),
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
    client.new_with_runners(
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultEmpty(None),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultInitialize(sample_initialize_result()),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(_, method, params) -> {
              should.equal(method, mcp.method_ping)
              should.equal(params, None)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ResultEmpty(None),
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
    client.new_with_runners(
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.RequestListTools(request_params)),
            ) -> {
              should.equal(method, mcp.method_list_tools)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ResultListTools(expected),
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

  client.list_tools(created, Some(params))
  |> should.equal(#(created, Ok(expected)))
}

pub fn list_tools_rejects_unexpected_result_variants_test() {
  let created =
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultEmpty(None),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.RequestSetLoggingLevel(request_params)),
            ) -> {
              should.equal(method, mcp.method_set_logging_level)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ResultEmpty(None),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, request) {
          case request {
            jsonrpc.Request(
              _,
              method,
              Some(actions.RequestCallTool(request_params)),
            ) -> {
              should.equal(method, mcp.method_call_tool)
              should.equal(request_params, params)
              transport_ok(jsonrpc.ResultResponse(
                jsonrpc.StringId("req-1"),
                actions.ResultCallTool(expected),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultCreateTask(expected),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultEmpty(None),
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
    client.new_with_runners(
      transport.Stdio(transport.StdioConfig("cmd", [], [], None, None)),
      transport.Runners(
        stdio_request: fn(_, _, _, _) {
          transport_ok(jsonrpc.ResultResponse(
            jsonrpc.StringId("req-1"),
            actions.ResultEmpty(None),
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
    protocol_version: jsonrpc.latest_protocol_version,
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
        input_schema: jsonrpc.VObject([]),
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
