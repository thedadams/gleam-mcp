import gleam/dict.{type Dict}
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

pub type ToolHandler =
  fn(Option(Dict(String, jsonrpc.Value))) ->
    Result(actions.CallToolResult, jsonrpc.RpcError)

pub type ContextToolHandler =
  fn(Server, RequestContext, Option(Dict(String, jsonrpc.Value))) ->
    Result(actions.CallToolResult, jsonrpc.RpcError)

pub type ResourceHandler =
  fn() -> Result(List(actions.ResourceContents), jsonrpc.RpcError)

pub type ResourceTemplateHandler =
  fn(String) -> Result(List(actions.ResourceContents), jsonrpc.RpcError)

pub type PromptHandler =
  fn(Option(Dict(String, String))) ->
    Result(actions.GetPromptResult, jsonrpc.RpcError)

pub type CompletionHandler =
  fn(actions.CompleteRequestParams) ->
    Result(actions.CompleteResult, jsonrpc.RpcError)

pub type LoggingHandler =
  fn(actions.SetLevelRequestParams) -> Result(Nil, jsonrpc.RpcError)

pub type HeaderAuthorization {
  HeaderAuthorization(header: String, validate: fn(String) -> Bool)
}

pub type RequestContext {
  RequestContext(session_id: Option(String))
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
  )
}

pub fn with_instructions(server: Server, instructions: String) -> Server {
  let Server(
    implementation: implementation,
    authorization: authorization,
    task_store: tasks,
    http_store: http_store,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    ..,
  ) = server

  Server(
    implementation,
    Some(instructions),
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
  )
}

pub fn with_header_authorization(
  server: Server,
  header: String,
  validate: fn(String) -> Bool,
) -> Server {
  let Server(
    implementation: implementation,
    instructions: instructions,
    task_store: tasks,
    http_store: http_store,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    ..,
  ) = server

  Server(
    implementation,
    instructions,
    Some(HeaderAuthorization(header, validate)),
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
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
  let tool =
    actions.Tool(
      name: name,
      title: None,
      description: Some(description),
      input_schema: input_schema,
      execution: Some(actions.ToolExecution(Some(actions.TaskOptional))),
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
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    [RegisteredTool(tool, PlainToolHandler(implementation)), ..tools],
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
  )
}

pub fn add_tool_with_context(
  server: Server,
  name: String,
  description: String,
  input_schema: jsonrpc.Value,
  implementation: ContextToolHandler,
) -> Server {
  let tool =
    actions.Tool(
      name: name,
      title: None,
      description: Some(description),
      input_schema: input_schema,
      execution: Some(actions.ToolExecution(Some(actions.TaskOptional))),
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
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    [RegisteredTool(tool, ContextualToolHandler(implementation)), ..tools],
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
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
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    [RegisteredResource(resource, implementation), ..resources],
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
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
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    [
      RegisteredResourceTemplate(resource_template, implementation),
      ..resource_templates
    ],
    prompts,
    completion_handler,
    logging_handler,
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
  ) = server

  Server(
    server_info,
    instructions,
    authorization,
    tasks,
    http_store,
    tools,
    resources,
    resource_templates,
    [RegisteredPrompt(prompt, implementation), ..prompts],
    completion_handler,
    logging_handler,
  )
}

pub fn set_completion_handler(
  server: Server,
  handler: CompletionHandler,
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
    logging_handler: logging_handler,
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
    Some(handler),
    logging_handler,
  )
}

pub fn set_logging_handler(server: Server, handler: LoggingHandler) -> Server {
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
    completion_handler: completion_handler,
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
    Some(handler),
  )
}

pub fn handle_request(
  server: Server,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> #(Server, jsonrpc.Response(actions.ClientActionResult)) {
  handle_request_with_context(server, RequestContext(None), request)
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
  let RequestContext(session_id: session_id) = context
  session_id
}

pub fn ensure_streamable_http_session(
  server: Server,
  session_id: Option(String),
) -> String {
  let Server(http_store: http_store, ..) = server
  streamable_http_store.ensure_session(http_store, session_id)
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
      streamable_http_store.send_request(http_store, value, request, 5000)
    }
    None ->
      Error(jsonrpc.invalid_params_error(
        "Server-sent requests require a streamable HTTP session",
      ))
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
      get_task_payload_result(server, params)
    actions.ClientRequestCancelTask(params) ->
      cancel_task_result(server, params)
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
  let listed =
    resources
    |> list.reverse
    |> list.map(fn(registered) {
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
  let listed =
    resource_templates
    |> list.reverse
    |> list.map(fn(registered) {
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
  let listed =
    prompts
    |> list.reverse
    |> list.map(fn(registered) {
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
  let listed =
    tools
    |> list.reverse
    |> list.map(fn(registered) {
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
    Ok(RegisteredTool(handler:, ..)) ->
      case task {
        Some(actions.TaskMetadata(ttl_ms)) -> {
          let outcome =
            run_tool_handler(server, handler, context, arguments)
            |> result.map(actions.TaskCallTool)
          let created = task_store.create(server.task_store, outcome, ttl_ms)
          Ok(
            actions.ClientResultCreateTask(actions.CreateTaskResult(
              created,
              None,
            )),
          )
        }
        None ->
          run_tool_handler(server, handler, context, arguments)
          |> result.map(actions.ClientResultCallTool)
      }
    Error(Nil) -> Error(jsonrpc.invalid_params_error("Unknown tool: " <> name))
  }
}

fn run_tool_handler(
  server: Server,
  handler: RegisteredToolHandler,
  context: RequestContext,
  arguments: Option(Dict(String, jsonrpc.Value)),
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
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.TaskIdParams(task_id) = params
  task_store.result(server.task_store, task_id)
  |> result.map(actions.ClientResultTaskResult)
}

fn cancel_task_result(
  server: Server,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.TaskIdParams(task_id) = params
  task_store.cancel(server.task_store, task_id)
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
  case tools {
    [] -> Error(Nil)
    [tool, ..rest] -> {
      let RegisteredTool(tool: descriptor, ..) = tool
      case descriptor.name == name {
        True -> Ok(tool)
        False -> find_tool(rest, name)
      }
    }
  }
}

fn find_prompt(
  prompts: List(RegisteredPrompt),
  name: String,
) -> Result(RegisteredPrompt, Nil) {
  case prompts {
    [] -> Error(Nil)
    [prompt, ..rest] -> {
      let RegisteredPrompt(prompt: descriptor, ..) = prompt
      case descriptor.name == name {
        True -> Ok(prompt)
        False -> find_prompt(rest, name)
      }
    }
  }
}

fn find_resource(
  resources: List(RegisteredResource),
  uri: String,
) -> Result(RegisteredResource, Nil) {
  case resources {
    [] -> Error(Nil)
    [resource, ..rest] -> {
      let RegisteredResource(resource: descriptor, ..) = resource
      case descriptor.uri == uri {
        True -> Ok(resource)
        False -> find_resource(rest, uri)
      }
    }
  }
}

fn find_resource_template(
  templates: List(RegisteredResourceTemplate),
  uri: String,
) -> Result(RegisteredResourceTemplate, Nil) {
  case templates {
    [] -> Error(Nil)
    [resource_template, ..rest] -> {
      let RegisteredResourceTemplate(resource_template: descriptor, ..) =
        resource_template
      case matches_template(descriptor.uri_template, uri) {
        True -> Ok(resource_template)
        False -> find_resource_template(rest, uri)
      }
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
