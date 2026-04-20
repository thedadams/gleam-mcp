import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities
import gleam_mcp/server/streamable_http_store
import gleam_mcp/task_store
import youid/uuid

const server_sent_request_timeout_ms = 3_600_000

pub type ToolHandler =
  fn(Option(dict.Dict(String, jsonrpc.Value))) ->
    Result(actions.CallToolResult, jsonrpc.RpcError)

pub type ContextToolHandler =
  fn(Server, RequestContext, Option(dict.Dict(String, jsonrpc.Value))) ->
    Result(actions.CallToolResult, jsonrpc.RpcError)

pub type ResourceHandler =
  fn() -> Result(List(actions.ResourceContents), jsonrpc.RpcError)

pub type ResourceTemplateHandler =
  fn(String) -> Result(List(actions.ResourceContents), jsonrpc.RpcError)

pub type PromptHandler =
  fn(Option(dict.Dict(String, String))) ->
    Result(actions.GetPromptResult, jsonrpc.RpcError)

pub type CompletionHandler =
  fn(actions.CompleteRequestParams) ->
    Result(actions.CompleteResult, jsonrpc.RpcError)

pub type LoggingHandler =
  fn(actions.SetLevelRequestParams) -> Result(Nil, jsonrpc.RpcError)

pub type TaskResultRequestHandler =
  fn(Server, RequestContext, String) -> Result(Nil, jsonrpc.RpcError)

pub type HeaderAuthorization {
  HeaderAuthorization(header: String, validate: fn(String) -> Bool)
}

pub type RequestContext {
  RequestContext(session_id: Option(String), task_id: Option(String))
}

pub opaque type Server {
  Server(
    implementation: actions.Implementation,
    instructions: Option(String),
    authorization: Option(HeaderAuthorization),
    task_store: task_store.Store,
    http_store: streamable_http_store.Store,
    tools: List(RegisteredTool),
    resources: List(RegisteredResource),
    resource_templates: List(RegisteredResourceTemplate),
    prompts: List(RegisteredPrompt),
    completion_handler: Option(CompletionHandler),
    logging_handler: Option(LoggingHandler),
    task_result_request_handler: Option(TaskResultRequestHandler),
  )
}

type RegisteredTool {
  RegisteredTool(tool: actions.Tool, handler: RegisteredToolHandler)
}

type RegisteredToolHandler {
  PlainToolHandler(ToolHandler)
  ContextualToolHandler(ContextToolHandler)
}

type RegisteredResource {
  RegisteredResource(resource: actions.Resource, handler: ResourceHandler)
}

type RegisteredResourceTemplate {
  RegisteredResourceTemplate(
    resource_template: actions.ResourceTemplate,
    handler: ResourceTemplateHandler,
  )
}

type RegisteredPrompt {
  RegisteredPrompt(prompt: actions.Prompt, handler: PromptHandler)
}

pub fn new(implementation: actions.Implementation) -> Server {
  Server(
    implementation,
    None,
    None,
    task_store.new(),
    streamable_http_store.new(),
    [],
    [],
    [],
    [],
    None,
    None,
    None,
  )
}

pub fn with_instructions(server: Server, instructions: String) -> Server {
  with_server_metadata(
    server,
    instructions: Some(instructions),
    authorization: header_authorization(server),
  )
}

pub fn with_header_authorization(
  server: Server,
  header: String,
  validate: fn(String) -> Bool,
) -> Server {
  let Server(instructions: instructions, ..) = server
  with_server_metadata(
    server,
    instructions: instructions,
    authorization: Some(HeaderAuthorization(header, validate)),
  )
}

pub fn header_authorization(server: Server) -> Option(HeaderAuthorization) {
  let Server(authorization: authorization, ..) = server
  authorization
}

pub fn add_tool(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  implementation: ToolHandler,
) -> Server {
  add_tool_with_execution(
    server,
    name,
    description,
    input_schema,
    actions.TaskOptional,
    implementation,
  )
}

pub fn add_tool_with_execution(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  task_support: actions.TaskSupport,
  implementation: ToolHandler,
) -> Server {
  register_tool(
    server,
    name,
    description,
    input_schema,
    task_support,
    PlainToolHandler(implementation),
  )
}

pub fn add_tool_with_context(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  implementation: ContextToolHandler,
) -> Server {
  add_tool_with_context_execution(
    server,
    name,
    description,
    input_schema,
    actions.TaskOptional,
    implementation,
  )
}

pub fn add_tool_with_context_execution(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  task_support: actions.TaskSupport,
  implementation: ContextToolHandler,
) -> Server {
  register_tool(
    server,
    name,
    description,
    input_schema,
    task_support,
    ContextualToolHandler(implementation),
  )
}

fn register_tool(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  task_support: actions.TaskSupport,
  handler: RegisteredToolHandler,
) -> Server {
  let tool =
    actions.Tool(
      name: name,
      title: None,
      description: Some(description),
      input_schema: input_schema,
      execution: Some(actions.ToolExecution(Some(task_support))),
      output_schema: None,
      annotations: None,
      icons: [],
      meta: None,
    )

  let Server(
    implementation: server_info,
    instructions: instructions,
    authorization: authorization,
    task_store: tasks,
    http_store: http_store,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    task_result_request_handler: task_result_request_handler,
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    [RegisteredTool(tool, handler), ..tools],
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
    task_result_request_handler,
  )
}

pub fn add_resource(
  server: Server,
  uri: String,
  name: String,
  description: String,
  mime_type: Option(String),
  implementation: ResourceHandler,
) -> Server {
  let resource =
    actions.Resource(
      uri: uri,
      name: name,
      title: None,
      description: Some(description),
      mime_type: mime_type,
      annotations: None,
      size: None,
      icons: [],
      meta: None,
    )

  let Server(resources: resources, ..) = server
  with_server_registry(
    server,
    tools: server.tools,
    resources: [RegisteredResource(resource, implementation), ..resources],
    resource_templates: server.resource_templates,
    prompts: server.prompts,
  )
}

pub fn add_resource_template(
  server: Server,
  uri_template: String,
  name: String,
  description: String,
  mime_type: Option(String),
  implementation: ResourceTemplateHandler,
) -> Server {
  let resource_template =
    actions.ResourceTemplate(
      uri_template: uri_template,
      name: name,
      title: None,
      description: Some(description),
      mime_type: mime_type,
      annotations: None,
      icons: [],
      meta: None,
    )

  let Server(resource_templates: resource_templates, ..) = server
  with_server_registry(
    server,
    tools: server.tools,
    resources: server.resources,
    resource_templates: [
      RegisteredResourceTemplate(resource_template, implementation),
      ..resource_templates
    ],
    prompts: server.prompts,
  )
}

pub fn add_prompt(
  server: Server,
  name: String,
  description: String,
  arguments: List(actions.PromptArgument),
  implementation: PromptHandler,
) -> Server {
  let prompt =
    actions.Prompt(
      name: name,
      title: None,
      description: Some(description),
      arguments: arguments,
      icons: [],
      meta: None,
    )

  let Server(prompts: prompts, ..) = server
  with_server_registry(
    server,
    tools: server.tools,
    resources: server.resources,
    resource_templates: server.resource_templates,
    prompts: [RegisteredPrompt(prompt, implementation), ..prompts],
  )
}

pub fn set_completion_handler(
  server: Server,
  handler: CompletionHandler,
) -> Server {
  with_server_handlers(
    server,
    completion_handler: Some(handler),
    logging_handler: server.logging_handler,
    task_result_request_handler: server.task_result_request_handler,
  )
}

pub fn set_logging_handler(server: Server, handler: LoggingHandler) -> Server {
  with_server_handlers(
    server,
    completion_handler: server.completion_handler,
    logging_handler: Some(handler),
    task_result_request_handler: server.task_result_request_handler,
  )
}

pub fn set_task_result_request_handler(
  server: Server,
  handler: TaskResultRequestHandler,
) -> Server {
  with_server_handlers(
    server,
    completion_handler: server.completion_handler,
    logging_handler: server.logging_handler,
    task_result_request_handler: Some(handler),
  )
}

pub fn handle_request(
  server: Server,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> #(Server, jsonrpc.Response(actions.ClientActionResult)) {
  handle_request_with_context(
    server,
    RequestContext(session_id: None, task_id: None),
    request,
  )
}

pub fn handle_request_with_context(
  server: Server,
  context: RequestContext,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> #(Server, jsonrpc.Response(actions.ClientActionResult)) {
  case request {
    jsonrpc.Request(id, _method, Some(action)) ->
      case dispatch_request(server, context, action) {
        Ok(result) -> #(server, jsonrpc.ResultResponse(id, result))
        Error(error) -> #(server, jsonrpc.ErrorResponse(Some(id), error))
      }
    jsonrpc.Request(id, method, None) -> #(
      server,
      jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.invalid_params_error("Missing params for " <> method),
      ),
    )
    jsonrpc.Notification(method, _) -> #(
      server,
      jsonrpc.ErrorResponse(
        None,
        jsonrpc.method_not_found_error(
          "Expected request, got notification: " <> method,
        ),
      ),
    )
  }
}

pub fn handle_notification(
  server: Server,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> #(Server, Result(Nil, jsonrpc.RpcError)) {
  case notification {
    jsonrpc.Notification(method, _) ->
      case method == mcp.method_initialized {
        True -> #(server, Ok(Nil))
        False -> #(server, Error(jsonrpc.method_not_found_error(method)))
      }
    jsonrpc.Request(_, method, _) -> #(
      server,
      Error(jsonrpc.method_not_found_error(method)),
    )
  }
}

pub fn session_id(context: RequestContext) -> Option(String) {
  let RequestContext(session_id: session_id, ..) = context
  session_id
}

pub fn task_id(context: RequestContext) -> Option(String) {
  let RequestContext(task_id: task_id, ..) = context
  task_id
}

pub fn ensure_streamable_http_session(
  server: Server,
  session_id: Option(String),
) -> String {
  let Server(http_store: http_store, ..) = server
  streamable_http_store.ensure_session(http_store, session_id)
}

pub fn has_streamable_http_session(server: Server, session_id: String) -> Bool {
  let Server(http_store: http_store, ..) = server
  streamable_http_store.has_session(http_store, session_id)
}

pub fn new_streamable_http_listener_id() -> String {
  streamable_http_store.new_listener_id()
}

pub fn register_streamable_http_listener(
  server: Server,
  session_id: String,
  listener_id: String,
  listener: process.Subject(streamable_http_store.ListenerMessage),
) -> Nil {
  let Server(http_store: http_store, ..) = server
  streamable_http_store.register_listener(
    http_store,
    session_id,
    listener_id,
    listener,
  )
}

pub fn unregister_streamable_http_listener(
  server: Server,
  session_id: String,
  listener_id: String,
) -> Nil {
  let Server(http_store: http_store, ..) = server
  streamable_http_store.unregister_listener(http_store, session_id, listener_id)
}

pub fn handle_server_sent_response(
  server: Server,
  context: RequestContext,
  body: String,
) -> Result(Nil, jsonrpc.RpcError) {
  case session_id(context) {
    Some(value) -> {
      let Server(http_store: http_store, ..) = server
      streamable_http_store.resolve_response(http_store, value, body)
    }
    None ->
      Error(jsonrpc.invalid_params_error(
        "Server-sent request responses require an MCP session id",
      ))
  }
}

pub fn send_request(
  server: Server,
  context: RequestContext,
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> Result(jsonrpc.Response(actions.ServerActionResult), jsonrpc.RpcError) {
  case session_id(context) {
    Some(value) -> {
      let Server(http_store: http_store, ..) = server
      streamable_http_store.send_request(
        http_store,
        value,
        request,
        server_sent_request_timeout_ms,
      )
    }
    None ->
      Error(jsonrpc.invalid_params_error(
        "Server-sent requests require a streamable HTTP session",
      ))
  }
}

pub fn send_notification(
  server: Server,
  context: RequestContext,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Result(Nil, jsonrpc.RpcError) {
  case session_id(context) {
    Some(value) -> {
      let Server(http_store: http_store, ..) = server
      streamable_http_store.send_notification(http_store, value, notification)
      Ok(Nil)
    }
    None ->
      Error(jsonrpc.invalid_params_error(
        "Server-sent notifications require a streamable HTTP session",
      ))
  }
}

pub fn update_task_status(
  server: Server,
  context: RequestContext,
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  let updated =
    task_store.update_status(server.task_store, task_id, status, status_message)

  case updated {
    Ok(task) -> {
      let _ = send_task_status_notification(server, context, task)
      Ok(task)
    }
    Error(error) -> Error(error)
  }
}

fn send_task_status_notification(
  server: Server,
  context: RequestContext,
  task: actions.Task,
) -> Result(Nil, jsonrpc.RpcError) {
  case session_id(context) {
    Some(_) ->
      send_notification(
        server,
        context,
        jsonrpc.Notification(
          mcp.method_notify_task_status,
          Some(
            actions.NotifyTaskStatus(actions.TaskStatusNotificationParams(
              task,
              None,
            )),
          ),
        ),
      )
    None -> Ok(Nil)
  }
}

pub fn elicit(
  server: Server,
  context: RequestContext,
  params: actions.ElicitRequestParams,
) -> Result(actions.ElicitResult, jsonrpc.RpcError) {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId(uuid.v4_string()),
      mcp.method_elicit,
      Some(actions.ServerRequestElicit(params)),
    )

  case send_request(server, context, request) {
    Ok(jsonrpc.ResultResponse(_, actions.ServerResultElicit(result))) ->
      Ok(result)
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(error)
    Ok(_) ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected result for elicitation request",
      ))
    Error(error) -> Error(error)
  }
}

pub fn create_message(
  server: Server,
  context: RequestContext,
  params: actions.CreateMessageRequestParams,
) -> Result(actions.ServerActionResult, jsonrpc.RpcError) {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId(uuid.v4_string()),
      mcp.method_create_message,
      Some(actions.ServerRequestCreateMessage(params)),
    )

  case send_request(server, context, request) {
    Ok(jsonrpc.ResultResponse(_, result)) -> Ok(result)
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(error)
    Error(error) -> Error(error)
  }
}

pub fn task_result(
  server: Server,
  task_id: String,
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  task_store.result(server.task_store, task_id)
  |> result.map(with_related_task_result(_, task_id))
}

fn with_related_task_result(
  task_result: actions.TaskResult,
  task_id: String,
) -> actions.TaskResult {
  case task_result {
    actions.TaskCallTool(result) ->
      actions.TaskCallTool(with_related_task_call_tool_result(result, task_id))
    actions.TaskCreateMessage(result) ->
      actions.TaskCreateMessage(with_related_task_create_message_result(
        result,
        task_id,
      ))
    actions.TaskElicit(result) ->
      actions.TaskElicit(with_related_task_elicit_result(result, task_id))
  }
}

fn with_related_task_call_tool_result(
  result: actions.CallToolResult,
  task_id: String,
) -> actions.CallToolResult {
  let actions.CallToolResult(content, structured_content, is_error, meta) =
    result
  actions.CallToolResult(
    content: content,
    structured_content: structured_content,
    is_error: is_error,
    meta: Some(merge_related_task_meta(meta, task_id)),
  )
}

fn with_related_task_create_message_result(
  result: actions.CreateMessageResult,
  task_id: String,
) -> actions.CreateMessageResult {
  let actions.CreateMessageResult(message, model, stop_reason, meta) = result
  actions.CreateMessageResult(
    message: message,
    model: model,
    stop_reason: stop_reason,
    meta: Some(merge_related_task_meta(meta, task_id)),
  )
}

fn with_related_task_elicit_result(
  result: actions.ElicitResult,
  task_id: String,
) -> actions.ElicitResult {
  let actions.ElicitResult(action, content, meta) = result
  actions.ElicitResult(
    action: action,
    content: content,
    meta: Some(merge_related_task_meta(meta, task_id)),
  )
}

fn merge_related_task_meta(
  meta: Option(actions.Meta),
  task_id: String,
) -> actions.Meta {
  let fields = case meta {
    Some(actions.Meta(fields)) -> fields
    None -> dict.new()
  }

  actions.Meta(dict.insert(
    fields,
    "io.modelcontextprotocol/related-task",
    related_task_value(task_id),
  ))
}

fn related_task_value(task_id: String) -> jsonrpc.Value {
  jsonrpc.VObject([#("taskId", jsonrpc.VString(task_id))])
}

fn dispatch_request(
  server: Server,
  context: RequestContext,
  action: actions.ClientActionRequest,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  case action {
    actions.ClientRequestInitialize(_) -> Ok(initialization_result(server))
    actions.ClientRequestPing(_) -> Ok(actions.ClientResultEmpty(None))
    actions.ClientRequestListResources(_) -> Ok(list_resources_result(server))
    actions.ClientRequestListResourceTemplates(_) ->
      Ok(list_resource_templates_result(server))
    actions.ClientRequestReadResource(params) ->
      read_resource_result(server, params)
    actions.ClientRequestSubscribeResource(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_subscribe_resource))
    actions.ClientRequestUnsubscribeResource(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_unsubscribe_resource))
    actions.ClientRequestListPrompts(_) -> Ok(list_prompts_result(server))
    actions.ClientRequestGetPrompt(params) -> get_prompt_result(server, params)
    actions.ClientRequestListTools(_) -> Ok(list_tools_result(server))
    actions.ClientRequestCallTool(params) ->
      call_tool_result(server, context, params)
    actions.ClientRequestComplete(params) -> complete_result(server, params)
    actions.ClientRequestSetLoggingLevel(params) ->
      set_logging_level_result(server, params)
    actions.ClientRequestListTasks(params) ->
      Ok(list_tasks_result(server, params))
    actions.ClientRequestGetTask(params) -> get_task_result(server, params)
    actions.ClientRequestGetTaskResult(params) ->
      get_task_payload_result(server, context, params)
    actions.ClientRequestCancelTask(params) ->
      cancel_task_result(server, context, params)
  }
}

fn initialization_result(server: Server) -> actions.ClientActionResult {
  let Server(implementation: implementation, instructions: instructions, ..) =
    server

  actions.ClientResultInitialize(actions.InitializeResult(
    protocol_version: jsonrpc.latest_protocol_version,
    capabilities: capabilities.infer(
      has_tools: server.tools != [],
      has_resources: server.resources != [] || server.resource_templates != [],
      has_prompts: server.prompts != [],
      has_completion: case server.completion_handler {
        Some(_) -> True
        None -> False
      },
      has_logging: case server.logging_handler {
        Some(_) -> True
        None -> False
      },
      has_tasks: server.tools != [],
    ),
    server_info: implementation,
    instructions: instructions,
    meta: None,
  ))
}

fn list_resources_result(server: Server) -> actions.ClientActionResult {
  let Server(resources: resources, ..) = server
  let listed = listed_entries(resources, fn(registered) {
    let RegisteredResource(resource, _) = registered
    resource
  })

  actions.ClientResultListResources(actions.ListResourcesResult(
    resources: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn list_resource_templates_result(server: Server) -> actions.ClientActionResult {
  let Server(resource_templates: resource_templates, ..) = server
  let listed = listed_entries(resource_templates, fn(registered) {
    let RegisteredResourceTemplate(resource_template, _) = registered
      resource_template
    })

  actions.ClientResultListResourceTemplates(actions.ListResourceTemplatesResult(
    resource_templates: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn read_resource_result(
  server: Server,
  params: actions.ReadResourceRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.ReadResourceRequestParams(uri, _) = params

  case find_resource(server.resources, uri) {
    Ok(RegisteredResource(handler:, ..)) ->
      handler()
      |> result.map(fn(contents) {
        actions.ClientResultReadResource(actions.ReadResourceResult(
          contents:,
          meta: None,
        ))
      })
    Error(Nil) ->
      case find_resource_template(server.resource_templates, uri) {
        Ok(RegisteredResourceTemplate(handler:, ..)) ->
          handler(uri)
          |> result.map(fn(contents) {
            actions.ClientResultReadResource(actions.ReadResourceResult(
              contents:,
              meta: None,
            ))
          })
        Error(Nil) ->
          Error(jsonrpc.invalid_params_error("Unknown resource: " <> uri))
      }
  }
}

fn list_prompts_result(server: Server) -> actions.ClientActionResult {
  let Server(prompts: prompts, ..) = server
  let listed = listed_entries(prompts, fn(registered) {
    let RegisteredPrompt(prompt, _) = registered
    prompt
  })

  actions.ClientResultListPrompts(actions.ListPromptsResult(
    prompts: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn get_prompt_result(
  server: Server,
  params: actions.GetPromptRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.GetPromptRequestParams(name, arguments, _) = params

  case find_prompt(server.prompts, name) {
    Ok(RegisteredPrompt(handler:, ..)) ->
      handler(arguments)
      |> result.map(actions.ClientResultGetPrompt)
    Error(Nil) ->
      Error(jsonrpc.invalid_params_error("Unknown prompt: " <> name))
  }
}

fn list_tools_result(server: Server) -> actions.ClientActionResult {
  let Server(tools: tools, ..) = server
  let listed = listed_entries(tools, fn(registered) {
    let RegisteredTool(tool, _) = registered
    tool
  })

  actions.ClientResultListTools(actions.ListToolsResult(
    tools: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn call_tool_result(
  server: Server,
  context: RequestContext,
  params: actions.CallToolRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.CallToolRequestParams(name, arguments, task, _) = params

  case find_tool(server.tools, name) {
    Ok(RegisteredTool(tool:, handler:)) ->
      case task, tool_task_support(tool) {
        Some(actions.TaskMetadata(ttl_ms)), _ ->
          Ok(create_tool_task_result(
            server,
            handler,
            context,
            arguments,
            ttl_ms,
          ))
        None, Some(actions.TaskRequired) ->
          Error(jsonrpc.method_not_found_error(mcp.method_call_tool))
        None, _ ->
          run_tool_handler(server, handler, context, arguments)
          |> result.map(actions.ClientResultCallTool)
      }
    Error(Nil) -> Error(jsonrpc.invalid_params_error("Unknown tool: " <> name))
  }
}

fn create_tool_task_result(
  server: Server,
  handler: RegisteredToolHandler,
  context: RequestContext,
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  ttl_ms: Option(Int),
) -> actions.ClientActionResult {
  let created = task_store.create(server.task_store, ttl_ms)
  let _ =
    process.spawn(fn() {
      let RequestContext(session_id:, ..) = context
      let task_context =
        RequestContext(session_id: session_id, task_id: Some(created.task_id))
      let outcome =
        run_tool_handler(server, handler, task_context, arguments)
        |> result.map(actions.TaskCallTool)
      let _ = complete_task(server, task_context, created.task_id, outcome)
      Nil
    })
  actions.ClientResultCreateTask(actions.CreateTaskResult(created, None))
}

fn complete_task(
  server: Server,
  context: RequestContext,
  task_id: String,
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> Result(actions.Task, jsonrpc.RpcError) {
  task_store.complete(server.task_store, task_id, outcome)
  |> result.map(fn(task) {
    let _ = send_task_status_notification(server, context, task)
    task
  })
}

fn tool_task_support(tool: actions.Tool) -> Option(actions.TaskSupport) {
  let actions.Tool(execution: execution, ..) = tool
  case execution {
    Some(actions.ToolExecution(task_support)) -> task_support
    None -> None
  }
}

fn run_tool_handler(
  server: Server,
  handler: RegisteredToolHandler,
  context: RequestContext,
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case handler {
    PlainToolHandler(tool_handler) -> tool_handler(arguments)
    ContextualToolHandler(tool_handler) ->
      tool_handler(server, context, arguments)
  }
}

fn list_tasks_result(
  server: Server,
  _params: actions.PaginatedRequestParams,
) -> actions.ClientActionResult {
  actions.ClientResultListTasks(actions.ListTasksResult(
    tasks: task_store.list(server.task_store),
    page: actions.Page(None),
    meta: None,
  ))
}

fn get_task_result(
  server: Server,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.TaskIdParams(task_id) = params
  task_store.get(server.task_store, task_id)
  |> result.map(fn(task) {
    actions.ClientResultGetTask(actions.GetTaskResult(task, None))
  })
}

fn get_task_payload_result(
  server: Server,
  context: RequestContext,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.TaskIdParams(task_id) = params
  case run_task_result_request_handler(server, context, task_id) {
    Ok(Nil) ->
      task_result(server, task_id)
      |> result.map(actions.ClientResultTaskResult)
    Error(error) -> Error(error)
  }
}

fn run_task_result_request_handler(
  server: Server,
  context: RequestContext,
  task_id: String,
) -> Result(Nil, jsonrpc.RpcError) {
  let Server(task_result_request_handler: handler, ..) = server

  case handler {
    Some(handler) -> handler(server, context, task_id)
    None -> Ok(Nil)
  }
}

fn cancel_task_result(
  server: Server,
  context: RequestContext,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.TaskIdParams(task_id) = params
  task_store.cancel(server.task_store, task_id)
  |> result.map(fn(task) {
    let _ = send_task_status_notification(server, context, task)
    task
  })
  |> result.map(fn(task) {
    actions.ClientResultCancelTask(actions.CancelTaskResult(task, None))
  })
}

fn complete_result(
  server: Server,
  params: actions.CompleteRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  case server.completion_handler {
    Some(handler) -> handler(params) |> result.map(actions.ClientResultComplete)
    None -> Error(jsonrpc.method_not_found_error(mcp.method_complete))
  }
}

fn set_logging_level_result(
  server: Server,
  params: actions.SetLevelRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  case server.logging_handler {
    Some(handler) ->
      handler(params) |> result.map(fn(_) { actions.ClientResultEmpty(None) })
    None -> Error(jsonrpc.method_not_found_error(mcp.method_set_logging_level))
  }
}

fn find_tool(
  tools: List(RegisteredTool),
  name: String,
) -> Result(RegisteredTool, Nil) {
  find_entry(tools, fn(registered) {
    let RegisteredTool(tool: descriptor, ..) = registered
    descriptor.name == name
  })
}

fn find_prompt(
  prompts: List(RegisteredPrompt),
  name: String,
) -> Result(RegisteredPrompt, Nil) {
  find_entry(prompts, fn(registered) {
    let RegisteredPrompt(prompt: descriptor, ..) = registered
    descriptor.name == name
  })
}

fn find_resource(
  resources: List(RegisteredResource),
  uri: String,
) -> Result(RegisteredResource, Nil) {
  find_entry(resources, fn(registered) {
    let RegisteredResource(resource: descriptor, ..) = registered
    descriptor.uri == uri
  })
}

fn find_resource_template(
  templates: List(RegisteredResourceTemplate),
  uri: String,
) -> Result(RegisteredResourceTemplate, Nil) {
  find_entry(templates, fn(registered) {
    let RegisteredResourceTemplate(resource_template: descriptor, ..) = registered
    matches_template(descriptor.uri_template, uri)
  })
}

fn with_server_metadata(
  server: Server,
  instructions instructions: Option(String),
  authorization authorization: Option(HeaderAuthorization),
) -> Server {
  let Server(
    implementation: implementation,
    task_store: tasks,
    http_store: http_store,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    task_result_request_handler: task_result_request_handler,
    ..,
  ) = server

  Server(
    implementation,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
    task_result_request_handler,
  )
}

fn with_server_registry(
  server: Server,
  tools tools: List(RegisteredTool),
  resources resources: List(RegisteredResource),
  resource_templates resource_templates: List(RegisteredResourceTemplate),
  prompts prompts: List(RegisteredPrompt),
) -> Server {
  let Server(
    implementation: implementation,
    instructions: instructions,
    authorization: authorization,
    task_store: tasks,
    http_store: http_store,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    task_result_request_handler: task_result_request_handler,
    ..,
  ) = server

  Server(
    implementation,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
    task_result_request_handler,
  )
}

fn with_server_handlers(
  server: Server,
  completion_handler completion_handler: Option(CompletionHandler),
  logging_handler logging_handler: Option(LoggingHandler),
  task_result_request_handler task_result_request_handler: Option(
    TaskResultRequestHandler,
  ),
) -> Server {
  let Server(
    implementation: implementation,
    instructions: instructions,
    authorization: authorization,
    task_store: tasks,
    http_store: http_store,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    ..,
  ) = server

  Server(
    implementation,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
    task_result_request_handler,
  )
}

fn listed_entries(entries: List(a), extract: fn(a) -> b) -> List(b) {
  entries
  |> list.reverse
  |> list.map(extract)
}

fn find_entry(entries: List(a), matches: fn(a) -> Bool) -> Result(a, Nil) {
  case entries {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case matches(entry) {
        True -> Ok(entry)
        False -> find_entry(rest, matches)
      }
  }
}

fn matches_template(template: String, uri: String) -> Bool {
  let literals = template_literals(template)
  case literals {
    [literal] -> uri == literal
    _ -> matches_literal_sequence(uri, literals)
  }
}

fn template_literals(template: String) -> List(String) {
  case string.split(template, on: "{") {
    [] -> [template]
    [first, ..rest] -> collect_template_literals(rest, [first]) |> list.reverse
  }
}

fn collect_template_literals(
  parts: List(String),
  acc: List(String),
) -> List(String) {
  case parts {
    [] -> acc
    [part, ..rest] ->
      case string.split(part, on: "}") {
        [] -> collect_template_literals(rest, [part, ..acc])
        [_placeholder] -> collect_template_literals(rest, ["", ..acc])
        [_placeholder, ..tail] ->
          collect_template_literals(rest, [string.join(tail, "}"), ..acc])
      }
  }
}

fn matches_literal_sequence(uri: String, literals: List(String)) -> Bool {
  case literals {
    [] -> False
    [first, ..rest] ->
      case string.starts_with(uri, first) {
        False -> False
        True ->
          match_remaining_literals(
            string.drop_start(from: uri, up_to: string.length(first)),
            rest,
          )
      }
  }
}

fn match_remaining_literals(remaining: String, literals: List(String)) -> Bool {
  case literals {
    [] -> string.is_empty(remaining)
    [last] ->
      case last {
        "" -> True
        _ -> string.ends_with(remaining, last)
      }
    [literal, ..rest] ->
      case literal {
        "" -> match_remaining_literals(remaining, rest)
        _ ->
          case string.split(remaining, on: literal) {
            [] -> False
            [_only] -> False
            [_before, ..tail] ->
              match_remaining_literals(string.join(tail, literal), rest)
          }
      }
  }
}
