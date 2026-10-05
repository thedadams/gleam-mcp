import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities
import gleam_mcp/server/oauth
import gleam_mcp/server/runtime
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
  IdentityAuthorization(header: String, validate: fn(String) -> Option(String))
  OAuthAuthorization(config: oauth.Config)
}

pub type RequestContext {
  RequestContext(session_id: Option(String), task_id: Option(String))
  RequestContextWithMeta(
    session_id: Option(String),
    task_id: Option(String),
    request_id: jsonrpc.RequestId,
    meta: Option(actions.RequestMeta),
  )
}

pub type NotificationHandler =
  fn(Server, RequestContext, actions.ActionNotification) ->
    Result(Nil, jsonrpc.RpcError)

type Options {
  Options(
    allowed_origins: List(String),
    notifications: Option(NotificationHandler),
    capabilities: Option(actions.ServerCapabilities),
    request_timeout_ms: Int,
    page_size: Int,
  )
}

pub opaque type Server {
  Server(
    implementation: actions.Implementation,
    instructions: Option(String),
    authorization: Option(HeaderAuthorization),
    task_store: task_store.Store,
    http_store: streamable_http_store.Store,
    runtime: runtime.Store(actions.ClientActionResult),
    tools: List(RegisteredTool),
    resources: List(RegisteredResource),
    resource_templates: List(RegisteredResourceTemplate),
    prompts: List(RegisteredPrompt),
    completion_handler: Option(CompletionHandler),
    logging_handler: Option(LoggingHandler),
    task_result_request_handler: Option(TaskResultRequestHandler),
    options: Options,
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
    runtime.new(),
    [],
    [],
    [],
    [],
    None,
    None,
    None,
    Options([], None, None, server_sent_request_timeout_ms, 100),
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

/// Authenticate each request to a stable application user identity.
pub fn with_identity_authorization(
  server: Server,
  header: String,
  validate: fn(String) -> Option(String),
) -> Server {
  Server(..server, authorization: Some(IdentityAuthorization(header, validate)))
}

/// Serve protected-resource metadata and enforce verified token claims on
/// every HTTP request. The issuer's token verifier is supplied in `config`.
pub fn with_oauth_authorization(
  server: Server,
  config: oauth.Config,
) -> Server {
  Server(..server, authorization: Some(OAuthAuthorization(config)))
}

/// Browser origins allowed to connect. Loopback same-origin requests are
/// accepted by default; connections without Origin are also allowed.
pub fn with_allowed_origins(server: Server, origins: List(String)) -> Server {
  Server(..server, options: Options(..server.options, allowed_origins: origins))
}

pub fn allowed_origins(server: Server) -> List(String) {
  server.options.allowed_origins
}

pub fn with_notification_handler(
  server: Server,
  handler: NotificationHandler,
) -> Server {
  Server(
    ..server,
    options: Options(..server.options, notifications: Some(handler)),
  )
}

pub fn with_capabilities(
  server: Server,
  capabilities: actions.ServerCapabilities,
) -> Server {
  Server(
    ..server,
    options: Options(..server.options, capabilities: Some(capabilities)),
  )
}

pub fn with_request_timeout(server: Server, timeout_ms: Int) -> Server {
  Server(
    ..server,
    options: Options(..server.options, request_timeout_ms: case timeout_ms > 0 {
      True -> timeout_ms
      False -> 1
    }),
  )
}

pub fn with_page_size(server: Server, page_size: Int) -> Server {
  Server(
    ..server,
    options: Options(..server.options, page_size: case page_size > 0 {
      True -> page_size
      False -> 1
    }),
  )
}

pub fn register_tool_descriptor(
  server: Server,
  tool: actions.Tool,
  handler: ToolHandler,
) -> Server {
  Server(..server, tools: [
    RegisteredTool(tool, PlainToolHandler(handler)),
    ..server.tools
  ])
}

pub fn register_context_tool_descriptor(
  server: Server,
  tool: actions.Tool,
  handler: ContextToolHandler,
) -> Server {
  Server(..server, tools: [
    RegisteredTool(tool, ContextualToolHandler(handler)),
    ..server.tools
  ])
}

pub fn register_resource_descriptor(
  server: Server,
  resource: actions.Resource,
  handler: ResourceHandler,
) -> Server {
  Server(..server, resources: [
    RegisteredResource(resource, handler),
    ..server.resources
  ])
}

pub fn register_resource_template_descriptor(
  server: Server,
  template: actions.ResourceTemplate,
  handler: ResourceTemplateHandler,
) -> Server {
  Server(..server, resource_templates: [
    RegisteredResourceTemplate(template, handler),
    ..server.resource_templates
  ])
}

pub fn register_prompt_descriptor(
  server: Server,
  prompt: actions.Prompt,
  handler: PromptHandler,
) -> Server {
  Server(..server, prompts: [
    RegisteredPrompt(prompt, handler),
    ..server.prompts
  ])
}

pub fn request_meta(context: RequestContext) -> Option(actions.RequestMeta) {
  case context {
    RequestContext(_, _) -> None
    RequestContextWithMeta(meta: meta, ..) -> meta
  }
}

pub fn progress_token(context: RequestContext) -> Option(jsonrpc.RequestId) {
  request_meta(context) |> option.then(fn(meta) { meta.progress_token })
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

  Server(..server, tools: [RegisteredTool(tool, handler), ..server.tools])
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
    jsonrpc.Request(id, _, Some(_)) -> {
      let reply = process.new_subject()
      start_request_with_context(server, context, request, reply)
      case process.receive_forever(reply) {
        Ok(result) -> #(server, jsonrpc.ResultResponse(id, result))
        Error(error) -> #(server, jsonrpc.ErrorResponse(Some(id), error))
      }
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

/// Register a request before returning, with its result delivered to an
/// explicitly supplied subject. Transports use this to keep reading messages
/// while a handler runs, without racing an immediately following cancellation.
pub fn start_request_with_context(
  server: Server,
  context: RequestContext,
  request: jsonrpc.Request(actions.ClientActionRequest),
  reply_to: process.Subject(
    Result(actions.ClientActionResult, jsonrpc.RpcError),
  ),
) -> Nil {
  case request {
    jsonrpc.Request(id, _, Some(action)) -> {
      let context =
        RequestContextWithMeta(
          context.session_id,
          context.task_id,
          id,
          action_meta(action),
        )
      case check_request_lifecycle(server, context, action) {
        Ok(_) ->
          runtime.start_with_reply(
            server.runtime,
            context.session_id,
            id,
            server.options.request_timeout_ms,
            fn() { dispatch_request(server, context, action) },
            reply_to,
          )
        Error(error) -> process.send(reply_to, Error(error))
      }
    }
    _ ->
      process.send(
        reply_to,
        Error(jsonrpc.invalid_params_error("Expected request parameters")),
      )
  }
}

pub fn handle_notification(
  server: Server,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> #(Server, Result(Nil, jsonrpc.RpcError)) {
  #(
    server,
    handle_notification_with_context(
      server,
      RequestContext(None, None),
      notification,
    ),
  )
}

pub fn handle_notification_with_context(
  server: Server,
  context: RequestContext,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Result(Nil, jsonrpc.RpcError) {
  case notification {
    jsonrpc.Notification(_, Some(action)) -> {
      case action {
        actions.NotifyInitialized(_) -> {
          case context.session_id |> option.then(session_metadata(server, _)) {
            Some(metadata) ->
              case metadata.initialized {
                True -> {
                  let assert Some(id) = context.session_id
                  streamable_http_store.set_metadata(
                    server.http_store,
                    id,
                    streamable_http_store.SessionMetadata(
                      ..metadata,
                      ready: True,
                    ),
                  )
                  Ok(Nil)
                }
                False ->
                  Error(jsonrpc.invalid_params_error(
                    "Session has not been initialized",
                  ))
              }
            None -> Ok(Nil)
          }
        }
        actions.NotifyCancelled(params) -> {
          case params.request_id {
            Some(id) -> runtime.cancel(server.runtime, context.session_id, id)
            None -> Nil
          }
          Ok(Nil)
        }
        _ -> Ok(Nil)
      }
      |> result.try(fn(_) {
        case server.options.notifications {
          Some(handler) -> handler(server, context, action)
          None -> Ok(Nil)
        }
      })
    }
    jsonrpc.Notification(_, None) -> Ok(Nil)
    jsonrpc.Request(_, method, _) ->
      Error(jsonrpc.method_not_found_error(method))
  }
}

pub fn session_id(context: RequestContext) -> Option(String) {
  context.session_id
}

pub fn task_id(context: RequestContext) -> Option(String) {
  context.task_id
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

pub fn session_metadata(
  server: Server,
  session_id: String,
) -> Option(streamable_http_store.SessionMetadata) {
  streamable_http_store.metadata(server.http_store, session_id)
}

pub fn close_session(server: Server, session_id: String) -> Nil {
  runtime.close(server.runtime, session_id)
  streamable_http_store.delete_session(server.http_store, session_id)
}

/// Bind a newly allocated transport session to its authenticated user.
pub fn bind_session(
  server: Server,
  session_id: String,
  principal: Option(String),
) -> Bool {
  case session_metadata(server, session_id) {
    Some(metadata) -> metadata.principal == principal
    None -> {
      streamable_http_store.set_metadata(
        server.http_store,
        session_id,
        streamable_http_store.SessionMetadata(
          protocol_version: jsonrpc.latest_protocol_version,
          client_capabilities: actions.ClientCapabilities(
            None,
            None,
            None,
            None,
            None,
          ),
          initialized: False,
          ready: False,
          principal: principal,
        ),
      )
      True
    }
  }
}

fn context_task_scope(
  server: Server,
  context: RequestContext,
) -> Option(String) {
  case context.session_id {
    Some(id) -> {
      case session_metadata(server, id) {
        Some(metadata) ->
          case metadata.principal {
            Some(principal) -> Some("principal:" <> principal)
            None -> Some("session:" <> id)
          }
        None -> Some("session:" <> id)
      }
    }
    None -> None
  }
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
  use _ <- result.try(check_server_request_capability(server, context, request))
  let request = associate_request(request, context.task_id)
  case session_id(context) {
    Some(value) -> {
      let Server(http_store: http_store, ..) = server
      streamable_http_store.send_request(
        http_store,
        value,
        request,
        server.options.request_timeout_ms,
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
  use _ <- result.try(check_outgoing_ready(server, context))
  use _ <- result.try(check_notification_capability(server, notification))
  let notification = associate_notification(notification, context.task_id)
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

fn check_notification_capability(
  server: Server,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Result(Nil, jsonrpc.RpcError) {
  let caps = advertised_capabilities(server)
  let allowed = case notification {
    jsonrpc.Notification(_, Some(actions.NotifyToolListChanged(_))) ->
      case caps.tools {
        Some(tools) -> tools.list_changed == Some(True)
        None -> False
      }
    jsonrpc.Notification(_, Some(actions.NotifyPromptListChanged(_))) ->
      case caps.prompts {
        Some(prompts) -> prompts.list_changed == Some(True)
        None -> False
      }
    jsonrpc.Notification(_, Some(actions.NotifyResourceListChanged(_))) ->
      case caps.resources {
        Some(resources) -> resources.list_changed == Some(True)
        None -> False
      }
    jsonrpc.Notification(_, Some(actions.NotifyResourceUpdated(_))) ->
      case caps.resources {
        Some(resources) -> resources.subscribe == Some(True)
        None -> False
      }
    jsonrpc.Notification(_, Some(actions.NotifyLoggingMessage(_))) ->
      option.is_some(caps.logging)
    jsonrpc.Notification(_, Some(actions.NotifyTaskStatus(_))) ->
      option.is_some(caps.tasks)
    jsonrpc.Notification(_, Some(actions.NotifyCancelled(_)))
    | jsonrpc.Notification(_, Some(actions.NotifyProgress(_)))
    | jsonrpc.Notification(_, Some(actions.NotifyElicitationComplete(_))) ->
      True
    _ -> False
  }
  case allowed {
    True -> Ok(Nil)
    False ->
      Error(jsonrpc.method_not_found_error(
        "Notification capability was not advertised",
      ))
  }
}

pub fn cancel_request(
  server: Server,
  context: RequestContext,
  request_id: jsonrpc.RequestId,
  reason: Option(String),
) -> Result(Nil, jsonrpc.RpcError) {
  send_notification(
    server,
    context,
    jsonrpc.Notification(
      mcp.method_notify_cancelled,
      Some(
        actions.NotifyCancelled(actions.CancelledNotificationParams(
          Some(request_id),
          reason,
          None,
        )),
      ),
    ),
  )
}

fn check_outgoing_ready(
  server: Server,
  context: RequestContext,
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(case context.session_id {
    Some(id) ->
      case has_streamable_http_session(server, id) {
        True -> Ok(Nil)
        False ->
          Error(jsonrpc.invalid_params_error("MCP session is closed or unknown"))
      }
    None -> Ok(Nil)
  })
  case context.session_id |> option.then(session_metadata(server, _)) {
    Some(metadata) if !metadata.ready ->
      Error(jsonrpc.invalid_params_error("Client is not ready"))
    _ -> Ok(Nil)
  }
}

fn check_server_request_capability(
  server: Server,
  context: RequestContext,
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(check_outgoing_ready(server, context))
  case context.session_id |> option.then(session_metadata(server, _)) {
    None -> Ok(Nil)
    Some(metadata) -> {
      let caps = metadata.client_capabilities
      let allowed = case request {
        jsonrpc.Request(_, _, Some(actions.ServerRequestPing(_))) -> True
        jsonrpc.Request(_, _, Some(actions.ServerRequestListRoots(_))) ->
          option.is_some(caps.roots)
        jsonrpc.Request(_, _, Some(actions.ServerRequestCreateMessage(params))) -> {
          case caps.sampling {
            None -> False
            Some(sampling) -> {
              let context_ok = case params.include_context {
                Some(actions.ThisServerContext)
                | Some(actions.AllServersContext) ->
                  option.is_some(sampling.context)
                _ -> True
              }
              let tools_ok = case
                params.tools != []
                || option.is_some(params.tool_choice)
                || sampling_messages_use_tools(params.messages)
              {
                True -> option.is_some(sampling.tools)
                False -> True
              }
              let task_ok = case params.task {
                None -> True
                Some(_) ->
                  option.is_some(
                    caps.tasks
                    |> option.then(fn(tasks) { tasks.requests })
                    |> option.then(fn(requests) {
                      requests.sampling_create_message
                    }),
                  )
              }
              context_ok && tools_ok && task_ok
            }
          }
        }
        jsonrpc.Request(_, _, Some(actions.ServerRequestElicit(params))) -> {
          let mode_ok = case caps.elicitation {
            None -> False
            Some(elicitation) ->
              case params {
                actions.ElicitRequestForm(_) ->
                  option.is_some(elicitation.form) || elicitation.url == None
                actions.ElicitRequestUrl(_) -> option.is_some(elicitation.url)
              }
          }
          let task = case params {
            actions.ElicitRequestForm(params) -> params.task
            actions.ElicitRequestUrl(params) -> params.task
          }
          let task_ok = case task {
            None -> True
            Some(_) ->
              option.is_some(
                caps.tasks
                |> option.then(fn(tasks) { tasks.requests })
                |> option.then(fn(requests) { requests.elicitation_create }),
              )
          }
          mode_ok && task_ok
        }
        jsonrpc.Request(_, _, Some(actions.ServerRequestListTasks(_))) ->
          option.is_some(caps.tasks |> option.then(fn(tasks) { tasks.list }))
        jsonrpc.Request(_, _, Some(actions.ServerRequestCancelTask(_))) ->
          option.is_some(caps.tasks |> option.then(fn(tasks) { tasks.cancel }))
        jsonrpc.Request(_, _, Some(actions.ServerRequestGetTask(_)))
        | jsonrpc.Request(_, _, Some(actions.ServerRequestGetTaskResult(_))) ->
          option.is_some(caps.tasks)
        _ -> False
      }
      case allowed {
        True -> Ok(Nil)
        False ->
          Error(jsonrpc.method_not_found_error(
            "Client capability was not negotiated",
          ))
      }
    }
  }
}

fn sampling_messages_use_tools(
  messages: List(actions.SamplingMessage),
) -> Bool {
  list.any(messages, fn(message) {
    let content = case message.content {
      actions.SingleSamplingContent(block) -> [block]
      actions.MultipleSamplingContent(blocks) -> blocks
    }
    list.any(content, fn(block) {
      case block {
        actions.SamplingToolUse(_) | actions.SamplingToolResult(_) -> True
        _ -> False
      }
    })
  })
}

fn associate_meta(
  meta: Option(actions.RequestMeta),
  task: Option(String),
) -> Option(actions.RequestMeta) {
  case task {
    None -> meta
    Some(task) -> {
      let meta = option.unwrap(meta, actions.RequestMeta(None, None))
      Some(
        actions.RequestMeta(
          ..meta,
          extra: Some(merge_related_task_meta(meta.extra, task)),
        ),
      )
    }
  }
}

fn associate_notification_meta(
  meta: Option(actions.NotificationMeta),
  task: Option(String),
) -> Option(actions.NotificationMeta) {
  case task {
    None -> meta
    Some(task) -> {
      let meta = option.unwrap(meta, actions.NotificationMeta(None))
      Some(
        actions.NotificationMeta(
          extra: Some(merge_related_task_meta(meta.extra, task)),
        ),
      )
    }
  }
}

fn associate_notification(
  notification: jsonrpc.Request(actions.ActionNotification),
  task: Option(String),
) -> jsonrpc.Request(actions.ActionNotification) {
  case notification {
    jsonrpc.Notification(method, Some(action)) -> {
      let action = case action {
        actions.NotifyInitialized(meta) ->
          actions.NotifyInitialized(associate_notification_meta(meta, task))
        actions.NotifyCancelled(params) ->
          actions.NotifyCancelled(
            actions.CancelledNotificationParams(
              ..params,
              meta: associate_notification_meta(params.meta, task),
            ),
          )
        actions.NotifyProgress(params) ->
          actions.NotifyProgress(
            actions.ProgressNotificationParams(
              ..params,
              meta: associate_notification_meta(params.meta, task),
            ),
          )
        actions.NotifyResourceListChanged(meta) ->
          actions.NotifyResourceListChanged(associate_notification_meta(
            meta,
            task,
          ))
        actions.NotifyResourceUpdated(params) ->
          actions.NotifyResourceUpdated(
            actions.ResourceUpdatedNotificationParams(
              ..params,
              meta: associate_notification_meta(params.meta, task),
            ),
          )
        actions.NotifyPromptListChanged(meta) ->
          actions.NotifyPromptListChanged(associate_notification_meta(
            meta,
            task,
          ))
        actions.NotifyToolListChanged(meta) ->
          actions.NotifyToolListChanged(associate_notification_meta(meta, task))
        actions.NotifyLoggingMessage(params) ->
          actions.NotifyLoggingMessage(
            actions.LoggingMessageNotificationParams(
              ..params,
              meta: associate_notification_meta(params.meta, task),
            ),
          )
        actions.NotifyRootsListChanged(meta) ->
          actions.NotifyRootsListChanged(associate_notification_meta(meta, task))
        actions.NotifyElicitationComplete(params) ->
          case task {
            None -> action
            Some(_) ->
              actions.NotifyElicitationComplete(
                actions.ElicitationCompleteNotificationParamsWithMeta(
                  actions.elicitation_complete_notification_id(params),
                  associate_notification_meta(
                    actions.elicitation_complete_notification_meta(params),
                    task,
                  ),
                ),
              )
          }
        actions.NotifyTaskStatus(_) -> action
      }
      jsonrpc.Notification(method, Some(action))
    }
    _ -> notification
  }
}

fn associate_request(
  request: jsonrpc.Request(actions.ServerActionRequest),
  task: Option(String),
) -> jsonrpc.Request(actions.ServerActionRequest) {
  case request {
    jsonrpc.Request(id, method, Some(action)) -> {
      let action = case action {
        actions.ServerRequestPing(meta) ->
          actions.ServerRequestPing(associate_meta(meta, task))
        actions.ServerRequestListRoots(meta) ->
          actions.ServerRequestListRoots(associate_meta(meta, task))
        actions.ServerRequestCreateMessage(params) ->
          actions.ServerRequestCreateMessage(
            actions.CreateMessageRequestParams(
              ..params,
              meta: associate_meta(params.meta, task),
            ),
          )
        actions.ServerRequestElicit(actions.ElicitRequestForm(params)) ->
          actions.ServerRequestElicit(actions.ElicitRequestForm(
            actions.ElicitRequestFormParams(
              ..params,
              meta: associate_meta(params.meta, task),
            ),
          ))
        actions.ServerRequestElicit(actions.ElicitRequestUrl(params)) ->
          actions.ServerRequestElicit(actions.ElicitRequestUrl(
            actions.ElicitRequestUrlParams(
              ..params,
              meta: associate_meta(params.meta, task),
            ),
          ))
        actions.ServerRequestListTasks(params) ->
          actions.ServerRequestListTasks(
            actions.PaginatedRequestParams(
              ..params,
              meta: associate_meta(params.meta, task),
            ),
          )
        _ -> action
      }
      jsonrpc.Request(id, method, Some(action))
    }
    _ -> request
  }
}

/// Send progress only when the initiating request supplied a progress token.
pub fn report_progress(
  server: Server,
  context: RequestContext,
  progress: Float,
  total: Option(Float),
  message: Option(String),
) -> Result(Nil, jsonrpc.RpcError) {
  case progress_token(context) {
    None -> Ok(Nil)
    Some(token) ->
      send_notification(
        server,
        context,
        jsonrpc.Notification(
          mcp.method_notify_progress,
          Some(
            actions.NotifyProgress(actions.ProgressNotificationParams(
              token,
              progress,
              total,
              message,
              None,
            )),
          ),
        ),
      )
  }
}

pub fn with_resource_subscriptions(server: Server) -> Server {
  let caps = advertised_capabilities(server)
  let resources =
    option.unwrap(
      caps.resources,
      actions.ServerResourcesCapabilities(None, None),
    )
  with_capabilities(
    server,
    actions.ServerCapabilities(
      ..caps,
      resources: Some(
        actions.ServerResourcesCapabilities(..resources, subscribe: Some(True)),
      ),
    ),
  )
}

fn subscribe_resource(
  server: Server,
  context: RequestContext,
  uri: String,
  enabled: Bool,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  case advertised_capabilities(server).resources {
    Some(resources) if resources.subscribe == Some(True) -> {
      let known = case
        find_resource(server.resources, uri),
        find_resource_template(server.resource_templates, uri)
      {
        Error(_), Error(_) -> False
        _, _ -> True
      }
      case context.session_id, known {
        Some(id), True -> {
          runtime.subscribe(server.runtime, id, uri, enabled)
          Ok(actions.ClientResultEmpty(None))
        }
        None, _ ->
          Error(jsonrpc.invalid_params_error(
            "Resource subscriptions require a session",
          ))
        _, False ->
          Error(jsonrpc.invalid_params_error("Unknown resource: " <> uri))
      }
    }
    _ -> Error(jsonrpc.method_not_found_error(mcp.method_subscribe_resource))
  }
}

pub fn notify_resource_updated(server: Server, uri: String) -> Nil {
  runtime.subscribers(server.runtime, uri)
  |> list.each(fn(id) {
    let _ =
      send_notification(
        server,
        RequestContext(Some(id), None),
        jsonrpc.Notification(
          mcp.method_notify_resource_updated,
          Some(
            actions.NotifyResourceUpdated(
              actions.ResourceUpdatedNotificationParams(uri, None),
            ),
          ),
        ),
      )
    Nil
  })
}

pub fn update_task_status(
  server: Server,
  context: RequestContext,
  task_id: String,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Result(actions.Task, jsonrpc.RpcError) {
  use _ <- result.try(get_task_result(
    server,
    context,
    actions.TaskIdParams(task_id),
  ))
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
  case elicit_with_tasks(server, context, params) {
    Ok(actions.Elicit(result)) -> Ok(result)
    Ok(actions.ElicitTask(_)) ->
      Error(jsonrpc.invalid_params_error(
        "Use elicit_with_tasks for task-augmented elicitation",
      ))
    Error(error) -> Error(error)
  }
}

pub fn elicit_with_tasks(
  server: Server,
  context: RequestContext,
  params: actions.ElicitRequestParams,
) -> Result(actions.ElicitResponse, jsonrpc.RpcError) {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId(uuid.v4_string()),
      mcp.method_elicit,
      Some(actions.ServerRequestElicit(params)),
    )

  case send_request(server, context, request) {
    Ok(jsonrpc.ResultResponse(_, actions.ServerResultElicit(result))) ->
      Ok(actions.Elicit(result))
    Ok(jsonrpc.ResultResponse(_, actions.ServerResultCreateTask(result))) ->
      Ok(actions.ElicitTask(result))
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
    actions.ClientRequestInitialize(params) -> {
      case context.session_id {
        Some(id) -> {
          let principal =
            session_metadata(server, id)
            |> option.then(fn(metadata) { metadata.principal })
          streamable_http_store.set_metadata(
            server.http_store,
            id,
            streamable_http_store.SessionMetadata(
              jsonrpc.latest_protocol_version,
              params.capabilities,
              True,
              False,
              principal,
            ),
          )
        }
        None -> Nil
      }
      Ok(initialization_result(server))
    }
    actions.ClientRequestPing(_) -> Ok(actions.ClientResultEmpty(None))
    actions.ClientRequestListResources(params) ->
      list_resources_result(server, params)
    actions.ClientRequestListResourceTemplates(params) ->
      list_resource_templates_result(server, params)
    actions.ClientRequestReadResource(params) ->
      read_resource_result(server, params)
    actions.ClientRequestSubscribeResource(params) ->
      subscribe_resource(server, context, params.uri, True)
    actions.ClientRequestUnsubscribeResource(params) ->
      subscribe_resource(server, context, params.uri, False)
    actions.ClientRequestListPrompts(params) ->
      list_prompts_result(server, params)
    actions.ClientRequestGetPrompt(params) -> get_prompt_result(server, params)
    actions.ClientRequestListTools(params) -> list_tools_result(server, params)
    actions.ClientRequestCallTool(params) ->
      call_tool_result(server, context, params)
    actions.ClientRequestComplete(params) -> complete_result(server, params)
    actions.ClientRequestSetLoggingLevel(params) ->
      set_logging_level_result(server, params)
    actions.ClientRequestListTasks(params) ->
      list_tasks_result(server, context, params)
    actions.ClientRequestGetTask(params) ->
      get_task_result(server, context, params)
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
    capabilities: advertised_capabilities(server),
    server_info: implementation,
    instructions: instructions,
    meta: None,
  ))
}

pub fn advertised_capabilities(server: Server) -> actions.ServerCapabilities {
  case server.options.capabilities {
    Some(configured) -> configured
    None ->
      capabilities.infer(
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
        has_tasks: list.any(server.tools, fn(registered) {
          case tool_task_support(registered.tool) {
            Some(actions.TaskForbidden) | None -> False
            _ -> True
          }
        }),
      )
  }
}

fn action_meta(
  action: actions.ClientActionRequest,
) -> Option(actions.RequestMeta) {
  case action {
    actions.ClientRequestInitialize(params) -> params.meta
    actions.ClientRequestPing(meta) -> meta
    actions.ClientRequestListResources(params)
    | actions.ClientRequestListResourceTemplates(params)
    | actions.ClientRequestListPrompts(params)
    | actions.ClientRequestListTools(params)
    | actions.ClientRequestListTasks(params) -> params.meta
    actions.ClientRequestReadResource(params) -> params.meta
    actions.ClientRequestSubscribeResource(params) -> params.meta
    actions.ClientRequestUnsubscribeResource(params) -> params.meta
    actions.ClientRequestGetPrompt(params) -> params.meta
    actions.ClientRequestCallTool(params) -> params.meta
    actions.ClientRequestComplete(params) -> params.meta
    actions.ClientRequestSetLoggingLevel(params) -> params.meta
    actions.ClientRequestGetTask(_)
    | actions.ClientRequestGetTaskResult(_)
    | actions.ClientRequestCancelTask(_) -> None
  }
}

fn check_request_lifecycle(
  server: Server,
  context: RequestContext,
  action: actions.ClientActionRequest,
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(case context.session_id {
    Some(id) ->
      case has_streamable_http_session(server, id) {
        True -> Ok(Nil)
        False ->
          Error(jsonrpc.invalid_params_error("MCP session is closed or unknown"))
      }
    None -> Ok(Nil)
  })
  case context.session_id |> option.then(session_metadata(server, _)) {
    None -> Ok(Nil)
    Some(metadata) -> {
      case action {
        actions.ClientRequestInitialize(_) ->
          case metadata.initialized {
            False -> Ok(Nil)
            True ->
              Error(jsonrpc.invalid_params_error(
                "Session is already initialized",
              ))
          }
        actions.ClientRequestPing(_) -> Ok(Nil)
        _ ->
          case metadata.ready {
            False ->
              Error(jsonrpc.invalid_params_error(
                "Session is not ready; send notifications/initialized first",
              ))
            True -> check_client_request_capability(server, action)
          }
      }
    }
  }
}

fn check_client_request_capability(
  server: Server,
  action: actions.ClientActionRequest,
) -> Result(Nil, jsonrpc.RpcError) {
  let caps = advertised_capabilities(server)
  let allowed = case action {
    actions.ClientRequestListResources(_)
    | actions.ClientRequestListResourceTemplates(_)
    | actions.ClientRequestReadResource(_) -> option.is_some(caps.resources)
    actions.ClientRequestSubscribeResource(_)
    | actions.ClientRequestUnsubscribeResource(_) ->
      case caps.resources {
        Some(resources) -> resources.subscribe == Some(True)
        None -> False
      }
    actions.ClientRequestListTools(_) | actions.ClientRequestCallTool(_) ->
      option.is_some(caps.tools)
    actions.ClientRequestListPrompts(_) | actions.ClientRequestGetPrompt(_) ->
      option.is_some(caps.prompts)
    actions.ClientRequestComplete(_) -> option.is_some(caps.completions)
    actions.ClientRequestSetLoggingLevel(_) -> option.is_some(caps.logging)
    actions.ClientRequestListTasks(_) ->
      option.is_some(caps.tasks |> option.then(fn(tasks) { tasks.list }))
    actions.ClientRequestCancelTask(_) ->
      option.is_some(caps.tasks |> option.then(fn(tasks) { tasks.cancel }))
    actions.ClientRequestGetTask(_) | actions.ClientRequestGetTaskResult(_) ->
      option.is_some(caps.tasks)
    _ -> True
  }
  case allowed {
    True -> Ok(Nil)
    False ->
      Error(jsonrpc.method_not_found_error("Capability was not advertised"))
  }
}

fn list_resources_result(
  server: Server,
  params: actions.PaginatedRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let Server(resources: resources, ..) = server
  let listed =
    listed_entries(resources, fn(registered) {
      let RegisteredResource(resource, _) = registered
      resource
    })

  paginate(listed, params.cursor, "resources", server.options.page_size)
  |> result.map(fn(page) {
    actions.ClientResultListResources(actions.ListResourcesResult(
      resources: page.0,
      page: page.1,
      meta: None,
    ))
  })
}

fn list_resource_templates_result(
  server: Server,
  params: actions.PaginatedRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let Server(resource_templates: resource_templates, ..) = server
  let listed =
    listed_entries(resource_templates, fn(registered) {
      let RegisteredResourceTemplate(resource_template, _) = registered
      resource_template
    })

  paginate(listed, params.cursor, "templates", server.options.page_size)
  |> result.map(fn(page) {
    actions.ClientResultListResourceTemplates(
      actions.ListResourceTemplatesResult(
        resource_templates: page.0,
        page: page.1,
        meta: None,
      ),
    )
  })
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

fn list_prompts_result(
  server: Server,
  params: actions.PaginatedRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let Server(prompts: prompts, ..) = server
  let listed =
    listed_entries(prompts, fn(registered) {
      let RegisteredPrompt(prompt, _) = registered
      prompt
    })

  paginate(listed, params.cursor, "prompts", server.options.page_size)
  |> result.map(fn(page) {
    actions.ClientResultListPrompts(actions.ListPromptsResult(
      prompts: page.0,
      page: page.1,
      meta: None,
    ))
  })
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

fn list_tools_result(
  server: Server,
  params: actions.PaginatedRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let Server(tools: tools, ..) = server
  let listed =
    listed_entries(tools, fn(registered) {
      let RegisteredTool(tool, _) = registered
      tool
    })

  paginate(listed, params.cursor, "tools", server.options.page_size)
  |> result.map(fn(page) {
    actions.ClientResultListTools(actions.ListToolsResult(
      tools: page.0,
      page: page.1,
      meta: None,
    ))
  })
}

fn call_tool_result(
  server: Server,
  context: RequestContext,
  params: actions.CallToolRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let actions.CallToolRequestParams(name, arguments, task, _) = params
  let support =
    advertised_capabilities(server).tasks
    |> option.then(fn(tasks) { tasks.requests })
    |> option.then(fn(requests) { requests.tools_call })

  case find_tool(server.tools, name) {
    Ok(RegisteredTool(tool:, handler:)) ->
      case support {
        None ->
          run_tool_handler(server, handler, context, arguments)
          |> result.map(actions.ClientResultCallTool)
        Some(_) ->
          case task, tool_task_support(tool) {
            Some(_), Some(actions.TaskForbidden) | Some(_), None ->
              Error(jsonrpc.invalid_params_error(
                "Tool does not support task execution",
              ))
            Some(actions.TaskMetadata(ttl_ms)), _ -> {
              Ok(create_tool_task_result(
                server,
                handler,
                context,
                arguments,
                ttl_ms,
              ))
            }
            None, Some(actions.TaskRequired) ->
              Error(jsonrpc.method_not_found_error(mcp.method_call_tool))
            None, _ ->
              run_tool_handler(server, handler, context, arguments)
              |> result.map(actions.ClientResultCallTool)
          }
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
  let created =
    task_store.create_scoped(
      server.task_store,
      ttl_ms,
      context_task_scope(server, context),
    )
  let task_context = case context {
    RequestContext(_, _) ->
      RequestContext(context.session_id, Some(created.task_id))
    RequestContextWithMeta(_, _, id, meta) ->
      RequestContextWithMeta(
        context.session_id,
        Some(created.task_id),
        id,
        meta,
      )
  }
  let _ =
    task_store.start_worker(server.task_store, created.task_id, fn() {
      run_tool_handler(server, handler, task_context, arguments)
      |> result.map(actions.TaskCallTool)
    })
  // Observe completion independently of the worker so crashes/cancellation also
  // produce status notifications when a transport is listening.
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        task_store.result_scoped(
          server.task_store,
          created.task_id,
          context_task_scope(server, context),
        )
      case task_store.get(server.task_store, created.task_id) {
        Ok(task) ->
          case task.status {
            actions.Cancelled -> Nil
            _ -> {
              let _ = send_task_status_notification(server, task_context, task)
              Nil
            }
          }
        Error(_) -> Nil
      }
    })
  actions.ClientResultCreateTask(actions.CreateTaskResult(created, None))
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
  context: RequestContext,
  params: actions.PaginatedRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let tasks = case context.session_id {
    None -> task_store.list(server.task_store)
    Some(_) ->
      task_store.list_scoped(
        server.task_store,
        context_task_scope(server, context),
      )
  }
  paginate(tasks, params.cursor, "tasks", server.options.page_size)
  |> result.map(fn(page) {
    actions.ClientResultListTasks(actions.ListTasksResult(page.0, page.1, None))
  })
}

fn get_task_result(
  server: Server,
  context: RequestContext,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let task = case context.session_id {
    None -> task_store.get(server.task_store, params.task_id)
    Some(_) ->
      task_store.get_scoped(
        server.task_store,
        params.task_id,
        context_task_scope(server, context),
      )
  }
  task
  |> result.map(fn(task) {
    actions.ClientResultGetTask(actions.GetTaskResult(task, None))
  })
}

fn get_task_payload_result(
  server: Server,
  context: RequestContext,
  params: actions.TaskIdParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  // Authorize before calling an application hook or waiting on the outcome.
  use _ <- result.try(get_task_result(server, context, params))
  use _ <- result.try(run_task_result_request_handler(
    server,
    context,
    params.task_id,
  ))
  let payload = case context.session_id {
    None -> task_store.result(server.task_store, params.task_id)
    Some(_) ->
      task_store.result_scoped(
        server.task_store,
        params.task_id,
        context_task_scope(server, context),
      )
  }
  payload |> result.map(actions.ClientResultTaskResult)
}

fn paginate(
  entries: List(a),
  cursor: Option(actions.Cursor),
  kind: String,
  size: Int,
) -> Result(#(List(a), actions.Page), jsonrpc.RpcError) {
  let offset = case cursor {
    None -> Ok(0)
    Some(actions.Cursor(value)) -> {
      case string.split(value, ":") {
        [tag, value] if tag == kind -> int.parse(value)
        _ -> Error(Nil)
      }
    }
  }
  use offset <- result.try(
    offset
    |> result.map_error(fn(_) {
      jsonrpc.invalid_params_error("Invalid pagination cursor")
    }),
  )
  case offset < 0 || offset > list.length(entries) {
    True -> Error(jsonrpc.invalid_params_error("Invalid pagination cursor"))
    False -> {
      let page = entries |> list.drop(offset) |> list.take(size)
      let next_offset = offset + list.length(page)
      let next = case next_offset < list.length(entries) {
        True -> Some(actions.Cursor(kind <> ":" <> int.to_string(next_offset)))
        False -> None
      }
      Ok(#(page, actions.Page(next)))
    }
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
  let cancelled = case context.session_id {
    None -> task_store.cancel(server.task_store, task_id)
    Some(_) ->
      task_store.cancel_scoped(
        server.task_store,
        task_id,
        context_task_scope(server, context),
      )
  }
  cancelled
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
    Some(handler) ->
      handler(params)
      |> result.map(fn(result) {
        let completion = result.completion
        let values = list.take(completion.values, 100)
        let truncated = list.length(completion.values) > 100
        actions.ClientResultComplete(
          actions.CompleteResult(
            ..result,
            completion: actions.CompletionValues(
              ..completion,
              values: values,
              has_more: case truncated {
                True -> Some(True)
                False -> completion.has_more
              },
            ),
          ),
        )
      })
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
    let RegisteredResourceTemplate(resource_template: descriptor, ..) =
      registered
    matches_template(descriptor.uri_template, uri)
  })
}

fn with_server_metadata(
  server: Server,
  instructions instructions: Option(String),
  authorization authorization: Option(HeaderAuthorization),
) -> Server {
  Server(..server, instructions: instructions, authorization: authorization)
}

fn with_server_registry(
  server: Server,
  tools tools: List(RegisteredTool),
  resources resources: List(RegisteredResource),
  resource_templates resource_templates: List(RegisteredResourceTemplate),
  prompts prompts: List(RegisteredPrompt),
) -> Server {
  Server(
    ..server,
    tools: tools,
    resources: resources,
    resource_templates: resource_templates,
    prompts: prompts,
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
  Server(
    ..server,
    completion_handler: completion_handler,
    logging_handler: logging_handler,
    task_result_request_handler: task_result_request_handler,
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
