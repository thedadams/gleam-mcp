import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/actions.{
  type ActionNotification, type ClientCapabilities, type ServerActionRequest,
  type ServerActionResult, ClientCapabilities, ClientElicitationCapabilities,
  ClientRootsCapabilities, ClientSamplingCapabilities,
}
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc.{
  type Request, type Response, type RpcError, type Value, VObject,
}
import gleam_mcp/mcp
import gleam_mcp/server/runtime
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
    request_runtime: runtime.Store(Response(ServerActionResult)),
    request_timeout_ms: Int,
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
    runtime.new(),
    60_000,
  )
}

/// Apply a deadline to ordinary incoming requests. Task workers use their own
/// retention and cancellation instead of this request deadline.
pub fn with_request_timeout(config: Config, timeout_ms: Int) -> Config {
  let timeout_ms = case timeout_ms < 1 {
    True -> 1
    False -> timeout_ms
  }
  Config(..config, request_timeout_ms: timeout_ms)
}

pub fn with_list_roots(
  config: Config,
  handler: fn(Option(actions.RequestMeta)) -> Result(List(Root), RpcError),
) -> Config {
  update_handlers(
    config,
    list_roots: Some(handler),
    create_message: None,
    sampling_tools: None,
    sampling_context: None,
    elicit_form: None,
    elicit_url: None,
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
  update_handlers(
    config,
    list_roots: None,
    create_message: Some(handler),
    sampling_tools: None,
    sampling_context: None,
    elicit_form: None,
    elicit_url: None,
  )
}

/// Enable sampling tool support. The callback receives an object with `tools`
/// and, when present, `toolChoice` before the sampling handler is invoked.
pub fn with_sampling_tools(
  config: Config,
  handler: fn(Value) -> Result(Nil, RpcError),
) -> Config {
  update_handlers(
    config,
    list_roots: None,
    create_message: None,
    sampling_tools: Some(handler),
    sampling_context: None,
    elicit_form: None,
    elicit_url: None,
  )
}

/// Enable sampling context support. The callback receives the requested
/// `thisServer` or `allServers` string before the sampling handler is invoked.
pub fn with_sampling_context(
  config: Config,
  handler: fn(Value) -> Result(Nil, RpcError),
) -> Config {
  update_handlers(
    config,
    list_roots: None,
    create_message: None,
    sampling_tools: None,
    sampling_context: Some(handler),
    elicit_form: None,
    elicit_url: None,
  )
}

pub fn with_elicit_form(
  config: Config,
  handler: fn(actions.ElicitRequestFormParams) ->
    Result(ElicitHandlerResult, RpcError),
) -> Config {
  update_handlers(
    config,
    list_roots: None,
    create_message: None,
    sampling_tools: None,
    sampling_context: None,
    elicit_form: Some(handler),
    elicit_url: None,
  )
}

pub fn with_elicit_url(
  config: Config,
  handler: fn(actions.ElicitRequestUrlParams) ->
    Result(ElicitHandlerResult, RpcError),
) -> Config {
  update_handlers(
    config,
    list_roots: None,
    create_message: None,
    sampling_tools: None,
    sampling_context: None,
    elicit_form: None,
    elicit_url: Some(handler),
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
    ..,
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

  let sampling = case create_message {
    None -> None
    Some(_) ->
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
  request: Request(ServerActionRequest),
) -> Result(Response(ServerActionResult), RpcError) {
  let reply = process.new_subject()
  start_request(config, request, reply)
  process.receive_forever(reply)
}

/// Start a request and acknowledge registration before returning. `reply_to`
/// must belong to the process that will receive and send the response.
pub fn start_request(
  config: Config,
  request: Request(ServerActionRequest),
  reply_to: process.Subject(Result(Response(ServerActionResult), RpcError)),
) -> Nil {
  case request {
    jsonrpc.Request(id, method, Some(action)) -> {
      let registered = process.new_subject()
      let _ =
        process.spawn_unlinked(fn() {
          let result =
            runtime.start(
              config.request_runtime,
              None,
              id,
              config.request_timeout_ms,
              fn() { dispatch_request(config, id, method, action) },
            )
          process.send(registered, Nil)
          let response = case process.receive_forever(result) {
            Ok(value) -> value
            Error(error) -> jsonrpc.ErrorResponse(Some(id), error)
          }
          process.send(reply_to, Ok(response))
        })
      let assert Ok(Nil) = process.receive(registered, 1000)
      Nil
    }
    _ -> process.send(reply_to, handle_invalid_request(request))
  }
}

fn handle_invalid_request(
  request: Request(ServerActionRequest),
) -> Result(Response(ServerActionResult), RpcError) {
  case request {
    jsonrpc.Request(id, method, _) ->
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
        actions.NotifyCancelled(params) -> {
          case params.request_id {
            Some(id) -> runtime.cancel(config.request_runtime, None, id)
            None -> Nil
          }
          run_callback_with_params(notify_cancelled, params)
        }
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
  _method: String,
  action: ServerActionRequest,
) -> Result(Response(ServerActionResult), RpcError) {
  case action {
    actions.ServerRequestPing(_) ->
      Ok(jsonrpc.ResultResponse(id, actions.ServerResultEmpty(None)))
    actions.ServerRequestListRoots(meta) -> list_roots_result(config, id, meta)
    actions.ServerRequestCreateMessage(params) ->
      create_message_result(config, id, params)
    actions.ServerRequestElicit(params) -> elicit_result(config, id, params)
    actions.ServerRequestListTasks(params) ->
      list_tasks_result(config, id, params)
    actions.ServerRequestGetTask(params) -> get_task_result(config, id, params)
    actions.ServerRequestGetTaskResult(params) ->
      get_task_payload_result(config, id, params)
    actions.ServerRequestCancelTask(params) ->
      cancel_task_result(config, id, params)
  }
}

fn list_roots_result(
  config: Config,
  id: jsonrpc.RequestId,
  meta: Option(actions.RequestMeta),
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(list_roots: list_roots, ..) = config

  case list_roots {
    Some(handler) ->
      handler(meta)
      |> result.try(validate_roots)
      |> result.map(fn(roots) {
        jsonrpc.ResultResponse(
          id,
          actions.ServerResultListRoots(actions.ListRootsResult(
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
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(create_message: create_message, task_store: tasks, ..) = config

  case create_message {
    Some(handler) ->
      case params.task {
        Some(actions.TaskMetadata(ttl_ms)) -> {
          let task = task_store.create(tasks, ttl_ms)
          let _ =
            task_store.start_worker(tasks, task.task_id, fn() {
              let outcome = case run_sampling_handler(config, handler, params) {
                Ok(result) -> create_message_task_result(result)
                Error(error) -> Error(error)
              }
              outcome
            })
          Ok(jsonrpc.ResultResponse(
            id,
            actions.ServerResultCreateTask(actions.CreateTaskResult(task, None)),
          ))
        }
        None ->
          run_sampling_handler(config, handler, params)
          |> result.try(fn(result) {
            case result {
              CreateMessage(value) ->
                Ok(jsonrpc.ResultResponse(
                  id,
                  actions.ServerResultCreateMessage(value),
                ))
              CreateMessageTask(_) ->
                Error(jsonrpc.invalid_params_error(
                  "Sampling task response requires task augmentation",
                ))
            }
          })
      }
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
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(
    elicit_form: elicit_form,
    elicit_url: elicit_url,
    task_store: tasks,
    ..,
  ) = config

  let handler = case params {
    actions.ElicitRequestForm(form) ->
      case elicit_form {
        Some(handler) -> Ok(fn() { handler(form) })
        None -> Error(jsonrpc.method_not_found_error(mcp.method_elicit))
      }
    actions.ElicitRequestUrl(url) ->
      case elicit_url {
        Some(handler) -> Ok(fn() { handler(url) })
        None -> Error(jsonrpc.method_not_found_error(mcp.method_elicit))
      }
  }

  use handler <- result.try(handler)
  case task_metadata(params) {
    Some(actions.TaskMetadata(ttl_ms)) -> {
      let task = task_store.create(tasks, ttl_ms)
      let _ =
        task_store.start_worker(tasks, task.task_id, fn() {
          handler() |> result.try(elicit_task_result)
        })
      Ok(jsonrpc.ResultResponse(
        id,
        actions.ServerResultCreateTask(actions.CreateTaskResult(task, None)),
      ))
    }
    None ->
      handler()
      |> result.try(fn(result) {
        case result {
          Elicit(value) ->
            Ok(jsonrpc.ResultResponse(id, actions.ServerResultElicit(value)))
          ElicitTask(_) ->
            Error(jsonrpc.invalid_params_error(
              "Elicitation task response requires task augmentation",
            ))
        }
      })
  }
}

fn create_message_task_result(
  result: CreateMessageHandlerResult,
) -> Result(actions.TaskResult, RpcError) {
  case result {
    CreateMessage(value) -> Ok(actions.TaskCreateMessage(value))
    CreateMessageTask(_) ->
      Error(jsonrpc.RpcError(
        code: -32_603,
        message: "Nested createMessage tasks are not supported",
        data: None,
      ))
  }
}

fn elicit_task_result(
  result: ElicitHandlerResult,
) -> Result(actions.TaskResult, RpcError) {
  case result {
    Elicit(value) -> Ok(actions.TaskElicit(value))
    ElicitTask(_) ->
      Error(jsonrpc.RpcError(
        code: -32_603,
        message: "Nested elicitation tasks are not supported",
        data: None,
      ))
  }
}

fn list_tasks_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.PaginatedRequestParams,
) -> Result(Response(ServerActionResult), RpcError) {
  use _ <- result.try(validate_task_cursor(params))
  let Config(task_store: tasks, ..) = config
  Ok(jsonrpc.ResultResponse(
    id,
    actions.ServerResultListTasks(actions.ListTasksResult(
      tasks: task_store.list(tasks),
      page: actions.Page(None),
      meta: None,
    )),
  ))
}

fn get_task_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.get(tasks, task_id)
  |> result.map(fn(task) {
    jsonrpc.ResultResponse(
      id,
      actions.ServerResultGetTask(actions.GetTaskResult(task, None)),
    )
  })
}

fn get_task_payload_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.result(tasks, task_id)
  |> result.map(fn(task_result) {
    jsonrpc.ResultResponse(id, actions.ServerResultTaskResult(task_result))
  })
}

fn cancel_task_result(
  config: Config,
  id: jsonrpc.RequestId,
  params: actions.TaskIdParams,
) -> Result(Response(ServerActionResult), RpcError) {
  let Config(task_store: tasks, ..) = config
  let actions.TaskIdParams(task_id) = params
  task_store.cancel(tasks, task_id)
  |> result.map(fn(task) {
    jsonrpc.ResultResponse(
      id,
      actions.ServerResultCancelTask(actions.CancelTaskResult(task, None)),
    )
  })
}

fn encode_root(root: Root) -> actions.Root {
  let Root(uri, name, meta) = root
  actions.Root(uri, name, option.map(meta, value_to_meta))
}

fn validate_roots(roots: List(Root)) -> Result(List(Root), RpcError) {
  case
    list.all(roots, fn(root) {
      case uri.parse(root.uri) {
        Ok(parsed) ->
          parsed.scheme == Some("file")
          && string.starts_with(string.lowercase(root.uri), "file://")
        Error(Nil) -> False
      }
    })
  {
    True -> Ok(roots)
    False ->
      Error(jsonrpc.invalid_params_error(
        "Root URIs must use the file:// scheme",
      ))
  }
}

fn validate_task_cursor(
  params: actions.PaginatedRequestParams,
) -> Result(Nil, RpcError) {
  case params.cursor {
    None -> Ok(Nil)
    Some(_) -> Error(jsonrpc.invalid_params_error("Invalid task cursor"))
  }
}

fn run_sampling_handler(
  config: Config,
  handler: fn(actions.CreateMessageRequestParams) ->
    Result(CreateMessageHandlerResult, RpcError),
  params: actions.CreateMessageRequestParams,
) -> Result(CreateMessageHandlerResult, RpcError) {
  use _ <- result.try(run_sampling_tools(config, params))
  use _ <- result.try(run_sampling_context(config, params))
  use response <- result.try(handler(params))
  case response, config.sampling_tools {
    CreateMessage(value), None ->
      case sampling_content_has_tools(value.message.content) {
        True ->
          Error(jsonrpc.invalid_params_error(
            "Sampling tool content requires the tools capability",
          ))
        False -> Ok(response)
      }
    _, _ -> Ok(response)
  }
}

fn run_sampling_tools(
  config: Config,
  params: actions.CreateMessageRequestParams,
) -> Result(Nil, RpcError) {
  let has_tool_content =
    list.any(params.messages, fn(message) {
      sampling_content_has_tools(message.content)
    })
  case params.tools, params.tool_choice, has_tool_content {
    [], None, False -> Ok(Nil)
    _, _, _ ->
      case config.sampling_tools {
        None ->
          Error(jsonrpc.invalid_params_error(
            "Sampling tools capability is not supported",
          ))
        Some(handler) -> {
          let tools =
            list.map(params.tools, fn(tool) {
              let assert Ok(value) =
                codec_common.encode_tool(tool)
                |> json.to_string
                |> json.parse(value_decoder())
              value
            })
          let fields = [#("tools", jsonrpc.VArray(tools))]
          let fields = case params.tool_choice {
            None -> fields
            Some(actions.ToolChoice(mode)) -> {
              let mode_fields = case mode {
                None -> []
                Some(actions.ToolAuto) -> [#("mode", jsonrpc.VString("auto"))]
                Some(actions.ToolRequired) -> [
                  #("mode", jsonrpc.VString("required")),
                ]
                Some(actions.ToolNone) -> [#("mode", jsonrpc.VString("none"))]
              }
              [#("toolChoice", jsonrpc.VObject(mode_fields)), ..fields]
            }
          }
          handler(jsonrpc.VObject(fields))
        }
      }
  }
}

fn sampling_content_has_tools(content: actions.SamplingContent) -> Bool {
  let blocks = case content {
    actions.SingleSamplingContent(block) -> [block]
    actions.MultipleSamplingContent(blocks) -> blocks
  }
  list.any(blocks, fn(block) {
    case block {
      actions.SamplingToolUse(_) | actions.SamplingToolResult(_) -> True
      _ -> False
    }
  })
}

fn run_sampling_context(
  config: Config,
  params: actions.CreateMessageRequestParams,
) -> Result(Nil, RpcError) {
  case params.include_context {
    None | Some(actions.NoContext) -> Ok(Nil)
    Some(context) ->
      case config.sampling_context {
        None ->
          Error(jsonrpc.invalid_params_error(
            "Sampling context capability is not supported",
          ))
        Some(handler) ->
          handler(
            jsonrpc.VString(case context {
              actions.NoContext -> "none"
              actions.ThisServerContext -> "thisServer"
              actions.AllServersContext -> "allServers"
            }),
          )
      }
  }
}

fn value_decoder() -> decode.Decoder(Value) {
  use <- decode.recursive
  decode.one_of(decode.map(decode.string, jsonrpc.VString), or: [
    decode.map(decode.int, jsonrpc.VInt),
    decode.map(decode.float, jsonrpc.VFloat),
    decode.map(decode.bool, jsonrpc.VBool),
    decode.map(decode.list(value_decoder()), jsonrpc.VArray),
    decode.map(decode.dict(decode.string, value_decoder()), fn(fields) {
      jsonrpc.VObject(dict.to_list(fields))
    }),
    decode.map(decode.optional(decode.dynamic), fn(_) { jsonrpc.VNull }),
  ])
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
  Config(
    ..config,
    notify_cancelled: choose_callback(notify_cancelled, config.notify_cancelled),
    notify_progress: choose_callback(notify_progress, config.notify_progress),
    notify_resource_list_changed: choose_callback(
      notify_resource_list_changed,
      config.notify_resource_list_changed,
    ),
    notify_resource_updated: choose_callback(
      notify_resource_updated,
      config.notify_resource_updated,
    ),
    notify_prompt_list_changed: choose_callback(
      notify_prompt_list_changed,
      config.notify_prompt_list_changed,
    ),
    notify_tool_list_changed: choose_callback(
      notify_tool_list_changed,
      config.notify_tool_list_changed,
    ),
    notify_logging_message: choose_callback(
      notify_logging_message,
      config.notify_logging_message,
    ),
    notify_roots_list_changed: choose_callback(
      notify_roots_list_changed,
      config.notify_roots_list_changed,
    ),
    notify_elicitation_complete: choose_callback(
      notify_elicitation_complete,
      config.notify_elicitation_complete,
    ),
    notify_task_status: choose_callback(
      notify_task_status,
      config.notify_task_status,
    ),
  )
}

fn update_handlers(
  config: Config,
  list_roots list_roots: Option(
    fn(Option(actions.RequestMeta)) -> Result(List(Root), RpcError),
  ),
  create_message create_message: Option(
    fn(actions.CreateMessageRequestParams) ->
      Result(CreateMessageHandlerResult, RpcError),
  ),
  sampling_tools sampling_tools: Option(fn(Value) -> Result(Nil, RpcError)),
  sampling_context sampling_context: Option(fn(Value) -> Result(Nil, RpcError)),
  elicit_form elicit_form: Option(
    fn(actions.ElicitRequestFormParams) -> Result(ElicitHandlerResult, RpcError),
  ),
  elicit_url elicit_url: Option(
    fn(actions.ElicitRequestUrlParams) -> Result(ElicitHandlerResult, RpcError),
  ),
) -> Config {
  Config(
    ..config,
    list_roots: choose_callback(list_roots, config.list_roots),
    create_message: choose_callback(create_message, config.create_message),
    sampling_tools: choose_callback(sampling_tools, config.sampling_tools),
    sampling_context: choose_callback(sampling_context, config.sampling_context),
    elicit_form: choose_callback(elicit_form, config.elicit_form),
    elicit_url: choose_callback(elicit_url, config.elicit_url),
  )
}

fn task_metadata(
  params: actions.ElicitRequestParams,
) -> Option(actions.TaskMetadata) {
  case params {
    actions.ElicitRequestForm(actions.ElicitRequestFormParams(task: task, ..)) ->
      task
    actions.ElicitRequestUrl(actions.ElicitRequestUrlParams(task: task, ..)) ->
      task
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
