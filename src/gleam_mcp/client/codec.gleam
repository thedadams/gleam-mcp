import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp

pub type ServerMessage {
  ActionRequest(jsonrpc.Request(actions.ActionRequest))
  ActionNotification(jsonrpc.Request(actions.ActionNotification))
  UnknownRequest(id: jsonrpc.RequestId, method: String)
  UnknownNotification(method: String)
}

pub fn encode_request(request: jsonrpc.Request(actions.ActionRequest)) -> String {
  request
  |> encode_action_request
  |> json.to_string
}

pub fn encode_notification(
  notification: jsonrpc.Request(actions.ActionNotification),
) -> String {
  notification
  |> encode_action_notification
  |> json.to_string
}

pub fn decode_response(
  body: String,
  request: jsonrpc.Request(actions.ActionRequest),
) -> Result(jsonrpc.Response(actions.ActionResult), String) {
  json.parse(body, response_decoder(request))
  |> result.map_error(json_error_message)
}

pub fn decode_server_message(body: String) -> Result(ServerMessage, String) {
  json.parse(body, server_message_decoder())
  |> result.map_error(json_error_message)
}

fn encode_action_request(
  request: jsonrpc.Request(actions.ActionRequest),
) -> json.Json {
  case request {
    jsonrpc.Request(id, method, params) ->
      base_request_fields(
        method,
        Some(id),
        option_map(params, encode_request_params),
      )
      |> json.object
    jsonrpc.Notification(method, params) ->
      base_request_fields(
        method,
        None,
        option_map(params, encode_request_params),
      )
      |> json.object
  }
}

fn encode_action_notification(
  request: jsonrpc.Request(actions.ActionNotification),
) -> json.Json {
  case request {
    jsonrpc.Request(id, method, params) ->
      base_request_fields(
        method,
        Some(id),
        option_map(params, encode_notification_params),
      )
      |> json.object
    jsonrpc.Notification(method, params) ->
      base_request_fields(
        method,
        None,
        option_map(params, encode_notification_params),
      )
      |> json.object
  }
}

fn base_request_fields(
  method: String,
  id: Option(jsonrpc.RequestId),
  params: Option(json.Json),
) -> List(#(String, json.Json)) {
  [
    #("jsonrpc", json.string(jsonrpc.jsonrpc_version)),
    #("method", json.string(method)),
  ]
  |> prepend_optional("id", option_map(id, encode_request_id))
  |> append_optional("params", params)
}

fn encode_request_params(request: actions.ActionRequest) -> json.Json {
  case request {
    actions.RequestInitialize(params) ->
      encode_initialize_request_params(params)
    actions.RequestPing(meta) -> encode_request_meta_only(meta)
    actions.RequestListResources(params) ->
      encode_paginated_request_params(params)
    actions.RequestListResourceTemplates(params) ->
      encode_paginated_request_params(params)
    actions.RequestReadResource(params) ->
      encode_read_resource_request_params(params)
    actions.RequestSubscribeResource(params) ->
      encode_subscribe_request_params(params)
    actions.RequestUnsubscribeResource(params) ->
      encode_unsubscribe_request_params(params)
    actions.RequestListPrompts(params) ->
      encode_paginated_request_params(params)
    actions.RequestGetPrompt(params) -> encode_get_prompt_request_params(params)
    actions.RequestListTools(params) -> encode_paginated_request_params(params)
    actions.RequestCallTool(params) -> encode_call_tool_request_params(params)
    actions.RequestComplete(params) -> encode_complete_request_params(params)
    actions.RequestSetLoggingLevel(params) ->
      encode_set_level_request_params(params)
    actions.RequestListRoots(meta) -> encode_request_meta_only(meta)
    actions.RequestCreateMessage(params) ->
      encode_create_message_request_params(params)
    actions.RequestElicit(params) -> encode_elicit_request_params(params)
    actions.RequestListTasks(params) -> encode_paginated_request_params(params)
    actions.RequestGetTask(params) -> encode_task_id_params(params)
    actions.RequestGetTaskResult(params) -> encode_task_id_params(params)
    actions.RequestCancelTask(params) -> encode_task_id_params(params)
  }
}

fn encode_notification_params(
  notification: actions.ActionNotification,
) -> json.Json {
  case notification {
    actions.NotifyInitialized(meta) -> encode_notification_meta_only(meta)
    actions.NotifyCancelled(params) ->
      encode_cancelled_notification_params(params)
    actions.NotifyProgress(params) ->
      encode_progress_notification_params(params)
    actions.NotifyResourceListChanged(meta) ->
      encode_notification_meta_only(meta)
    actions.NotifyResourceUpdated(params) ->
      encode_resource_updated_notification_params(params)
    actions.NotifyPromptListChanged(meta) -> encode_notification_meta_only(meta)
    actions.NotifyToolListChanged(meta) -> encode_notification_meta_only(meta)
    actions.NotifyLoggingMessage(params) ->
      encode_logging_message_notification_params(params)
    actions.NotifyRootsListChanged(meta) -> encode_notification_meta_only(meta)
    actions.NotifyElicitationComplete(params) ->
      encode_elicitation_complete_notification_params(params)
    actions.NotifyTaskStatus(params) ->
      encode_task_status_notification_params(params)
  }
}

fn encode_initialize_request_params(
  params: actions.InitializeRequestParams,
) -> json.Json {
  let actions.InitializeRequestParams(
    protocol_version: protocol_version,
    capabilities: capabilities,
    client_info: client_info,
    meta: meta,
  ) = params

  [
    #("protocolVersion", json.string(protocol_version)),
    #("capabilities", encode_client_capabilities(capabilities)),
    #("clientInfo", encode_implementation(client_info)),
  ]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_request_meta_only(meta: Option(actions.RequestMeta)) -> json.Json {
  case meta {
    Some(value) -> json.object([#("_meta", encode_request_meta(value))])
    None -> json.object([])
  }
}

fn encode_notification_meta_only(
  meta: Option(actions.NotificationMeta),
) -> json.Json {
  case meta {
    Some(value) -> json.object([#("_meta", encode_notification_meta(value))])
    None -> json.object([])
  }
}

fn encode_paginated_request_params(
  params: actions.PaginatedRequestParams,
) -> json.Json {
  let actions.PaginatedRequestParams(cursor, meta) = params

  []
  |> append_optional("cursor", option_map(cursor, encode_cursor))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_read_resource_request_params(
  params: actions.ReadResourceRequestParams,
) -> json.Json {
  let actions.ReadResourceRequestParams(uri, meta) = params

  [#("uri", json.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_subscribe_request_params(
  params: actions.SubscribeRequestParams,
) -> json.Json {
  let actions.SubscribeRequestParams(uri, meta) = params

  [#("uri", json.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_unsubscribe_request_params(
  params: actions.UnsubscribeRequestParams,
) -> json.Json {
  let actions.UnsubscribeRequestParams(uri, meta) = params

  [#("uri", json.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_get_prompt_request_params(
  params: actions.GetPromptRequestParams,
) -> json.Json {
  let actions.GetPromptRequestParams(name, arguments, meta) = params

  [#("name", json.string(name))]
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, json.string(value))
      })
      |> json.object
    }),
  )
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_call_tool_request_params(
  params: actions.CallToolRequestParams,
) -> json.Json {
  let actions.CallToolRequestParams(name, arguments, task, meta) = params

  [#("name", json.string(name))]
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, encode_value(value))
      })
      |> json.object
    }),
  )
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_complete_request_params(
  params: actions.CompleteRequestParams,
) -> json.Json {
  let actions.CompleteRequestParams(ref, argument, context, meta) = params

  [
    #("ref", encode_completion_ref(ref)),
    #("argument", encode_complete_argument(argument)),
  ]
  |> append_optional("context", option_map(context, encode_complete_context))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_set_level_request_params(
  params: actions.SetLevelRequestParams,
) -> json.Json {
  let actions.SetLevelRequestParams(level, meta) = params

  [#("level", encode_logging_level(level))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_create_message_request_params(
  params: actions.CreateMessageRequestParams,
) -> json.Json {
  let actions.CreateMessageRequestParams(
    messages: messages,
    model_preferences: model_preferences,
    system_prompt: system_prompt,
    include_context: include_context,
    temperature: temperature,
    max_tokens: max_tokens,
    stop_sequences: stop_sequences,
    metadata: metadata,
    tools: tools,
    tool_choice: tool_choice,
    task: task,
    meta: meta,
  ) = params

  [
    #("messages", json.array(messages, encode_sampling_message)),
    #("maxTokens", json.int(max_tokens)),
  ]
  |> append_optional(
    "modelPreferences",
    option_map(model_preferences, encode_model_preferences),
  )
  |> append_optional("systemPrompt", option_map(system_prompt, json.string))
  |> append_optional(
    "includeContext",
    option_map(include_context, encode_include_context),
  )
  |> append_optional("temperature", option_map(temperature, json.float))
  |> append_optional("stopSequences", case stop_sequences {
    [] -> None
    _ -> Some(json.array(stop_sequences, json.string))
  })
  |> append_optional("metadata", option_map(metadata, encode_value))
  |> append_optional("tools", case tools {
    [] -> None
    _ -> Some(json.array(tools, encode_tool))
  })
  |> append_optional("toolChoice", option_map(tool_choice, encode_tool_choice))
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_elicit_request_params(
  params: actions.ElicitRequestParams,
) -> json.Json {
  case params {
    actions.ElicitRequestForm(form) -> encode_elicit_request_form_params(form)
    actions.ElicitRequestUrl(url) -> encode_elicit_request_url_params(url)
  }
}

fn encode_elicit_request_form_params(
  params: actions.ElicitRequestFormParams,
) -> json.Json {
  let actions.ElicitRequestFormParams(message, requested_schema, task, meta) =
    params

  [
    #("message", json.string(message)),
    #("requestedSchema", encode_value(requested_schema)),
  ]
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_elicit_request_url_params(
  params: actions.ElicitRequestUrlParams,
) -> json.Json {
  let actions.ElicitRequestUrlParams(message, elicitation_id, url, task, meta) =
    params

  [
    #("mode", json.string("url")),
    #("message", json.string(message)),
    #("elicitationId", json.string(elicitation_id)),
    #("url", json.string(url)),
  ]
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> json.object
}

fn encode_task_id_params(params: actions.TaskIdParams) -> json.Json {
  let actions.TaskIdParams(task_id) = params
  json.object([#("taskId", json.string(task_id))])
}

fn encode_cancelled_notification_params(
  params: actions.CancelledNotificationParams,
) -> json.Json {
  let actions.CancelledNotificationParams(request_id, reason, meta) = params

  []
  |> append_optional("requestId", option_map(request_id, encode_request_id))
  |> append_optional("reason", option_map(reason, json.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> json.object
}

fn encode_progress_notification_params(
  params: actions.ProgressNotificationParams,
) -> json.Json {
  let actions.ProgressNotificationParams(
    progress_token,
    progress,
    total,
    message,
    meta,
  ) = params

  [
    #("progressToken", encode_request_id(progress_token)),
    #("progress", json.float(progress)),
  ]
  |> append_optional("total", option_map(total, json.float))
  |> append_optional("message", option_map(message, json.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> json.object
}

fn encode_resource_updated_notification_params(
  params: actions.ResourceUpdatedNotificationParams,
) -> json.Json {
  let actions.ResourceUpdatedNotificationParams(uri, meta) = params

  [#("uri", json.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> json.object
}

fn encode_logging_message_notification_params(
  params: actions.LoggingMessageNotificationParams,
) -> json.Json {
  let actions.LoggingMessageNotificationParams(level, logger, data, meta) =
    params

  [#("level", encode_logging_level(level)), #("data", encode_value(data))]
  |> append_optional("logger", option_map(logger, json.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> json.object
}

fn encode_elicitation_complete_notification_params(
  params: actions.ElicitationCompleteNotificationParams,
) -> json.Json {
  let actions.ElicitationCompleteNotificationParams(elicitation_id) = params
  json.object([#("elicitationId", json.string(elicitation_id))])
}

fn encode_task_status_notification_params(
  params: actions.TaskStatusNotificationParams,
) -> json.Json {
  let actions.TaskStatusNotificationParams(task, meta) = params

  task_fields(task)
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> json.object
}

fn encode_request_meta(meta: actions.RequestMeta) -> json.Json {
  let actions.RequestMeta(progress_token, extra) = meta

  []
  |> append_optional(
    "progressToken",
    option_map(progress_token, encode_request_id),
  )
  |> append_meta_fields(extra)
  |> json.object
}

fn encode_notification_meta(meta: actions.NotificationMeta) -> json.Json {
  let actions.NotificationMeta(extra) = meta
  [] |> append_meta_fields(extra) |> json.object
}

fn append_meta_fields(
  entries: List(#(String, json.Json)),
  meta: Option(actions.Meta),
) -> List(#(String, json.Json)) {
  case meta {
    Some(actions.Meta(fields)) ->
      list.append(
        entries,
        dict.to_list(fields)
          |> list.map(fn(entry) {
            let #(key, value) = entry
            #(key, encode_value(value))
          }),
      )
    None -> entries
  }
}

fn encode_client_capabilities(
  capabilities: actions.ClientCapabilities,
) -> json.Json {
  let actions.ClientCapabilities(
    experimental,
    roots,
    sampling,
    elicitation,
    tasks,
  ) = capabilities

  []
  |> append_optional(
    "experimental",
    option_map(experimental, fn(fields) {
      encode_value(jsonrpc.VObject(dict.to_list(fields)))
    }),
  )
  |> append_optional(
    "roots",
    option_map(roots, encode_client_roots_capabilities),
  )
  |> append_optional(
    "sampling",
    option_map(sampling, encode_client_sampling_capabilities),
  )
  |> append_optional(
    "elicitation",
    option_map(elicitation, encode_client_elicitation_capabilities),
  )
  |> append_optional(
    "tasks",
    option_map(tasks, encode_client_tasks_capabilities),
  )
  |> json.object
}

fn encode_client_roots_capabilities(
  capabilities: actions.ClientRootsCapabilities,
) -> json.Json {
  let actions.ClientRootsCapabilities(list_changed) = capabilities

  []
  |> append_optional("listChanged", option_map(list_changed, json.bool))
  |> json.object
}

fn encode_client_sampling_capabilities(
  capabilities: actions.ClientSamplingCapabilities,
) -> json.Json {
  let actions.ClientSamplingCapabilities(context, tools) = capabilities

  []
  |> append_optional("context", option_map(context, encode_value))
  |> append_optional("tools", option_map(tools, encode_value))
  |> json.object
}

fn encode_client_elicitation_capabilities(
  capabilities: actions.ClientElicitationCapabilities,
) -> json.Json {
  let actions.ClientElicitationCapabilities(form, url) = capabilities

  []
  |> append_optional("form", option_map(form, encode_value))
  |> append_optional("url", option_map(url, encode_value))
  |> json.object
}

fn encode_client_tasks_capabilities(
  capabilities: actions.ClientTasksCapabilities,
) -> json.Json {
  let actions.ClientTasksCapabilities(list, cancel, requests) = capabilities

  []
  |> append_optional("list", option_map(list, encode_value))
  |> append_optional("cancel", option_map(cancel, encode_value))
  |> append_optional(
    "requests",
    option_map(requests, encode_client_task_request_capabilities),
  )
  |> json.object
}

fn encode_client_task_request_capabilities(
  capabilities: actions.ClientTaskRequestCapabilities,
) -> json.Json {
  let actions.ClientTaskRequestCapabilities(
    sampling_create_message,
    elicitation_create,
  ) = capabilities

  []
  |> append_optional("sampling", case sampling_create_message {
    Some(value) -> Some(json.object([#("createMessage", encode_value(value))]))
    None -> None
  })
  |> append_optional("elicitation", case elicitation_create {
    Some(value) -> Some(json.object([#("create", encode_value(value))]))
    None -> None
  })
  |> json.object
}

fn encode_implementation(implementation: actions.Implementation) -> json.Json {
  let actions.Implementation(
    name,
    version,
    title,
    description,
    website_url,
    icons,
  ) = implementation

  [#("name", json.string(name)), #("version", json.string(version))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("websiteUrl", option_map(website_url, json.string))
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(json.array(icons, encode_icon))
  })
  |> json.object
}

fn encode_icon(icon: actions.Icon) -> json.Json {
  let actions.Icon(src, mime_type, sizes, theme) = icon

  [#("src", json.string(src))]
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("sizes", case sizes {
    [] -> None
    _ -> Some(json.array(sizes, json.string))
  })
  |> append_optional("theme", option_map(theme, encode_icon_theme))
  |> json.object
}

fn encode_icon_theme(theme: actions.IconTheme) -> json.Json {
  case theme {
    actions.LightTheme -> json.string("light")
    actions.DarkTheme -> json.string("dark")
  }
}

fn encode_task_metadata(metadata: actions.TaskMetadata) -> json.Json {
  let actions.TaskMetadata(ttl_ms) = metadata

  []
  |> append_optional("ttl", option_map(ttl_ms, json.int))
  |> json.object
}

fn encode_completion_ref(ref: actions.CompletionRef) -> json.Json {
  case ref {
    actions.PromptRef(name, title) ->
      [#("type", json.string("ref/prompt")), #("name", json.string(name))]
      |> append_optional("title", option_map(title, json.string))
      |> json.object
    actions.ResourceTemplateRef(uri) ->
      json.object([
        #("type", json.string("ref/resource")),
        #("uri", json.string(uri)),
      ])
  }
}

fn encode_complete_argument(argument: actions.CompleteArgument) -> json.Json {
  let actions.CompleteArgument(name, value) = argument
  json.object([#("name", json.string(name)), #("value", json.string(value))])
}

fn encode_complete_context(context: actions.CompleteContext) -> json.Json {
  let actions.CompleteContext(arguments) = context

  []
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, json.string(value))
      })
      |> json.object
    }),
  )
  |> json.object
}

fn encode_logging_level(level: actions.LoggingLevel) -> json.Json {
  json.string(logging_level_string(level))
}

fn logging_level_string(level: actions.LoggingLevel) -> String {
  case level {
    actions.Debug -> "debug"
    actions.Info -> "info"
    actions.Notice -> "notice"
    actions.Warning -> "warning"
    actions.Error -> "error"
    actions.Critical -> "critical"
    actions.Alert -> "alert"
    actions.Emergency -> "emergency"
  }
}

fn encode_model_preferences(preferences: actions.ModelPreferences) -> json.Json {
  let actions.ModelPreferences(
    hints,
    cost_priority,
    speed_priority,
    intelligence_priority,
  ) = preferences

  []
  |> append_optional("hints", case hints {
    [] -> None
    _ -> Some(json.array(hints, encode_model_hint))
  })
  |> append_optional("costPriority", option_map(cost_priority, json.float))
  |> append_optional("speedPriority", option_map(speed_priority, json.float))
  |> append_optional(
    "intelligencePriority",
    option_map(intelligence_priority, json.float),
  )
  |> json.object
}

fn encode_model_hint(hint: actions.ModelHint) -> json.Json {
  let actions.ModelHint(name) = hint
  [] |> append_optional("name", option_map(name, json.string)) |> json.object
}

fn encode_include_context(context: actions.IncludeContext) -> json.Json {
  case context {
    actions.NoContext -> json.string("none")
    actions.ThisServerContext -> json.string("thisServer")
    actions.AllServersContext -> json.string("allServers")
  }
}

fn encode_sampling_message(message: actions.SamplingMessage) -> json.Json {
  let actions.SamplingMessage(role, content, meta) = message

  [#("role", encode_role(role)), #("content", encode_sampling_content(content))]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_sampling_content(content: actions.SamplingContent) -> json.Json {
  case content {
    actions.SingleSamplingContent(block) ->
      encode_sampling_message_content_block(block)
    actions.MultipleSamplingContent(blocks) ->
      json.array(blocks, encode_sampling_message_content_block)
  }
}

fn encode_sampling_message_content_block(
  block: actions.SamplingMessageContentBlock,
) -> json.Json {
  case block {
    actions.SamplingText(content) -> encode_text_content(content)
    actions.SamplingImage(content) -> encode_image_content(content)
    actions.SamplingAudio(content) -> encode_audio_content(content)
    actions.SamplingToolUse(content) -> encode_tool_use_content(content)
    actions.SamplingToolResult(content) -> encode_tool_result_content(content)
  }
}

fn encode_tool_choice(choice: actions.ToolChoice) -> json.Json {
  let actions.ToolChoice(mode) = choice

  []
  |> append_optional(
    "mode",
    option_map(mode, fn(mode) {
      case mode {
        actions.ToolAuto -> json.string("auto")
        actions.ToolRequired -> json.string("required")
        actions.ToolNone -> json.string("none")
      }
    }),
  )
  |> json.object
}

fn encode_tool(tool: actions.Tool) -> json.Json {
  let actions.Tool(
    name,
    title,
    description,
    input_schema,
    execution,
    output_schema,
    annotations,
    icons,
    meta,
  ) = tool

  [#("name", json.string(name)), #("inputSchema", encode_value(input_schema))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("execution", option_map(execution, encode_tool_execution))
  |> append_optional("outputSchema", option_map(output_schema, encode_value))
  |> append_optional(
    "annotations",
    option_map(annotations, encode_tool_annotations),
  )
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(json.array(icons, encode_icon))
  })
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_tool_execution(execution: actions.ToolExecution) -> json.Json {
  let actions.ToolExecution(task_support) = execution

  []
  |> append_optional(
    "taskSupport",
    option_map(task_support, fn(task_support) {
      case task_support {
        actions.TaskForbidden -> json.string("forbidden")
        actions.TaskOptional -> json.string("optional")
        actions.TaskRequired -> json.string("required")
      }
    }),
  )
  |> json.object
}

fn encode_tool_annotations(annotations: actions.ToolAnnotations) -> json.Json {
  let actions.ToolAnnotations(
    title,
    read_only_hint,
    destructive_hint,
    idempotent_hint,
    open_world_hint,
  ) = annotations

  []
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("readOnlyHint", option_map(read_only_hint, json.bool))
  |> append_optional("destructiveHint", option_map(destructive_hint, json.bool))
  |> append_optional("idempotentHint", option_map(idempotent_hint, json.bool))
  |> append_optional("openWorldHint", option_map(open_world_hint, json.bool))
  |> json.object
}

fn encode_tool_use_content(content: actions.ToolUseContent) -> json.Json {
  let actions.ToolUseContent(id, name, input, meta) = content

  [
    #("type", json.string("tool_use")),
    #("id", json.string(id)),
    #("name", json.string(name)),
    #(
      "input",
      dict.to_list(input)
        |> list.map(fn(entry) {
          let #(key, value) = entry
          #(key, encode_value(value))
        })
        |> json.object,
    ),
  ]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_tool_result_content(content: actions.ToolResultContent) -> json.Json {
  let actions.ToolResultContent(
    tool_use_id,
    blocks,
    structured_content,
    is_error,
    meta,
  ) = content

  [
    #("type", json.string("tool_result")),
    #("toolUseId", json.string(tool_use_id)),
    #("content", json.array(blocks, encode_content_block)),
  ]
  |> append_optional(
    "structuredContent",
    option_map(structured_content, fn(fields) {
      dict.to_list(fields)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, encode_value(value))
      })
      |> json.object
    }),
  )
  |> append_optional("isError", option_map(is_error, json.bool))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_content_block(block: actions.ContentBlock) -> json.Json {
  case block {
    actions.TextBlock(content) -> encode_text_content(content)
    actions.ImageBlock(content) -> encode_image_content(content)
    actions.AudioBlock(content) -> encode_audio_content(content)
    actions.ResourceLinkBlock(link) -> encode_resource_link(link)
    actions.EmbeddedResourceBlock(resource) ->
      encode_embedded_resource(resource)
  }
}

fn encode_text_content(content: actions.TextContent) -> json.Json {
  let actions.TextContent(text, annotations, meta) = content

  [#("type", json.string("text")), #("text", json.string(text))]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_image_content(content: actions.ImageContent) -> json.Json {
  let actions.ImageContent(data, mime_type, annotations, meta) = content

  [
    #("type", json.string("image")),
    #("data", json.string(data)),
    #("mimeType", json.string(mime_type)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_audio_content(content: actions.AudioContent) -> json.Json {
  let actions.AudioContent(data, mime_type, annotations, meta) = content

  [
    #("type", json.string("audio")),
    #("data", json.string(data)),
    #("mimeType", json.string(mime_type)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_resource_link(link: actions.ResourceLink) -> json.Json {
  let actions.ResourceLink(resource) = link
  resource_fields(resource)
  |> prepend_field(#("type", json.string("resource_link")))
  |> json.object
}

fn encode_embedded_resource(resource: actions.EmbeddedResource) -> json.Json {
  let actions.EmbeddedResource(resource, annotations, meta) = resource

  [
    #("type", json.string("resource")),
    #("resource", encode_resource_contents(resource)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_resource_contents(contents: actions.ResourceContents) -> json.Json {
  case contents {
    actions.TextResourceContents(uri, mime_type, text, meta) ->
      [#("uri", json.string(uri)), #("text", json.string(text))]
      |> append_optional("mimeType", option_map(mime_type, json.string))
      |> append_optional("_meta", option_map(meta, encode_meta))
      |> json.object
    actions.BlobResourceContents(uri, mime_type, blob, meta) ->
      [#("uri", json.string(uri)), #("blob", json.string(blob))]
      |> append_optional("mimeType", option_map(mime_type, json.string))
      |> append_optional("_meta", option_map(meta, encode_meta))
      |> json.object
  }
}

fn encode_annotations(annotations: actions.Annotations) -> json.Json {
  let actions.Annotations(audience, priority, last_modified) = annotations

  []
  |> append_optional("audience", case audience {
    [] -> None
    _ -> Some(json.array(audience, encode_role))
  })
  |> append_optional("priority", option_map(priority, json.float))
  |> append_optional("lastModified", option_map(last_modified, json.string))
  |> json.object
}

fn encode_meta(meta: actions.Meta) -> json.Json {
  let actions.Meta(fields) = meta

  dict.to_list(fields)
  |> list.map(fn(entry) {
    let #(key, value) = entry
    #(key, encode_value(value))
  })
  |> json.object
}

fn encode_role(role: actions.Role) -> json.Json {
  case role {
    actions.User -> json.string("user")
    actions.Assistant -> json.string("assistant")
  }
}

fn encode_cursor(cursor: actions.Cursor) -> json.Json {
  let actions.Cursor(value) = cursor
  json.string(value)
}

fn encode_task_status(status: actions.TaskStatus) -> json.Json {
  case status {
    actions.Working -> json.string("working")
    actions.InputRequired -> json.string("input_required")
    actions.Completed -> json.string("completed")
    actions.Failed -> json.string("failed")
    actions.Cancelled -> json.string("cancelled")
  }
}

fn encode_value(value: jsonrpc.Value) -> json.Json {
  case value {
    jsonrpc.VNull -> json.null()
    jsonrpc.VString(value) -> json.string(value)
    jsonrpc.VInt(value) -> json.int(value)
    jsonrpc.VFloat(value) -> json.float(value)
    jsonrpc.VBool(value) -> json.bool(value)
    jsonrpc.VArray(values) -> json.array(values, encode_value)
    jsonrpc.VObject(values) ->
      values
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, encode_value(value))
      })
      |> json.object
  }
}

fn encode_request_id(id: jsonrpc.RequestId) -> json.Json {
  case id {
    jsonrpc.IntId(value) -> json.int(value)
    jsonrpc.StringId(value) -> json.string(value)
  }
}

fn response_decoder(
  request: jsonrpc.Request(actions.ActionRequest),
) -> decode.Decoder(jsonrpc.Response(actions.ActionResult)) {
  case request {
    jsonrpc.Request(original_id, _, Some(action)) ->
      decode.one_of(
        result_response_decoder(original_id, action_result_decoder(action)),
        or: [error_response_decoder()],
      )
    jsonrpc.Request(original_id, _, None) ->
      decode.one_of(
        result_response_decoder(original_id, empty_result_decoder()),
        or: [error_response_decoder()],
      )
    jsonrpc.Notification(_, _) ->
      decode.failure(
        jsonrpc.ErrorResponse(None, jsonrpc.user_rejected_error()),
        expected: "JSON-RPC response",
      )
  }
}

fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  decode.then(decode.at(["method"], decode.string), fn(method) {
    case method {
      method if method == mcp.method_list_roots -> list_roots_message_decoder()
      method if method == mcp.method_create_message ->
        create_message_message_decoder()
      method if method == mcp.method_elicit -> elicit_message_decoder()
      method if method == mcp.method_list_tasks -> list_tasks_message_decoder()
      method if method == mcp.method_get_task -> get_task_message_decoder()
      method if method == mcp.method_get_task_result ->
        get_task_result_message_decoder()
      method if method == mcp.method_cancel_task ->
        cancel_task_message_decoder()
      method if method == mcp.method_notify_cancelled ->
        cancelled_notification_decoder()
      method if method == mcp.method_notify_progress ->
        progress_notification_decoder()
      method if method == mcp.method_notify_resource_list_changed ->
        resource_list_changed_notification_decoder()
      method if method == mcp.method_notify_resource_updated ->
        resource_updated_notification_decoder()
      method if method == mcp.method_notify_prompts_list_changed ->
        prompt_list_changed_notification_decoder()
      method if method == mcp.method_notify_tools_list_changed ->
        tool_list_changed_notification_decoder()
      method if method == mcp.method_notify_logging_message ->
        logging_message_notification_decoder()
      method if method == mcp.method_notify_roots_list_changed ->
        roots_list_changed_notification_decoder()
      method if method == mcp.method_notify_elicitation_complete ->
        elicitation_complete_notification_decoder()
      method if method == mcp.method_notify_task_status ->
        task_status_notification_decoder()
      _ -> unknown_server_message_decoder(method)
    }
  })
}

fn list_roots_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_list_roots,
    {
      use params <- decode.optional_field(
        "params",
        None,
        decode.optional(request_meta_decoder()),
      )
      decode.success(params)
    },
    fn(params) { actions.RequestListRoots(params) },
  )
}

fn create_message_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_create_message,
    {
      use params <- decode.field(
        "params",
        create_message_request_params_decoder(),
      )
      decode.success(params)
    },
    fn(params) { actions.RequestCreateMessage(params) },
  )
}

fn elicit_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_elicit,
    {
      use params <- decode.field("params", elicit_request_params_decoder())
      decode.success(params)
    },
    fn(params) { actions.RequestElicit(params) },
  )
}

fn list_tasks_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_list_tasks,
    {
      use params <- decode.optional_field(
        "params",
        actions.PaginatedRequestParams(None, None),
        paginated_request_params_decoder(),
      )
      decode.success(params)
    },
    fn(params) { actions.RequestListTasks(params) },
  )
}

fn get_task_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_get_task,
    {
      use params <- decode.field("params", task_id_params_decoder())
      decode.success(params)
    },
    fn(params) { actions.RequestGetTask(params) },
  )
}

fn get_task_result_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_get_task_result,
    {
      use params <- decode.field("params", task_id_params_decoder())
      decode.success(params)
    },
    fn(params) { actions.RequestGetTaskResult(params) },
  )
}

fn cancel_task_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    mcp.method_cancel_task,
    {
      use params <- decode.field("params", task_id_params_decoder())
      decode.success(params)
    },
    fn(params) { actions.RequestCancelTask(params) },
  )
}

fn roots_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_roots_list_changed, {
    use meta <- decode.optional_field(
      "params",
      None,
      notification_meta_only_decoder(),
    )
    decode.success(actions.NotifyRootsListChanged(meta))
  })
}

fn cancelled_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_cancelled, {
    use params <- decode.field(
      "params",
      cancelled_notification_params_decoder(),
    )
    decode.success(actions.NotifyCancelled(params))
  })
}

fn progress_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_progress, {
    use params <- decode.field("params", progress_notification_params_decoder())
    decode.success(actions.NotifyProgress(params))
  })
}

fn resource_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_resource_list_changed, {
    use meta <- decode.optional_field(
      "params",
      None,
      notification_meta_only_decoder(),
    )
    decode.success(actions.NotifyResourceListChanged(meta))
  })
}

fn resource_updated_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_resource_updated, {
    use params <- decode.field(
      "params",
      resource_updated_notification_params_decoder(),
    )
    decode.success(actions.NotifyResourceUpdated(params))
  })
}

fn prompt_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_prompts_list_changed, {
    use meta <- decode.optional_field(
      "params",
      None,
      notification_meta_only_decoder(),
    )
    decode.success(actions.NotifyPromptListChanged(meta))
  })
}

fn tool_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_tools_list_changed, {
    use meta <- decode.optional_field(
      "params",
      None,
      notification_meta_only_decoder(),
    )
    decode.success(actions.NotifyToolListChanged(meta))
  })
}

fn logging_message_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_logging_message, {
    use params <- decode.field(
      "params",
      logging_message_notification_params_decoder(),
    )
    decode.success(actions.NotifyLoggingMessage(params))
  })
}

fn elicitation_complete_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_elicitation_complete, {
    use params <- decode.field(
      "params",
      elicitation_complete_notification_params_decoder(),
    )
    decode.success(actions.NotifyElicitationComplete(params))
  })
}

fn task_status_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(mcp.method_notify_task_status, {
    use params <- decode.field(
      "params",
      task_status_notification_params_decoder(),
    )
    decode.success(actions.NotifyTaskStatus(params))
  })
}

fn decode_server_notification_message(
  _method: String,
  params_decoder: decode.Decoder(actions.ActionNotification),
) -> decode.Decoder(ServerMessage) {
  decode.then(
    {
      use id <- decode.optional_field(
        "id",
        None,
        decode.optional(request_id_decoder()),
      )
      decode.success(id)
    },
    fn(id) {
      decode.then(params_decoder, fn(notification) {
        let method = notification_method(notification)
        case id {
          Some(request_id) -> decode.success(UnknownRequest(request_id, method))
          None ->
            decode.success(
              ActionNotification(jsonrpc.Notification(
                method,
                Some(notification),
              )),
            )
        }
      })
    },
  )
}

fn notification_method(notification: actions.ActionNotification) -> String {
  case notification {
    actions.NotifyInitialized(_) -> mcp.method_initialized
    actions.NotifyCancelled(_) -> mcp.method_notify_cancelled
    actions.NotifyProgress(_) -> mcp.method_notify_progress
    actions.NotifyResourceListChanged(_) ->
      mcp.method_notify_resource_list_changed
    actions.NotifyResourceUpdated(_) -> mcp.method_notify_resource_updated
    actions.NotifyPromptListChanged(_) -> mcp.method_notify_prompts_list_changed
    actions.NotifyToolListChanged(_) -> mcp.method_notify_tools_list_changed
    actions.NotifyLoggingMessage(_) -> mcp.method_notify_logging_message
    actions.NotifyRootsListChanged(_) -> mcp.method_notify_roots_list_changed
    actions.NotifyElicitationComplete(_) ->
      mcp.method_notify_elicitation_complete
    actions.NotifyTaskStatus(_) -> mcp.method_notify_task_status
  }
}

fn unknown_server_message_decoder(
  method: String,
) -> decode.Decoder(ServerMessage) {
  {
    use id <- decode.optional_field(
      "id",
      None,
      decode.optional(request_id_decoder()),
    )
    case id {
      Some(request_id) -> decode.success(UnknownRequest(request_id, method))
      None -> decode.success(UnknownNotification(method))
    }
  }
}

fn decode_server_request_message(
  method: String,
  params_decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ActionRequest,
) -> decode.Decoder(ServerMessage) {
  decode.then(decode.at(["id"], request_id_decoder()), fn(id) {
    decode.then(params_decoder, fn(params) {
      decode.success(
        ActionRequest(jsonrpc.Request(id, method, Some(wrap(params)))),
      )
    })
  })
}

fn cancelled_notification_params_decoder() -> decode.Decoder(
  actions.CancelledNotificationParams,
) {
  {
    use request_id <- decode.optional_field(
      "requestId",
      None,
      decode.optional(request_id_decoder()),
    )
    use reason <- decode.optional_field(
      "reason",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(actions.CancelledNotificationParams(request_id, reason, meta))
  }
}

fn progress_notification_params_decoder() -> decode.Decoder(
  actions.ProgressNotificationParams,
) {
  {
    use progress_token <- decode.field("progressToken", request_id_decoder())
    use progress <- decode.field("progress", number_decoder())
    use total <- decode.optional_field(
      "total",
      None,
      decode.optional(number_decoder()),
    )
    use message <- decode.optional_field(
      "message",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(actions.ProgressNotificationParams(
      progress_token,
      progress,
      total,
      message,
      meta,
    ))
  }
}

fn resource_updated_notification_params_decoder() -> decode.Decoder(
  actions.ResourceUpdatedNotificationParams,
) {
  {
    use uri <- decode.field("uri", decode.string)
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(actions.ResourceUpdatedNotificationParams(uri, meta))
  }
}

fn logging_message_notification_params_decoder() -> decode.Decoder(
  actions.LoggingMessageNotificationParams,
) {
  {
    use level <- decode.field("level", logging_level_decoder())
    use logger <- decode.optional_field(
      "logger",
      None,
      decode.optional(decode.string),
    )
    use data <- decode.field("data", value_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(actions.LoggingMessageNotificationParams(
      level,
      logger,
      data,
      meta,
    ))
  }
}

fn elicitation_complete_notification_params_decoder() -> decode.Decoder(
  actions.ElicitationCompleteNotificationParams,
) {
  {
    use elicitation_id <- decode.field("elicitationId", decode.string)
    decode.success(actions.ElicitationCompleteNotificationParams(elicitation_id))
  }
}

fn task_status_notification_params_decoder() -> decode.Decoder(
  actions.TaskStatusNotificationParams,
) {
  {
    use task_id <- decode.field("taskId", decode.string)
    use status <- decode.field("status", task_status_decoder())
    use status_message <- decode.optional_field(
      "statusMessage",
      None,
      decode.optional(decode.string),
    )
    use created_at <- decode.field("createdAt", decode.string)
    use last_updated_at <- decode.field("lastUpdatedAt", decode.string)
    use ttl_ms <- decode.field("ttl", decode.optional(decode.int))
    use poll_interval_ms <- decode.optional_field(
      "pollInterval",
      None,
      decode.optional(decode.int),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(actions.TaskStatusNotificationParams(
      actions.Task(
        task_id,
        status,
        status_message,
        created_at,
        last_updated_at,
        ttl_ms,
        poll_interval_ms,
      ),
      meta,
    ))
  }
}

fn result_response_decoder(
  original_id: jsonrpc.RequestId,
  decoder result_decoder: decode.Decoder(actions.ActionResult),
) -> decode.Decoder(jsonrpc.Response(actions.ActionResult)) {
  {
    use version <- decode.field("jsonrpc", decode.string)
    use _id <- decode.field("id", request_id_decoder())
    use result <- decode.field("result", result_decoder)
    let _ = version
    decode.success(jsonrpc.ResultResponse(original_id, result))
  }
}

fn error_response_decoder() -> decode.Decoder(
  jsonrpc.Response(actions.ActionResult),
) {
  {
    use version <- decode.field("jsonrpc", decode.string)
    use id <- decode.optional_field(
      "id",
      None,
      decode.optional(request_id_decoder()),
    )
    use error <- decode.field("error", error_decoder())
    let _ = version
    decode.success(jsonrpc.ErrorResponse(id, error))
  }
}

fn action_result_decoder(
  action: actions.ActionRequest,
) -> decode.Decoder(actions.ActionResult) {
  case action {
    actions.RequestInitialize(_) ->
      decode.map(initialize_result_decoder(), actions.ResultInitialize)
    actions.RequestPing(_) -> empty_result_decoder()
    actions.RequestListResources(_) ->
      decode.map(list_resources_result_decoder(), actions.ResultListResources)
    actions.RequestListResourceTemplates(_) ->
      decode.map(
        list_resource_templates_result_decoder(),
        actions.ResultListResourceTemplates,
      )
    actions.RequestReadResource(_) ->
      decode.map(read_resource_result_decoder(), actions.ResultReadResource)
    actions.RequestSubscribeResource(_) -> empty_result_decoder()
    actions.RequestUnsubscribeResource(_) -> empty_result_decoder()
    actions.RequestListPrompts(_) ->
      decode.map(list_prompts_result_decoder(), actions.ResultListPrompts)
    actions.RequestGetPrompt(_) ->
      decode.map(get_prompt_result_decoder(), actions.ResultGetPrompt)
    actions.RequestListTools(_) ->
      decode.map(list_tools_result_decoder(), actions.ResultListTools)
    actions.RequestCallTool(_) ->
      decode.one_of(
        decode.map(create_task_result_decoder(), actions.ResultCreateTask),
        or: [decode.map(call_tool_result_decoder(), actions.ResultCallTool)],
      )
    actions.RequestComplete(_) ->
      decode.map(complete_result_decoder(), actions.ResultComplete)
    actions.RequestSetLoggingLevel(_) -> empty_result_decoder()
    actions.RequestListRoots(_) ->
      decode.map(list_roots_result_decoder(), actions.ResultListRoots)
    actions.RequestCreateMessage(_) ->
      decode.one_of(
        decode.map(create_task_result_decoder(), actions.ResultCreateTask),
        or: [
          decode.map(
            create_message_result_decoder(),
            actions.ResultCreateMessage,
          ),
        ],
      )
    actions.RequestElicit(_) ->
      decode.one_of(
        decode.map(create_task_result_decoder(), actions.ResultCreateTask),
        or: [decode.map(elicit_result_decoder(), actions.ResultElicit)],
      )
    actions.RequestListTasks(_) ->
      decode.map(list_tasks_result_decoder(), actions.ResultListTasks)
    actions.RequestGetTask(_) ->
      decode.map(get_task_result_decoder(), actions.ResultGetTask)
    actions.RequestGetTaskResult(_) ->
      decode.map(task_result_decoder(), actions.ResultTaskResult)
    actions.RequestCancelTask(_) ->
      decode.map(cancel_task_result_decoder(), actions.ResultCancelTask)
  }
}

fn empty_result_decoder() -> decode.Decoder(actions.ActionResult) {
  decode.map(meta_only_decoder(), actions.ResultEmpty)
}

fn initialize_result_decoder() -> decode.Decoder(actions.InitializeResult) {
  {
    use protocol_version <- decode.field("protocolVersion", decode.string)
    use capabilities <- decode.field(
      "capabilities",
      server_capabilities_decoder(),
    )
    use server_info <- decode.field("serverInfo", implementation_decoder())
    use instructions <- decode.optional_field(
      "instructions",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.InitializeResult(
      protocol_version: protocol_version,
      capabilities: capabilities,
      server_info: server_info,
      instructions: instructions,
      meta: meta,
    ))
  }
}

fn list_resources_result_decoder() -> decode.Decoder(
  actions.ListResourcesResult,
) {
  paginated_result_decoder("resources", decode.list(of: resource_decoder()))
  |> decode.map(fn(result) {
    let #(resources, page, meta) = result
    actions.ListResourcesResult(resources:, page:, meta:)
  })
}

fn list_resource_templates_result_decoder() -> decode.Decoder(
  actions.ListResourceTemplatesResult,
) {
  paginated_result_decoder(
    "resourceTemplates",
    decode.list(of: resource_template_decoder()),
  )
  |> decode.map(fn(result) {
    let #(resource_templates, page, meta) = result
    actions.ListResourceTemplatesResult(resource_templates:, page:, meta:)
  })
}

fn read_resource_result_decoder() -> decode.Decoder(actions.ReadResourceResult) {
  {
    use contents <- decode.field(
      "contents",
      decode.list(of: resource_contents_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ReadResourceResult(contents:, meta:))
  }
}

fn list_prompts_result_decoder() -> decode.Decoder(actions.ListPromptsResult) {
  paginated_result_decoder("prompts", decode.list(of: prompt_decoder()))
  |> decode.map(fn(result) {
    let #(prompts, page, meta) = result
    actions.ListPromptsResult(prompts:, page:, meta:)
  })
}

fn get_prompt_result_decoder() -> decode.Decoder(actions.GetPromptResult) {
  {
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use messages <- decode.field(
      "messages",
      decode.list(of: prompt_message_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.GetPromptResult(description:, messages:, meta:))
  }
}

fn list_tools_result_decoder() -> decode.Decoder(actions.ListToolsResult) {
  paginated_result_decoder("tools", decode.list(of: tool_decoder()))
  |> decode.map(fn(result) {
    let #(tools, page, meta) = result
    actions.ListToolsResult(tools:, page:, meta:)
  })
}

fn call_tool_result_decoder() -> decode.Decoder(actions.CallToolResult) {
  {
    use content <- decode.field(
      "content",
      decode.list(of: content_block_decoder()),
    )
    use structured_content <- decode.optional_field(
      "structuredContent",
      None,
      decode.optional(value_dict_decoder()),
    )
    use is_error <- decode.optional_field(
      "isError",
      None,
      decode.optional(decode.bool),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.CallToolResult(
      content:,
      structured_content:,
      is_error:,
      meta:,
    ))
  }
}

fn complete_result_decoder() -> decode.Decoder(actions.CompleteResult) {
  {
    use completion <- decode.field("completion", completion_values_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.CompleteResult(completion:, meta:))
  }
}

fn list_roots_result_decoder() -> decode.Decoder(actions.ListRootsResult) {
  {
    use roots <- decode.field("roots", decode.list(of: root_decoder()))
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ListRootsResult(roots:, meta:))
  }
}

fn create_message_result_decoder() -> decode.Decoder(
  actions.CreateMessageResult,
) {
  {
    use message <- decode.field("message", sampling_message_decoder())
    use model <- decode.field("model", decode.string)
    use stop_reason <- decode.optional_field(
      "stopReason",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.CreateMessageResult(
      message: message,
      model: model,
      stop_reason: stop_reason,
      meta: meta,
    ))
  }
}

fn elicit_result_decoder() -> decode.Decoder(actions.ElicitResult) {
  {
    use action <- decode.field("action", elicit_action_decoder())
    use content <- decode.optional_field(
      "content",
      None,
      decode.optional(elicit_content_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ElicitResult(action:, content:, meta:))
  }
}

fn create_message_request_params_decoder() -> decode.Decoder(
  actions.CreateMessageRequestParams,
) {
  {
    use messages <- decode.field(
      "messages",
      decode.list(of: sampling_message_decoder()),
    )
    use model_preferences <- decode.optional_field(
      "modelPreferences",
      None,
      decode.optional(model_preferences_decoder()),
    )
    use system_prompt <- decode.optional_field(
      "systemPrompt",
      None,
      decode.optional(decode.string),
    )
    use include_context <- decode.optional_field(
      "includeContext",
      None,
      decode.optional(include_context_decoder()),
    )
    use temperature <- decode.optional_field(
      "temperature",
      None,
      decode.optional(number_decoder()),
    )
    use max_tokens <- decode.field("maxTokens", decode.int)
    use stop_sequences <- decode.optional_field(
      "stopSequences",
      [],
      decode.list(of: decode.string),
    )
    use metadata <- decode.optional_field(
      "metadata",
      None,
      decode.optional(value_decoder()),
    )
    use tools <- decode.optional_field(
      "tools",
      [],
      decode.list(of: tool_decoder()),
    )
    use tool_choice <- decode.optional_field(
      "toolChoice",
      None,
      decode.optional(tool_choice_decoder()),
    )
    use task <- decode.optional_field(
      "task",
      None,
      decode.optional(task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.CreateMessageRequestParams(
      messages: messages,
      model_preferences: model_preferences,
      system_prompt: system_prompt,
      include_context: include_context,
      temperature: temperature,
      max_tokens: max_tokens,
      stop_sequences: stop_sequences,
      metadata: metadata,
      tools: tools,
      tool_choice: tool_choice,
      task: task,
      meta: meta,
    ))
  }
}

fn paginated_request_params_decoder() -> decode.Decoder(
  actions.PaginatedRequestParams,
) {
  {
    use cursor <- decode.optional_field(
      "cursor",
      None,
      decode.optional(decode.map(decode.string, actions.Cursor)),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.PaginatedRequestParams(cursor, meta))
  }
}

fn elicit_request_params_decoder() -> decode.Decoder(
  actions.ElicitRequestParams,
) {
  {
    use mode <- decode.optional_field(
      "mode",
      None,
      decode.optional(decode.string),
    )
    case mode {
      Some("url") ->
        decode.map(
          elicit_request_url_params_decoder(),
          actions.ElicitRequestUrl,
        )
      _ ->
        decode.map(
          elicit_request_form_params_decoder(),
          actions.ElicitRequestForm,
        )
    }
  }
}

fn elicit_request_form_params_decoder() -> decode.Decoder(
  actions.ElicitRequestFormParams,
) {
  {
    use message <- decode.field("message", decode.string)
    use requested_schema <- decode.field("requestedSchema", value_decoder())
    use task <- decode.optional_field(
      "task",
      None,
      decode.optional(task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.ElicitRequestFormParams(
      message,
      requested_schema,
      task,
      meta,
    ))
  }
}

fn elicit_request_url_params_decoder() -> decode.Decoder(
  actions.ElicitRequestUrlParams,
) {
  {
    use message <- decode.field("message", decode.string)
    use elicitation_id <- decode.field("elicitationId", decode.string)
    use url <- decode.field("url", decode.string)
    use task <- decode.optional_field(
      "task",
      None,
      decode.optional(task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.ElicitRequestUrlParams(
      message,
      elicitation_id,
      url,
      task,
      meta,
    ))
  }
}

fn request_meta_decoder() -> decode.Decoder(actions.RequestMeta) {
  {
    use progress_token <- decode.optional_field(
      "progressToken",
      None,
      decode.optional(request_id_decoder()),
    )
    use extra <- decode.optional_field(
      "extra",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.RequestMeta(progress_token, extra))
  }
}

fn notification_meta_only_decoder() -> decode.Decoder(
  Option(actions.NotificationMeta),
) {
  {
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(meta)
  }
}

fn notification_meta_decoder() -> decode.Decoder(actions.NotificationMeta) {
  {
    use extra <- decode.optional_field(
      "extra",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.NotificationMeta(extra))
  }
}

fn task_metadata_decoder() -> decode.Decoder(actions.TaskMetadata) {
  {
    use ttl_ms <- decode.optional_field(
      "ttl",
      None,
      decode.optional(decode.int),
    )
    decode.success(actions.TaskMetadata(ttl_ms))
  }
}

fn task_id_params_decoder() -> decode.Decoder(actions.TaskIdParams) {
  {
    use task_id <- decode.field("taskId", decode.string)
    decode.success(actions.TaskIdParams(task_id))
  }
}

fn model_preferences_decoder() -> decode.Decoder(actions.ModelPreferences) {
  {
    use hints <- decode.optional_field(
      "hints",
      [],
      decode.list(of: model_hint_decoder()),
    )
    use cost_priority <- decode.optional_field(
      "costPriority",
      None,
      decode.optional(number_decoder()),
    )
    use speed_priority <- decode.optional_field(
      "speedPriority",
      None,
      decode.optional(number_decoder()),
    )
    use intelligence_priority <- decode.optional_field(
      "intelligencePriority",
      None,
      decode.optional(number_decoder()),
    )
    decode.success(actions.ModelPreferences(
      hints,
      cost_priority,
      speed_priority,
      intelligence_priority,
    ))
  }
}

fn model_hint_decoder() -> decode.Decoder(actions.ModelHint) {
  {
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    decode.success(actions.ModelHint(name))
  }
}

fn include_context_decoder() -> decode.Decoder(actions.IncludeContext) {
  decode.then(decode.string, fn(value) {
    case value {
      "none" -> decode.success(actions.NoContext)
      "thisServer" -> decode.success(actions.ThisServerContext)
      "allServers" -> decode.success(actions.AllServersContext)
      _ -> decode.failure(actions.NoContext, expected: "IncludeContext")
    }
  })
}

fn sampling_message_decoder() -> decode.Decoder(actions.SamplingMessage) {
  {
    use role <- decode.field("role", role_decoder())
    use content <- decode.field("content", sampling_content_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.SamplingMessage(role, content, meta))
  }
}

fn tool_choice_decoder() -> decode.Decoder(actions.ToolChoice) {
  {
    use mode <- decode.optional_field(
      "mode",
      None,
      decode.optional(tool_choice_mode_decoder()),
    )
    decode.success(actions.ToolChoice(mode))
  }
}

fn tool_choice_mode_decoder() -> decode.Decoder(actions.ToolChoiceMode) {
  decode.then(decode.string, fn(value) {
    case value {
      "auto" -> decode.success(actions.ToolAuto)
      "required" -> decode.success(actions.ToolRequired)
      "none" -> decode.success(actions.ToolNone)
      _ -> decode.failure(actions.ToolAuto, expected: "ToolChoiceMode")
    }
  })
}

fn create_task_result_decoder() -> decode.Decoder(actions.CreateTaskResult) {
  {
    use task <- decode.field("task", task_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.CreateTaskResult(task:, meta:))
  }
}

fn list_tasks_result_decoder() -> decode.Decoder(actions.ListTasksResult) {
  paginated_result_decoder("tasks", decode.list(of: task_decoder()))
  |> decode.map(fn(result) {
    let #(tasks, page, meta) = result
    actions.ListTasksResult(tasks:, page:, meta:)
  })
}

fn get_task_result_decoder() -> decode.Decoder(actions.GetTaskResult) {
  {
    use task_id <- decode.field("taskId", decode.string)
    use status <- decode.field("status", task_status_decoder())
    use status_message <- decode.optional_field(
      "statusMessage",
      None,
      decode.optional(decode.string),
    )
    use created_at <- decode.field("createdAt", decode.string)
    use last_updated_at <- decode.field("lastUpdatedAt", decode.string)
    use ttl_ms <- decode.field("ttl", decode.optional(decode.int))
    use poll_interval_ms <- decode.optional_field(
      "pollInterval",
      None,
      decode.optional(decode.int),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    let task =
      actions.Task(
        task_id,
        status,
        status_message,
        created_at,
        last_updated_at,
        ttl_ms,
        poll_interval_ms,
      )
    decode.success(actions.GetTaskResult(task:, meta:))
  }
}

fn task_result_decoder() -> decode.Decoder(actions.TaskResult) {
  decode.one_of(
    decode.map(call_tool_result_decoder(), actions.TaskCallTool),
    or: [
      decode.map(create_message_result_decoder(), actions.TaskCreateMessage),
      decode.map(elicit_result_decoder(), actions.TaskElicit),
    ],
  )
}

fn cancel_task_result_decoder() -> decode.Decoder(actions.CancelTaskResult) {
  {
    use task_id <- decode.field("taskId", decode.string)
    use status <- decode.field("status", task_status_decoder())
    use status_message <- decode.optional_field(
      "statusMessage",
      None,
      decode.optional(decode.string),
    )
    use created_at <- decode.field("createdAt", decode.string)
    use last_updated_at <- decode.field("lastUpdatedAt", decode.string)
    use ttl_ms <- decode.field("ttl", decode.optional(decode.int))
    use poll_interval_ms <- decode.optional_field(
      "pollInterval",
      None,
      decode.optional(decode.int),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    let task =
      actions.Task(
        task_id,
        status,
        status_message,
        created_at,
        last_updated_at,
        ttl_ms,
        poll_interval_ms,
      )
    decode.success(actions.CancelTaskResult(task:, meta:))
  }
}

fn paginated_result_decoder(
  key: String,
  decoder inner: decode.Decoder(a),
) -> decode.Decoder(#(a, actions.Page, Option(actions.Meta))) {
  {
    use entries <- decode.field(key, inner)
    use next_cursor <- decode.optional_field(
      "nextCursor",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(#(
      entries,
      actions.Page(option_map(next_cursor, actions.Cursor)),
      meta,
    ))
  }
}

fn implementation_decoder() -> decode.Decoder(actions.Implementation) {
  {
    use name <- decode.field("name", decode.string)
    use version <- decode.field("version", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use website_url <- decode.optional_field(
      "websiteUrl",
      None,
      decode.optional(decode.string),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    decode.success(actions.Implementation(
      name: name,
      version: version,
      title: title,
      description: description,
      website_url: website_url,
      icons: icons,
    ))
  }
}

fn server_capabilities_decoder() -> decode.Decoder(actions.ServerCapabilities) {
  {
    use experimental <- decode.optional_field(
      "experimental",
      None,
      decode.optional(value_dict_decoder()),
    )
    use logging <- decode.optional_field(
      "logging",
      None,
      decode.optional(value_decoder()),
    )
    use completions <- decode.optional_field(
      "completions",
      None,
      decode.optional(value_decoder()),
    )
    use prompts <- decode.optional_field(
      "prompts",
      None,
      decode.optional(server_prompts_capabilities_decoder()),
    )
    use resources <- decode.optional_field(
      "resources",
      None,
      decode.optional(server_resources_capabilities_decoder()),
    )
    use tools <- decode.optional_field(
      "tools",
      None,
      decode.optional(server_tools_capabilities_decoder()),
    )
    use tasks <- decode.optional_field(
      "tasks",
      None,
      decode.optional(server_tasks_capabilities_decoder()),
    )
    decode.success(actions.ServerCapabilities(
      experimental,
      logging,
      completions,
      prompts,
      resources,
      tools,
      tasks,
    ))
  }
}

fn server_prompts_capabilities_decoder() -> decode.Decoder(
  actions.ServerPromptsCapabilities,
) {
  {
    use list_changed <- decode.optional_field(
      "listChanged",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.ServerPromptsCapabilities(list_changed: list_changed))
  }
}

fn server_resources_capabilities_decoder() -> decode.Decoder(
  actions.ServerResourcesCapabilities,
) {
  {
    use subscribe <- decode.optional_field(
      "subscribe",
      None,
      decode.optional(decode.bool),
    )
    use list_changed <- decode.optional_field(
      "listChanged",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.ServerResourcesCapabilities(
      subscribe: subscribe,
      list_changed: list_changed,
    ))
  }
}

fn server_tools_capabilities_decoder() -> decode.Decoder(
  actions.ServerToolsCapabilities,
) {
  {
    use list_changed <- decode.optional_field(
      "listChanged",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.ServerToolsCapabilities(list_changed: list_changed))
  }
}

fn server_tasks_capabilities_decoder() -> decode.Decoder(
  actions.ServerTasksCapabilities,
) {
  {
    use list <- decode.optional_field(
      "list",
      None,
      decode.optional(value_decoder()),
    )
    use cancel <- decode.optional_field(
      "cancel",
      None,
      decode.optional(value_decoder()),
    )
    use requests <- decode.optional_field(
      "requests",
      None,
      decode.optional(server_task_request_capabilities_decoder()),
    )
    decode.success(actions.ServerTasksCapabilities(list, cancel, requests))
  }
}

fn server_task_request_capabilities_decoder() -> decode.Decoder(
  actions.ServerTaskRequestCapabilities,
) {
  {
    use tools_call <- decode.optional_field("tools", None, {
      use call <- decode.optional_field(
        "call",
        None,
        decode.optional(value_decoder()),
      )
      decode.success(call)
    })
    decode.success(actions.ServerTaskRequestCapabilities(tools_call: tools_call))
  }
}

fn icon_decoder() -> decode.Decoder(actions.Icon) {
  {
    use src <- decode.field("src", decode.string)
    use mime_type <- decode.optional_field(
      "mimeType",
      None,
      decode.optional(decode.string),
    )
    use sizes <- decode.optional_field(
      "sizes",
      [],
      decode.list(of: decode.string),
    )
    use theme <- decode.optional_field(
      "theme",
      None,
      decode.optional(icon_theme_decoder()),
    )
    decode.success(actions.Icon(src, mime_type, sizes, theme))
  }
}

fn icon_theme_decoder() -> decode.Decoder(actions.IconTheme) {
  decode.then(decode.string, fn(value) {
    case value {
      "light" -> decode.success(actions.LightTheme)
      "dark" -> decode.success(actions.DarkTheme)
      _ -> decode.failure(actions.LightTheme, expected: "IconTheme")
    }
  })
}

fn resource_decoder() -> decode.Decoder(actions.Resource) {
  {
    use uri <- decode.field("uri", decode.string)
    use name <- decode.field("name", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use mime_type <- decode.optional_field(
      "mimeType",
      None,
      decode.optional(decode.string),
    )
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use size <- decode.optional_field("size", None, decode.optional(decode.int))
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.Resource(
      uri,
      name,
      title,
      description,
      mime_type,
      annotations,
      size,
      icons,
      meta,
    ))
  }
}

fn resource_template_decoder() -> decode.Decoder(actions.ResourceTemplate) {
  {
    use uri_template <- decode.field("uriTemplate", decode.string)
    use name <- decode.field("name", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use mime_type <- decode.optional_field(
      "mimeType",
      None,
      decode.optional(decode.string),
    )
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ResourceTemplate(
      uri_template,
      name,
      title,
      description,
      mime_type,
      annotations,
      icons,
      meta,
    ))
  }
}

fn resource_contents_decoder() -> decode.Decoder(actions.ResourceContents) {
  decode.one_of(
    {
      use uri <- decode.field("uri", decode.string)
      use mime_type <- decode.optional_field(
        "mimeType",
        None,
        decode.optional(decode.string),
      )
      use text <- decode.field("text", decode.string)
      use meta <- decode.optional_field(
        "_meta",
        None,
        decode.optional(meta_decoder()),
      )
      decode.success(actions.TextResourceContents(uri, mime_type, text, meta))
    },
    or: [
      {
        use uri <- decode.field("uri", decode.string)
        use mime_type <- decode.optional_field(
          "mimeType",
          None,
          decode.optional(decode.string),
        )
        use blob <- decode.field("blob", decode.string)
        use meta <- decode.optional_field(
          "_meta",
          None,
          decode.optional(meta_decoder()),
        )
        decode.success(actions.BlobResourceContents(uri, mime_type, blob, meta))
      },
    ],
  )
}

fn prompt_decoder() -> decode.Decoder(actions.Prompt) {
  {
    use name <- decode.field("name", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use arguments <- decode.optional_field(
      "arguments",
      [],
      decode.list(of: prompt_argument_decoder()),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.Prompt(
      name,
      title,
      description,
      arguments,
      icons,
      meta,
    ))
  }
}

fn prompt_argument_decoder() -> decode.Decoder(actions.PromptArgument) {
  {
    use name <- decode.field("name", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use required <- decode.optional_field(
      "required",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.PromptArgument(name, title, description, required))
  }
}

fn prompt_message_decoder() -> decode.Decoder(actions.PromptMessage) {
  {
    use role <- decode.field("role", role_decoder())
    use content <- decode.field("content", content_block_decoder())
    decode.success(actions.PromptMessage(role:, content:))
  }
}

fn tool_decoder() -> decode.Decoder(actions.Tool) {
  {
    use name <- decode.field("name", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use input_schema <- decode.field("inputSchema", value_decoder())
    use execution <- decode.optional_field(
      "execution",
      None,
      decode.optional(tool_execution_decoder()),
    )
    use output_schema <- decode.optional_field(
      "outputSchema",
      None,
      decode.optional(value_decoder()),
    )
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(tool_annotations_decoder()),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.Tool(
      name,
      title,
      description,
      input_schema,
      execution,
      output_schema,
      annotations,
      icons,
      meta,
    ))
  }
}

fn tool_execution_decoder() -> decode.Decoder(actions.ToolExecution) {
  {
    use task_support <- decode.optional_field(
      "taskSupport",
      None,
      decode.optional(task_support_decoder()),
    )
    decode.success(actions.ToolExecution(task_support: task_support))
  }
}

fn task_support_decoder() -> decode.Decoder(actions.TaskSupport) {
  decode.then(decode.string, fn(value) {
    case value {
      "forbidden" -> decode.success(actions.TaskForbidden)
      "optional" -> decode.success(actions.TaskOptional)
      "required" -> decode.success(actions.TaskRequired)
      _ -> decode.failure(actions.TaskForbidden, expected: "TaskSupport")
    }
  })
}

fn tool_annotations_decoder() -> decode.Decoder(actions.ToolAnnotations) {
  {
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use read_only_hint <- decode.optional_field(
      "readOnlyHint",
      None,
      decode.optional(decode.bool),
    )
    use destructive_hint <- decode.optional_field(
      "destructiveHint",
      None,
      decode.optional(decode.bool),
    )
    use idempotent_hint <- decode.optional_field(
      "idempotentHint",
      None,
      decode.optional(decode.bool),
    )
    use open_world_hint <- decode.optional_field(
      "openWorldHint",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.ToolAnnotations(
      title,
      read_only_hint,
      destructive_hint,
      idempotent_hint,
      open_world_hint,
    ))
  }
}

fn completion_values_decoder() -> decode.Decoder(actions.CompletionValues) {
  {
    use values <- decode.field("values", decode.list(of: decode.string))
    use total <- decode.optional_field(
      "total",
      None,
      decode.optional(decode.int),
    )
    use has_more <- decode.optional_field(
      "hasMore",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.CompletionValues(values, total, has_more))
  }
}

fn root_decoder() -> decode.Decoder(actions.Root) {
  {
    use uri <- decode.field("uri", decode.string)
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.Root(uri, name, meta))
  }
}

fn sampling_content_decoder() -> decode.Decoder(actions.SamplingContent) {
  decode.one_of(
    decode.map(
      sampling_message_content_block_decoder(),
      actions.SingleSamplingContent,
    ),
    or: [
      decode.map(
        decode.list(of: sampling_message_content_block_decoder()),
        actions.MultipleSamplingContent,
      ),
    ],
  )
}

fn sampling_message_content_block_decoder() -> decode.Decoder(
  actions.SamplingMessageContentBlock,
) {
  decode.then(decode.at(["type"], decode.string), fn(kind) {
    case kind {
      "text" -> decode.map(text_content_decoder(), actions.SamplingText)
      "image" -> decode.map(image_content_decoder(), actions.SamplingImage)
      "audio" -> decode.map(audio_content_decoder(), actions.SamplingAudio)
      "tool_use" ->
        decode.map(tool_use_content_decoder(), actions.SamplingToolUse)
      "tool_result" ->
        decode.map(tool_result_content_decoder(), actions.SamplingToolResult)
      _ ->
        decode.failure(
          actions.SamplingText(actions.TextContent("", None, None)),
          expected: "SamplingMessageContentBlock",
        )
    }
  })
}

fn content_block_decoder() -> decode.Decoder(actions.ContentBlock) {
  decode.then(decode.at(["type"], decode.string), fn(kind) {
    case kind {
      "text" -> decode.map(text_content_decoder(), actions.TextBlock)
      "image" -> decode.map(image_content_decoder(), actions.ImageBlock)
      "audio" -> decode.map(audio_content_decoder(), actions.AudioBlock)
      "resource_link" ->
        decode.map(resource_link_decoder(), actions.ResourceLinkBlock)
      "resource" ->
        decode.map(embedded_resource_decoder(), actions.EmbeddedResourceBlock)
      _ ->
        decode.failure(
          actions.TextBlock(actions.TextContent("", None, None)),
          expected: "ContentBlock",
        )
    }
  })
}

fn text_content_decoder() -> decode.Decoder(actions.TextContent) {
  {
    use text <- decode.field("text", decode.string)
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.TextContent(text, annotations, meta))
  }
}

fn image_content_decoder() -> decode.Decoder(actions.ImageContent) {
  {
    use data <- decode.field("data", decode.string)
    use mime_type <- decode.field("mimeType", decode.string)
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ImageContent(data, mime_type, annotations, meta))
  }
}

fn audio_content_decoder() -> decode.Decoder(actions.AudioContent) {
  {
    use data <- decode.field("data", decode.string)
    use mime_type <- decode.field("mimeType", decode.string)
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.AudioContent(data, mime_type, annotations, meta))
  }
}

fn resource_link_decoder() -> decode.Decoder(actions.ResourceLink) {
  decode.map(resource_decoder(), actions.ResourceLink)
}

fn embedded_resource_decoder() -> decode.Decoder(actions.EmbeddedResource) {
  {
    use resource <- decode.field("resource", resource_contents_decoder())
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(annotations_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.EmbeddedResource(resource, annotations, meta))
  }
}

fn annotations_decoder() -> decode.Decoder(actions.Annotations) {
  {
    use audience <- decode.optional_field(
      "audience",
      [],
      decode.list(of: role_decoder()),
    )
    use priority <- decode.optional_field(
      "priority",
      None,
      decode.optional(number_decoder()),
    )
    use last_modified <- decode.optional_field(
      "lastModified",
      None,
      decode.optional(decode.string),
    )
    decode.success(actions.Annotations(audience, priority, last_modified))
  }
}

fn tool_use_content_decoder() -> decode.Decoder(actions.ToolUseContent) {
  {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use input <- decode.field("input", value_dict_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ToolUseContent(id, name, input, meta))
  }
}

fn tool_result_content_decoder() -> decode.Decoder(actions.ToolResultContent) {
  {
    use tool_use_id <- decode.field("toolUseId", decode.string)
    use content <- decode.field(
      "content",
      decode.list(of: content_block_decoder()),
    )
    use structured_content <- decode.optional_field(
      "structuredContent",
      None,
      decode.optional(value_dict_decoder()),
    )
    use is_error <- decode.optional_field(
      "isError",
      None,
      decode.optional(decode.bool),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(actions.ToolResultContent(
      tool_use_id,
      content,
      structured_content,
      is_error,
      meta,
    ))
  }
}

fn task_decoder() -> decode.Decoder(actions.Task) {
  {
    use task_id <- decode.field("taskId", decode.string)
    use status <- decode.field("status", task_status_decoder())
    use status_message <- decode.optional_field(
      "statusMessage",
      None,
      decode.optional(decode.string),
    )
    use created_at <- decode.field("createdAt", decode.string)
    use last_updated_at <- decode.field("lastUpdatedAt", decode.string)
    use ttl_ms <- decode.field("ttl", decode.optional(decode.int))
    use poll_interval_ms <- decode.optional_field(
      "pollInterval",
      None,
      decode.optional(decode.int),
    )
    decode.success(actions.Task(
      task_id,
      status,
      status_message,
      created_at,
      last_updated_at,
      ttl_ms,
      poll_interval_ms,
    ))
  }
}

fn task_status_decoder() -> decode.Decoder(actions.TaskStatus) {
  decode.then(decode.string, fn(value) {
    case value {
      "working" -> decode.success(actions.Working)
      "input_required" -> decode.success(actions.InputRequired)
      "completed" -> decode.success(actions.Completed)
      "failed" -> decode.success(actions.Failed)
      "cancelled" -> decode.success(actions.Cancelled)
      _ -> decode.failure(actions.Working, expected: "TaskStatus")
    }
  })
}

fn logging_level_decoder() -> decode.Decoder(actions.LoggingLevel) {
  decode.then(decode.string, fn(value) {
    case value {
      "debug" -> decode.success(actions.Debug)
      "info" -> decode.success(actions.Info)
      "notice" -> decode.success(actions.Notice)
      "warning" -> decode.success(actions.Warning)
      "error" -> decode.success(actions.Error)
      "critical" -> decode.success(actions.Critical)
      "alert" -> decode.success(actions.Alert)
      "emergency" -> decode.success(actions.Emergency)
      _ -> decode.failure(actions.Info, expected: "LoggingLevel")
    }
  })
}

fn role_decoder() -> decode.Decoder(actions.Role) {
  decode.then(decode.string, fn(value) {
    case value {
      "user" -> decode.success(actions.User)
      "assistant" -> decode.success(actions.Assistant)
      _ -> decode.failure(actions.User, expected: "Role")
    }
  })
}

fn elicit_action_decoder() -> decode.Decoder(actions.ElicitAction) {
  decode.then(decode.string, fn(value) {
    case value {
      "accept" -> decode.success(actions.ElicitAccept)
      "decline" -> decode.success(actions.ElicitDecline)
      "cancel" -> decode.success(actions.ElicitCancel)
      _ -> decode.failure(actions.ElicitCancel, expected: "ElicitAction")
    }
  })
}

fn elicit_content_decoder() -> decode.Decoder(
  dict.Dict(String, actions.ElicitValue),
) {
  decode.dict(decode.string, elicit_value_decoder())
}

fn elicit_value_decoder() -> decode.Decoder(actions.ElicitValue) {
  decode.one_of(decode.map(decode.string, actions.ElicitString), or: [
    decode.map(decode.int, actions.ElicitInt),
    decode.map(number_decoder(), actions.ElicitFloat),
    decode.map(decode.bool, actions.ElicitBool),
    decode.map(decode.list(of: decode.string), actions.ElicitStringArray),
  ])
}

fn meta_only_decoder() -> decode.Decoder(Option(actions.Meta)) {
  {
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(meta_decoder()),
    )
    decode.success(meta)
  }
}

fn meta_decoder() -> decode.Decoder(actions.Meta) {
  decode.map(value_dict_decoder(), actions.Meta)
}

fn value_dict_decoder() -> decode.Decoder(dict.Dict(String, jsonrpc.Value)) {
  decode.dict(decode.string, value_decoder())
}

fn request_id_decoder() -> decode.Decoder(jsonrpc.RequestId) {
  decode.one_of(decode.map(decode.string, jsonrpc.StringId), or: [
    decode.map(decode.int, jsonrpc.IntId),
  ])
}

fn error_decoder() -> decode.Decoder(jsonrpc.RpcError) {
  {
    use code <- decode.field("code", decode.int)
    use message <- decode.field("message", decode.string)
    use data <- decode.optional_field(
      "data",
      None,
      decode.optional(value_decoder()),
    )
    decode.success(jsonrpc.RpcError(code:, message:, data: data))
  }
}

fn value_decoder() -> decode.Decoder(jsonrpc.Value) {
  use <- decode.recursive
  decode.one_of(decode.map(decode.string, jsonrpc.VString), or: [
    decode.map(decode.int, jsonrpc.VInt),
    decode.map(number_decoder(), jsonrpc.VFloat),
    decode.map(decode.bool, jsonrpc.VBool),
    decode.map(decode.list(of: value_decoder()), jsonrpc.VArray),
    decode.map(decode.dict(decode.string, value_decoder()), fn(fields) {
      jsonrpc.VObject(dict.to_list(fields))
    }),
    null_value_decoder(),
  ])
}

fn null_value_decoder() -> decode.Decoder(jsonrpc.Value) {
  decode.map(decode.optional(decode.dynamic), fn(_) { jsonrpc.VNull })
  |> decode.collapse_errors("Null")
}

fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
}

fn json_error_message(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of JSON input"
    json.UnexpectedByte(byte) -> "Unexpected JSON byte: " <> byte
    json.UnexpectedSequence(sequence) ->
      "Unexpected JSON sequence: " <> sequence
    json.UnableToDecode(errors) ->
      case errors {
        [] -> "Unable to decode JSON value"
        [decode.DecodeError(expected, found, path), ..] ->
          "Expected "
          <> expected
          <> ", found "
          <> found
          <> decode_path_suffix(path)
      }
  }
}

fn decode_path_suffix(path: List(String)) -> String {
  case path {
    [] -> ""
    _ -> " at " <> string.join(path, ".")
  }
}

fn prepend_field(
  fields: List(#(String, json.Json)),
  field: #(String, json.Json),
) -> List(#(String, json.Json)) {
  [field, ..fields]
}

fn resource_fields(resource: actions.Resource) -> List(#(String, json.Json)) {
  let actions.Resource(
    uri,
    name,
    title,
    description,
    mime_type,
    annotations,
    size,
    icons,
    meta,
  ) = resource

  [#("uri", json.string(uri)), #("name", json.string(name))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("size", option_map(size, json.int))
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(json.array(icons, encode_icon))
  })
  |> append_optional("_meta", option_map(meta, encode_meta))
}

fn task_fields(task: actions.Task) -> List(#(String, json.Json)) {
  let actions.Task(
    task_id,
    status,
    status_message,
    created_at,
    last_updated_at,
    ttl_ms,
    poll_interval_ms,
  ) = task

  [
    #("taskId", json.string(task_id)),
    #("status", encode_task_status(status)),
    #("createdAt", json.string(created_at)),
    #("lastUpdatedAt", json.string(last_updated_at)),
    #("ttl", json.nullable(ttl_ms, json.int)),
  ]
  |> append_optional("statusMessage", option_map(status_message, json.string))
  |> append_optional("pollInterval", option_map(poll_interval_ms, json.int))
}

fn append_optional(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(json.Json),
) -> List(#(String, json.Json)) {
  case value {
    Some(value) -> list.append(fields, [#(key, value)])
    None -> fields
  }
}

fn prepend_optional(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(json.Json),
) -> List(#(String, json.Json)) {
  case value {
    Some(value) -> [#(key, value), ..fields]
    None -> fields
  }
}

fn option_map(input: Option(a), fun: fn(a) -> b) -> Option(b) {
  case input {
    Some(value) -> Some(fun(value))
    None -> None
  }
}
