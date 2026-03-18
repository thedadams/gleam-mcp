import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities

pub type ToolHandler =
  fn(Option(Dict(String, jsonrpc.Value))) ->
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

pub opaque type Server {
  Server(
    implementation: actions.Implementation,
    instructions: Option(String),
    tools: List(RegisteredTool),
    resources: List(RegisteredResource),
    resource_templates: List(RegisteredResourceTemplate),
    prompts: List(RegisteredPrompt),
    completion_handler: Option(CompletionHandler),
    logging_handler: Option(LoggingHandler),
  )
}

type RegisteredTool {
  RegisteredTool(tool: actions.Tool, handler: ToolHandler)
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
  Server(implementation, None, [], [], [], [], None, None)
}

pub fn with_instructions(server: Server, instructions: String) -> Server {
  let Server(
    implementation: implementation,
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
    tools,
    resources,
    resource_templates,
    prompts,
    completion_handler,
    logging_handler,
  )
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
      execution: None,
      output_schema: None,
      annotations: None,
      icons: [],
      meta: None,
    )

  let Server(
    implementation: server_info,
    instructions: instructions,
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
    [RegisteredTool(tool, implementation), ..tools],
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
  request: jsonrpc.Request(actions.ActionRequest),
) -> #(Server, jsonrpc.Response(actions.ActionResult)) {
  case request {
    jsonrpc.Request(id, _method, Some(action)) ->
      case dispatch_request(server, action) {
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

fn dispatch_request(
  server: Server,
  action: actions.ActionRequest,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  case action {
    actions.RequestInitialize(_) -> Ok(initialization_result(server))
    actions.RequestPing(_) -> Ok(actions.ResultEmpty(None))
    actions.RequestListResources(_) -> Ok(list_resources_result(server))
    actions.RequestListResourceTemplates(_) ->
      Ok(list_resource_templates_result(server))
    actions.RequestReadResource(params) -> read_resource_result(server, params)
    actions.RequestSubscribeResource(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_subscribe_resource))
    actions.RequestUnsubscribeResource(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_unsubscribe_resource))
    actions.RequestListPrompts(_) -> Ok(list_prompts_result(server))
    actions.RequestGetPrompt(params) -> get_prompt_result(server, params)
    actions.RequestListTools(_) -> Ok(list_tools_result(server))
    actions.RequestCallTool(params) -> call_tool_result(server, params)
    actions.RequestComplete(params) -> complete_result(server, params)
    actions.RequestSetLoggingLevel(params) ->
      set_logging_level_result(server, params)
    actions.RequestListRoots(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_list_roots))
    actions.RequestCreateMessage(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_create_message))
    actions.RequestElicit(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_elicit))
    actions.RequestListTasks(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_list_tasks))
    actions.RequestGetTask(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_get_task))
    actions.RequestGetTaskResult(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_get_task_result))
    actions.RequestCancelTask(_) ->
      Error(jsonrpc.method_not_found_error(mcp.method_cancel_task))
  }
}

fn initialization_result(server: Server) -> actions.ActionResult {
  let Server(implementation: implementation, instructions: instructions, ..) =
    server

  actions.ResultInitialize(actions.InitializeResult(
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
    ),
    server_info: implementation,
    instructions: instructions,
    meta: None,
  ))
}

fn list_resources_result(server: Server) -> actions.ActionResult {
  let Server(resources: resources, ..) = server
  let listed =
    resources
    |> list.reverse
    |> list.map(fn(registered) {
      let RegisteredResource(resource, _) = registered
      resource
    })

  actions.ResultListResources(actions.ListResourcesResult(
    resources: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn list_resource_templates_result(server: Server) -> actions.ActionResult {
  let Server(resource_templates: resource_templates, ..) = server
  let listed =
    resource_templates
    |> list.reverse
    |> list.map(fn(registered) {
      let RegisteredResourceTemplate(resource_template, _) = registered
      resource_template
    })

  actions.ResultListResourceTemplates(actions.ListResourceTemplatesResult(
    resource_templates: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn read_resource_result(
  server: Server,
  params: actions.ReadResourceRequestParams,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  let actions.ReadResourceRequestParams(uri, _) = params

  case find_resource(server.resources, uri) {
    Ok(RegisteredResource(handler:, ..)) ->
      handler()
      |> result.map(fn(contents) {
        actions.ResultReadResource(actions.ReadResourceResult(
          contents:,
          meta: None,
        ))
      })
    Error(Nil) ->
      case find_resource_template(server.resource_templates, uri) {
        Ok(RegisteredResourceTemplate(handler:, ..)) ->
          handler(uri)
          |> result.map(fn(contents) {
            actions.ResultReadResource(actions.ReadResourceResult(
              contents:,
              meta: None,
            ))
          })
        Error(Nil) ->
          Error(jsonrpc.invalid_params_error("Unknown resource: " <> uri))
      }
  }
}

fn list_prompts_result(server: Server) -> actions.ActionResult {
  let Server(prompts: prompts, ..) = server
  let listed =
    prompts
    |> list.reverse
    |> list.map(fn(registered) {
      let RegisteredPrompt(prompt, _) = registered
      prompt
    })

  actions.ResultListPrompts(actions.ListPromptsResult(
    prompts: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn get_prompt_result(
  server: Server,
  params: actions.GetPromptRequestParams,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  let actions.GetPromptRequestParams(name, arguments, _) = params

  case find_prompt(server.prompts, name) {
    Ok(RegisteredPrompt(handler:, ..)) ->
      handler(arguments)
      |> result.map(actions.ResultGetPrompt)
    Error(Nil) ->
      Error(jsonrpc.invalid_params_error("Unknown prompt: " <> name))
  }
}

fn list_tools_result(server: Server) -> actions.ActionResult {
  let Server(tools: tools, ..) = server
  let listed =
    tools
    |> list.reverse
    |> list.map(fn(registered) {
      let RegisteredTool(tool, _) = registered
      tool
    })

  actions.ResultListTools(actions.ListToolsResult(
    tools: listed,
    page: actions.Page(None),
    meta: None,
  ))
}

fn call_tool_result(
  server: Server,
  params: actions.CallToolRequestParams,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  let actions.CallToolRequestParams(name, arguments, _, _) = params

  case find_tool(server.tools, name) {
    Ok(RegisteredTool(handler:, ..)) ->
      handler(arguments) |> result.map(actions.ResultCallTool)
    Error(Nil) -> Error(jsonrpc.invalid_params_error("Unknown tool: " <> name))
  }
}

fn complete_result(
  server: Server,
  params: actions.CompleteRequestParams,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  case server.completion_handler {
    Some(handler) -> handler(params) |> result.map(actions.ResultComplete)
    None -> Error(jsonrpc.method_not_found_error(mcp.method_complete))
  }
}

fn set_logging_level_result(
  server: Server,
  params: actions.SetLevelRequestParams,
) -> Result(actions.ActionResult, jsonrpc.RpcError) {
  case server.logging_handler {
    Some(handler) ->
      handler(params) |> result.map(fn(_) { actions.ResultEmpty(None) })
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
