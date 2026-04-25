import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions.{
  type ActionNotification, type ClientActionRequest, type ClientActionResult,
  type Implementation,
}
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc.{type Request, type Response, type RpcError, Request}
import gleam_mcp/mcp
import youid/uuid

pub type Client {
  Client(
    transport_config: transport.Config,
    runners: transport.Runners,
    capabilities: capabilities.Config,
    protocol_version: String,
    session_id: Option(String),
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
  new_with_runners(transport_config, transport.default_runners(), capabilities)
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
  )
}

pub fn initialize(
  client: Client,
  client_info: Implementation,
) -> Result(#(Client, actions.InitializeResult), ClientError) {
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
      let #(_, r) = initialized(next_client)
      case r {
        Ok(_) -> Ok(#(next_client, result))
        Error(error) -> Error(error)
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
  #(client, listen_forever(client))
}

fn listen_forever(client: Client) -> Result(Nil, ClientError) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
  ) = client

  case transport_config {
    transport.Http(http_config) ->
      case
        transport.streamable_http_listen(
          http_config,
          session_id,
          protocol_version,
          capability_config,
        )
      {
        Ok(next_session_id) ->
          listen_forever(set_runtime(client, next_session_id))
        Error(error) ->
          case should_retry_http_listen(error) {
            True -> {
              process.sleep(100)
              listen_forever(client)
            }
            False -> Error(Transport(error))
          }
      }
    transport.Stdio(stdio_config) -> {
      let transport.Runners(stdio_listen: stdio_listen, ..) = runners
      case stdio_listen(stdio_config, session_id, capability_config) {
        Ok(transport.TransportResponse(session_id: next_session_id, ..)) -> {
          let _ = set_runtime(client, next_session_id)
          case process.sleep_forever() {
            _ -> Ok(Nil)
          }
        }
        Error(error) -> Error(Transport(error))
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
}

pub fn call_tool(
  client: Client,
  params: actions.CallToolRequestParams,
) -> #(Client, Result(actions.CallToolResponse, ClientError)) {
  request_action(
    client,
    mcp.method_call_tool,
    actions.ClientRequestCallTool(params),
    fn(result) {
      case result {
        actions.ClientResultCallTool(res) -> Some(actions.CallTool(res))
        actions.ClientResultCreateTask(res) -> Some(actions.CallToolTask(res))
        _ -> None
      }
    },
  )
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

pub fn tool_list_changed(client: Client) -> #(Client, Result(Nil, ClientError)) {
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

pub fn roots_list_changed(client: Client) -> #(Client, Result(Nil, ClientError)) {
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

fn send_request(
  client: Client,
  method: String,
  params: Option(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
  ) = client

  let transport.Runners(
    stdio_request: stdio_request,
    streamable_request: streamable_request,
    ..,
  ) = runners

  case
    send(
      transport_config,
      session_id,
      protocol_version,
      capability_config,
      method,
      params,
      stdio_request,
      streamable_request,
    )
  {
    Ok(transport.TransportResponse(response: value, session_id: next_session_id)) -> #(
      set_runtime(client, next_session_id),
      Ok(value),
    )
    Error(error) -> #(client, Error(error))
  }
}

fn send_notification(
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
    Error(error) -> #(client, Error(error))
  }
}

fn send(
  transport_config: transport.Config,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  method: String,
  params: Option(action),
  stdio_request: fn(
    transport.StdioConfig,
    Option(String),
    capabilities.Config,
    Request(action),
  ) ->
    Result(transport.TransportResponse(result), transport.TransportError),
  streamable_request: fn(
    transport.HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    Request(action),
  ) ->
    Result(transport.TransportResponse(result), transport.TransportError),
) -> Result(transport.TransportResponse(result), ClientError) {
  let request = Request(jsonrpc.StringId(uuid.v4_string()), method, params)

  send_message(
    transport_config,
    session_id,
    protocol_version,
    capability_config,
    request,
    stdio_request,
    streamable_request,
  )
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
  ) ->
    Result(transport.TransportResponse(result), transport.TransportError),
  streamable_request: fn(
    transport.HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    Request(action),
  ) ->
    Result(transport.TransportResponse(result), transport.TransportError),
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
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capabilities,
    protocol_version: protocol_version,
    ..,
  ) = client

  let next_session_id = case session_id {
    Some(_) -> session_id
    None -> client.session_id
  }

  Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capabilities,
    protocol_version: protocol_version,
    session_id: next_session_id,
  )
}
