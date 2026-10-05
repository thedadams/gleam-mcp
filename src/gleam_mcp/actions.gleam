import gleam/dict.{type Dict}
import gleam/option.{type Option, None}
import gleam_mcp/jsonrpc.{type RequestId, type Value}

pub type Meta {
  Meta(fields: Dict(String, Value))
}

pub type RelatedTask {
  RelatedTask(task_id: String)
}

pub type RequestMeta {
  RequestMeta(progress_token: Option(RequestId), extra: Option(Meta))
}

pub type NotificationMeta {
  NotificationMeta(extra: Option(Meta))
}

pub type Cursor {
  Cursor(value: String)
}

pub type TaskMetadata {
  TaskMetadata(ttl_ms: Option(Int))
}

pub type Page {
  Page(next_cursor: Option(Cursor))
}

pub type Role {
  User
  Assistant
}

pub type LoggingLevel {
  Debug
  Info
  Notice
  Warning
  Error
  Critical
  Alert
  Emergency
}

pub type ClientActionRequest {
  ClientRequestDiscover(Option(RequestMeta))
  ClientRequestSubscriptionsListen(SubscriptionsListenParams)
  ClientRequestWithInput(
    request: ClientActionRequest,
    request_state: Option(String),
    input_responses: Option(Dict(String, Value)),
  )
  ClientRequestUpdateTask(TaskUpdateParams)
  ClientRequestInitialize(InitializeRequestParams)
  ClientRequestPing(Option(RequestMeta))
  ClientRequestListResources(PaginatedRequestParams)
  ClientRequestListResourceTemplates(PaginatedRequestParams)
  ClientRequestReadResource(ReadResourceRequestParams)
  ClientRequestSubscribeResource(SubscribeRequestParams)
  ClientRequestUnsubscribeResource(UnsubscribeRequestParams)
  ClientRequestListPrompts(PaginatedRequestParams)
  ClientRequestGetPrompt(GetPromptRequestParams)
  ClientRequestListTools(PaginatedRequestParams)
  ClientRequestCallTool(CallToolRequestParams)
  ClientRequestComplete(CompleteRequestParams)
  ClientRequestSetLoggingLevel(SetLevelRequestParams)
  ClientRequestListTasks(PaginatedRequestParams)
  ClientRequestGetTask(TaskIdParams)
  ClientRequestGetTaskResult(TaskIdParams)
  ClientRequestCancelTask(TaskIdParams)
}

pub type ServerActionRequest {
  ServerRequestPing(Option(RequestMeta))
  ServerRequestListRoots(Option(RequestMeta))
  ServerRequestCreateMessage(CreateMessageRequestParams)
  ServerRequestElicit(ElicitRequestParams)
  ServerRequestListTasks(PaginatedRequestParams)
  ServerRequestGetTask(TaskIdParams)
  ServerRequestGetTaskResult(TaskIdParams)
  ServerRequestCancelTask(TaskIdParams)
}

pub type ClientActionResult {
  ClientResultWithCache(result: ClientActionResult, hint: CacheHint)
  ClientResultDiscover(DiscoverResult)
  ClientResultSubscriptionsListen(SubscriptionsListenResult)
  ClientResultInputRequired(InputRequiredResult)
  ClientResultTaskModern(Value)
  ClientResultEmpty(Option(Meta))
  ClientResultInitialize(InitializeResult)
  ClientResultListResources(ListResourcesResult)
  ClientResultListResourceTemplates(ListResourceTemplatesResult)
  ClientResultReadResource(ReadResourceResult)
  ClientResultListPrompts(ListPromptsResult)
  ClientResultGetPrompt(GetPromptResult)
  ClientResultListTools(ListToolsResult)
  ClientResultCallTool(CallToolResult)
  ClientResultComplete(CompleteResult)
  ClientResultCreateTask(CreateTaskResult)
  ClientResultGetTask(GetTaskResult)
  ClientResultTaskResult(TaskResult)
  ClientResultCancelTask(CancelTaskResult)
  ClientResultListTasks(ListTasksResult)
}

pub type ServerActionResult {
  ServerResultEmpty(Option(Meta))
  ServerResultListRoots(ListRootsResult)
  ServerResultCreateMessage(CreateMessageResult)
  ServerResultElicit(ElicitResult)
  ServerResultCreateTask(CreateTaskResult)
  ServerResultGetTask(GetTaskResult)
  ServerResultTaskResult(TaskResult)
  ServerResultCancelTask(CancelTaskResult)
  ServerResultListTasks(ListTasksResult)
}

pub type ActionNotification {
  NotifyTaskModern(value: Value, meta: Option(NotificationMeta))
  NotifySubscriptionsAcknowledged(Option(NotificationMeta))
  NotifySubscriptionsAcknowledgedWithFilter(
    notifications: Option(Value),
    meta: Option(NotificationMeta),
  )
  NotifyInitialized(Option(NotificationMeta))
  NotifyCancelled(CancelledNotificationParams)
  NotifyProgress(ProgressNotificationParams)
  NotifyResourceListChanged(Option(NotificationMeta))
  NotifyResourceUpdated(ResourceUpdatedNotificationParams)
  NotifyPromptListChanged(Option(NotificationMeta))
  NotifyToolListChanged(Option(NotificationMeta))
  NotifyLoggingMessage(LoggingMessageNotificationParams)
  NotifyRootsListChanged(Option(NotificationMeta))
  NotifyElicitationComplete(ElicitationCompleteNotificationParams)
  NotifyTaskStatus(TaskStatusNotificationParams)
}

/// The modern discovery result. Capabilities retain their complete JSON shape,
/// including extension capabilities unknown to this SDK.
pub type DiscoverResult {
  DiscoverResult(
    supported_versions: List(String),
    capabilities: Dict(String, Value),
    instructions: Option(String),
    meta: Option(Meta),
  )
}

pub type CacheScope {
  Public
  Private
}

pub type CacheHint {
  CacheHint(ttl_ms: Int, scope: CacheScope)
}

pub type SubscriptionsListenParams {
  SubscriptionsListenParams(
    notifications: Option(Value),
    meta: Option(RequestMeta),
  )
}

pub type SubscriptionsListenResult {
  SubscriptionsListenResult(meta: Option(Meta))
}

/// At least one of input_requests and request_state must be present. A state
/// alone represents a continuation that needs no client input.
pub type InputRequiredResult {
  InputRequiredResult(
    input_requests: Option(Dict(String, Value)),
    request_state: Option(String),
    meta: Option(Meta),
  )
}

pub type InitializeRequestParams {
  InitializeRequestParams(
    protocol_version: String,
    capabilities: ClientCapabilities,
    client_info: Implementation,
    meta: Option(RequestMeta),
  )
}

pub type InitializeResult {
  InitializeResult(
    protocol_version: String,
    capabilities: ServerCapabilities,
    server_info: Implementation,
    instructions: Option(String),
    meta: Option(Meta),
  )
}

pub type ClientCapabilities {
  ClientCapabilities(
    experimental: Option(Dict(String, Value)),
    roots: Option(ClientRootsCapabilities),
    sampling: Option(ClientSamplingCapabilities),
    elicitation: Option(ClientElicitationCapabilities),
    tasks: Option(ClientTasksCapabilities),
  )
}

pub type ClientRootsCapabilities {
  ClientRootsCapabilities(list_changed: Option(Bool))
}

pub type ClientSamplingCapabilities {
  ClientSamplingCapabilities(context: Option(Value), tools: Option(Value))
}

pub type ClientElicitationCapabilities {
  ClientElicitationCapabilities(form: Option(Value), url: Option(Value))
}

pub type ClientTasksCapabilities {
  ClientTasksCapabilities(
    list: Option(Value),
    cancel: Option(Value),
    requests: Option(ClientTaskRequestCapabilities),
  )
}

pub type ClientTaskRequestCapabilities {
  ClientTaskRequestCapabilities(
    sampling_create_message: Option(Value),
    elicitation_create: Option(Value),
  )
}

pub type ServerCapabilities {
  ServerCapabilities(
    experimental: Option(Dict(String, Value)),
    logging: Option(Value),
    completions: Option(Value),
    prompts: Option(ServerPromptsCapabilities),
    resources: Option(ServerResourcesCapabilities),
    tools: Option(ServerToolsCapabilities),
    tasks: Option(ServerTasksCapabilities),
  )
}

pub type ServerPromptsCapabilities {
  ServerPromptsCapabilities(list_changed: Option(Bool))
}

pub type ServerResourcesCapabilities {
  ServerResourcesCapabilities(
    subscribe: Option(Bool),
    list_changed: Option(Bool),
  )
}

pub type ServerToolsCapabilities {
  ServerToolsCapabilities(list_changed: Option(Bool))
}

pub type ServerTasksCapabilities {
  ServerTasksCapabilities(
    list: Option(Value),
    cancel: Option(Value),
    requests: Option(ServerTaskRequestCapabilities),
  )
}

pub type ServerTaskRequestCapabilities {
  ServerTaskRequestCapabilities(tools_call: Option(Value))
}

pub type Implementation {
  Implementation(
    name: String,
    version: String,
    title: Option(String),
    description: Option(String),
    website_url: Option(String),
    icons: List(Icon),
  )
}

pub type Icon {
  Icon(
    src: String,
    mime_type: Option(String),
    sizes: List(String),
    theme: Option(IconTheme),
  )
}

pub type IconTheme {
  LightTheme
  DarkTheme
}

pub type CancelledNotificationParams {
  CancelledNotificationParams(
    request_id: Option(RequestId),
    reason: Option(String),
    meta: Option(NotificationMeta),
  )
}

pub type ProgressNotificationParams {
  ProgressNotificationParams(
    progress_token: RequestId,
    progress: Float,
    total: Option(Float),
    message: Option(String),
    meta: Option(NotificationMeta),
  )
}

pub type PaginatedRequestParams {
  PaginatedRequestParams(cursor: Option(Cursor), meta: Option(RequestMeta))
}

pub type ResourceRequestBase {
  ResourceRequestBase(uri: String, meta: Option(RequestMeta))
}

pub type ReadResourceRequestParams {
  ReadResourceRequestParams(uri: String, meta: Option(RequestMeta))
}

pub type SubscribeRequestParams {
  SubscribeRequestParams(uri: String, meta: Option(RequestMeta))
}

pub type UnsubscribeRequestParams {
  UnsubscribeRequestParams(uri: String, meta: Option(RequestMeta))
}

pub type ListResourcesResult {
  ListResourcesResult(resources: List(Resource), page: Page, meta: Option(Meta))
}

pub type ListResourceTemplatesResult {
  ListResourceTemplatesResult(
    resource_templates: List(ResourceTemplate),
    page: Page,
    meta: Option(Meta),
  )
}

pub type Resource {
  Resource(
    uri: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    annotations: Option(Annotations),
    size: Option(Int),
    icons: List(Icon),
    meta: Option(Meta),
  )
}

pub type ResourceTemplate {
  ResourceTemplate(
    uri_template: String,
    name: String,
    title: Option(String),
    description: Option(String),
    mime_type: Option(String),
    annotations: Option(Annotations),
    icons: List(Icon),
    meta: Option(Meta),
  )
}

pub type ReadResourceResult {
  ReadResourceResult(contents: List(ResourceContents), meta: Option(Meta))
}

pub type ResourceContents {
  TextResourceContents(
    uri: String,
    mime_type: Option(String),
    text: String,
    meta: Option(Meta),
  )
  BlobResourceContents(
    uri: String,
    mime_type: Option(String),
    blob: String,
    meta: Option(Meta),
  )
}

pub type ResourceUpdatedNotificationParams {
  ResourceUpdatedNotificationParams(uri: String, meta: Option(NotificationMeta))
}

pub type ListPromptsResult {
  ListPromptsResult(prompts: List(Prompt), page: Page, meta: Option(Meta))
}

pub type Prompt {
  Prompt(
    name: String,
    title: Option(String),
    description: Option(String),
    arguments: List(PromptArgument),
    icons: List(Icon),
    meta: Option(Meta),
  )
}

pub type PromptArgument {
  PromptArgument(
    name: String,
    title: Option(String),
    description: Option(String),
    required: Option(Bool),
  )
}

pub type GetPromptRequestParams {
  GetPromptRequestParams(
    name: String,
    arguments: Option(Dict(String, String)),
    meta: Option(RequestMeta),
  )
}

pub type GetPromptResult {
  GetPromptResult(
    description: Option(String),
    messages: List(PromptMessage),
    meta: Option(Meta),
  )
}

pub type PromptMessage {
  PromptMessage(role: Role, content: ContentBlock)
}

pub type ContentBlock {
  TextBlock(TextContent)
  ImageBlock(ImageContent)
  AudioBlock(AudioContent)
  ResourceLinkBlock(ResourceLink)
  EmbeddedResourceBlock(EmbeddedResource)
}

pub type TextContent {
  TextContent(
    text: String,
    annotations: Option(Annotations),
    meta: Option(Meta),
  )
}

pub type ImageContent {
  ImageContent(
    data: String,
    mime_type: String,
    annotations: Option(Annotations),
    meta: Option(Meta),
  )
}

pub type AudioContent {
  AudioContent(
    data: String,
    mime_type: String,
    annotations: Option(Annotations),
    meta: Option(Meta),
  )
}

pub type ResourceLink {
  ResourceLink(resource: Resource)
}

pub type EmbeddedResource {
  EmbeddedResource(
    resource: ResourceContents,
    annotations: Option(Annotations),
    meta: Option(Meta),
  )
}

pub type Annotations {
  Annotations(
    audience: List(Role),
    priority: Option(Float),
    last_modified: Option(String),
  )
}

pub type ListToolsResult {
  ListToolsResult(tools: List(Tool), page: Page, meta: Option(Meta))
}

pub type Tool {
  Tool(
    name: String,
    title: Option(String),
    description: Option(String),
    input_schema: Value,
    execution: Option(ToolExecution),
    output_schema: Option(Value),
    annotations: Option(ToolAnnotations),
    icons: List(Icon),
    meta: Option(Meta),
  )
}

pub type ToolExecution {
  ToolExecution(task_support: Option(TaskSupport))
}

pub type TaskSupport {
  TaskForbidden
  TaskOptional
  TaskRequired
}

pub type ToolAnnotations {
  ToolAnnotations(
    title: Option(String),
    read_only_hint: Option(Bool),
    destructive_hint: Option(Bool),
    idempotent_hint: Option(Bool),
    open_world_hint: Option(Bool),
  )
}

pub type CallToolRequestParams {
  CallToolRequestParams(
    name: String,
    arguments: Option(Dict(String, Value)),
    task: Option(TaskMetadata),
    meta: Option(RequestMeta),
  )
}

pub type CallToolResult {
  CallToolResult(
    content: List(ContentBlock),
    structured_content: Option(Value),
    is_error: Option(Bool),
    meta: Option(Meta),
  )
}

pub type CallToolResponse {
  CallTool(CallToolResult)
  CallToolTask(CreateTaskResult)
  CallToolTaskModern(Value)
}

pub type TaskStatus {
  Working
  InputRequired
  Completed
  Failed
  Cancelled
}

pub type Task {
  Task(
    task_id: String,
    status: TaskStatus,
    status_message: Option(String),
    created_at: String,
    last_updated_at: String,
    ttl_ms: Option(Int),
    poll_interval_ms: Option(Int),
  )
}

pub type CreateTaskResult {
  CreateTaskResult(task: Task, meta: Option(Meta))
}

pub type TaskIdParams {
  TaskIdParams(task_id: String)
  TaskIdParamsWithMeta(task_id: String, meta: Option(RequestMeta))
}

pub type TaskUpdateParams {
  TaskUpdateParams(
    task_id: String,
    input: Option(Value),
    meta: Option(RequestMeta),
  )
}

pub fn task_id(params: TaskIdParams) -> String {
  case params {
    TaskIdParams(id) | TaskIdParamsWithMeta(id, _) -> id
  }
}

pub fn task_id_meta(params: TaskIdParams) -> Option(RequestMeta) {
  case params {
    TaskIdParams(_) -> None
    TaskIdParamsWithMeta(_, meta) -> meta
  }
}

/// Return the metadata attached to the underlying request, including a
/// multi-round-trip continuation request.
pub fn request_meta(request: ClientActionRequest) -> Option(RequestMeta) {
  case request {
    ClientRequestDiscover(meta) | ClientRequestPing(meta) -> meta
    ClientRequestSubscriptionsListen(params) -> params.meta
    ClientRequestWithInput(request, _, _) -> request_meta(request)
    ClientRequestUpdateTask(params) -> params.meta
    ClientRequestInitialize(params) -> params.meta
    ClientRequestListResources(params)
    | ClientRequestListResourceTemplates(params)
    | ClientRequestListPrompts(params)
    | ClientRequestListTools(params)
    | ClientRequestListTasks(params) -> params.meta
    ClientRequestReadResource(params) -> params.meta
    ClientRequestSubscribeResource(params) -> params.meta
    ClientRequestUnsubscribeResource(params) -> params.meta
    ClientRequestGetPrompt(params) -> params.meta
    ClientRequestCallTool(params) -> params.meta
    ClientRequestComplete(params) -> params.meta
    ClientRequestSetLoggingLevel(params) -> params.meta
    ClientRequestGetTask(params)
    | ClientRequestGetTaskResult(params)
    | ClientRequestCancelTask(params) -> task_id_meta(params)
  }
}

pub fn with_request_meta(
  request: ClientActionRequest,
  meta: Option(RequestMeta),
) -> ClientActionRequest {
  case request {
    ClientRequestDiscover(_) -> ClientRequestDiscover(meta)
    ClientRequestPing(_) -> ClientRequestPing(meta)
    ClientRequestSubscriptionsListen(params) ->
      ClientRequestSubscriptionsListen(
        SubscriptionsListenParams(..params, meta:),
      )
    ClientRequestWithInput(request, state, responses) ->
      ClientRequestWithInput(with_request_meta(request, meta), state, responses)
    ClientRequestUpdateTask(params) ->
      ClientRequestUpdateTask(TaskUpdateParams(..params, meta:))
    ClientRequestInitialize(params) ->
      ClientRequestInitialize(InitializeRequestParams(..params, meta:))
    ClientRequestListResources(params) ->
      ClientRequestListResources(PaginatedRequestParams(..params, meta:))
    ClientRequestListResourceTemplates(params) ->
      ClientRequestListResourceTemplates(
        PaginatedRequestParams(..params, meta:),
      )
    ClientRequestListPrompts(params) ->
      ClientRequestListPrompts(PaginatedRequestParams(..params, meta:))
    ClientRequestListTools(params) ->
      ClientRequestListTools(PaginatedRequestParams(..params, meta:))
    ClientRequestListTasks(params) ->
      ClientRequestListTasks(PaginatedRequestParams(..params, meta:))
    ClientRequestReadResource(params) ->
      ClientRequestReadResource(ReadResourceRequestParams(..params, meta:))
    ClientRequestSubscribeResource(params) ->
      ClientRequestSubscribeResource(SubscribeRequestParams(..params, meta:))
    ClientRequestUnsubscribeResource(params) ->
      ClientRequestUnsubscribeResource(
        UnsubscribeRequestParams(..params, meta:),
      )
    ClientRequestGetPrompt(params) ->
      ClientRequestGetPrompt(GetPromptRequestParams(..params, meta:))
    ClientRequestCallTool(params) ->
      ClientRequestCallTool(CallToolRequestParams(..params, meta:))
    ClientRequestComplete(params) ->
      ClientRequestComplete(CompleteRequestParams(..params, meta:))
    ClientRequestSetLoggingLevel(params) ->
      ClientRequestSetLoggingLevel(SetLevelRequestParams(..params, meta:))
    ClientRequestGetTask(params) ->
      ClientRequestGetTask(TaskIdParamsWithMeta(task_id(params), meta))
    ClientRequestGetTaskResult(params) ->
      ClientRequestGetTaskResult(TaskIdParamsWithMeta(task_id(params), meta))
    ClientRequestCancelTask(params) ->
      ClientRequestCancelTask(TaskIdParamsWithMeta(task_id(params), meta))
  }
}

pub fn request_state(request: ClientActionRequest) -> Option(String) {
  case request {
    ClientRequestWithInput(_, state, _) -> state
    _ -> None
  }
}

pub fn input_responses(
  request: ClientActionRequest,
) -> Option(Dict(String, Value)) {
  case request {
    ClientRequestWithInput(_, _, responses) -> responses
    _ -> None
  }
}

pub fn request_without_input(
  request: ClientActionRequest,
) -> ClientActionRequest {
  case request {
    ClientRequestWithInput(inner, _, _) -> request_without_input(inner)
    _ -> request
  }
}

pub type GetTaskResult {
  GetTaskResult(task: Task, meta: Option(Meta))
}

pub type TaskResult {
  TaskResultModern(Value)
  TaskCallTool(CallToolResult)
  TaskCreateMessage(CreateMessageResult)
  TaskElicit(ElicitResult)
}

pub type CancelTaskResult {
  CancelTaskResult(task: Task, meta: Option(Meta))
}

pub type ListTasksResult {
  ListTasksResult(tasks: List(Task), page: Page, meta: Option(Meta))
}

pub type TaskStatusNotificationParams {
  TaskStatusNotificationParams(task: Task, meta: Option(NotificationMeta))
}

pub type SetLevelRequestParams {
  SetLevelRequestParams(level: LoggingLevel, meta: Option(RequestMeta))
}

pub type LoggingMessageNotificationParams {
  LoggingMessageNotificationParams(
    level: LoggingLevel,
    logger: Option(String),
    data: Value,
    meta: Option(NotificationMeta),
  )
}

pub type CreateMessageRequestParams {
  CreateMessageRequestParams(
    messages: List(SamplingMessage),
    model_preferences: Option(ModelPreferences),
    system_prompt: Option(String),
    include_context: Option(IncludeContext),
    temperature: Option(Float),
    max_tokens: Int,
    stop_sequences: List(String),
    metadata: Option(Value),
    tools: List(Tool),
    tool_choice: Option(ToolChoice),
    task: Option(TaskMetadata),
    meta: Option(RequestMeta),
  )
}

pub type CreateMessageResponse {
  CreateMessage(CreateMessageResult)
  CreateMessageTask(CreateTaskResult)
}

pub type ModelPreferences {
  ModelPreferences(
    hints: List(ModelHint),
    cost_priority: Option(Float),
    speed_priority: Option(Float),
    intelligence_priority: Option(Float),
  )
}

pub type ModelHint {
  ModelHint(name: Option(String))
}

pub type IncludeContext {
  NoContext
  ThisServerContext
  AllServersContext
}

pub type ToolChoice {
  ToolChoice(mode: Option(ToolChoiceMode))
}

pub type ToolChoiceMode {
  ToolAuto
  ToolRequired
  ToolNone
}

pub type SamplingMessage {
  SamplingMessage(role: Role, content: SamplingContent, meta: Option(Meta))
}

pub type SamplingContent {
  SingleSamplingContent(SamplingMessageContentBlock)
  MultipleSamplingContent(List(SamplingMessageContentBlock))
}

pub type SamplingMessageContentBlock {
  SamplingText(TextContent)
  SamplingImage(ImageContent)
  SamplingAudio(AudioContent)
  SamplingToolUse(ToolUseContent)
  SamplingToolResult(ToolResultContent)
}

pub type ToolUseContent {
  ToolUseContent(
    id: String,
    name: String,
    input: Dict(String, Value),
    meta: Option(Meta),
  )
}

pub type ToolResultContent {
  ToolResultContent(
    tool_use_id: String,
    content: List(ContentBlock),
    structured_content: Option(Value),
    is_error: Option(Bool),
    meta: Option(Meta),
  )
}

pub type CreateMessageResult {
  CreateMessageResult(
    message: SamplingMessage,
    model: String,
    stop_reason: Option(String),
    meta: Option(Meta),
  )
}

pub type CompleteRequestParams {
  CompleteRequestParams(
    ref: CompletionRef,
    argument: CompleteArgument,
    context: Option(CompleteContext),
    meta: Option(RequestMeta),
  )
}

pub type CompletionRef {
  PromptRef(name: String, title: Option(String))
  ResourceTemplateRef(uri: String)
}

pub type CompleteArgument {
  CompleteArgument(name: String, value: String)
}

pub type CompleteContext {
  CompleteContext(arguments: Option(Dict(String, String)))
}

pub type CompleteResult {
  CompleteResult(completion: CompletionValues, meta: Option(Meta))
}

pub type CompletionValues {
  CompletionValues(
    values: List(String),
    total: Option(Int),
    has_more: Option(Bool),
  )
}

pub type Root {
  Root(uri: String, name: Option(String), meta: Option(Meta))
}

pub type ListRootsResult {
  ListRootsResult(roots: List(Root), meta: Option(Meta))
}

pub type ElicitRequestParams {
  ElicitRequestForm(ElicitRequestFormParams)
  ElicitRequestUrl(ElicitRequestUrlParams)
}

pub type ElicitResponse {
  Elicit(ElicitResult)
  ElicitTask(CreateTaskResult)
}

pub type ElicitRequestFormParams {
  ElicitRequestFormParams(
    message: String,
    requested_schema: Value,
    task: Option(TaskMetadata),
    meta: Option(RequestMeta),
  )
}

pub type ElicitRequestUrlParams {
  ElicitRequestUrlParams(
    message: String,
    elicitation_id: String,
    url: String,
    task: Option(TaskMetadata),
    meta: Option(RequestMeta),
  )
  ElicitRequestUrlParamsWithoutId(
    message: String,
    url: String,
    task: Option(TaskMetadata),
    meta: Option(RequestMeta),
  )
}

pub fn elicit_url(params: ElicitRequestUrlParams) -> String {
  case params {
    ElicitRequestUrlParams(_, _, url, _, _)
    | ElicitRequestUrlParamsWithoutId(_, url, _, _) -> url
  }
}

pub fn elicit_url_task(params: ElicitRequestUrlParams) -> Option(TaskMetadata) {
  case params {
    ElicitRequestUrlParams(_, _, _, task, _)
    | ElicitRequestUrlParamsWithoutId(_, _, task, _) -> task
  }
}

pub fn elicit_url_meta(params: ElicitRequestUrlParams) -> Option(RequestMeta) {
  case params {
    ElicitRequestUrlParams(_, _, _, _, meta)
    | ElicitRequestUrlParamsWithoutId(_, _, _, meta) -> meta
  }
}

pub type ElicitationCompleteNotificationParams {
  ElicitationCompleteNotificationParams(elicitation_id: String)
  ElicitationCompleteNotificationParamsWithMeta(
    elicitation_id: String,
    meta: Option(NotificationMeta),
  )
}

pub fn elicitation_complete_notification_id(
  params: ElicitationCompleteNotificationParams,
) -> String {
  params.elicitation_id
}

pub fn elicitation_complete_notification_meta(
  params: ElicitationCompleteNotificationParams,
) -> Option(NotificationMeta) {
  case params {
    ElicitationCompleteNotificationParams(_) -> option.None
    ElicitationCompleteNotificationParamsWithMeta(_, meta) -> meta
  }
}

pub type ElicitResult {
  ElicitResult(
    action: ElicitAction,
    content: Option(Dict(String, ElicitValue)),
    meta: Option(Meta),
  )
}

pub type ElicitAction {
  ElicitAccept
  ElicitDecline
  ElicitCancel
}

pub type ElicitValue {
  ElicitString(String)
  ElicitInt(Int)
  ElicitFloat(Float)
  ElicitBool(Bool)
  ElicitStringArray(List(String))
}
