import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleeunit/should

pub fn main() {
  initialization_records_peer_capabilities_and_notification_runtime_test()
  unsupported_negotiated_versions_are_rejected_before_notification_test()
  initialization_requires_initialized_notification_success_test()
  negotiated_capabilities_prevent_unsupported_requests_test()
  tool_task_negotiation_is_enforced_before_invocation_test()
  expired_session_reinitializes_without_replaying_mutation_test()
  per_request_timeout_preserves_default_and_explicit_request_id_test()
  closed_clients_reject_new_requests_test()
  close_is_visible_to_existing_client_copies_test()
  close_unblocks_existing_stdio_listener_test()
  in_flight_expiration_does_not_reopen_closed_client_test()
  explicit_initialize_reopens_without_reviving_old_copies_test()
  reopening_an_old_copy_discards_its_deleted_session_test()
  automatic_tool_discovery_rejects_cursor_cycles_test()
  automatic_tool_discovery_has_a_page_limit_test()
}

pub fn initialization_records_peer_capabilities_and_notification_runtime_test() {
  let caps = empty_server_capabilities()
  let created =
    http_client(
      fn(_, _, request) {
        initialize_response(
          request,
          caps,
          jsonrpc.legacy_protocol_version,
          Some("initial"),
        )
      },
      fn(_, _, version, _, _) {
        should.equal(version, jsonrpc.legacy_protocol_version)
        Ok(transport.TransportResponse(
          jsonrpc.ResultResponse(jsonrpc.StringId("notify"), Nil),
          Some("ready"),
        ))
      },
    )
  let #(ready, _) = client.initialize(created, implementation()) |> should.be_ok
  should.equal(client.peer_capabilities(ready), Some(caps))
  should.equal(ready.session_id, Some("ready"))
  should.equal(ready.client_info, Some(implementation()))
}

pub fn unsupported_negotiated_versions_are_rejected_before_notification_test() {
  let notified = process.new_subject()
  let created =
    http_client(
      fn(_, _, request) {
        initialize_response(
          request,
          empty_server_capabilities(),
          "2024-11-05",
          None,
        )
      },
      fn(_, _, _, _, _) {
        process.send(notified, Nil)
        empty_notification(None)
      },
    )
  client.initialize(created, implementation()) |> should.be_error
  should.equal(process.receive(notified, 5), Error(Nil))
}

pub fn initialization_requires_initialized_notification_success_test() {
  let created =
    http_client(
      fn(_, _, request) {
        initialize_response(
          request,
          empty_server_capabilities(),
          jsonrpc.legacy_protocol_version,
          None,
        )
      },
      fn(_, _, _, _, _) { Error(transport.HttpError("notification rejected")) },
    )
  should.equal(
    client.initialize(created, implementation()),
    Error(client.Transport(transport.HttpError("notification rejected"))),
  )
}

pub fn negotiated_capabilities_prevent_unsupported_requests_test() {
  let issued = process.new_subject()
  let created =
    http_client(
      fn(_, _, request) {
        case request {
          jsonrpc.Request(_, _, Some(actions.ClientRequestInitialize(_))) ->
            initialize_response(
              request,
              empty_server_capabilities(),
              jsonrpc.legacy_protocol_version,
              None,
            )
          _ -> {
            process.send(issued, Nil)
            Error(transport.UnexpectedResponse(
              "unsupported request reached transport",
            ))
          }
        }
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(ready, _) = client.initialize(created, implementation()) |> should.be_ok
  let #(_, result) = client.list_resources(ready, None)
  let assert client.Rpc(error) = result |> should.be_error
  should.equal(error.code, jsonrpc.method_not_found_error_code)
  should.equal(process.receive(issued, 5), Error(Nil))
}

pub fn tool_task_negotiation_is_enforced_before_invocation_test() {
  let invoked = process.new_subject()
  let caps = tool_server_capabilities()
  let tools = [
    tool("required", actions.TaskRequired),
    tool("forbidden", actions.TaskForbidden),
    tool("optional", actions.TaskOptional),
  ]
  let created =
    http_client(
      fn(_, _, request) {
        case request {
          jsonrpc.Request(_id, _, Some(actions.ClientRequestInitialize(_))) ->
            initialize_response(
              request,
              caps,
              jsonrpc.legacy_protocol_version,
              None,
            )
          jsonrpc.Request(id, _, Some(actions.ClientRequestListTools(_))) ->
            Ok(transport.TransportResponse(
              jsonrpc.ResultResponse(
                id,
                actions.ClientResultListTools(actions.ListToolsResult(
                  tools,
                  actions.Page(None),
                  None,
                )),
              ),
              None,
            ))
          jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(_))) -> {
            process.send(invoked, Nil)
            Ok(transport.TransportResponse(
              jsonrpc.ResultResponse(
                id,
                actions.ClientResultCallTool(actions.CallToolResult(
                  [],
                  None,
                  None,
                  None,
                )),
              ),
              None,
            ))
          }
          _ -> Error(transport.UnexpectedResponse("unexpected request"))
        }
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(ready, _) = client.initialize(created, implementation()) |> should.be_ok
  let #(ready, required) =
    client.call_tool(
      ready,
      actions.CallToolRequestParams("required", None, None, None),
    )
  required |> should.be_error
  let #(ready, forbidden) =
    client.call_tool(
      ready,
      actions.CallToolRequestParams(
        "forbidden",
        None,
        Some(actions.TaskMetadata(None)),
        None,
      ),
    )
  forbidden |> should.be_error
  should.equal(process.receive(invoked, 5), Error(Nil))
  let #(_, allowed) =
    client.call_tool(
      ready,
      actions.CallToolRequestParams("optional", None, None, None),
    )
  allowed |> should.be_ok
  should.equal(process.receive(invoked, 1000), Ok(Nil))
}

pub fn expired_session_reinitializes_without_replaying_mutation_test() {
  let events = process.new_subject()
  let caps = tool_server_capabilities()
  let created =
    http_client(
      fn(session, _, request) {
        case request {
          jsonrpc.Request(_, _, Some(actions.ClientRequestInitialize(_))) -> {
            should.equal(session, None)
            process.send(events, "initialize")
            initialize_response(
              request,
              caps,
              jsonrpc.legacy_protocol_version,
              Some("fresh"),
            )
          }
          jsonrpc.Request(_, _, Some(actions.ClientRequestCallTool(_))) -> {
            should.equal(session, Some("expired"))
            process.send(events, "mutation")
            Error(transport.SessionExpired)
          }
          _ -> Error(transport.UnexpectedResponse("unexpected request"))
        }
      },
      fn(_, session, _, _, _) {
        process.send(events, "initialized")
        empty_notification(session)
      },
    )
  let ready =
    client.Client(
      ..created,
      session_id: Some("expired"),
      peer_capabilities: Some(caps),
      client_info: Some(implementation()),
      cached_tools: dict.from_list([
        #("mutate", tool("mutate", actions.TaskOptional)),
      ]),
    )
  let #(recovered, result) =
    client.call_tool(
      ready,
      actions.CallToolRequestParams("mutate", None, None, None),
    )
  should.equal(result, Error(client.Transport(transport.SessionExpired)))
  should.equal(recovered.session_id, Some("fresh"))
  should.equal(client.peer_capabilities(recovered), Some(caps))
  should.equal(process.receive(events, 1000), Ok("mutation"))
  should.equal(process.receive(events, 1000), Ok("initialize"))
  should.equal(process.receive(events, 1000), Ok("initialized"))
  should.equal(process.receive(events, 5), Error(Nil))
}

pub fn per_request_timeout_preserves_default_and_explicit_request_id_test() {
  let created =
    http_client(
      fn(_, _, request) {
        let assert jsonrpc.Request(id, _, _) = request
        should.equal(id, jsonrpc.StringId("cancel-me"))
        Ok(transport.TransportResponse(
          jsonrpc.ResultResponse(id, actions.ClientResultEmpty(None)),
          None,
        ))
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let runners = created.runners
  let custom =
    transport.Runners(
      ..runners,
      streamable_request: fn(
        config: transport.HttpConfig,
        session,
        version,
        capabilities,
        request,
      ) {
        should.equal(config.timeout_ms, Some(17))
        runners.streamable_request(
          config,
          session,
          version,
          capabilities,
          request,
        )
      },
    )
  let created = client.Client(..created, runners: custom)
  let #(next, result) =
    client.request_with_timeout(
      created,
      jsonrpc.Request(
        jsonrpc.StringId("cancel-me"),
        mcp.method_ping,
        Some(actions.ClientRequestPing(None)),
      ),
      17,
    )
  result |> should.be_ok
  should.equal(next.transport_config, created.transport_config)
}

pub fn closed_clients_reject_new_requests_test() {
  let created =
    http_client(
      fn(_, _, _) {
        Error(transport.UnexpectedResponse("closed client sent a request"))
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(closed, result) = client.close(created)
  result |> should.be_ok
  should.equal(closed.session_id, None)
  let #(_, result) = client.ping(closed)
  result |> should.be_error
}

pub fn close_is_visible_to_existing_client_copies_test() {
  let created =
    http_client(
      fn(_, _, _) {
        Error(transport.UnexpectedResponse("closed copy sent a request"))
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(_, result) = client.close(created)
  result |> should.be_ok
  let #(_, result) = client.ping(created)
  result |> should.be_error
  let #(_, result) = client.listen(created)
  result |> should.be_error
}

pub fn close_unblocks_existing_stdio_listener_test() {
  let started = process.new_subject()
  let finished = process.new_subject()
  let created =
    http_client(
      fn(_, _, _) { Error(transport.UnexpectedResponse("unused")) },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let runners =
    transport.Runners(..created.runners, stdio_listen: fn(_, _, _) {
      process.send(started, Nil)
      empty_notification(Some("stdio"))
    })
  let created =
    client.Client(
      ..created,
      transport_config: transport.Stdio(transport.StdioConfig(
        "unused",
        [],
        [],
        None,
        None,
      )),
      runners: runners,
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(finished, client.listen(created))
    })
  should.equal(process.receive(started, 1000), Ok(Nil))
  let #(_, result) = client.close(created)
  result |> should.be_ok
  let #(_, result) = process.receive(finished, 1000) |> should.be_ok
  result |> should.be_ok
}

pub fn in_flight_expiration_does_not_reopen_closed_client_test() {
  let started = process.new_subject()
  let finished = process.new_subject()
  let recovered = process.new_subject()
  let created =
    http_client(
      fn(_, _, request) {
        case request {
          jsonrpc.Request(_, "ping", _) -> {
            let release = process.new_subject()
            process.send(started, release)
            process.receive_forever(release)
            Error(transport.SessionExpired)
          }
          _ -> {
            process.send(recovered, Nil)
            Error(transport.UnexpectedResponse("closed client recovered"))
          }
        }
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let created = client.Client(..created, client_info: Some(implementation()))
  let _ =
    process.spawn_unlinked(fn() { process.send(finished, client.ping(created)) })
  let release = process.receive(started, 1000) |> should.be_ok
  let #(_, result) = client.close(created)
  result |> should.be_ok
  process.send(release, Nil)
  let #(stopped, result) = process.receive(finished, 1000) |> should.be_ok
  should.equal(result, Error(client.Transport(transport.SessionExpired)))
  should.equal(stopped.closed, True)
  should.equal(process.receive(recovered, 5), Error(Nil))
}

pub fn explicit_initialize_reopens_without_reviving_old_copies_test() {
  let created =
    http_client(
      fn(_, _, request) {
        case request {
          jsonrpc.Request(id, "ping", _) ->
            Ok(transport.TransportResponse(
              jsonrpc.ResultResponse(id, actions.ClientResultEmpty(None)),
              None,
            ))
          _ ->
            initialize_response(
              request,
              empty_server_capabilities(),
              jsonrpc.legacy_protocol_version,
              None,
            )
        }
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(closed, result) = client.close(created)
  result |> should.be_ok
  let #(reopened, _) =
    client.initialize(closed, implementation()) |> should.be_ok
  let #(_, result) = client.ping(reopened)
  result |> should.be_ok
  let #(_, result) = client.ping(created)
  result |> should.be_error
}

pub fn reopening_an_old_copy_discards_its_deleted_session_test() {
  let created =
    http_client(
      fn(session, _, request) {
        should.equal(session, None)
        initialize_response(
          request,
          empty_server_capabilities(),
          jsonrpc.legacy_protocol_version,
          None,
        )
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let #(_, result) = client.close(created)
  result |> should.be_ok
  // An older immutable copy may still hold the ID deleted by another copy.
  let stale = client.Client(..created, session_id: Some("deleted"))
  let #(reopened, _) =
    client.initialize(stale, implementation()) |> should.be_ok
  should.equal(reopened.session_id, None)
}

pub fn automatic_tool_discovery_rejects_cursor_cycles_test() {
  let issued = process.new_subject()
  let created =
    http_client(
      fn(_, _, request) {
        let assert jsonrpc.Request(
          id,
          _,
          Some(actions.ClientRequestListTools(_)),
        ) = request
        process.send(issued, Nil)
        tools_page_response(id, "repeated")
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let created =
    client.Client(
      ..created,
      peer_capabilities: Some(tool_server_capabilities()),
    )
  let #(_, result) =
    client.call_tool(
      created,
      actions.CallToolRequestParams("unknown", None, None, None),
    )
  let assert client.Transport(transport.UnexpectedResponse(_)) =
    result |> should.be_error
  should.equal(process.receive(issued, 1000), Ok(Nil))
  should.equal(process.receive(issued, 1000), Ok(Nil))
  should.equal(process.receive(issued, 5), Error(Nil))
}

pub fn automatic_tool_discovery_has_a_page_limit_test() {
  let issued = process.new_subject()
  let created =
    http_client(
      fn(_, _, request) {
        let assert jsonrpc.Request(
          id,
          _,
          Some(actions.ClientRequestListTools(params)),
        ) = request
        let offset = case params.cursor {
          None -> 0
          Some(actions.Cursor(cursor)) -> int.parse(cursor) |> should.be_ok
        }
        process.send(issued, Nil)
        tools_page_response(id, int.to_string(offset + 1))
      },
      fn(_, _, _, _, _) { empty_notification(None) },
    )
  let created =
    client.Client(
      ..created,
      peer_capabilities: Some(tool_server_capabilities()),
    )
  let #(_, result) =
    client.call_tool(
      created,
      actions.CallToolRequestParams("unknown", None, None, None),
    )
  let assert client.Transport(transport.UnexpectedResponse(_)) =
    result |> should.be_error
  list.each(list.repeat(Nil, 100), fn(_) {
    should.equal(process.receive(issued, 1000), Ok(Nil))
  })
  should.equal(process.receive(issued, 5), Error(Nil))
}

fn tools_page_response(
  id: jsonrpc.RequestId,
  cursor: String,
) -> Result(
  transport.TransportResponse(actions.ClientActionResult),
  transport.TransportError,
) {
  Ok(transport.TransportResponse(
    jsonrpc.ResultResponse(
      id,
      actions.ClientResultListTools(actions.ListToolsResult(
        [],
        actions.Page(Some(actions.Cursor(cursor))),
        None,
      )),
    ),
    None,
  ))
}

fn http_client(
  handler: fn(
    Option(String),
    String,
    jsonrpc.Request(actions.ClientActionRequest),
  ) ->
    Result(
      transport.TransportResponse(actions.ClientActionResult),
      transport.TransportError,
    ),
  notification: fn(
    transport.HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    jsonrpc.Request(actions.ActionNotification),
  ) -> Result(transport.TransportResponse(Nil), transport.TransportError),
) -> client.Client {
  client.new_with_runners(
    transport.Http(transport.HttpConfig("https://example.com", [], Some(5000))),
    transport.Runners(
      stdio_request: fn(_, _, _, _) {
        Error(transport.UnexpectedResponse("wrong transport"))
      },
      stdio_notification: fn(_, _, _, _) {
        Error(transport.UnexpectedResponse("wrong transport"))
      },
      stdio_listen: fn(_, _, _) {
        Error(transport.UnexpectedResponse("wrong transport"))
      },
      streamable_request: fn(_, session, version, _, request) {
        handler(session, version, request)
      },
      streamable_notification: notification,
    ),
    capabilities.none(),
  )
  |> client.with_protocol_version(jsonrpc.legacy_protocol_version)
}

fn initialize_response(
  request: jsonrpc.Request(actions.ClientActionRequest),
  caps: actions.ServerCapabilities,
  version: String,
  session: Option(String),
) -> Result(
  transport.TransportResponse(actions.ClientActionResult),
  transport.TransportError,
) {
  let assert jsonrpc.Request(id, _, _) = request
  Ok(transport.TransportResponse(
    jsonrpc.ResultResponse(
      id,
      actions.ClientResultInitialize(actions.InitializeResult(
        version,
        caps,
        implementation(),
        None,
        None,
      )),
    ),
    session,
  ))
}

fn empty_notification(
  session: Option(String),
) -> Result(transport.TransportResponse(Nil), transport.TransportError) {
  Ok(transport.TransportResponse(
    jsonrpc.ResultResponse(jsonrpc.StringId("notification"), Nil),
    session,
  ))
}

fn implementation() -> actions.Implementation {
  actions.Implementation("test", "1", None, None, None, [])
}

fn empty_server_capabilities() -> actions.ServerCapabilities {
  actions.ServerCapabilities(None, None, None, None, None, None, None)
}

fn tool_server_capabilities() -> actions.ServerCapabilities {
  actions.ServerCapabilities(
    None,
    None,
    None,
    None,
    None,
    Some(actions.ServerToolsCapabilities(None)),
    Some(actions.ServerTasksCapabilities(
      Some(jsonrpc.VObject([])),
      Some(jsonrpc.VObject([])),
      Some(actions.ServerTaskRequestCapabilities(Some(jsonrpc.VObject([])))),
    )),
  )
}

fn tool(name: String, support: actions.TaskSupport) -> actions.Tool {
  actions.Tool(
    name,
    None,
    None,
    jsonrpc.VObject([#("type", jsonrpc.VString("object"))]),
    Some(actions.ToolExecution(Some(support))),
    None,
    None,
    [],
    None,
  )
}
