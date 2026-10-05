import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions.{
  type ActionNotification, type ClientActionRequest, type ClientActionResult,
  type Implementation,
}
import gleam_mcp/client/capabilities
import gleam_mcp/client/runtime
import gleam_mcp/client/stdio_manager
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc.{type Request, type Response, type RpcError, Request}
import gleam_mcp/mcp
import youid/uuid

const maximum_tool_discovery_pages = 100

pub type Client {
  Client(
    transport_config: transport.Config,
    runners: transport.Runners,
    capabilities: capabilities.Config,
    protocol_version: String,
    session_id: Option(String),
    peer_capabilities: Option(actions.ServerCapabilities),
    client_info: Option(Implementation),
    cached_tools: Dict(String, actions.Tool),
    stdio_manager: Option(stdio_manager.Manager),
    closed: Bool,
    lifecycle: runtime.Control,
    generation: Int,
  )
}

pub type ClientError {
  Rpc(RpcError)
  Transport(transport.TransportError)
}

pub fn new(
  transport_config: transport.Config,
  capabilities: capabilities.Config,
) -> Client {
  let manager = stdio_manager.start()
  let client =
    new_with_runners(
      transport_config,
      transport.default_runners_with_manager(manager),
      capabilities,
    )
  Client(..client, stdio_manager: Some(manager))
}

pub fn new_with_runners(
  transport_config: transport.Config,
  runners: transport.Runners,
  capabilities: capabilities.Config,
) -> Client {
  Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capabilities,
    protocol_version: jsonrpc.latest_protocol_version,
    session_id: None,
    peer_capabilities: None,
    client_info: None,
    cached_tools: dict.new(),
    stdio_manager: None,
    closed: False,
    lifecycle: runtime.new(),
    generation: 0,
  )
}

pub fn initialize(
  client: Client,
  client_info: Implementation,
) -> Result(#(Client, actions.InitializeResult), ClientError) {
  let client = case is_closed(client) {
    True ->
      Client(
        ..client,
        session_id: None,
        peer_capabilities: None,
        cached_tools: dict.new(),
      )
    False -> client
  }
  let generation = runtime.open(client.lifecycle)
  initialize_current(Client(..client, generation: generation), client_info)
}

fn initialize_current(
  client: Client,
  client_info: Implementation,
) -> Result(#(Client, actions.InitializeResult), ClientError) {
  let client = Client(..client, client_info: Some(client_info), closed: False)
  let Client(capabilities: config, protocol_version: protocol_version, ..) =
    client

  let params =
    actions.InitializeRequestParams(
      protocol_version,
      capabilities.to_initialize_capabilities(config),
      client_info,
      None,
    )

  let #(next_client, response) =
    send_request(
      client,
      mcp.method_initialize,
      Some(actions.ClientRequestInitialize(params)),
    )

  case response {
    Ok(jsonrpc.ResultResponse(_, actions.ClientResultInitialize(result))) -> {
      use _ <- result.try(validate_initialize_result(result))
      let next_client =
        Client(
          ..next_client,
          protocol_version: result.protocol_version,
          peer_capabilities: Some(result.capabilities),
          cached_tools: dict.new(),
        )
      case is_closed(next_client) {
        True -> {
          let _ = close(next_client)
          Error(Transport(transport.UnexpectedResponse("MCP client is closed")))
        }
        False -> {
          let #(ready_client, r) = initialized(next_client)
          case r, is_closed(ready_client) {
            Ok(_), False -> Ok(#(ready_client, result))
            _, True -> {
              let _ = close(ready_client)
              Error(
                Transport(transport.UnexpectedResponse("MCP client is closed")),
              )
            }
            Error(error), False -> Error(error)
          }
        }
      }
    }
    Ok(jsonrpc.ResultResponse(_, _)) ->
      Error(
        Transport(transport.UnexpectedResponse(
          "Unexpected response to initialize request",
        )),
      )
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(Rpc(error))
    Error(error) -> Error(error)
  }
}

pub fn peer_capabilities(client: Client) -> Option(actions.ServerCapabilities) {
  client.peer_capabilities
}

fn validate_initialize_result(
  value: actions.InitializeResult,
) -> Result(Nil, ClientError) {
  case value.protocol_version == jsonrpc.latest_protocol_version {
    False ->
      Error(
        Transport(transport.UnexpectedResponse(
          "Unsupported negotiated MCP protocol version: "
          <> value.protocol_version,
        )),
      )
    True ->
      case value.capabilities.tasks {
        Some(actions.ServerTasksCapabilities(
          requests: Some(actions.ServerTaskRequestCapabilities(tools_call: Some(
            _,
          ))),
          ..,
        ))
          if value.capabilities.tools == None
        ->
          Error(
            Transport(transport.UnexpectedResponse(
              "Server declared tool tasks without tools capability",
            )),
          )
        _ -> Ok(Nil)
      }
  }
}

/// Close resources owned by the default client. Custom runner implementations
/// own their subprocess resources and must close them themselves.
pub fn close(client: Client) -> #(Client, Result(Nil, ClientError)) {
  runtime.close(client.lifecycle, client.generation)
  let outcome = case client.transport_config {
    transport.Http(config) ->
      case client.session_id {
        None -> Ok(Nil)
        Some(_) ->
          transport.close_http(
            config,
            client.session_id,
            client.protocol_version,
          )
          |> result.map_error(Transport)
      }
    transport.Stdio(_) ->
      case client.stdio_manager {
        Some(manager) ->
          stdio_manager.close(manager, client.session_id)
          |> result.map_error(fn(error) {
            Transport(transport.ProcessError(error))
          })
        None -> Ok(Nil)
      }
  }
  case outcome {
    Ok(Nil) | Error(Transport(transport.SessionExpired)) -> #(
      Client(
        ..client,
        session_id: None,
        peer_capabilities: None,
        cached_tools: dict.new(),
        closed: True,
      ),
      Ok(Nil),
    )
    Error(error) -> #(Client(..client, closed: True), Error(error))
  }
}

/// Override the timeout for subsequent requests from this client value.
pub fn with_request_timeout(client: Client, timeout_ms: Int) -> Client {
  let timeout_ms = case timeout_ms < 1 {
    True -> 1
    False -> timeout_ms
  }
  let config = case client.transport_config {
    transport.Http(config) ->
      transport.Http(
        transport.HttpConfig(..config, timeout_ms: Some(timeout_ms)),
      )
    transport.Stdio(config) ->
      transport.Stdio(
        transport.StdioConfig(..config, timeout_ms: Some(timeout_ms)),
      )
  }
  Client(..client, transport_config: config)
}

pub fn ping(client: Client) -> #(Client, Result(Nil, ClientError)) {
  let #(next_client, response) = send_request(client, mcp.method_ping, None)
  case response {
    Ok(jsonrpc.ResultResponse(_, _)) -> #(next_client, Ok(Nil))
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(next_client, Error(Rpc(error)))
    Error(error) -> #(next_client, Error(error))
  }
}

pub fn initialized(client: Client) -> #(Client, Result(Nil, ClientError)) {
  send_notification(client, mcp.method_initialized, None)
}

pub fn listen(client: Client) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(
      client,
      Error(Transport(transport.UnexpectedResponse("MCP client is closed"))),
    )
    False -> listen_forever(client)
  }
}

fn listen_forever(client: Client) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(Client(..client, closed: True), Ok(Nil))
    False -> listen_once(client)
  }
}

fn listen_once(client: Client) -> #(Client, Result(Nil, ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  case transport_config {
    transport.Http(http_config) -> {
      let stop = process.new_subject()
      runtime.watch(client.lifecycle, client.generation, stop)
      let outcome =
        transport.streamable_http_listen_until_closed(
          http_config,
          session_id,
          protocol_version,
          capability_config,
          stop,
        )
      runtime.unwatch(client.lifecycle, stop)
      case outcome {
        Ok(next_session_id) ->
          listen_forever(set_runtime(client, next_session_id))
        Error(error) ->
          case is_closed(client), should_retry_http_listen(error) {
            True, _ -> #(Client(..client, closed: True), Ok(Nil))
            False, True -> {
              process.sleep(100)
              listen_forever(client)
            }
            False, False ->
              case error {
                transport.SessionExpired -> #(
                  recover_expired_session(
                    client,
                    jsonrpc.Request(
                      jsonrpc.StringId("expired-listen"),
                      "listen",
                      None,
                    ),
                  ),
                  Error(Transport(error)),
                )
                _ -> #(client, Error(Transport(error)))
              }
          }
      }
    }
    transport.Stdio(stdio_config) -> {
      let transport.Runners(stdio_listen: stdio_listen, ..) = runners
      case stdio_listen(stdio_config, session_id, capability_config) {
        Ok(transport.TransportResponse(session_id: next_session_id, ..)) -> {
          let client = set_runtime(client, next_session_id)
          runtime.await_closed(client.lifecycle, client.generation)
          #(Client(..client, closed: True), Ok(Nil))
        }
        Error(error) -> #(client, Error(Transport(error)))
      }
    }
  }
}

fn should_retry_http_listen(error: transport.TransportError) -> Bool {
  case error {
    transport.TimeoutError -> True
    transport.HttpError(_) -> True
    _ -> False
  }
}

pub fn list_resources(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourcesResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_resources,
    params,
    actions.ClientRequestListResources,
    fn(result) {
      case result {
        actions.ClientResultListResources(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn list_resource_templates(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourceTemplatesResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_resource_templates,
    params,
    actions.ClientRequestListResourceTemplates,
    fn(result) {
      case result {
        actions.ClientResultListResourceTemplates(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn read_resource(
  client: Client,
  params: actions.ReadResourceRequestParams,
) -> #(Client, Result(actions.ReadResourceResult, ClientError)) {
  request_action(
    client,
    mcp.method_read_resource,
    actions.ClientRequestReadResource(params),
    fn(result) {
      case result {
        actions.ClientResultReadResource(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn subscribe_resource(
  client: Client,
  params: actions.SubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_subscribe_resource,
    actions.ClientRequestSubscribeResource(params),
  )
}

pub fn unsubscribe_resource(
  client: Client,
  params: actions.UnsubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_unsubscribe_resource,
    actions.ClientRequestUnsubscribeResource(params),
  )
}

pub fn list_prompts(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListPromptsResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_prompts,
    params,
    actions.ClientRequestListPrompts,
    fn(result) {
      case result {
        actions.ClientResultListPrompts(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn get_prompt(
  client: Client,
  params: actions.GetPromptRequestParams,
) -> #(Client, Result(actions.GetPromptResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_prompt,
    actions.ClientRequestGetPrompt(params),
    fn(result) {
      case result {
        actions.ClientResultGetPrompt(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn list_tools(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListToolsResult, ClientError)) {
  let #(next_client, outcome) =
    request_paginated(
      client,
      mcp.method_list_tools,
      params,
      actions.ClientRequestListTools,
      fn(result) {
        case result {
          actions.ClientResultListTools(value) -> Some(value)
          _ -> None
        }
      },
    )
  case outcome {
    Ok(page) -> {
      let tools = case params {
        Some(actions.PaginatedRequestParams(cursor: Some(_), ..)) ->
          next_client.cached_tools
        _ -> dict.new()
      }
      let tools =
        list.fold(page.tools, tools, fn(tools, tool) {
          dict.insert(tools, tool.name, tool)
        })
      #(Client(..next_client, cached_tools: tools), Ok(page))
    }
    Error(error) -> #(next_client, Error(error))
  }
}

pub fn call_tool(
  client: Client,
  params: actions.CallToolRequestParams,
) -> #(Client, Result(actions.CallToolResponse, ClientError)) {
  let #(client, descriptor) = ensure_tool_descriptor(client, params.name)
  case descriptor {
    Error(error) -> #(client, Error(error))
    Ok(_) ->
      request_action(
        client,
        mcp.method_call_tool,
        actions.ClientRequestCallTool(params),
        fn(result) {
          case result {
            actions.ClientResultCallTool(res) -> Some(actions.CallTool(res))
            actions.ClientResultCreateTask(res) ->
              Some(actions.CallToolTask(res))
            _ -> None
          }
        },
      )
  }
}

pub fn complete(
  client: Client,
  params: actions.CompleteRequestParams,
) -> #(Client, Result(actions.CompleteResult, ClientError)) {
  request_action(
    client,
    mcp.method_complete,
    actions.ClientRequestComplete(params),
    fn(result) {
      case result {
        actions.ClientResultComplete(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn set_logging_level(
  client: Client,
  params: actions.SetLevelRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_set_logging_level,
    actions.ClientRequestSetLoggingLevel(params),
  )
}

pub fn list_tasks(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListTasksResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_tasks,
    params,
    actions.ClientRequestListTasks,
    fn(result) {
      case result {
        actions.ClientResultListTasks(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn get_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.GetTaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_task,
    actions.ClientRequestGetTask(params),
    fn(result) {
      case result {
        actions.ClientResultGetTask(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn get_task_result(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.TaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_task_result,
    actions.ClientRequestGetTaskResult(params),
    fn(result) {
      case result {
        actions.ClientResultTaskResult(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn cancel_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.CancelTaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_cancel_task,
    actions.ClientRequestCancelTask(params),
    fn(result) {
      case result {
        actions.ClientResultCancelTask(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn cancelled(
  client: Client,
  params: actions.CancelledNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_cancelled,
    actions.NotifyCancelled(params),
  )
}

pub fn progress(
  client: Client,
  params: actions.ProgressNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_progress,
    actions.NotifyProgress(params),
  )
}

pub fn resource_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_resource_list_changed,
    actions.NotifyResourceListChanged(None),
  )
}

pub fn resource_updated(
  client: Client,
  params: actions.ResourceUpdatedNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_resource_updated,
    actions.NotifyResourceUpdated(params),
  )
}

pub fn prompt_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_prompts_list_changed,
    actions.NotifyPromptListChanged(None),
  )
}

pub fn tool_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_tools_list_changed,
    actions.NotifyToolListChanged(None),
  )
}

pub fn logging_message(
  client: Client,
  params: actions.LoggingMessageNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_logging_message,
    actions.NotifyLoggingMessage(params),
  )
}

pub fn roots_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_roots_list_changed,
    actions.NotifyRootsListChanged(None),
  )
}

pub fn elicitation_complete(
  client: Client,
  params: actions.ElicitationCompleteNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_elicitation_complete,
    actions.NotifyElicitationComplete(params),
  )
}

pub fn task_status(
  client: Client,
  params: actions.TaskStatusNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_task_status,
    actions.NotifyTaskStatus(params),
  )
}

fn request_paginated(
  client: Client,
  method: String,
  params: Option(actions.PaginatedRequestParams),
  wrap: fn(actions.PaginatedRequestParams) -> actions.ClientActionRequest,
  extract: fn(actions.ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  request_action(
    client,
    method,
    wrap(default_paginated_params(params)),
    extract,
  )
}

fn request_action(
  client: Client,
  method: String,
  action: actions.ClientActionRequest,
  extract: fn(actions.ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  send_request(client, method, Some(action))
  |> expect_result(method, extract)
}

fn request_empty(
  client: Client,
  method: String,
  action: actions.ClientActionRequest,
) -> #(Client, Result(Nil, ClientError)) {
  send_request(client, method, Some(action))
  |> expect_empty_result
}

fn notify_action(
  client: Client,
  method: String,
  action: ActionNotification,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(client, method, Some(action))
}

fn default_paginated_params(
  params: Option(actions.PaginatedRequestParams),
) -> actions.PaginatedRequestParams {
  case params {
    Some(value) -> value
    None -> actions.PaginatedRequestParams(None, None)
  }
}

fn expect_empty_result(
  response: #(Client, Result(Response(ClientActionResult), ClientError)),
) -> #(Client, Result(Nil, ClientError)) {
  let #(client, result) = response

  case result {
    Ok(jsonrpc.ResultResponse(_, _)) -> #(client, Ok(Nil))
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
  }
}

fn expect_result(
  response: #(Client, Result(Response(ClientActionResult), ClientError)),
  method: String,
  extract: fn(ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  let #(client, pending) = response

  case pending {
    Ok(jsonrpc.ResultResponse(_, result)) -> {
      case extract(result) {
        Some(value) -> #(client, Ok(value))
        None -> #(client, Error(unexpected_response_error(method)))
      }
    }
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
  }
}

fn unexpected_response_error(method: String) -> ClientError {
  Transport(transport.UnexpectedResponse(
    "Unexpected response to " <> method <> " request",
  ))
}

fn ensure_tool_descriptor(
  client: Client,
  name: String,
) -> #(Client, Result(Nil, ClientError)) {
  case client.peer_capabilities {
    None -> #(client, Ok(Nil))
    Some(_) ->
      case dict.get(client.cached_tools, name) {
        Ok(_) -> #(client, Ok(Nil))
        Error(Nil) ->
          discover_tool(client, name, None, [], maximum_tool_discovery_pages)
      }
  }
}

fn discover_tool(
  client: Client,
  name: String,
  cursor: Option(actions.Cursor),
  visited: List(actions.Cursor),
  remaining_pages: Int,
) -> #(Client, Result(Nil, ClientError)) {
  case remaining_pages <= 0 {
    True -> #(
      client,
      Error(
        Transport(transport.UnexpectedResponse(
          "Tool discovery exceeded 100 pages; list and cache tools explicitly",
        )),
      ),
    )
    False -> discover_tool_page(client, name, cursor, visited, remaining_pages)
  }
}

fn discover_tool_page(
  client: Client,
  name: String,
  cursor: Option(actions.Cursor),
  visited: List(actions.Cursor),
  remaining_pages: Int,
) -> #(Client, Result(Nil, ClientError)) {
  let #(client, response) =
    list_tools(client, Some(actions.PaginatedRequestParams(cursor, None)))
  case response {
    Error(error) -> #(client, Error(error))
    Ok(page) ->
      case dict.get(client.cached_tools, name) {
        Ok(_) -> #(client, Ok(Nil))
        Error(Nil) ->
          case page.page.next_cursor {
            Some(next) ->
              case list.contains(visited, next) {
                True -> #(
                  client,
                  Error(
                    Transport(transport.UnexpectedResponse(
                      "Server repeated a tools/list pagination cursor",
                    )),
                  ),
                )
                False ->
                  discover_tool(
                    client,
                    name,
                    Some(next),
                    [next, ..visited],
                    remaining_pages - 1,
                  )
              }
            None -> #(
              client,
              Error(Rpc(jsonrpc.invalid_params_error("Unknown tool: " <> name))),
            )
          }
      }
  }
}

fn validate_request_capability(
  client: Client,
  params: Option(ClientActionRequest),
  method: String,
) -> Result(Nil, ClientError) {
  case is_closed(client), params {
    True, Some(actions.ClientRequestInitialize(_)) -> Ok(Nil)
    True, _ ->
      Error(Transport(transport.UnexpectedResponse("MCP client is closed")))
    False, _ ->
      case client.peer_capabilities, params {
        None, _ -> Ok(Nil)
        Some(caps), Some(action) -> {
          let allowed = case action {
            actions.ClientRequestInitialize(_) | actions.ClientRequestPing(_) ->
              True
            actions.ClientRequestListResources(_)
            | actions.ClientRequestListResourceTemplates(_)
            | actions.ClientRequestReadResource(_) -> caps.resources != None
            actions.ClientRequestSubscribeResource(_)
            | actions.ClientRequestUnsubscribeResource(_) ->
              case caps.resources {
                Some(cap) -> cap.subscribe == Some(True)
                None -> False
              }
            actions.ClientRequestListPrompts(_)
            | actions.ClientRequestGetPrompt(_) -> caps.prompts != None
            actions.ClientRequestListTools(_)
            | actions.ClientRequestCallTool(_) -> caps.tools != None
            actions.ClientRequestComplete(_) -> caps.completions != None
            actions.ClientRequestSetLoggingLevel(_) -> caps.logging != None
            actions.ClientRequestListTasks(_) ->
              case caps.tasks {
                Some(tasks) -> tasks.list != None
                None -> False
              }
            actions.ClientRequestCancelTask(_) ->
              case caps.tasks {
                Some(tasks) -> tasks.cancel != None
                None -> False
              }
            actions.ClientRequestGetTask(_)
            | actions.ClientRequestGetTaskResult(_) -> caps.tasks != None
          }
          case allowed {
            False ->
              Error(
                Rpc(jsonrpc.method_not_found_error(
                  "Peer did not declare capability for " <> method,
                )),
              )
            True ->
              case action {
                actions.ClientRequestCallTool(params) ->
                  validate_tool_task(client, caps, params)
                _ -> Ok(Nil)
              }
          }
        }
        _, None -> Ok(Nil)
      }
  }
}

fn validate_tool_task(
  client: Client,
  caps: actions.ServerCapabilities,
  params: actions.CallToolRequestParams,
) -> Result(Nil, ClientError) {
  let support = case dict.get(client.cached_tools, params.name) {
    Ok(tool) ->
      case tool.execution {
        Some(execution) -> execution.task_support
        None -> None
      }
    Error(Nil) -> None
  }
  let task_calls = case caps.tasks {
    Some(actions.ServerTasksCapabilities(requests: Some(requests), ..)) ->
      requests.tools_call != None
    _ -> False
  }
  case params.task, support {
    Some(_), _ if !task_calls ->
      Error(
        Rpc(jsonrpc.method_not_found_error(
          "Peer does not support task-augmented tools/call",
        )),
      )
    Some(_), Some(actions.TaskForbidden) | Some(_), None ->
      Error(
        Rpc(jsonrpc.method_not_found_error(
          "Tool does not support task augmentation",
        )),
      )
    None, Some(actions.TaskRequired) ->
      Error(
        Rpc(jsonrpc.method_not_found_error("Tool requires task augmentation")),
      )
    _, _ -> Ok(Nil)
  }
}

fn recover_expired_session(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> Client {
  let fresh =
    Client(
      ..client,
      session_id: None,
      peer_capabilities: None,
      cached_tools: dict.new(),
    )
  let initialize_request = case incoming {
    Request(_, method, _) -> method == mcp.method_initialize
    jsonrpc.Notification(_, _) -> False
  }
  case is_closed(client), initialize_request, client.client_info {
    False, False, Some(info) ->
      case initialize_current(fresh, info) {
        Ok(#(recovered, _)) -> recovered
        Error(_) -> fresh
      }
    True, _, _ -> Client(..fresh, closed: True)
    _, _, _ -> fresh
  }
}

fn validate_response_mode(
  client: Client,
  incoming: Request(ClientActionRequest),
  response: Response(ClientActionResult),
) -> Result(Response(ClientActionResult), ClientError) {
  case client.peer_capabilities, incoming, response {
    Some(_),
      Request(_, _, Some(actions.ClientRequestCallTool(params))),
      jsonrpc.ResultResponse(_, result)
    -> {
      case params.task, result {
        Some(_), actions.ClientResultCreateTask(_)
        | None, actions.ClientResultCallTool(_)
        -> Ok(response)
        _, _ ->
          Error(
            Transport(transport.UnexpectedResponse(
              "tools/call response did not match task augmentation mode",
            )),
          )
      }
    }
    _, _, _ -> Ok(response)
  }
}

fn send_request(
  client: Client,
  method: String,
  params: Option(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  request(client, Request(jsonrpc.StringId(uuid.v4_string()), method, params))
}

/// Issue a request with a caller-selected ID. Use the same ID with `cancelled`
/// for ordinary requests; task execution must be cancelled with `cancel_task`.
/// Request metadata can include a progress token handled by the configured
/// progress callback.
pub fn request(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  case incoming {
    jsonrpc.Notification(_, _) -> #(
      client,
      Error(Rpc(jsonrpc.invalid_params_error("Expected a request"))),
    )
    Request(_, method, params) -> {
      let #(client, prepared) = case params {
        Some(actions.ClientRequestCallTool(params)) ->
          ensure_tool_descriptor(client, params.name)
        _ -> #(client, Ok(Nil))
      }
      case prepared {
        Error(error) -> #(client, Error(error))
        Ok(Nil) ->
          case validate_request_capability(client, params, method) {
            Error(error) -> #(client, Error(error))
            Ok(Nil) -> perform_request(client, incoming)
          }
      }
    }
  }
}

/// Set a timeout for one request while retaining the client's default timeout.
pub fn request_with_timeout(
  client: Client,
  incoming: Request(ClientActionRequest),
  timeout_ms: Int,
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let #(next_client, outcome) =
    request(with_request_timeout(client, timeout_ms), incoming)
  #(Client(..next_client, transport_config: client.transport_config), outcome)
}

fn perform_request(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  let transport.Runners(
    stdio_request: stdio_request,
    streamable_request: streamable_request,
    ..,
  ) = runners

  case
    send_message(
      transport_config,
      session_id,
      protocol_version,
      capability_config,
      incoming,
      stdio_request,
      streamable_request,
    )
  {
    Ok(transport.TransportResponse(response: value, session_id: next_session_id)) -> #(
      set_runtime(client, next_session_id),
      validate_response_mode(client, incoming, value),
    )
    Error(Transport(transport.SessionExpired)) -> #(
      recover_expired_session(client, incoming),
      Error(Transport(transport.SessionExpired)),
    )
    Error(error) -> #(client, Error(error))
  }
}

fn send_notification(
  client: Client,
  method: String,
  params: Option(ActionNotification),
) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(
      client,
      Error(Transport(transport.UnexpectedResponse("MCP client is closed"))),
    )
    False -> perform_notification(client, method, params)
  }
}

fn perform_notification(
  client: Client,
  method: String,
  params: Option(ActionNotification),
) -> #(Client, Result(Nil, ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  let transport.Runners(
    stdio_notification: stdio_request,
    streamable_notification: streamable_request,
    ..,
  ) = runners

  let notification = jsonrpc.Notification(method, params)

  case
    send_message(
      transport_config,
      session_id,
      protocol_version,
      capability_config,
      notification,
      stdio_request,
      streamable_request,
    )
  {
    Ok(transport.TransportResponse(session_id: next_session_id, ..)) -> #(
      set_runtime(client, next_session_id),
      Ok(Nil),
    )
    Error(Transport(transport.SessionExpired)) -> {
      let client = case method == mcp.method_initialized {
        True ->
          Client(
            ..client,
            session_id: None,
            peer_capabilities: None,
            cached_tools: dict.new(),
          )
        False ->
          recover_expired_session(
            client,
            jsonrpc.Request(
              jsonrpc.StringId("expired-notification"),
              method,
              None,
            ),
          )
      }
      #(client, Error(Transport(transport.SessionExpired)))
    }
    Error(error) -> #(client, Error(error))
  }
}

fn send_message(
  transport_config: transport.Config,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  request: Request(action),
  stdio_request: fn(
    transport.StdioConfig,
    Option(String),
    capabilities.Config,
    Request(action),
  ) -> Result(transport.TransportResponse(result), transport.TransportError),
  streamable_request: fn(
    transport.HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    Request(action),
  ) -> Result(transport.TransportResponse(result), transport.TransportError),
) -> Result(transport.TransportResponse(result), ClientError) {
  transport.send_request(
    transport_config,
    session_id,
    protocol_version,
    capability_config,
    request,
    stdio_request,
    streamable_request,
  )
  |> result.map_error(Transport)
}

fn set_runtime(client: Client, session_id: Option(String)) -> Client {
  let next_session_id = case session_id {
    Some(_) -> session_id
    None -> client.session_id
  }

  Client(..client, session_id: next_session_id)
}

fn is_closed(client: Client) -> Bool {
  client.closed || !runtime.is_open(client.lifecycle, client.generation)
}
