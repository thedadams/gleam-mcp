import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions.{
  type ActionNotification, type ActionRequest, type ActionResult,
  type ClientCapabilities, ClientCapabilities, ClientElicitationCapabilities,
  ClientRootsCapabilities, ClientSamplingCapabilities,
}
import gleam_mcp/jsonrpc.{
  type Request, type Response, type RpcError, type Value, VObject,
}
import gleam_mcp/mcp
import gleam_mcp/task_store

pub type Root {
  Root(uri: String, name: Option(String), meta: Option(Value))
}

pub type CreateMessageHandlerResult {
  CreateMessage(actions.CreateMessageResult)
  CreateMessageTask(actions.CreateTaskResult)
}

pub type ElicitHandlerResult {
  Elicit(actions.ElicitResult)
  ElicitTask(actions.CreateTaskResult)
}

pub type Config {
  Config(
    list_roots: Option(
      fn(Option(actions.RequestMeta)) -> Result(List(Root), RpcError),
    ),
    notify_cancelled: Option(
      fn(actions.CancelledNotificationParams) -> Result(Nil, RpcError),
    ),
    notify_progress: Option(
      fn(actions.ProgressNotificationParams) -> Result(Nil, RpcError),
    ),
    notify_resource_list_changed: Option(fn() -> Result(Nil, RpcError)),
    notify_resource_updated: Option(
      fn(actions.ResourceUpdatedNotificationParams) -> Result(Nil, RpcError),
    ),
    notify_prompt_list_changed: Option(fn() -> Result(Nil, RpcError)),
    notify_tool_list_changed: Option(fn() -> Result(Nil, RpcError)),
    notify_logging_message: Option(
      fn(actions.LoggingMessageNotificationParams) -> Result(Nil, RpcError),
    ),
    notify_roots_list_changed: Option(fn() -> Result(Nil, RpcError)),
    notify_elicitation_complete: Option(
      fn(actions.ElicitationCompleteNotificationParams) -> Result(Nil, RpcError),
    ),
    notify_task_status: Option(
      fn(actions.TaskStatusNotificationParams) -> Result(Nil, RpcError),
    ),
    task_store: task_store.Store,
    create_message: Option(
      fn(actions.CreateMessageRequestParams) ->
        Result(CreateMessageHandlerResult, RpcError),
    ),
    sampling_tools: Option(fn(Value) -> Result(Nil, RpcError)),
    sampling_context: Option(fn(Value) -> Result(Nil, RpcError)),
    elicit_form: Option(
      fn(actions.ElicitRequestFormParams) ->
        Result(ElicitHandlerResult, RpcError),
    ),
    elicit_url: Option(
      fn(actions.ElicitRequestUrlParams) ->
        Result(ElicitHandlerResult, RpcError),
    ),
  )
}

pub fn none() -> Config {
  Config(
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    task_store.new(),
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_list_roots(
  config: Config,
  handler: fn(Option(actions.RequestMeta)) -> Result(List(Root), RpcError),
) -> Config {
  let Config(
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    create_message: create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    ..,
  ) = config

  Config(
    Some(handler),
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    create_message,
    sampling_tools,
    sampling_context,
    elicit_form,
    elicit_url,
  )
}

pub fn with_notify_cancelled(
  config: Config,
  handler: fn(actions.CancelledNotificationParams) -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    Some(handler),
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_progress(
  config: Config,
  handler: fn(actions.ProgressNotificationParams) -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    Some(handler),
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_resource_list_changed(
  config: Config,
  handler: fn() -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    Some(handler),
    None,
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_resource_updated(
  config: Config,
  handler: fn(actions.ResourceUpdatedNotificationParams) ->
    Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    Some(handler),
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_prompt_list_changed(
  config: Config,
  handler: fn() -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    Some(handler),
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_tool_list_changed(
  config: Config,
  handler: fn() -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    None,
    Some(handler),
    None,
    None,
    None,
    None,
  )
}

pub fn with_notify_logging_message(
  config: Config,
  handler: fn(actions.LoggingMessageNotificationParams) -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    None,
    None,
    Some(handler),
    None,
    None,
    None,
  )
}

pub fn with_notify_roots_list_changed(
  config: Config,
  handler: fn() -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    Some(handler),
    None,
    None,
  )
}

pub fn with_notify_elicitation_complete(
  config: Config,
  handler: fn(actions.ElicitationCompleteNotificationParams) ->
    Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    Some(handler),
    None,
  )
}

pub fn with_notify_task_status(
  config: Config,
  handler: fn(actions.TaskStatusNotificationParams) -> Result(Nil, RpcError),
) -> Config {
  update_callbacks(
    config,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    Some(handler),
  )
}

pub fn with_create_message(
  config: Config,
  handler: fn(actions.CreateMessageRequestParams) ->
    Result(CreateMessageHandlerResult, RpcError),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    ..,
  ) = config

  Config(
    list_roots,
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    Some(handler),
    sampling_tools,
    sampling_context,
    elicit_form,
    elicit_url,
  )
}

pub fn with_sampling_tools(
  config: Config,
  handler: fn(Value) -> Result(Nil, RpcError),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    create_message: create_message,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    ..,
  ) = config

  Config(
    list_roots,
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    create_message,
    Some(handler),
    sampling_context,
    elicit_form,
    elicit_url,
  )
}

pub fn with_sampling_context(
  config: Config,
  handler: fn(Value) -> Result(Nil, RpcError),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    create_message: create_message,
    sampling_tools: sampling_tools,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    ..,
  ) = config

  Config(
    list_roots,
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    create_message,
    sampling_tools,
    Some(handler),
    elicit_form,
    elicit_url,
  )
}

pub fn with_elicit_form(
  config: Config,
  handler: fn(actions.ElicitRequestFormParams) ->
    Result(ElicitHandlerResult, RpcError),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    create_message: create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_url: elicit_url,
    ..,
  ) = config

  Config(
    list_roots,
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    create_message,
    sampling_tools,
    sampling_context,
    Some(handler),
    elicit_url,
  )
}

pub fn with_elicit_url(
  config: Config,
  handler: fn(actions.ElicitRequestUrlParams) ->
    Result(ElicitHandlerResult, RpcError),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    task_store: tasks,
    create_message: create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    ..,
  ) = config

  Config(
    list_roots,
    notify_cancelled,
    notify_progress,
    notify_resource_list_changed,
    notify_resource_updated,
    notify_prompt_list_changed,
    notify_tool_list_changed,
    notify_logging_message,
    notify_roots_list_changed,
    notify_elicitation_complete,
    notify_task_status,
    tasks,
    create_message,
    sampling_tools,
    sampling_context,
    elicit_form,
    Some(handler),
  )
}

pub fn to_initialize_capabilities(config: Config) -> ClientCapabilities {
  let Config(
    list_roots: list_roots,
    notify_cancelled: _,
    notify_progress: _,
    notify_resource_list_changed: _,
    notify_resource_updated: _,
    notify_prompt_list_changed: _,
    notify_tool_list_changed: _,
    notify_logging_message: _,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: _,
    notify_task_status: _,
    task_store: _,
    create_message: create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
  ) = config

  let roots = case list_roots {
    None -> None
    Some(_) ->
      Some(
        ClientRootsCapabilities(
          list_changed: Some(has(notify_roots_list_changed)),
        ),
      )
  }

  let sampling = case create_message, sampling_tools, sampling_context {
    None, None, None -> None
    _, _, _ ->
      Some(
        ClientSamplingCapabilities(
          context: case sampling_context {
            Some(_) -> Some(VObject([]))
            None -> None
          },
          tools: case sampling_tools {
            Some(_) -> Some(VObject([]))
            None -> None
          },
        ),
      )
  }

  let elicitation = case elicit_form, elicit_url {
    None, None -> None
    _, _ ->
      Some(
        ClientElicitationCapabilities(
          form: case elicit_form {
            Some(_) -> Some(VObject([]))
            None -> None
          },
          url: case elicit_url {
            Some(_) -> Some(VObject([]))
            None -> None
          },
        ),
      )
  }

  ClientCapabilities(
    experimental: None,
    roots: roots,
    sampling: sampling,
    elicitation: elicitation,
    tasks: case create_message, elicit_form, elicit_url {
      None, None, None -> None
      _, _, _ ->
        Some(actions.ClientTasksCapabilities(
          list: Some(VObject([])),
          cancel: Some(VObject([])),
          requests: Some(
            actions.ClientTaskRequestCapabilities(
              sampling_create_message: case create_message {
                Some(_) -> Some(VObject([]))
                None -> None
              },
              elicitation_create: case elicit_form, elicit_url {
                Some(_), _ -> Some(VObject([]))
                _, Some(_) -> Some(VObject([]))
                None, None -> None
              },
            ),
          ),
        ))
    },
  )
}

pub fn handle_request(
  config: Config,
  request: Request(ActionRequest),
) -> Result(Response(ActionResult), RpcError) {
  case request {
    jsonrpc.Request(id, method, Some(action)) ->
      dispatch_request(config, id, method, action)
    jsonrpc.Request(id, method, None) ->
      Ok(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.invalid_params_error("Missing params for " <> method),
      ))
    jsonrpc.Notification(method, _) ->
      Ok(jsonrpc.ErrorResponse(
        None,
        jsonrpc.method_not_found_error(
          "Expected request, got notification: " <> method,
        ),
      ))
  }
}

pub fn handle_notification(
  config: Config,
  notification: Request(ActionNotification),
) -> Result(Nil, RpcError) {
  let Config(
    notify_cancelled: notify_cancelled,
    notify_progress: notify_progress,
    notify_resource_list_changed: notify_resource_list_changed,
    notify_resource_updated: notify_resource_updated,
    notify_prompt_list_changed: notify_prompt_list_changed,
    notify_tool_list_changed: notify_tool_list_changed,
    notify_logging_message: notify_logging_message,
    notify_roots_list_changed: notify_roots_list_changed,
    notify_elicitation_complete: notify_elicitation_complete,
    notify_task_status: notify_task_status,
    ..,
  ) = config

  case notification {
    jsonrpc.Notification(_method, Some(action)) ->
      case action {
        actions.NotifyCancelled(params) ->
          run_callback_with_params(notify_cancelled, params)
        actions.NotifyProgress(params) ->
          run_callback_with_params(notify_progress, params)
        actions.NotifyResourceListChanged(_) ->
          run_callback(notify_resource_list_changed)
        actions.NotifyResourceUpdated(params) ->
          run_callback_with_params(notify_resource_updated, params)
        actions.NotifyPromptListChanged(_) ->
          run_callback(notify_prompt_list_changed)
        actions.NotifyToolListChanged(_) ->
          run_callback(notify_tool_list_changed)
        actions.NotifyLoggingMessage(params) ->
          run_callback_with_params(notify_logging_message, params)
        actions.NotifyRootsListChanged(_) ->
          run_callback(notify_roots_list_changed)
        actions.NotifyElicitationComplete(params) ->
          run_callback_with_params(notify_elicitation_complete, params)
        actions.NotifyTaskStatus(params) ->
          run_callback_with_params(notify_task_status, params)
        actions.NotifyInitialized(_) -> Ok(Nil)
      }
    jsonrpc.Notification(_, None) -> Ok(Nil)
    jsonrpc.Request(_, method, _) ->
      Error(jsonrpc.method_not_found_error(method))
  }
}

fn dispatch_request(
  config: Config,
  id: jsonrpc.RequestId,
  method: String,
  action: ActionRequest,
) -> Result(Response(ActionResult), RpcError) {
  case action {
    actions.RequestListRoots(meta) -> list_roots_result(config, id, meta)
    actions.RequestCreateMessage(params) ->
      create_message_result(config, id, params)
    actions.RequestElicit(params) -> elicit_result(config, id, params)
    actions.RequestListTasks(_) -> Ok(list_tasks_result(config, id))
    actions.RequestGetTask(params) -> get_task_result(config, id, params)
    actions.RequestGetTaskResult(params) ->
      get_task_payload_result(config, id, params)
    actions.RequestCancelTask(params) -> cancel_task_result(config, id, params)
    _ ->
      Ok(jsonrpc.ErrorResponse(Some(id), jsonrpc.method_not_found_error(method)))
  }
}

fn list_roots_result(
  config: Config,
  id: jsonrpc.RequestId,
  meta: Option(actions.RequestMeta),
) -> Result(Response(ActionResult), RpcError) {
  let Config(list_roots: list_roots, ..) = config

  case list_roots {
    Some(handler) ->
      handler(meta)
      |> result.map(fn(roots) {
        jsonrpc.ResultResponse(
          id,
          actions.ResultListRoots(actions.ListRootsResult(
            roots: list.map(roots, encode_root),
            meta: None,
          )),
        )
      })
    None ->
      Ok(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.method_not_found_error(mcp.method_list_roots),
      ))
  }
}

fn create_message_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.CreateMessageRequestParams,
) -> Result(Response(ActionResult), RpcError) {
  let Config(create_message: create_message, task_store: tasks, ..) = config

  case create_message {
    Some(handler) ->
      handler(params)
      |> result.map(fn(result) {
        jsonrpc.ResultResponse(id, case result {
          CreateMessage(value) ->
            case params.task {
              Some(actions.TaskMetadata(ttl_ms)) ->
                actions.ResultCreateTask(actions.CreateTaskResult(
                  task_store.create(
                    tasks,
                    Ok(actions.TaskCreateMessage(value)),
                    ttl_ms,
                  ),
                  None,
                ))
              None -> actions.ResultCreateMessage(value)
            }
          CreateMessageTask(value) -> actions.ResultCreateTask(value)
        })
      })
    None ->
      Ok(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.method_not_found_error(mcp.method_create_message),
      ))
  }
}

fn elicit_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.ElicitRequestParams,
) -> Result(Response(ActionResult), RpcError) {
  let Config(
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    task_store: tasks,
    ..,
  ) = config

  let handler_result = case params {
    actions.ElicitRequestForm(form) ->
      case elicit_form {
        Some(handler) -> handler(form)
        None -> Error(jsonrpc.method_not_found_error(mcp.method_elicit))
      }
    actions.ElicitRequestUrl(url) ->
      case elicit_url {
        Some(handler) -> handler(url)
        None -> Error(jsonrpc.method_not_found_error(mcp.method_elicit))
      }
  }

  handler_result
  |> result.map(fn(result) {
    jsonrpc.ResultResponse(id, case result {
      Elicit(value) ->
        case task_ttl(params) {
          Some(ttl_ms) ->
            actions.ResultCreateTask(actions.CreateTaskResult(
              task_store.create(
                tasks,
                Ok(actions.TaskElicit(value)),
                Some(ttl_ms),
              ),
              None,
            ))
          None -> actions.ResultElicit(value)
        }
      ElicitTask(value) -> actions.ResultCreateTask(value)
    })
  })
}

fn list_tasks_result(
  config: Config,
  id: jsonrpc.RequestId,
) -> Response(ActionResult) {
  let Config(task_store: tasks, ..) = config
  jsonrpc.ResultResponse(
    id,
    actions.ResultListTasks(actions.ListTasksResult(
      tasks: task_store.list(tasks),
      page: actions.Page(None),
      meta: None,
    )),
  )
}

fn get_task_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.get(tasks, task_id)
  |> result.map(fn(task) {
    jsonrpc.ResultResponse(
      id,
      actions.ResultGetTask(actions.GetTaskResult(task, None)),
    )
  })
}

fn get_task_payload_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.result(tasks, task_id)
  |> result.map(fn(task_result) {
    jsonrpc.ResultResponse(id, actions.ResultTaskResult(task_result))
  })
}

fn cancel_task_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.cancel(tasks, task_id)
  |> result.map(fn(task) {
    jsonrpc.ResultResponse(
      id,
      actions.ResultCancelTask(actions.CancelTaskResult(task, None)),
    )
  })
}

fn encode_root(root: Root) -> actions.Root {
  let Root(uri, name, meta) = root
  actions.Root(uri, name, option.map(meta, value_to_meta))
}

fn value_to_meta(value: Value) -> actions.Meta {
  case value {
    jsonrpc.VObject(fields) -> actions.Meta(dict.from_list(fields))
    _ -> actions.Meta(dict.new())
  }
}

fn update_callbacks(
  config: Config,
  notify_cancelled: Option(
    fn(actions.CancelledNotificationParams) -> Result(Nil, RpcError),
  ),
  notify_progress: Option(
    fn(actions.ProgressNotificationParams) -> Result(Nil, RpcError),
  ),
  notify_resource_list_changed: Option(fn() -> Result(Nil, RpcError)),
  notify_resource_updated: Option(
    fn(actions.ResourceUpdatedNotificationParams) -> Result(Nil, RpcError),
  ),
  notify_prompt_list_changed: Option(fn() -> Result(Nil, RpcError)),
  notify_tool_list_changed: Option(fn() -> Result(Nil, RpcError)),
  notify_logging_message: Option(
    fn(actions.LoggingMessageNotificationParams) -> Result(Nil, RpcError),
  ),
  notify_roots_list_changed: Option(fn() -> Result(Nil, RpcError)),
  notify_elicitation_complete: Option(
    fn(actions.ElicitationCompleteNotificationParams) -> Result(Nil, RpcError),
  ),
  notify_task_status: Option(
    fn(actions.TaskStatusNotificationParams) -> Result(Nil, RpcError),
  ),
) -> Config {
  let Config(
    list_roots: list_roots,
    notify_cancelled: current_notify_cancelled,
    notify_progress: current_notify_progress,
    notify_resource_list_changed: current_notify_resource_list_changed,
    notify_resource_updated: current_notify_resource_updated,
    notify_prompt_list_changed: current_notify_prompt_list_changed,
    notify_tool_list_changed: current_notify_tool_list_changed,
    notify_logging_message: current_notify_logging_message,
    notify_roots_list_changed: current_notify_roots_list_changed,
    notify_elicitation_complete: current_notify_elicitation_complete,
    notify_task_status: current_notify_task_status,
    task_store: task_store,
    create_message: create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
  ) = config

  Config(
    list_roots,
    choose_callback(notify_cancelled, current_notify_cancelled),
    choose_callback(notify_progress, current_notify_progress),
    choose_callback(
      notify_resource_list_changed,
      current_notify_resource_list_changed,
    ),
    choose_callback(notify_resource_updated, current_notify_resource_updated),
    choose_callback(
      notify_prompt_list_changed,
      current_notify_prompt_list_changed,
    ),
    choose_callback(notify_tool_list_changed, current_notify_tool_list_changed),
    choose_callback(notify_logging_message, current_notify_logging_message),
    choose_callback(
      notify_roots_list_changed,
      current_notify_roots_list_changed,
    ),
    choose_callback(
      notify_elicitation_complete,
      current_notify_elicitation_complete,
    ),
    choose_callback(notify_task_status, current_notify_task_status),
    task_store,
    create_message,
    sampling_tools,
    sampling_context,
    elicit_form,
    elicit_url,
  )
}

fn task_ttl(params: actions.ElicitRequestParams) -> Option(Int) {
  case params {
    actions.ElicitRequestForm(actions.ElicitRequestFormParams(
      task: Some(actions.TaskMetadata(ttl_ms)),
      ..,
    )) -> ttl_ms
    actions.ElicitRequestUrl(actions.ElicitRequestUrlParams(
      task: Some(actions.TaskMetadata(ttl_ms)),
      ..,
    )) -> ttl_ms
    _ -> None
  }
}

fn run_callback(
  handler: Option(fn() -> Result(Nil, RpcError)),
) -> Result(Nil, RpcError) {
  case handler {
    Some(callback) -> callback()
    None -> Ok(Nil)
  }
}

fn run_callback_with_params(
  handler: Option(fn(a) -> Result(Nil, RpcError)),
  params: a,
) -> Result(Nil, RpcError) {
  case handler {
    Some(callback) -> callback(params)
    None -> Ok(Nil)
  }
}

fn has(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

fn choose_callback(updated: Option(a), current: Option(a)) -> Option(a) {
  case updated {
    Some(_) -> updated
    None -> current
  }
}
