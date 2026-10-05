import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities
import gleam_mcp/server/oauth
import gleam_mcp/server/runtime
import gleam_mcp/server/streamable_http_store
import gleam_mcp/task_store
import gleam_mcp/wire
import youid/uuid

const task_extension = "io.modelcontextprotocol/tasks"

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
  ModernRequestContext(
    session_id: Option(String),
    task_id: Option(String),
    request_id: jsonrpc.RequestId,
    meta: Option(actions.RequestMeta),
    principal: Option(String),
    transport_scope: String,
    worker: Option(process.Pid),
    notifications: Option(
      process.Subject(streamable_http_store.ListenerMessage),
    ),
  )
}

pub type NotificationHandler =
  fn(Server, RequestContext, actions.ActionNotification) ->
    Result(Nil, jsonrpc.RpcError)

pub type ModernRequestHandler =
  fn(Server, RequestContext, actions.ClientActionRequest) ->
    Result(actions.ClientActionResult, jsonrpc.RpcError)

type Options {
  Options(
    allowed_origins: List(String),
    notifications: Option(NotificationHandler),
    capabilities: Option(actions.ServerCapabilities),
    request_timeout_ms: Int,
    page_size: Int,
    modern_handler: Option(ModernRequestHandler),
    state_secret: BitArray,
    extensions: dict.Dict(String, jsonrpc.Value),
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
    subscriptions: runtime.SubscriptionStore,
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
    runtime.new_subscriptions(),
    [],
    [],
    [],
    [],
    None,
    None,
    None,
    Options(
      [],
      None,
      None,
      server_sent_request_timeout_ms,
      100,
      None,
      crypto.strong_random_bytes(32),
      dict.new(),
    ),
  )
}

pub fn implementation(server: Server) -> actions.Implementation {
  server.implementation
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

/// Supply MRTR-aware handlers. Each retry carries all of its own input and
/// opaque request state; handlers must verify application-owned state before
/// using it for authorization or business decisions.
pub fn with_modern_request_handler(
  server: Server,
  handler: ModernRequestHandler,
) -> Server {
  Server(
    ..server,
    options: Options(..server.options, modern_handler: Some(handler)),
  )
}

/// Declare supported protocol extensions in modern discovery responses.
pub fn with_extensions(
  server: Server,
  extensions: dict.Dict(String, jsonrpc.Value),
) -> Server {
  Server(..server, options: Options(..server.options, extensions: extensions))
}

/// A modern transport scopes cancellation and notifications to an individual
/// request. It never establishes an MCP protocol session.
pub fn modern_request_context(
  principal: Option(String),
  transport_scope: String,
  notifications: Option(process.Subject(streamable_http_store.ListenerMessage)),
) -> RequestContext {
  ModernRequestContext(
    None,
    None,
    jsonrpc.IntId(0),
    None,
    principal,
    transport_scope,
    None,
    notifications,
  )
}

/// Configure the same signing secret on server instances that share MRTR
/// continuations. The secret must contain at least 32 random bytes.
pub fn with_request_state_secret(
  server: Server,
  secret: BitArray,
) -> Result(Server, String) {
  case bit_array.byte_size(secret) >= 32 {
    True ->
      Ok(
        Server(
          ..server,
          options: Options(..server.options, state_secret: secret),
        ),
      )
    False ->
      Error("Request state signing secrets must contain at least 32 bytes")
  }
}

/// Protect continuation state and bind it to the authenticated caller, a
/// method/parameter identity chosen by the application, and a short expiry.
pub fn sign_request_state(
  server: Server,
  context: RequestContext,
  binding: String,
  state: String,
  ttl_ms: Int,
) -> String {
  let principal = context_principal(context)
  let expiry = current_time_ms() + int.clamp(ttl_ms, 1, 3_600_000)
  let payload =
    json.object([
      #("principal", case principal {
        Some(value) -> json.string(value)
        None -> json.null()
      }),
      #("binding", json.string(binding)),
      #("state", json.string(state)),
      #("expiry", json.int(expiry)),
    ])
    |> json.to_string
  crypto.sign_message(
    <<payload:utf8>>,
    server.options.state_secret,
    crypto.Sha256,
  )
}

pub fn verify_request_state(
  server: Server,
  context: RequestContext,
  binding: String,
  token: String,
) -> Result(String, jsonrpc.RpcError) {
  use payload <- result.try(
    crypto.verify_signed_message(token, server.options.state_secret)
    |> result.map_error(fn(_) {
      jsonrpc.invalid_params_error("Invalid request state signature")
    }),
  )
  use payload <- result.try(
    bit_array.to_string(payload)
    |> result.map_error(fn(_) {
      jsonrpc.invalid_params_error("Invalid request state encoding")
    }),
  )
  let decoder = {
    use principal <- decode.field("principal", decode.optional(decode.string))
    use binding <- decode.field("binding", decode.string)
    use state <- decode.field("state", decode.string)
    use expiry <- decode.field("expiry", decode.int)
    decode.success(#(principal, binding, state, expiry))
  }
  use decoded <- result.try(
    json.parse(payload, decoder)
    |> result.map_error(fn(_) {
      jsonrpc.invalid_params_error("Invalid request state payload")
    }),
  )
  case
    decoded.0 == context_principal(context)
    && decoded.1 == binding
    && decoded.3 > current_time_ms()
  {
    True -> Ok(decoded.2)
    False ->
      Error(jsonrpc.invalid_params_error(
        "Request state expired or belongs to a different caller or request",
      ))
  }
}

fn current_time_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn context_principal(context: RequestContext) -> Option(String) {
  case context {
    ModernRequestContext(principal: principal, ..) -> principal
    _ -> None
  }
}

pub fn is_modern_context(context: RequestContext) -> Bool {
  case context {
    ModernRequestContext(..) -> True
    _ -> False
  }
}

fn runtime_scope(context: RequestContext) -> Option(String) {
  case context {
    ModernRequestContext(transport_scope: scope, ..) -> Some(scope)
    _ -> context.session_id
  }
}

/// Cancel a request using its transport correlation scope.
pub fn cancel_incoming_request(
  server: Server,
  context: RequestContext,
  id: jsonrpc.RequestId,
) -> Nil {
  runtime.cancel(server.runtime, runtime_scope(context), id)
  case runtime_scope(context) {
    Some(scope) -> runtime.cancel_subscription(server.subscriptions, scope, id)
    None -> Nil
  }
}

pub fn close_modern_transport(server: Server, scope: String) -> Nil {
  runtime.close(server.runtime, scope)
  runtime.close_subscription_scope(server.subscriptions, scope)
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

pub fn tool_descriptor(server: Server, name: String) -> Option(actions.Tool) {
  find_tool(server.tools, name)
  |> result.map(fn(registered) { registered.tool })
  |> option.from_result
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
    ModernRequestContext(meta: meta, ..) -> meta
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
      let context = case is_modern_context(context), is_modern_action(action) {
        False, True ->
          modern_request_context(
            None,
            context.session_id |> option.unwrap("direct"),
            None,
          )
        _, _ -> context
      }
      let context = request_context(context, id, action_meta(action))
      let duplicate_subscription = case runtime_scope(context) {
        Some(scope) ->
          runtime.subscription_active(server.subscriptions, scope, id)
        None -> False
      }
      let validation = case duplicate_subscription {
        True ->
          Error(jsonrpc.RpcError(
            -32_600,
            "Duplicate active subscription id",
            None,
          ))
        False ->
          case is_modern_context(context) {
            True -> validate_modern_request(server, context, action)
            False -> check_request_lifecycle(server, context, action)
          }
      }
      case validation {
        Ok(_) ->
          runtime.start_with_reply(
            server.runtime,
            runtime_scope(context),
            id,
            server.options.request_timeout_ms,
            fn() {
              case is_modern_context(context) {
                True -> {
                  let assert ModernRequestContext(..) = context
                  dispatch_modern_request(
                    server,
                    ModernRequestContext(
                      ..context,
                      worker: Some(process.self()),
                    ),
                    action,
                  )
                }
                False -> dispatch_request(server, context, action)
              }
            },
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

pub fn request_context(
  context: RequestContext,
  id: jsonrpc.RequestId,
  meta: Option(actions.RequestMeta),
) -> RequestContext {
  case context {
    ModernRequestContext(..) ->
      ModernRequestContext(..context, request_id: id, meta: meta)
    _ ->
      case uses_modern_metadata(meta) {
        True ->
          ModernRequestContext(
            None,
            context.task_id,
            id,
            meta,
            None,
            "direct",
            None,
            None,
          )
        False ->
          RequestContextWithMeta(context.session_id, context.task_id, id, meta)
      }
  }
}

pub fn uses_modern_metadata(meta: Option(actions.RequestMeta)) -> Bool {
  option.is_some(request_meta_value(
    meta,
    "io.modelcontextprotocol/protocolVersion",
  ))
}

pub fn is_modern_action(action: actions.ClientActionRequest) -> Bool {
  uses_modern_metadata(action_meta(action))
  || case base_request(action) {
    actions.ClientRequestDiscover(_)
    | actions.ClientRequestSubscriptionsListen(_)
    | actions.ClientRequestUpdateTask(_) -> True
    _ -> False
  }
}

pub fn protocol_version(meta: Option(actions.RequestMeta)) -> Option(String) {
  case request_meta_value(meta, "io.modelcontextprotocol/protocolVersion") {
    Some(jsonrpc.VString(value)) -> Some(value)
    _ -> None
  }
}

fn request_meta_value(
  meta: Option(actions.RequestMeta),
  key: String,
) -> Option(jsonrpc.Value) {
  use meta <- option.then(meta)
  use extra <- option.then(meta.extra)
  dict.get(extra.fields, key) |> option.from_result
}

fn client_capability_value(
  context: RequestContext,
  key: String,
) -> Option(jsonrpc.Value) {
  case
    request_meta_value(
      request_meta(context),
      "io.modelcontextprotocol/clientCapabilities",
    )
  {
    Some(jsonrpc.VObject(fields)) ->
      dict.get(dict.from_list(fields), key) |> option.from_result
    _ -> None
  }
}

pub fn validate_modern_request(
  server: Server,
  context: RequestContext,
  action: actions.ClientActionRequest,
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(wire.validate_request_metadata(request_meta(context)))
  case action {
    actions.ClientRequestWithInput(request, _, _) ->
      validate_modern_request(server, context, request)
    actions.ClientRequestGetTask(_) | actions.ClientRequestCancelTask(_) ->
      require_task_extension(server, context)
    actions.ClientRequestUpdateTask(params) -> {
      use _ <- result.try(require_task_extension(server, context))
      case params.input {
        Some(jsonrpc.VObject(_)) -> Ok(Nil)
        _ ->
          Error(jsonrpc.invalid_params_error(
            "tasks/update requires inputResponses object",
          ))
      }
    }
    actions.ClientRequestSubscriptionsListen(params) ->
      validate_subscription_filter(params.notifications)
    actions.ClientRequestInitialize(_)
    | actions.ClientRequestPing(_)
    | actions.ClientRequestSubscribeResource(_)
    | actions.ClientRequestUnsubscribeResource(_)
    | actions.ClientRequestSetLoggingLevel(_)
    | actions.ClientRequestListTasks(_)
    | actions.ClientRequestGetTaskResult(_) ->
      Error(jsonrpc.method_not_found_error(
        "Method is not defined in the modern protocol",
      ))
    _ -> check_client_request_capability(server, action)
  }
}

fn log_rank(level: String) -> Option(Int) {
  case level {
    "debug" -> Some(0)
    "info" -> Some(1)
    "notice" -> Some(2)
    "warning" -> Some(3)
    "error" -> Some(4)
    "critical" -> Some(5)
    "alert" -> Some(6)
    "emergency" -> Some(7)
    _ -> None
  }
}

fn dispatch_modern_request(
  server: Server,
  context: RequestContext,
  action: actions.ClientActionRequest,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let base = base_request(action)
  let outcome = case base {
    actions.ClientRequestDiscover(_) -> Ok(discovery_result(server))
    actions.ClientRequestGetTask(params) ->
      modern_task_result(server, context, params.task_id)
    actions.ClientRequestCancelTask(params) -> {
      use snapshot <- result.try(task_store.snapshot_scoped(
        server.task_store,
        params.task_id,
        context_task_scope(server, context),
      ))
      case snapshot.task.status {
        actions.Completed | actions.Failed | actions.Cancelled -> Nil
        _ -> {
          let _ =
            task_store.cancel_scoped(
              server.task_store,
              params.task_id,
              context_task_scope(server, context),
            )
          Nil
        }
      }
      Ok(actions.ClientResultEmpty(None))
    }
    actions.ClientRequestUpdateTask(params) -> {
      let inputs = case params.input {
        Some(jsonrpc.VObject(fields)) -> dict.from_list(fields)
        None -> dict.new()
        _ -> dict.new()
      }
      task_store.submit_inputs_scoped(
        server.task_store,
        params.task_id,
        context_task_scope(server, context),
        inputs,
      )
      |> result.map(fn(_) { actions.ClientResultEmpty(None) })
    }
    actions.ClientRequestSubscriptionsListen(_) ->
      Error(jsonrpc.invalid_params_error(
        "Subscriptions require a streaming transport",
      ))
    actions.ClientRequestCallTool(params) -> {
      case server.options.modern_handler {
        Some(handler) -> handler(server, context, action)
        None -> modern_call_tool(server, context, params)
      }
    }
    actions.ClientRequestReadResource(_) | actions.ClientRequestGetPrompt(_) -> {
      case server.options.modern_handler {
        Some(handler) -> handler(server, context, action)
        None -> dispatch_request(server, context, base)
      }
    }
    _ -> dispatch_request(server, context, base)
  }
  use response <- result.try(
    outcome
    |> result.map_error(fn(error) {
      case error.code {
        -32_002 | -32_042 ->
          jsonrpc.RpcError(-32_603, error.message, error.data)
        _ -> error
      }
    }),
  )
  use _ <- result.try(validate_modern_result(server, context, base, response))
  let response = strip_input_cache(response)
  let response = case
    actions.request_state(action),
    actions.input_responses(action),
    base
  {
    None, None, _ -> response
    _, _, actions.ClientRequestReadResource(_) ->
      actions.ClientResultWithCache(
        response,
        actions.CacheHint(0, actions.Private),
      )
    _, _, _ -> response
  }
  Ok(response)
}

fn strip_input_cache(
  response: actions.ClientActionResult,
) -> actions.ClientActionResult {
  case response {
    actions.ClientResultWithCache(value, hint) -> {
      let value = strip_input_cache(value)
      case value {
        actions.ClientResultInputRequired(_) -> value
        _ -> actions.ClientResultWithCache(value, hint)
      }
    }
    _ -> response
  }
}

fn base_request(
  action: actions.ClientActionRequest,
) -> actions.ClientActionRequest {
  case action {
    actions.ClientRequestWithInput(request, _, _) -> base_request(request)
    _ -> action
  }
}

pub fn modern_capabilities(server: Server) -> dict.Dict(String, jsonrpc.Value) {
  let value =
    wire.result_value(
      initialization_result(server),
      jsonrpc.legacy_protocol_version,
      server.implementation,
    )
  let fields = case value {
    jsonrpc.VObject(fields) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let caps = case dict.get(fields, "capabilities") {
    Ok(jsonrpc.VObject(fields)) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let caps = dict.delete(caps, "tasks")
  let extensions = case option.is_some(advertised_capabilities(server).tasks) {
    True ->
      dict.insert(
        server.options.extensions,
        task_extension,
        jsonrpc.VObject([]),
      )
    False -> server.options.extensions
  }
  case dict.size(extensions) > 0 {
    True ->
      dict.insert(caps, "extensions", jsonrpc.VObject(dict.to_list(extensions)))
    False -> caps
  }
}

fn validate_subscription_filter(
  filter: Option(jsonrpc.Value),
) -> Result(Nil, jsonrpc.RpcError) {
  case filter {
    Some(jsonrpc.VObject(fields)) ->
      list.try_each(fields, fn(pair) {
        case pair {
          #("toolsListChanged", jsonrpc.VBool(_))
          | #("promptsListChanged", jsonrpc.VBool(_))
          | #("resourcesListChanged", jsonrpc.VBool(_)) -> Ok(Nil)
          #("resourceSubscriptions", jsonrpc.VArray(values))
          | #("taskIds", jsonrpc.VArray(values)) ->
            list.try_each(values, fn(value) {
              case value {
                jsonrpc.VString(_) -> Ok(Nil)
                _ ->
                  Error(jsonrpc.invalid_params_error(
                    "Subscription identifiers must be strings",
                  ))
              }
            })
          #("toolsListChanged", _)
          | #("promptsListChanged", _)
          | #("resourcesListChanged", _)
          | #("resourceSubscriptions", _)
          | #("taskIds", _) ->
            Error(jsonrpc.invalid_params_error("Invalid subscription filter"))
          _ -> Ok(Nil)
        }
      })
    _ ->
      Error(jsonrpc.invalid_params_error(
        "subscriptions/listen requires notifications object",
      ))
  }
}

/// Register a modern notification stream. The acknowledgment is the first
/// delivered event, and only effective, explicitly requested filters are used.
pub fn listen_subscription(
  server: Server,
  context: RequestContext,
  params: actions.SubscriptionsListenParams,
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(validate_modern_request(
    server,
    context,
    actions.ClientRequestSubscriptionsListen(params),
  ))
  let assert ModernRequestContext(
    transport_scope: scope,
    request_id: id,
    notifications: sink,
    ..,
  ) = context
  use _ <- result.try(case runtime.active(server.runtime, Some(scope), id) {
    True ->
      Error(jsonrpc.RpcError(-32_600, "Duplicate active request id", None))
    False -> Ok(Nil)
  })
  use sink <- result.try(
    sink
    |> option.to_result(jsonrpc.invalid_params_error(
      "Subscriptions require a streaming transport",
    )),
  )
  let requested = case params.notifications {
    Some(jsonrpc.VObject(fields)) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let caps = advertised_capabilities(server)
  let effective =
    dict.filter(requested, fn(key, value) {
      case key, value {
        "toolsListChanged", jsonrpc.VBool(True) ->
          caps.tools
          |> option.map(fn(cap) { cap.list_changed == Some(True) })
          |> option.unwrap(False)
        "promptsListChanged", jsonrpc.VBool(True) ->
          caps.prompts
          |> option.map(fn(cap) { cap.list_changed == Some(True) })
          |> option.unwrap(False)
        "resourcesListChanged", jsonrpc.VBool(True) ->
          caps.resources
          |> option.map(fn(cap) { cap.list_changed == Some(True) })
          |> option.unwrap(False)
        "resourceSubscriptions", jsonrpc.VArray(_) ->
          caps.resources
          |> option.map(fn(cap) { cap.subscribe == Some(True) })
          |> option.unwrap(False)
        "taskIds", jsonrpc.VArray(_) ->
          has_task_extension(context) && server_supports_tasks(server)
        _, _ -> False
      }
    })
  // Do not agree to notifications for another authenticated caller's task.
  let effective = case dict.get(effective, "taskIds") {
    Ok(jsonrpc.VArray(ids)) ->
      dict.insert(
        effective,
        "taskIds",
        jsonrpc.VArray(
          list.filter(ids, fn(value) {
            case value {
              jsonrpc.VString(id) ->
                task_store.get_scoped(
                  server.task_store,
                  id,
                  context_task_scope(server, context),
                )
                |> result.is_ok
              _ -> False
            }
          }),
        ),
      )
    _ -> effective
  }
  let correlate = fn(notification) { correlate_subscription(notification, id) }
  let ack =
    jsonrpc.Notification(
      "notifications/subscriptions/acknowledged",
      Some(actions.NotifySubscriptionsAcknowledgedWithFilter(
        Some(jsonrpc.VObject(dict.to_list(effective))),
        None,
      )),
    )
  let closing =
    wire.encode_response(
      jsonrpc.ResultResponse(
        id,
        actions.ClientResultSubscriptionsListen(
          actions.SubscriptionsListenResult(
            Some(
              actions.Meta(
                dict.from_list([
                  #(
                    "io.modelcontextprotocol/subscriptionId",
                    request_id_value(id),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
      jsonrpc.latest_protocol_version,
      server.implementation,
    )
  runtime.listen_request(
    server.subscriptions,
    scope,
    id,
    sink,
    fn(notification) { subscription_accepts(effective, notification) },
    correlate,
    ack,
    closing,
  )
}

/// Emit an application change only to modern subscriptions that opted in.
pub fn publish_notification(
  server: Server,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Nil {
  runtime.publish(server.subscriptions, notification)
}

fn subscription_accepts(
  filter: dict.Dict(String, jsonrpc.Value),
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Bool {
  case notification {
    jsonrpc.Notification(_, Some(actions.NotifyToolListChanged(_))) ->
      dict.get(filter, "toolsListChanged") == Ok(jsonrpc.VBool(True))
    jsonrpc.Notification(_, Some(actions.NotifyPromptListChanged(_))) ->
      dict.get(filter, "promptsListChanged") == Ok(jsonrpc.VBool(True))
    jsonrpc.Notification(_, Some(actions.NotifyResourceListChanged(_))) ->
      dict.get(filter, "resourcesListChanged") == Ok(jsonrpc.VBool(True))
    jsonrpc.Notification(_, Some(actions.NotifyResourceUpdated(params))) ->
      case dict.get(filter, "resourceSubscriptions") {
        Ok(jsonrpc.VArray(uris)) ->
          list.contains(uris, jsonrpc.VString(params.uri))
        _ -> False
      }
    jsonrpc.Notification(
      _,
      Some(actions.NotifyTaskModern(jsonrpc.VObject(fields), _)),
    ) -> {
      case
        dict.get(filter, "taskIds"),
        dict.get(dict.from_list(fields), "taskId")
      {
        Ok(jsonrpc.VArray(ids)), Ok(id) -> list.contains(ids, id)
        _, _ -> False
      }
    }
    _ -> False
  }
}

fn request_id_value(id: jsonrpc.RequestId) -> jsonrpc.Value {
  case id {
    jsonrpc.IntId(id) -> jsonrpc.VInt(id)
    jsonrpc.StringId(id) -> jsonrpc.VString(id)
  }
}

fn subscription_meta(
  meta: Option(actions.NotificationMeta),
  id: jsonrpc.RequestId,
) -> Option(actions.NotificationMeta) {
  let fields = case meta |> option.then(fn(meta) { meta.extra }) {
    Some(meta) -> meta.fields
    None -> dict.new()
  }
  Some(
    actions.NotificationMeta(
      Some(
        actions.Meta(dict.insert(
          fields,
          "io.modelcontextprotocol/subscriptionId",
          request_id_value(id),
        )),
      ),
    ),
  )
}

fn correlate_subscription(
  notification: jsonrpc.Request(actions.ActionNotification),
  id: jsonrpc.RequestId,
) -> jsonrpc.Request(actions.ActionNotification) {
  case notification {
    jsonrpc.Notification(method, Some(action)) -> {
      let action = case action {
        actions.NotifyToolListChanged(meta) ->
          actions.NotifyToolListChanged(subscription_meta(meta, id))
        actions.NotifyPromptListChanged(meta) ->
          actions.NotifyPromptListChanged(subscription_meta(meta, id))
        actions.NotifyResourceListChanged(meta) ->
          actions.NotifyResourceListChanged(subscription_meta(meta, id))
        actions.NotifyResourceUpdated(params) ->
          actions.NotifyResourceUpdated(
            actions.ResourceUpdatedNotificationParams(
              ..params,
              meta: subscription_meta(params.meta, id),
            ),
          )
        actions.NotifySubscriptionsAcknowledged(meta) ->
          actions.NotifySubscriptionsAcknowledged(subscription_meta(meta, id))
        actions.NotifySubscriptionsAcknowledgedWithFilter(filter, meta) ->
          actions.NotifySubscriptionsAcknowledgedWithFilter(
            filter,
            subscription_meta(meta, id),
          )
        actions.NotifyTaskModern(value, meta) ->
          actions.NotifyTaskModern(value, subscription_meta(meta, id))
        _ -> action
      }
      jsonrpc.Notification(method, Some(action))
    }
    _ -> notification
  }
}

fn discovery_result(server: Server) -> actions.ClientActionResult {
  actions.ClientResultDiscover(actions.DiscoverResult(
    [jsonrpc.latest_protocol_version, jsonrpc.legacy_protocol_version],
    modern_capabilities(server),
    server.instructions,
    None,
  ))
}

fn has_task_extension(context: RequestContext) -> Bool {
  case client_capability_value(context, "extensions") {
    Some(jsonrpc.VObject(fields)) ->
      case dict.get(dict.from_list(fields), task_extension) {
        Ok(jsonrpc.VObject(_)) -> True
        _ -> False
      }
    _ -> False
  }
}

fn server_supports_tasks(server: Server) -> Bool {
  option.is_some(advertised_capabilities(server).tasks)
  || case dict.get(server.options.extensions, task_extension) {
    Ok(jsonrpc.VObject(_)) -> True
    _ -> False
  }
}

fn require_task_extension(
  server: Server,
  context: RequestContext,
) -> Result(Nil, jsonrpc.RpcError) {
  case server_supports_tasks(server), has_task_extension(context) {
    False, _ ->
      Error(jsonrpc.method_not_found_error("Tasks extension is not supported"))
    True, False ->
      Error(missing_capability(
        "extensions",
        jsonrpc.VObject([#(task_extension, jsonrpc.VObject([]))]),
      ))
    True, True -> Ok(Nil)
  }
}

fn missing_capability(
  name: String,
  capability: jsonrpc.Value,
) -> jsonrpc.RpcError {
  jsonrpc.RpcError(
    -32_021,
    "Required client capability is missing",
    Some(
      jsonrpc.VObject([
        #("requiredCapabilities", jsonrpc.VObject([#(name, capability)])),
      ]),
    ),
  )
}

fn validate_modern_result(
  server: Server,
  context: RequestContext,
  action: actions.ClientActionRequest,
  response: actions.ClientActionResult,
) -> Result(Nil, jsonrpc.RpcError) {
  case response {
    actions.ClientResultWithCache(value, _) ->
      validate_modern_result(server, context, action, value)
    actions.ClientResultTaskModern(jsonrpc.VObject(fields)) -> {
      case dict.get(dict.from_list(fields), "resultType") {
        Ok(jsonrpc.VString("task")) -> {
          use _ <- result.try(case action {
            actions.ClientRequestCallTool(_) -> Ok(Nil)
            _ ->
              Error(jsonrpc.invalid_params_error(
                "Only tools/call supports task augmentation",
              ))
          })
          require_task_extension(server, context)
        }
        _ -> Ok(Nil)
      }
    }
    actions.ClientResultInputRequired(params) -> {
      use _ <- result.try(case action {
        actions.ClientRequestCallTool(_)
        | actions.ClientRequestReadResource(_)
        | actions.ClientRequestGetPrompt(_) -> Ok(Nil)
        _ ->
          Error(jsonrpc.invalid_params_error(
            "MRTR is only supported for tools/call, resources/read and prompts/get",
          ))
      })
      use _ <- result.try(case params.input_requests, params.request_state {
        None, None ->
          Error(jsonrpc.invalid_params_error(
            "input_required needs inputRequests or requestState",
          ))
        _, _ -> Ok(Nil)
      })
      list.try_each(
        params.input_requests |> option.unwrap(dict.new()) |> dict.values,
        fn(request) { validate_input_request(context, request) },
      )
    }
    _ -> Ok(Nil)
  }
}

fn validate_input_request(
  context: RequestContext,
  request: jsonrpc.Value,
) -> Result(Nil, jsonrpc.RpcError) {
  let fields = case request {
    jsonrpc.VObject(fields) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let params = case dict.get(fields, "params") {
    Ok(jsonrpc.VObject(fields)) -> dict.from_list(fields)
    _ -> dict.new()
  }
  case dict.get(fields, "method") {
    Ok(jsonrpc.VString("roots/list")) ->
      require_input_capability(context, "roots", None)
    Ok(jsonrpc.VString("sampling/createMessage")) -> {
      use _ <- result.try(require_input_capability(context, "sampling", None))
      use _ <- result.try(case dict.get(params, "includeContext") {
        Ok(jsonrpc.VString("thisServer")) | Ok(jsonrpc.VString("allServers")) ->
          require_input_capability(context, "sampling", Some("context"))
        _ -> Ok(Nil)
      })
      let tools =
        value_uses_tools(jsonrpc.VObject(dict.to_list(params)))
        || case dict.get(params, "tools"), dict.get(params, "toolChoice") {
          Ok(jsonrpc.VArray([])), Error(_) | Error(_), Error(_) -> False
          _, _ -> True
        }
      case tools {
        True -> require_input_capability(context, "sampling", Some("tools"))
        False -> Ok(Nil)
      }
    }
    Ok(jsonrpc.VString("elicitation/create")) -> {
      let mode = case dict.get(params, "mode") {
        Ok(jsonrpc.VString("url")) -> "url"
        _ -> "form"
      }
      require_input_capability(context, "elicitation", Some(mode))
    }
    _ ->
      Error(jsonrpc.invalid_params_error(
        "Unsupported MRTR input request method",
      ))
  }
}

fn value_uses_tools(value: jsonrpc.Value) -> Bool {
  case value {
    jsonrpc.VArray(values) -> list.any(values, value_uses_tools)
    jsonrpc.VObject(fields) -> {
      let kind = dict.get(dict.from_list(fields), "type")
      kind == Ok(jsonrpc.VString("tool_use"))
      || kind == Ok(jsonrpc.VString("tool_result"))
      || list.any(fields, fn(field) { value_uses_tools(field.1) })
    }
    _ -> False
  }
}

fn require_input_capability(
  context: RequestContext,
  name: String,
  sub: Option(String),
) -> Result(Nil, jsonrpc.RpcError) {
  let present = case client_capability_value(context, name), sub {
    Some(jsonrpc.VObject(_)), None -> True
    Some(jsonrpc.VObject(fields)), Some(key) ->
      case dict.get(dict.from_list(fields), key) {
        Ok(jsonrpc.VObject(_)) -> True
        _ -> name == "elicitation" && key == "form" && fields == []
      }
    _, _ -> False
  }
  case present {
    True -> Ok(Nil)
    False ->
      Error(
        missing_capability(name, case sub {
          Some(key) -> jsonrpc.VObject([#(key, jsonrpc.VObject([]))])
          None -> jsonrpc.VObject([])
        }),
      )
  }
}

fn modern_call_tool(
  server: Server,
  context: RequestContext,
  params: actions.CallToolRequestParams,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  use registered <- result.try(
    find_tool(server.tools, params.name)
    |> result.map_error(fn(_) {
      jsonrpc.invalid_params_error("Unknown tool: " <> params.name)
    }),
  )
  let execute = fn() {
    run_tool_handler(server, registered.handler, context, params.arguments)
    |> result.map(actions.ClientResultCallTool)
  }
  case
    has_task_extension(context),
    server_supports_tasks(server),
    tool_task_support(registered.tool)
  {
    True, True, Some(actions.TaskOptional)
    | True, True, Some(actions.TaskRequired)
    ->
      create_modern_task(server, context, Some(task_store.maximum_ttl_ms), fn() {
        run_tool_handler(
          server,
          registered.handler,
          modern_task_context(context),
          params.arguments,
        )
        |> result.map(actions.ClientResultCallTool)
        |> result.map(fn(value) {
          task_store.ModernComplete(wire.result_value(
            value,
            jsonrpc.latest_protocol_version,
            server.implementation,
          ))
        })
      })
    _, _, _ -> execute()
  }
}

/// An asynchronous task has no request progress or log stream. Use this context
/// for application task callbacks that retain the initiating caller identity.
pub fn modern_task_context(context: RequestContext) -> RequestContext {
  case context {
    ModernRequestContext(..) -> {
      let meta =
        request_meta(context)
        |> option.map(fn(meta) {
          actions.RequestMeta(
            None,
            meta.extra
              |> option.map(fn(extra) {
                actions.Meta(dict.delete(
                  extra.fields,
                  "io.modelcontextprotocol/logLevel",
                ))
              }),
          )
        })
      ModernRequestContext(..context, notifications: None, meta: meta)
    }
    _ -> context
  }
}

/// Create an optional Tasks extension handle. The task worker is cancelled and
/// retained by the task store independently of the request's transport.
pub fn create_modern_task(
  server: Server,
  context: RequestContext,
  ttl_ms: Option(Int),
  worker: fn() -> Result(task_store.ModernOutcome, jsonrpc.RpcError),
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  use _ <- result.try(require_task_extension(server, context))
  let task =
    task_store.create_scoped(
      server.task_store,
      ttl_ms,
      context_task_scope(server, context),
    )
  use _ <- result.try(
    task_store.start_modern_worker(server.task_store, task.task_id, fn() {
      worker() |> result.try(validate_task_inputs(context, _))
    }),
  )
  Ok(
    actions.ClientResultTaskModern(
      jsonrpc.VObject([
        #("resultType", jsonrpc.VString("task")),
        ..task_fields(task)
      ]),
    ),
  )
}

fn validate_task_inputs(
  context: RequestContext,
  outcome: task_store.ModernOutcome,
) -> Result(task_store.ModernOutcome, jsonrpc.RpcError) {
  case outcome {
    task_store.ModernComplete(_) -> Ok(outcome)
    task_store.ModernInputRequired(inputs, resume) -> {
      use _ <- result.try(
        list.try_each(dict.values(inputs), validate_input_request(context, _)),
      )
      Ok(
        task_store.ModernInputRequired(inputs, fn(responses) {
          resume(responses) |> result.try(validate_task_inputs(context, _))
        }),
      )
    }
  }
}

fn task_fields(task: actions.Task) -> List(#(String, jsonrpc.Value)) {
  [
    #("taskId", jsonrpc.VString(task.task_id)),
    #(
      "status",
      jsonrpc.VString(case task.status {
        actions.Working -> "working"
        actions.InputRequired -> "input_required"
        actions.Completed -> "completed"
        actions.Failed -> "failed"
        actions.Cancelled -> "cancelled"
      }),
    ),
    #("createdAt", jsonrpc.VString(task.created_at)),
    #("lastUpdatedAt", jsonrpc.VString(task.last_updated_at)),
    #("ttlMs", case task.ttl_ms {
      Some(ttl) -> jsonrpc.VInt(ttl)
      None -> jsonrpc.VNull
    }),
    #(
      "pollIntervalMs",
      jsonrpc.VInt(task.poll_interval_ms |> option.unwrap(5000)),
    ),
    ..case task.status_message {
      Some(message) -> [#("statusMessage", jsonrpc.VString(message))]
      None -> []
    }
  ]
}

fn modern_task_result(
  server: Server,
  context: RequestContext,
  id: String,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  use snapshot <- result.try(task_store.snapshot_scoped(
    server.task_store,
    id,
    context_task_scope(server, context),
  ))
  let task = case snapshot.task.status, snapshot.outcome {
    actions.Failed, Some(Ok(_)) ->
      actions.Task(..snapshot.task, status: actions.Completed)
    _, _ -> snapshot.task
  }
  let extra = case task.status, snapshot.outcome {
    actions.InputRequired, _ -> [
      #("inputRequests", jsonrpc.VObject(dict.to_list(snapshot.inputs))),
    ]
    actions.Completed, Some(Ok(payload)) -> [
      #("result", task_payload_value(server, payload)),
    ]
    actions.Failed, Some(Error(error)) -> [
      #(
        "error",
        jsonrpc.VObject([
          #("code", jsonrpc.VInt(error.code)),
          #("message", jsonrpc.VString(error.message)),
          ..case error.data {
            Some(data) -> [#("data", data)]
            None -> []
          }
        ]),
      ),
    ]
    _, _ -> []
  }
  Ok(
    actions.ClientResultTaskModern(
      jsonrpc.VObject([
        #("resultType", jsonrpc.VString("complete")),
        ..list.append(task_fields(task), extra)
      ]),
    ),
  )
}

fn task_payload_value(
  server: Server,
  payload: actions.TaskResult,
) -> jsonrpc.Value {
  case payload {
    actions.TaskResultModern(value) -> value
    actions.TaskCallTool(result) ->
      wire.result_value(
        actions.ClientResultCallTool(result),
        jsonrpc.latest_protocol_version,
        server.implementation,
      )
    actions.TaskCreateMessage(_) | actions.TaskElicit(_) -> jsonrpc.VObject([])
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
            Some(id) -> cancel_incoming_request(server, context, id)
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
  runtime.close_subscription_scope(server.subscriptions, session_id)
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
          protocol_version: jsonrpc.legacy_protocol_version,
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
  case context {
    ModernRequestContext(principal: principal, ..) -> {
      // Modern tasks are durable handles and do not belong to a transport
      // session. Authenticated callers retain access across connections.
      principal |> option.map(fn(value) { "principal:" <> value })
    }
    _ -> legacy_context_task_scope(server, context)
  }
}

fn legacy_context_task_scope(
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
  use _ <- result.try(case is_modern_context(context) {
    True ->
      Error(jsonrpc.invalid_params_error(
        "Modern requests require MRTR input requests instead of server-initiated JSON-RPC requests",
      ))
    False -> Ok(Nil)
  })
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
  case context {
    ModernRequestContext(..) ->
      send_modern_notification(server, context, notification)
    _ -> send_legacy_notification(server, context, notification)
  }
}

fn send_legacy_notification(
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

fn send_modern_notification(
  server: Server,
  context: RequestContext,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> Result(Nil, jsonrpc.RpcError) {
  let assert ModernRequestContext(
    notifications: sink,
    request_id: id,
    worker: worker,
    ..,
  ) = context
  let allowed = case notification {
    jsonrpc.Notification(_, Some(actions.NotifyProgress(params))) ->
      progress_token(context) == Some(params.progress_token)
    jsonrpc.Notification(_, Some(actions.NotifyLoggingMessage(params))) -> {
      let requested = case
        request_meta_value(
          request_meta(context),
          "io.modelcontextprotocol/logLevel",
        )
      {
        Some(jsonrpc.VString(level)) -> log_rank(level)
        _ -> None
      }
      case requested {
        None -> False
        Some(minimum) ->
          logging_rank(params.level) >= minimum
          && option.is_some(advertised_capabilities(server).logging)
      }
    }
    _ -> False
  }
  let allowed =
    allowed
    && case worker {
      Some(worker) ->
        runtime.active_worker(
          server.runtime,
          runtime_scope(context),
          id,
          worker,
        )
      None -> False
    }
  case allowed, sink {
    True, Some(subject) -> {
      process.send(
        subject,
        streamable_http_store.DeliverNotification(notification),
      )
      Ok(Nil)
    }
    _, _ -> Ok(Nil)
  }
}

fn logging_rank(level: actions.LoggingLevel) -> Int {
  case level {
    actions.Debug -> 0
    actions.Info -> 1
    actions.Notice -> 2
    actions.Warning -> 3
    actions.Error -> 4
    actions.Critical -> 5
    actions.Alert -> 6
    actions.Emergency -> 7
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
            actions.ElicitRequestUrl(params) -> actions.elicit_url_task(params)
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
        _ -> action
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
        actions.ServerRequestElicit(actions.ElicitRequestUrl(params)) -> {
          let meta = associate_meta(actions.elicit_url_meta(params), task)
          let params = case params {
            actions.ElicitRequestUrlParams(..) ->
              actions.ElicitRequestUrlParams(..params, meta: meta)
            actions.ElicitRequestUrlParamsWithoutId(..) ->
              actions.ElicitRequestUrlParamsWithoutId(..params, meta: meta)
          }
          actions.ServerRequestElicit(actions.ElicitRequestUrl(params))
        }
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
  publish_notification(
    server,
    jsonrpc.Notification(
      mcp.method_notify_resource_updated,
      Some(
        actions.NotifyResourceUpdated(actions.ResourceUpdatedNotificationParams(
          uri,
          None,
        )),
      ),
    ),
  )
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
    actions.TaskResultModern(_) -> task_result
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
    actions.ClientRequestWithInput(request, _, _) ->
      dispatch_request(server, context, request)
    actions.ClientRequestDiscover(_)
    | actions.ClientRequestSubscriptionsListen(_)
    | actions.ClientRequestUpdateTask(_) ->
      Error(jsonrpc.method_not_found_error(
        "Modern protocol method requires per-request metadata",
      ))
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
              jsonrpc.legacy_protocol_version,
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
    protocol_version: jsonrpc.legacy_protocol_version,
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

pub fn action_meta(
  action: actions.ClientActionRequest,
) -> Option(actions.RequestMeta) {
  actions.request_meta(action)
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
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })

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
    ModernRequestContext(..) ->
      ModernRequestContext(..context, task_id: Some(created.task_id))
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
  let task = case is_modern_context(context), context.session_id {
    False, None -> task_store.get(server.task_store, params.task_id)
    _, _ ->
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
  let task_id = actions.task_id(params)
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
