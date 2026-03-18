import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions.{
  type ActionNotification, type ActionRequest, type ActionResult,
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
      Some(actions.RequestInitialize(params)),
    )

  case response {
    Ok(jsonrpc.ResultResponse(_, actions.ResultInitialize(result))) -> {
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
  let Client(
    transport_config: transport_config,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
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
        Ok(next_session_id) -> #(set_runtime(client, next_session_id), Ok(Nil))
        Error(error) -> #(client, Error(Transport(error)))
      }
    transport.Stdio(_) -> #(
      client,
      Error(
        Transport(transport.UnexpectedResponse(
          "Listening for server-sent requests is only supported over HTTP",
        )),
      ),
    )
  }
}

pub fn list_resources(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourcesResult, ClientError)) {
  let resource_params = case params {
    Some(p) -> p
    None -> actions.PaginatedRequestParams(None, None)
  }
  send_request(
    client,
    mcp.method_list_resources,
    Some(actions.RequestListResources(resource_params)),
  )
  |> expect_result("resources/list", fn(result) {
    case result {
      actions.ResultListResources(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn list_resource_templates(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourceTemplatesResult, ClientError)) {
  let template_params = case params {
    Some(p) -> p
    None -> actions.PaginatedRequestParams(None, None)
  }
  send_request(
    client,
    mcp.method_list_resource_templates,
    Some(actions.RequestListResourceTemplates(template_params)),
  )
  |> expect_result("resources/templates/list", fn(result) {
    case result {
      actions.ResultListResourceTemplates(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn read_resource(
  client: Client,
  params: actions.ReadResourceRequestParams,
) -> #(Client, Result(actions.ReadResourceResult, ClientError)) {
  send_request(
    client,
    mcp.method_read_resource,
    Some(actions.RequestReadResource(params)),
  )
  |> expect_result("resources/read", fn(result) {
    case result {
      actions.ResultReadResource(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn subscribe_resource(
  client: Client,
  params: actions.SubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_request(
    client,
    mcp.method_subscribe_resource,
    Some(actions.RequestSubscribeResource(params)),
  )
  |> expect_empty_result
}

pub fn unsubscribe_resource(
  client: Client,
  params: actions.UnsubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_request(
    client,
    mcp.method_unsubscribe_resource,
    Some(actions.RequestUnsubscribeResource(params)),
  )
  |> expect_empty_result
}

pub fn list_prompts(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListPromptsResult, ClientError)) {
  let prompt_params = case params {
    Some(p) -> p
    None -> actions.PaginatedRequestParams(None, None)
  }
  send_request(
    client,
    mcp.method_list_prompts,
    Some(actions.RequestListPrompts(prompt_params)),
  )
  |> expect_result("prompts/list", fn(result) {
    case result {
      actions.ResultListPrompts(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn get_prompt(
  client: Client,
  params: actions.GetPromptRequestParams,
) -> #(Client, Result(actions.GetPromptResult, ClientError)) {
  send_request(
    client,
    mcp.method_get_prompt,
    Some(actions.RequestGetPrompt(params)),
  )
  |> expect_result("prompts/get", fn(result) {
    case result {
      actions.ResultGetPrompt(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn list_tools(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListToolsResult, ClientError)) {
  let request_params = case params {
    Some(p) -> p
    None -> actions.PaginatedRequestParams(None, None)
  }
  send_request(
    client,
    mcp.method_list_tools,
    Some(actions.RequestListTools(request_params)),
  )
  |> expect_result("tools/list", fn(result) {
    case result {
      actions.ResultListTools(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn call_tool(
  client: Client,
  params: actions.CallToolRequestParams,
) -> #(Client, Result(actions.ActionResult, ClientError)) {
  send_request(
    client,
    mcp.method_call_tool,
    Some(actions.RequestCallTool(params)),
  )
  |> expect_result("tools/call", fn(result) {
    case result {
      actions.ResultCallTool(_) -> Some(result)
      actions.ResultCreateTask(_) -> Some(result)
      _ -> None
    }
  })
}

pub fn complete(
  client: Client,
  params: actions.CompleteRequestParams,
) -> #(Client, Result(actions.CompleteResult, ClientError)) {
  send_request(
    client,
    mcp.method_complete,
    Some(actions.RequestComplete(params)),
  )
  |> expect_result("completion/complete", fn(result) {
    case result {
      actions.ResultComplete(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn set_logging_level(
  client: Client,
  params: actions.SetLevelRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_request(
    client,
    mcp.method_set_logging_level,
    Some(actions.RequestSetLoggingLevel(params)),
  )
  |> expect_empty_result
}

pub fn list_roots(
  client: Client,
  meta: Option(actions.RequestMeta),
) -> #(Client, Result(actions.ListRootsResult, ClientError)) {
  send_request(
    client,
    mcp.method_list_roots,
    Some(actions.RequestListRoots(meta)),
  )
  |> expect_result("roots/list", fn(result) {
    case result {
      actions.ResultListRoots(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn create_message(
  client: Client,
  params: actions.CreateMessageRequestParams,
) -> #(Client, Result(actions.ActionResult, ClientError)) {
  send_request(
    client,
    mcp.method_create_message,
    Some(actions.RequestCreateMessage(params)),
  )
  |> expect_result("sampling/createMessage", fn(result) {
    case result {
      actions.ResultCreateMessage(_) -> Some(result)
      actions.ResultCreateTask(_) -> Some(result)
      _ -> None
    }
  })
}

pub fn elicit(
  client: Client,
  params: actions.ElicitRequestParams,
) -> #(Client, Result(actions.ActionResult, ClientError)) {
  send_request(client, mcp.method_elicit, Some(actions.RequestElicit(params)))
  |> expect_result("elicitation/create", fn(result) {
    case result {
      actions.ResultElicit(_) -> Some(result)
      actions.ResultCreateTask(_) -> Some(result)
      _ -> None
    }
  })
}

pub fn list_tasks(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListTasksResult, ClientError)) {
  let request_params = case params {
    Some(p) -> p
    None -> actions.PaginatedRequestParams(None, None)
  }
  send_request(
    client,
    mcp.method_list_tasks,
    Some(actions.RequestListTasks(request_params)),
  )
  |> expect_result("tasks/list", fn(result) {
    case result {
      actions.ResultListTasks(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn get_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.GetTaskResult, ClientError)) {
  send_request(
    client,
    mcp.method_get_task,
    Some(actions.RequestGetTask(params)),
  )
  |> expect_result("tasks/get", fn(result) {
    case result {
      actions.ResultGetTask(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn get_task_result(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.TaskPayloadResult, ClientError)) {
  send_request(
    client,
    mcp.method_get_task_result,
    Some(actions.RequestGetTaskResult(params)),
  )
  |> expect_result("tasks/result", fn(result) {
    case result {
      actions.ResultTaskPayload(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn cancel_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.CancelTaskResult, ClientError)) {
  send_request(
    client,
    mcp.method_cancel_task,
    Some(actions.RequestCancelTask(params)),
  )
  |> expect_result("tasks/cancel", fn(result) {
    case result {
      actions.ResultCancelTask(value) -> Some(value)
      _ -> None
    }
  })
}

pub fn cancelled(
  client: Client,
  params: actions.CancelledNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_cancelled,
    Some(actions.NotifyCancelled(params)),
  )
}

pub fn progress(
  client: Client,
  params: actions.ProgressNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_progress,
    Some(actions.NotifyProgress(params)),
  )
}

pub fn resource_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_resource_list_changed,
    Some(actions.NotifyResourceListChanged(None)),
  )
}

pub fn resource_updated(
  client: Client,
  params: actions.ResourceUpdatedNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_resource_updated,
    Some(actions.NotifyResourceUpdated(params)),
  )
}

pub fn prompt_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_prompts_list_changed,
    Some(actions.NotifyPromptListChanged(None)),
  )
}

pub fn tool_list_changed(client: Client) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_tools_list_changed,
    Some(actions.NotifyToolListChanged(None)),
  )
}

pub fn logging_message(
  client: Client,
  params: actions.LoggingMessageNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_logging_message,
    Some(actions.NotifyLoggingMessage(params)),
  )
}

pub fn roots_list_changed(client: Client) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_roots_list_changed,
    Some(actions.NotifyRootsListChanged(None)),
  )
}

pub fn elicitation_complete(
  client: Client,
  params: actions.ElicitationCompleteNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_elicitation_complete,
    Some(actions.NotifyElicitationComplete(params)),
  )
}

pub fn task_status(
  client: Client,
  params: actions.TaskStatusNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(
    client,
    mcp.method_notify_task_status,
    Some(actions.NotifyTaskStatus(params)),
  )
}

fn expect_empty_result(
  response: #(Client, Result(Response(ActionResult), ClientError)),
) -> #(Client, Result(Nil, ClientError)) {
  let #(client, result) = response

  case result {
    Ok(jsonrpc.ResultResponse(_, _)) -> #(client, Ok(Nil))
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
  }
}

fn expect_result(
  response: #(Client, Result(Response(ActionResult), ClientError)),
  method: String,
  extract: fn(ActionResult) -> Option(result),
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
  params: Option(ActionRequest),
) -> #(Client, Result(Response(ActionResult), ClientError)) {
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
  stdio_request: fn(transport.StdioConfig, Option(String), Request(action)) ->
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
  stdio_request: fn(transport.StdioConfig, Option(String), Request(action)) ->
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
