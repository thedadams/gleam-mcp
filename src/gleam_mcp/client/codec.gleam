import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/codec_encode
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc
import gleam_mcp/mcp

pub type ServerMessage {
  ServerActionRequest(jsonrpc.Request(actions.ServerActionRequest))
  ActionNotification(jsonrpc.Request(actions.ActionNotification))
  UnknownRequest(id: jsonrpc.RequestId, method: String)
  UnknownNotification(method: String)
}

pub fn encode_request(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> String {
  request
  |> encode_jsonrpc_request(encode_request_params)
  |> codec_value.to_string
}

pub fn encode_server_request(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> String {
  request
  |> encode_jsonrpc_request(encode_server_request_params)
  |> codec_value.to_string
}

pub fn encode_notification(
  notification: jsonrpc.Request(actions.ActionNotification),
) -> String {
  notification
  |> encode_jsonrpc_request(encode_notification_params)
  |> codec_value.to_string
}

pub fn decode_response(
  body: String,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> Result(jsonrpc.Response(actions.ClientActionResult), String) {
  json.parse(body, response_decoder(request))
  |> result.map_error(codec_decode.json_error_message)
}

pub fn decode_server_response(
  body: String,
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> Result(jsonrpc.Response(actions.ServerActionResult), String) {
  json.parse(body, server_response_decoder(request))
  |> result.map_error(codec_decode.json_error_message)
}

pub fn decode_server_message(body: String) -> Result(ServerMessage, String) {
  json.parse(body, server_message_decoder())
  |> result.map_error(codec_decode.json_error_message)
}

pub fn encode_client_capabilities_value(
  capabilities: actions.ClientCapabilities,
) -> jsonrpc.Value {
  encode_client_capabilities(capabilities) |> codec_value.normalize
}

pub fn decode_server_capabilities(
  value: jsonrpc.Value,
) -> Result(actions.ServerCapabilities, String) {
  codec_decode.decode_value(value, server_capabilities_decoder())
}

pub fn decode_implementation(
  value: jsonrpc.Value,
) -> Result(actions.Implementation, String) {
  codec_decode.decode_value(value, codec_decode.implementation_decoder())
}

fn encode_jsonrpc_request(
  request: jsonrpc.Request(a),
  encode_params: fn(a) -> jsonrpc.Value,
) -> jsonrpc.Value {
  case request {
    jsonrpc.Request(id, method, params) ->
      base_request_fields(method, Some(id), option_map(params, encode_params))
      |> codec_value.object
    jsonrpc.Notification(method, params) ->
      base_request_fields(method, None, option_map(params, encode_params))
      |> codec_value.object
  }
}

fn base_request_fields(
  method: String,
  id: Option(jsonrpc.RequestId),
  params: Option(jsonrpc.Value),
) -> List(#(String, jsonrpc.Value)) {
  [
    #("jsonrpc", codec_value.string(jsonrpc.jsonrpc_version)),
    #("method", codec_value.string(method)),
  ]
  |> prepend_optional("id", option_map(id, codec_encode.encode_request_id))
  |> append_optional("params", params)
}

fn encode_request_params(
  request: actions.ClientActionRequest,
) -> jsonrpc.Value {
  case request {
    actions.ClientRequestDiscover(meta) -> encode_request_meta_only(meta)
    actions.ClientRequestSubscriptionsListen(params) ->
      []
      |> append_optional(
        "notifications",
        option_map(params.notifications, codec_encode.encode_value),
      )
      |> append_optional("_meta", option_map(params.meta, encode_request_meta))
      |> codec_value.object
    actions.ClientRequestWithInput(inner, state, responses) ->
      encode_request_params(inner)
      |> codec_value.object_fields
      |> list.filter(fn(field) {
        field.0 != "requestState" && field.0 != "inputResponses"
      })
      |> append_optional("requestState", option_map(state, codec_value.string))
      |> append_optional(
        "inputResponses",
        option_map(responses, fn(fields) {
          codec_encode.encode_value_object(dict.to_list(fields))
        }),
      )
      |> codec_value.object
    actions.ClientRequestUpdateTask(params) ->
      [#("taskId", codec_value.string(params.task_id))]
      |> append_optional(
        "inputResponses",
        option_map(params.input, codec_encode.encode_value),
      )
      |> append_optional("_meta", option_map(params.meta, encode_request_meta))
      |> codec_value.object
    actions.ClientRequestInitialize(params) ->
      encode_initialize_request_params(params)
    actions.ClientRequestPing(meta) -> encode_request_meta_only(meta)
    actions.ClientRequestListResources(params) ->
      encode_paginated_request_params(params)
    actions.ClientRequestListResourceTemplates(params) ->
      encode_paginated_request_params(params)
    actions.ClientRequestReadResource(params) ->
      encode_read_resource_request_params(params)
    actions.ClientRequestSubscribeResource(params) ->
      encode_subscribe_request_params(params)
    actions.ClientRequestUnsubscribeResource(params) ->
      encode_unsubscribe_request_params(params)
    actions.ClientRequestListPrompts(params) ->
      encode_paginated_request_params(params)
    actions.ClientRequestGetPrompt(params) ->
      encode_get_prompt_request_params(params)
    actions.ClientRequestListTools(params) ->
      encode_paginated_request_params(params)
    actions.ClientRequestCallTool(params) ->
      encode_call_tool_request_params(params)
    actions.ClientRequestComplete(params) ->
      encode_complete_request_params(params)
    actions.ClientRequestSetLoggingLevel(params) ->
      encode_set_level_request_params(params)
    actions.ClientRequestListTasks(params) ->
      encode_paginated_request_params(params)
    actions.ClientRequestGetTask(params) -> encode_task_id_params(params)
    actions.ClientRequestGetTaskResult(params) -> encode_task_id_params(params)
    actions.ClientRequestCancelTask(params) -> encode_task_id_params(params)
  }
}

fn encode_server_request_params(
  request: actions.ServerActionRequest,
) -> jsonrpc.Value {
  case request {
    actions.ServerRequestPing(meta) -> encode_request_meta_only(meta)
    actions.ServerRequestListRoots(meta) -> encode_request_meta_only(meta)
    actions.ServerRequestCreateMessage(params) ->
      encode_create_message_request_params(params)
    actions.ServerRequestElicit(params) -> encode_elicit_request_params(params)
    actions.ServerRequestListTasks(params) ->
      encode_paginated_request_params(params)
    actions.ServerRequestGetTask(params) -> encode_task_id_params(params)
    actions.ServerRequestGetTaskResult(params) -> encode_task_id_params(params)
    actions.ServerRequestCancelTask(params) -> encode_task_id_params(params)
  }
}

fn encode_notification_params(
  notification: actions.ActionNotification,
) -> jsonrpc.Value {
  case notification {
    actions.NotifyTaskModern(value, meta) ->
      value
      |> codec_encode.encode_value
      |> codec_value.object_fields
      |> list.filter(fn(field) { field.0 != "_meta" })
      |> append_optional("_meta", option_map(meta, encode_notification_meta))
      |> codec_value.object
    actions.NotifySubscriptionsAcknowledged(meta) ->
      encode_notification_meta_only(meta)
    actions.NotifySubscriptionsAcknowledgedWithFilter(notifications, meta) ->
      []
      |> append_optional(
        "notifications",
        option_map(notifications, codec_encode.encode_value),
      )
      |> append_optional("_meta", option_map(meta, encode_notification_meta))
      |> codec_value.object
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
) -> jsonrpc.Value {
  let actions.InitializeRequestParams(
    protocol_version: protocol_version,
    capabilities: capabilities,
    client_info: client_info,
    meta: meta,
  ) = params

  [
    #("protocolVersion", codec_value.string(protocol_version)),
    #("capabilities", encode_client_capabilities(capabilities)),
    #("clientInfo", codec_encode.encode_implementation(client_info)),
  ]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_request_meta_only(
  meta: Option(actions.RequestMeta),
) -> jsonrpc.Value {
  case meta {
    Some(value) -> codec_value.object([#("_meta", encode_request_meta(value))])
    None -> codec_value.object([])
  }
}

fn encode_notification_meta_only(
  meta: Option(actions.NotificationMeta),
) -> jsonrpc.Value {
  case meta {
    Some(value) ->
      codec_value.object([#("_meta", encode_notification_meta(value))])
    None -> codec_value.object([])
  }
}

fn encode_paginated_request_params(
  params: actions.PaginatedRequestParams,
) -> jsonrpc.Value {
  let actions.PaginatedRequestParams(cursor, meta) = params

  []
  |> append_optional("cursor", option_map(cursor, codec_encode.encode_cursor))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_read_resource_request_params(
  params: actions.ReadResourceRequestParams,
) -> jsonrpc.Value {
  let actions.ReadResourceRequestParams(uri, meta) = params

  [#("uri", codec_value.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_subscribe_request_params(
  params: actions.SubscribeRequestParams,
) -> jsonrpc.Value {
  let actions.SubscribeRequestParams(uri, meta) = params

  [#("uri", codec_value.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_unsubscribe_request_params(
  params: actions.UnsubscribeRequestParams,
) -> jsonrpc.Value {
  let actions.UnsubscribeRequestParams(uri, meta) = params

  [#("uri", codec_value.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_get_prompt_request_params(
  params: actions.GetPromptRequestParams,
) -> jsonrpc.Value {
  let actions.GetPromptRequestParams(name, arguments, meta) = params

  [#("name", codec_value.string(name))]
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, codec_value.string(value))
      })
      |> codec_value.object
    }),
  )
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_call_tool_request_params(
  params: actions.CallToolRequestParams,
) -> jsonrpc.Value {
  let actions.CallToolRequestParams(name, arguments, task, meta) = params

  [#("name", codec_value.string(name))]
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, codec_encode.encode_value(value))
      })
      |> codec_value.object
    }),
  )
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_complete_request_params(
  params: actions.CompleteRequestParams,
) -> jsonrpc.Value {
  let actions.CompleteRequestParams(ref, argument, context, meta) = params

  [
    #("ref", encode_completion_ref(ref)),
    #("argument", encode_complete_argument(argument)),
  ]
  |> append_optional("context", option_map(context, encode_complete_context))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_set_level_request_params(
  params: actions.SetLevelRequestParams,
) -> jsonrpc.Value {
  let actions.SetLevelRequestParams(level, meta) = params

  [#("level", encode_logging_level(level))]
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_create_message_request_params(
  params: actions.CreateMessageRequestParams,
) -> jsonrpc.Value {
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
    #("messages", codec_value.array(messages, encode_sampling_message)),
    #("maxTokens", codec_value.int(max_tokens)),
  ]
  |> append_optional(
    "modelPreferences",
    option_map(model_preferences, encode_model_preferences),
  )
  |> append_optional(
    "systemPrompt",
    option_map(system_prompt, codec_value.string),
  )
  |> append_optional(
    "includeContext",
    option_map(include_context, encode_include_context),
  )
  |> append_optional("temperature", option_map(temperature, codec_value.float))
  |> append_optional("stopSequences", case stop_sequences {
    [] -> None
    _ -> Some(codec_value.array(stop_sequences, codec_value.string))
  })
  |> append_optional(
    "metadata",
    option_map(metadata, codec_encode.encode_value),
  )
  |> append_optional("tools", case tools {
    [] -> None
    _ -> Some(codec_value.array(tools, codec_encode.encode_tool))
  })
  |> append_optional("toolChoice", option_map(tool_choice, encode_tool_choice))
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_elicit_request_params(
  params: actions.ElicitRequestParams,
) -> jsonrpc.Value {
  case params {
    actions.ElicitRequestForm(form) -> encode_elicit_request_form_params(form)
    actions.ElicitRequestUrl(url) -> encode_elicit_request_url_params(url)
  }
}

fn encode_elicit_request_form_params(
  params: actions.ElicitRequestFormParams,
) -> jsonrpc.Value {
  let actions.ElicitRequestFormParams(message, requested_schema, task, meta) =
    params

  [
    #("message", codec_value.string(message)),
    #("requestedSchema", codec_encode.encode_value(requested_schema)),
  ]
  |> append_optional("task", option_map(task, encode_task_metadata))
  |> append_optional("_meta", option_map(meta, encode_request_meta))
  |> codec_value.object
}

fn encode_elicit_request_url_params(
  params: actions.ElicitRequestUrlParams,
) -> jsonrpc.Value {
  let elicitation_id = case params {
    actions.ElicitRequestUrlParams(_, id, _, _, _) -> Some(id)
    actions.ElicitRequestUrlParamsWithoutId(..) -> None
  }

  [
    #("mode", codec_value.string("url")),
    #("message", codec_value.string(params.message)),
    #("url", codec_value.string(actions.elicit_url(params))),
  ]
  |> append_optional(
    "elicitationId",
    option_map(elicitation_id, codec_value.string),
  )
  |> append_optional(
    "task",
    option_map(actions.elicit_url_task(params), encode_task_metadata),
  )
  |> append_optional(
    "_meta",
    option_map(actions.elicit_url_meta(params), encode_request_meta),
  )
  |> codec_value.object
}

fn encode_task_id_params(params: actions.TaskIdParams) -> jsonrpc.Value {
  [#("taskId", codec_value.string(actions.task_id(params)))]
  |> append_optional(
    "_meta",
    option_map(actions.task_id_meta(params), encode_request_meta),
  )
  |> codec_value.object
}

fn encode_cancelled_notification_params(
  params: actions.CancelledNotificationParams,
) -> jsonrpc.Value {
  let actions.CancelledNotificationParams(request_id, reason, meta) = params

  []
  |> append_optional(
    "requestId",
    option_map(request_id, codec_encode.encode_request_id),
  )
  |> append_optional("reason", option_map(reason, codec_value.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> codec_value.object
}

fn encode_progress_notification_params(
  params: actions.ProgressNotificationParams,
) -> jsonrpc.Value {
  let actions.ProgressNotificationParams(
    progress_token,
    progress,
    total,
    message,
    meta,
  ) = params

  [
    #("progressToken", codec_encode.encode_request_id(progress_token)),
    #("progress", codec_value.float(progress)),
  ]
  |> append_optional("total", option_map(total, codec_value.float))
  |> append_optional("message", option_map(message, codec_value.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> codec_value.object
}

fn encode_resource_updated_notification_params(
  params: actions.ResourceUpdatedNotificationParams,
) -> jsonrpc.Value {
  let actions.ResourceUpdatedNotificationParams(uri, meta) = params

  [#("uri", codec_value.string(uri))]
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> codec_value.object
}

fn encode_logging_message_notification_params(
  params: actions.LoggingMessageNotificationParams,
) -> jsonrpc.Value {
  let actions.LoggingMessageNotificationParams(level, logger, data, meta) =
    params

  [
    #("level", encode_logging_level(level)),
    #("data", codec_encode.encode_value(data)),
  ]
  |> append_optional("logger", option_map(logger, codec_value.string))
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> codec_value.object
}

fn encode_elicitation_complete_notification_params(
  params: actions.ElicitationCompleteNotificationParams,
) -> jsonrpc.Value {
  [
    #(
      "elicitationId",
      codec_value.string(actions.elicitation_complete_notification_id(params)),
    ),
  ]
  |> append_optional(
    "_meta",
    option_map(
      actions.elicitation_complete_notification_meta(params),
      encode_notification_meta,
    ),
  )
  |> codec_value.object
}

fn encode_task_status_notification_params(
  params: actions.TaskStatusNotificationParams,
) -> jsonrpc.Value {
  let actions.TaskStatusNotificationParams(task, meta) = params

  codec_encode.task_fields(task)
  |> append_optional("_meta", option_map(meta, encode_notification_meta))
  |> codec_value.object
}

fn encode_request_meta(meta: actions.RequestMeta) -> jsonrpc.Value {
  let actions.RequestMeta(progress_token, extra) = meta

  []
  |> append_optional(
    "progressToken",
    option_map(progress_token, codec_encode.encode_request_id),
  )
  |> append_meta_fields(extra)
  |> codec_value.object
}

fn encode_notification_meta(meta: actions.NotificationMeta) -> jsonrpc.Value {
  let actions.NotificationMeta(extra) = meta
  [] |> append_meta_fields(extra) |> codec_value.object
}

fn append_meta_fields(
  entries: List(#(String, jsonrpc.Value)),
  meta: Option(actions.Meta),
) -> List(#(String, jsonrpc.Value)) {
  case meta {
    Some(actions.Meta(fields)) ->
      list.append(
        entries,
        dict.to_list(fields)
          |> list.map(fn(entry) {
            let #(key, value) = entry
            #(key, codec_encode.encode_value(value))
          }),
      )
    None -> entries
  }
}

fn encode_client_capabilities(
  capabilities: actions.ClientCapabilities,
) -> jsonrpc.Value {
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
      codec_encode.encode_value(jsonrpc.VObject(dict.to_list(fields)))
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
  |> codec_value.object
}

fn encode_client_roots_capabilities(
  capabilities: actions.ClientRootsCapabilities,
) -> jsonrpc.Value {
  let actions.ClientRootsCapabilities(list_changed) = capabilities

  []
  |> append_optional("listChanged", option_map(list_changed, codec_value.bool))
  |> codec_value.object
}

fn encode_client_sampling_capabilities(
  capabilities: actions.ClientSamplingCapabilities,
) -> jsonrpc.Value {
  let actions.ClientSamplingCapabilities(context, tools) = capabilities

  []
  |> append_optional("context", option_map(context, codec_encode.encode_value))
  |> append_optional("tools", option_map(tools, codec_encode.encode_value))
  |> codec_value.object
}

fn encode_client_elicitation_capabilities(
  capabilities: actions.ClientElicitationCapabilities,
) -> jsonrpc.Value {
  let actions.ClientElicitationCapabilities(form, url) = capabilities

  []
  |> append_optional("form", option_map(form, codec_encode.encode_value))
  |> append_optional("url", option_map(url, codec_encode.encode_value))
  |> codec_value.object
}

fn encode_client_tasks_capabilities(
  capabilities: actions.ClientTasksCapabilities,
) -> jsonrpc.Value {
  let actions.ClientTasksCapabilities(list, cancel, requests) = capabilities

  []
  |> append_optional("list", option_map(list, codec_encode.encode_value))
  |> append_optional("cancel", option_map(cancel, codec_encode.encode_value))
  |> append_optional(
    "requests",
    option_map(requests, encode_client_task_request_capabilities),
  )
  |> codec_value.object
}

fn encode_client_task_request_capabilities(
  capabilities: actions.ClientTaskRequestCapabilities,
) -> jsonrpc.Value {
  let actions.ClientTaskRequestCapabilities(
    sampling_create_message,
    elicitation_create,
  ) = capabilities

  []
  |> append_optional("sampling", case sampling_create_message {
    Some(value) ->
      Some(
        codec_value.object([
          #("createMessage", codec_encode.encode_value(value)),
        ]),
      )
    None -> None
  })
  |> append_optional("elicitation", case elicitation_create {
    Some(value) ->
      Some(codec_value.object([#("create", codec_encode.encode_value(value))]))
    None -> None
  })
  |> codec_value.object
}

fn encode_task_metadata(metadata: actions.TaskMetadata) -> jsonrpc.Value {
  let actions.TaskMetadata(ttl_ms) = metadata

  []
  |> append_optional("ttl", option_map(ttl_ms, codec_value.int))
  |> codec_value.object
}

fn encode_completion_ref(ref: actions.CompletionRef) -> jsonrpc.Value {
  case ref {
    actions.PromptRef(name, title) ->
      [
        #("type", codec_value.string("ref/prompt")),
        #("name", codec_value.string(name)),
      ]
      |> append_optional("title", option_map(title, codec_value.string))
      |> codec_value.object
    actions.ResourceTemplateRef(uri) ->
      codec_value.object([
        #("type", codec_value.string("ref/resource")),
        #("uri", codec_value.string(uri)),
      ])
  }
}

fn encode_complete_argument(
  argument: actions.CompleteArgument,
) -> jsonrpc.Value {
  let actions.CompleteArgument(name, value) = argument
  codec_value.object([
    #("name", codec_value.string(name)),
    #("value", codec_value.string(value)),
  ])
}

fn encode_complete_context(context: actions.CompleteContext) -> jsonrpc.Value {
  let actions.CompleteContext(arguments) = context

  []
  |> append_optional(
    "arguments",
    option_map(arguments, fn(arguments) {
      dict.to_list(arguments)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, codec_value.string(value))
      })
      |> codec_value.object
    }),
  )
  |> codec_value.object
}

fn encode_logging_level(level: actions.LoggingLevel) -> jsonrpc.Value {
  codec_value.string(logging_level_string(level))
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

fn encode_model_preferences(
  preferences: actions.ModelPreferences,
) -> jsonrpc.Value {
  let actions.ModelPreferences(
    hints,
    cost_priority,
    speed_priority,
    intelligence_priority,
  ) = preferences

  []
  |> append_optional("hints", case hints {
    [] -> None
    _ -> Some(codec_value.array(hints, encode_model_hint))
  })
  |> append_optional(
    "costPriority",
    option_map(cost_priority, codec_value.float),
  )
  |> append_optional(
    "speedPriority",
    option_map(speed_priority, codec_value.float),
  )
  |> append_optional(
    "intelligencePriority",
    option_map(intelligence_priority, codec_value.float),
  )
  |> codec_value.object
}

fn encode_model_hint(hint: actions.ModelHint) -> jsonrpc.Value {
  let actions.ModelHint(name) = hint
  []
  |> append_optional("name", option_map(name, codec_value.string))
  |> codec_value.object
}

fn encode_include_context(context: actions.IncludeContext) -> jsonrpc.Value {
  case context {
    actions.NoContext -> codec_value.string("none")
    actions.ThisServerContext -> codec_value.string("thisServer")
    actions.AllServersContext -> codec_value.string("allServers")
  }
}

fn encode_sampling_message(message: actions.SamplingMessage) -> jsonrpc.Value {
  let actions.SamplingMessage(role, content, meta) = message

  [#("role", encode_role(role)), #("content", encode_sampling_content(content))]
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_sampling_content(content: actions.SamplingContent) -> jsonrpc.Value {
  case content {
    actions.SingleSamplingContent(block) ->
      codec_encode.encode_sampling_message_content_block(block)
    actions.MultipleSamplingContent(blocks) ->
      codec_value.array(
        blocks,
        codec_encode.encode_sampling_message_content_block,
      )
  }
}

fn encode_tool_choice(choice: actions.ToolChoice) -> jsonrpc.Value {
  let actions.ToolChoice(mode) = choice

  []
  |> append_optional(
    "mode",
    option_map(mode, fn(mode) {
      case mode {
        actions.ToolAuto -> codec_value.string("auto")
        actions.ToolRequired -> codec_value.string("required")
        actions.ToolNone -> codec_value.string("none")
      }
    }),
  )
  |> codec_value.object
}

fn encode_role(role: actions.Role) -> jsonrpc.Value {
  case role {
    actions.User -> codec_value.string("user")
    actions.Assistant -> codec_value.string("assistant")
  }
}

fn response_decoder(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> decode.Decoder(jsonrpc.Response(actions.ClientActionResult)) {
  case request {
    jsonrpc.Request(original_id, _, Some(action)) ->
      decode.then(codec_common.response_envelope_decoder(original_id), fn(_) {
        decode.one_of(
          result_response_decoder(original_id, action_result_decoder(action)),
          or: [error_response_decoder()],
        )
      })
    jsonrpc.Request(original_id, _, None) ->
      decode.then(codec_common.response_envelope_decoder(original_id), fn(_) {
        decode.one_of(
          result_response_decoder(original_id, empty_result_decoder()),
          or: [error_response_decoder()],
        )
      })
    jsonrpc.Notification(_, _) ->
      decode.failure(
        jsonrpc.ErrorResponse(None, jsonrpc.user_rejected_error()),
        expected: "JSON-RPC response",
      )
  }
}

fn server_response_decoder(
  request: jsonrpc.Request(actions.ServerActionRequest),
) -> decode.Decoder(jsonrpc.Response(actions.ServerActionResult)) {
  case request {
    jsonrpc.Request(original_id, _, Some(action)) ->
      decode.then(codec_common.response_envelope_decoder(original_id), fn(_) {
        decode.one_of(
          server_result_response_decoder(
            original_id,
            server_action_result_decoder(action),
          ),
          or: [server_error_response_decoder()],
        )
      })
    jsonrpc.Request(original_id, _, None) ->
      decode.then(codec_common.response_envelope_decoder(original_id), fn(_) {
        decode.one_of(
          server_result_response_decoder(
            original_id,
            server_empty_result_decoder(),
          ),
          or: [server_error_response_decoder()],
        )
      })
    jsonrpc.Notification(_, _) ->
      decode.failure(
        jsonrpc.ErrorResponse(None, jsonrpc.user_rejected_error()),
        expected: "JSON-RPC response",
      )
  }
}

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use _ <- decode.then(codec_common.request_envelope_decoder())
  use _ <- decode.then(codec_common.request_parameters_decoder())
  decode.then(decode.at(["method"], decode.string), fn(method) {
    case method {
      "notifications/tasks" ->
        decode_required_server_notification_message(
          mcp.method_notify_task,
          {
            use fields <- decode.then(codec_decode.value_dict_decoder())
            use meta <- decode.then(
              codec_decode.notification_meta_only_decoder(),
            )
            decode.success(actions.NotifyTaskModern(
              jsonrpc.VObject(dict.to_list(dict.delete(fields, "_meta"))),
              meta,
            ))
          },
          fn(notification) { notification },
        )
      "notifications/subscriptions/acknowledged" ->
        decode_required_server_notification_message(
          mcp.method_notify_subscriptions_acknowledged,
          {
            use notifications <- decode.field(
              "notifications",
              subscription_filter_decoder(),
            )
            use meta <- decode.then(
              codec_decode.notification_meta_only_decoder(),
            )
            decode.success(actions.NotifySubscriptionsAcknowledgedWithFilter(
              Some(notifications),
              meta,
            ))
          },
          fn(notification) { notification },
        )
      method if method == mcp.method_ping -> ping_message_decoder()
      method if method == mcp.method_list_roots -> list_roots_message_decoder()
      method if method == mcp.method_create_message ->
        create_message_message_decoder()
      method if method == mcp.method_elicit -> elicit_message_decoder()
      method if method == mcp.method_list_tasks -> list_tasks_message_decoder()
      method if method == mcp.method_get_task -> get_task_message_decoder()
      method if method == mcp.method_get_task_result ->
        get_task_result_message_decoder()
      method if method == mcp.method_cancel_task -> cancel_task_message_decoder()
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

fn ping_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_optional_server_request_message(
    mcp.method_ping,
    None,
    codec_decode.request_meta_only_decoder(),
    actions.ServerRequestPing,
  )
}

fn list_roots_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_optional_server_request_message(
    mcp.method_list_roots,
    None,
    codec_decode.request_meta_only_decoder(),
    actions.ServerRequestListRoots,
  )
}

fn create_message_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_request_message(
    mcp.method_create_message,
    create_message_request_params_decoder(),
    actions.ServerRequestCreateMessage,
  )
}

fn elicit_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_request_message(
    mcp.method_elicit,
    elicit_request_params_decoder(),
    actions.ServerRequestElicit,
  )
}

fn list_tasks_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_optional_server_request_message(
    mcp.method_list_tasks,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ServerRequestListTasks,
  )
}

fn get_task_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_request_message(
    mcp.method_get_task,
    codec_decode.task_id_params_decoder(),
    actions.ServerRequestGetTask,
  )
}

fn get_task_result_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_request_message(
    mcp.method_get_task_result,
    codec_decode.task_id_params_decoder(),
    actions.ServerRequestGetTaskResult,
  )
}

fn cancel_task_message_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_request_message(
    mcp.method_cancel_task,
    codec_decode.task_id_params_decoder(),
    actions.ServerRequestCancelTask,
  )
}

fn roots_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_meta_server_notification_message(
    mcp.method_notify_roots_list_changed,
    actions.NotifyRootsListChanged,
  )
}

fn cancelled_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_cancelled,
    cancelled_notification_params_decoder(),
    actions.NotifyCancelled,
  )
}

fn progress_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_progress,
    progress_notification_params_decoder(),
    actions.NotifyProgress,
  )
}

fn resource_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_meta_server_notification_message(
    mcp.method_notify_resource_list_changed,
    actions.NotifyResourceListChanged,
  )
}

fn resource_updated_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_resource_updated,
    resource_updated_notification_params_decoder(),
    actions.NotifyResourceUpdated,
  )
}

fn prompt_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_meta_server_notification_message(
    mcp.method_notify_prompts_list_changed,
    actions.NotifyPromptListChanged,
  )
}

fn tool_list_changed_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_meta_server_notification_message(
    mcp.method_notify_tools_list_changed,
    actions.NotifyToolListChanged,
  )
}

fn logging_message_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_logging_message,
    logging_message_notification_params_decoder(),
    actions.NotifyLoggingMessage,
  )
}

fn elicitation_complete_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_elicitation_complete,
    elicitation_complete_notification_params_decoder(),
    actions.NotifyElicitationComplete,
  )
}

fn task_status_notification_decoder() -> decode.Decoder(ServerMessage) {
  decode_required_server_notification_message(
    mcp.method_notify_task_status,
    task_status_notification_params_decoder(),
    actions.NotifyTaskStatus,
  )
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
        decode.optional(codec_decode.request_id_decoder()),
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

fn decode_required_server_request_message(
  method: String,
  decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ServerActionRequest,
) -> decode.Decoder(ServerMessage) {
  decode_server_request_message(method, required_params_decoder(decoder), wrap)
}

fn decode_optional_server_request_message(
  method: String,
  default: params,
  decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ServerActionRequest,
) -> decode.Decoder(ServerMessage) {
  decode_server_request_message(
    method,
    optional_params_decoder(default, decoder),
    wrap,
  )
}

fn decode_required_server_notification_message(
  method: String,
  decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ActionNotification,
) -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(
    method,
    decode.map(required_params_decoder(decoder), wrap),
  )
}

fn decode_meta_server_notification_message(
  method: String,
  wrap: fn(Option(actions.NotificationMeta)) -> actions.ActionNotification,
) -> decode.Decoder(ServerMessage) {
  decode_server_notification_message(
    method,
    decode.map(
      optional_params_decoder(
        None,
        codec_decode.notification_meta_only_decoder(),
      ),
      wrap,
    ),
  )
}

fn required_params_decoder(decoder: decode.Decoder(a)) -> decode.Decoder(a) {
  {
    use params <- decode.field("params", decoder)
    decode.success(params)
  }
}

fn optional_params_decoder(
  default: a,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  {
    use params <- decode.optional_field("params", default, decoder)
    decode.success(params)
  }
}

fn notification_method(notification: actions.ActionNotification) -> String {
  case notification {
    actions.NotifyTaskModern(_, _) -> mcp.method_notify_task
    actions.NotifySubscriptionsAcknowledged(_)
    | actions.NotifySubscriptionsAcknowledgedWithFilter(_, _) ->
      mcp.method_notify_subscriptions_acknowledged
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
      decode.optional(codec_decode.request_id_decoder()),
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
  wrap: fn(params) -> actions.ServerActionRequest,
) -> decode.Decoder(ServerMessage) {
  decode.then(decode.at(["id"], codec_decode.request_id_decoder()), fn(id) {
    decode.then(params_decoder, fn(params) {
      decode.success(
        ServerActionRequest(jsonrpc.Request(id, method, Some(wrap(params)))),
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
      decode.optional(codec_decode.request_id_decoder()),
    )
    use reason <- decode.optional_field(
      "reason",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.notification_meta_decoder()),
    )
    decode.success(actions.CancelledNotificationParams(request_id, reason, meta))
  }
}

fn progress_notification_params_decoder() -> decode.Decoder(
  actions.ProgressNotificationParams,
) {
  {
    use progress_token <- decode.field(
      "progressToken",
      codec_decode.request_id_decoder(),
    )
    use progress <- decode.field("progress", codec_decode.number_decoder())
    use total <- decode.optional_field(
      "total",
      None,
      decode.optional(codec_decode.number_decoder()),
    )
    use message <- decode.optional_field(
      "message",
      None,
      decode.optional(decode.string),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.notification_meta_decoder()),
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
      decode.optional(codec_decode.notification_meta_decoder()),
    )
    decode.success(actions.ResourceUpdatedNotificationParams(uri, meta))
  }
}

fn logging_message_notification_params_decoder() -> decode.Decoder(
  actions.LoggingMessageNotificationParams,
) {
  {
    use level <- decode.field("level", codec_decode.logging_level_decoder())
    use logger <- decode.optional_field(
      "logger",
      None,
      decode.optional(decode.string),
    )
    use data <- decode.field("data", value_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.notification_meta_decoder()),
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
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.notification_meta_decoder()),
    )
    decode.success(case meta {
      None -> actions.ElicitationCompleteNotificationParams(elicitation_id)
      Some(_) ->
        actions.ElicitationCompleteNotificationParamsWithMeta(
          elicitation_id,
          meta,
        )
    })
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
      decode.optional(codec_decode.notification_meta_decoder()),
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
  decoder result_decoder: decode.Decoder(actions.ClientActionResult),
) -> decode.Decoder(jsonrpc.Response(actions.ClientActionResult)) {
  successful_response_decoder(original_id, result_decoder)
}

fn error_response_decoder() -> decode.Decoder(
  jsonrpc.Response(actions.ClientActionResult),
) {
  failed_response_decoder()
}

fn server_result_response_decoder(
  original_id: jsonrpc.RequestId,
  decoder result_decoder: decode.Decoder(actions.ServerActionResult),
) -> decode.Decoder(jsonrpc.Response(actions.ServerActionResult)) {
  successful_response_decoder(original_id, result_decoder)
}

fn server_error_response_decoder() -> decode.Decoder(
  jsonrpc.Response(actions.ServerActionResult),
) {
  failed_response_decoder()
}

fn action_result_decoder(
  action: actions.ClientActionRequest,
) -> decode.Decoder(actions.ClientActionResult) {
  use result_type <- decode.optional_field(
    "resultType",
    None,
    decode.map(decode.string, Some),
  )
  case result_type {
    Some("input_required") ->
      decode.map(
        input_required_result_decoder(),
        actions.ClientResultInputRequired,
      )
    _ -> complete_action_result_decoder(action)
  }
}

fn complete_action_result_decoder(
  action: actions.ClientActionRequest,
) -> decode.Decoder(actions.ClientActionResult) {
  case action {
    actions.ClientRequestDiscover(_) ->
      decode.map(discover_result_decoder(), actions.ClientResultDiscover)
    actions.ClientRequestSubscriptionsListen(_) -> {
      use meta <- decode.optional_field(
        "_meta",
        None,
        decode.optional(meta_decoder()),
      )
      decode.success(
        actions.ClientResultSubscriptionsListen(
          actions.SubscriptionsListenResult(meta),
        ),
      )
    }
    actions.ClientRequestWithInput(inner, _, _) ->
      complete_action_result_decoder(inner)
    actions.ClientRequestUpdateTask(_) ->
      decode.map(value_decoder(), actions.ClientResultTaskModern)
    actions.ClientRequestInitialize(_) ->
      decode.map(initialize_result_decoder(), actions.ClientResultInitialize)
    actions.ClientRequestPing(_) -> empty_result_decoder()
    actions.ClientRequestListResources(_) ->
      decode.map(
        list_resources_result_decoder(),
        actions.ClientResultListResources,
      )
    actions.ClientRequestListResourceTemplates(_) ->
      decode.map(
        list_resource_templates_result_decoder(),
        actions.ClientResultListResourceTemplates,
      )
    actions.ClientRequestReadResource(_) ->
      decode.map(
        read_resource_result_decoder(),
        actions.ClientResultReadResource,
      )
    actions.ClientRequestSubscribeResource(_) -> empty_result_decoder()
    actions.ClientRequestUnsubscribeResource(_) -> empty_result_decoder()
    actions.ClientRequestListPrompts(_) ->
      decode.map(list_prompts_result_decoder(), actions.ClientResultListPrompts)
    actions.ClientRequestGetPrompt(_) ->
      decode.map(get_prompt_result_decoder(), actions.ClientResultGetPrompt)
    actions.ClientRequestListTools(_) ->
      decode.map(list_tools_result_decoder(), actions.ClientResultListTools)
    actions.ClientRequestCallTool(_) ->
      decode.one_of(
        decode.map(create_task_result_decoder(), actions.ClientResultCreateTask),
        or: [
          decode.map(call_tool_result_decoder(), actions.ClientResultCallTool),
        ],
      )
    actions.ClientRequestComplete(_) ->
      decode.map(complete_result_decoder(), actions.ClientResultComplete)
    actions.ClientRequestSetLoggingLevel(_) -> empty_result_decoder()
    actions.ClientRequestListTasks(_) ->
      decode.map(list_tasks_result_decoder(), actions.ClientResultListTasks)
    actions.ClientRequestGetTask(_) ->
      decode.map(get_task_result_decoder(), actions.ClientResultGetTask)
    actions.ClientRequestGetTaskResult(_) ->
      decode.map(task_result_decoder(), actions.ClientResultTaskResult)
    actions.ClientRequestCancelTask(_) ->
      decode.map(cancel_task_result_decoder(), actions.ClientResultCancelTask)
  }
}

fn discover_result_decoder() -> decode.Decoder(actions.DiscoverResult) {
  use versions <- decode.field("supportedVersions", decode.list(decode.string))
  use capabilities <- decode.field(
    "capabilities",
    codec_decode.value_dict_decoder(),
  )
  use instructions <- decode.optional_field(
    "instructions",
    None,
    decode.map(decode.string, Some),
  )
  use meta <- decode.optional_field(
    "_meta",
    None,
    decode.map(meta_decoder(), Some),
  )
  decode.success(actions.DiscoverResult(
    versions,
    capabilities,
    instructions,
    meta,
  ))
}

fn input_required_result_decoder() -> decode.Decoder(
  actions.InputRequiredResult,
) {
  use result_type <- decode.field("resultType", decode.string)
  case result_type {
    "input_required" -> {
      use requests <- decode.optional_field(
        "inputRequests",
        None,
        decode.map(codec_decode.value_dict_decoder(), Some),
      )
      use state <- decode.optional_field(
        "requestState",
        None,
        decode.map(decode.string, Some),
      )
      use meta <- decode.optional_field(
        "_meta",
        None,
        decode.map(meta_decoder(), Some),
      )
      case requests, state {
        None, None ->
          decode.failure(
            actions.InputRequiredResult(None, None, None),
            expected: "inputRequests or requestState",
          )
        _, _ ->
          decode.success(actions.InputRequiredResult(requests, state, meta))
      }
    }
    _ ->
      decode.failure(
        actions.InputRequiredResult(None, None, None),
        expected: "input_required resultType",
      )
  }
}

pub fn subscription_filter_decoder() -> decode.Decoder(jsonrpc.Value) {
  use fields <- decode.then(codec_decode.value_dict_decoder())
  use _tools <- decode.optional_field(
    "toolsListChanged",
    None,
    decode.map(decode.bool, Some),
  )
  use _prompts <- decode.optional_field(
    "promptsListChanged",
    None,
    decode.map(decode.bool, Some),
  )
  use _resources <- decode.optional_field(
    "resourcesListChanged",
    None,
    decode.map(decode.bool, Some),
  )
  use _subscriptions <- decode.optional_field(
    "resourceSubscriptions",
    None,
    decode.map(decode.list(decode.string), Some),
  )
  use _extensions <- decode.optional_field(
    "extensions",
    None,
    decode.map(
      decode.dict(decode.string, codec_decode.value_dict_decoder()),
      Some,
    ),
  )
  decode.success(jsonrpc.VObject(dict.to_list(fields)))
}

fn server_action_result_decoder(
  action: actions.ServerActionRequest,
) -> decode.Decoder(actions.ServerActionResult) {
  case action {
    actions.ServerRequestPing(_) -> server_empty_result_decoder()
    actions.ServerRequestListRoots(_) ->
      decode.map(list_roots_result_decoder(), actions.ServerResultListRoots)
    actions.ServerRequestCreateMessage(params) ->
      case params.task {
        Some(_) ->
          decode.one_of(
            decode.map(
              create_message_result_decoder(),
              actions.ServerResultCreateMessage,
            ),
            or: [
              decode.map(
                create_task_result_decoder(),
                actions.ServerResultCreateTask,
              ),
            ],
          )
        None ->
          decode.map(
            create_message_result_decoder(),
            actions.ServerResultCreateMessage,
          )
      }
    actions.ServerRequestElicit(_) ->
      decode.one_of(
        decode.map(create_task_result_decoder(), actions.ServerResultCreateTask),
        or: [decode.map(elicit_result_decoder(), actions.ServerResultElicit)],
      )
    actions.ServerRequestListTasks(_) ->
      decode.map(list_tasks_result_decoder(), actions.ServerResultListTasks)
    actions.ServerRequestGetTask(_) ->
      decode.map(get_task_result_decoder(), actions.ServerResultGetTask)
    actions.ServerRequestGetTaskResult(_) ->
      decode.map(task_result_decoder(), actions.ServerResultTaskResult)
    actions.ServerRequestCancelTask(_) ->
      decode.map(cancel_task_result_decoder(), actions.ServerResultCancelTask)
  }
}

fn empty_result_decoder() -> decode.Decoder(actions.ClientActionResult) {
  meta_result_decoder(actions.ClientResultEmpty)
}

fn server_empty_result_decoder() -> decode.Decoder(actions.ServerActionResult) {
  meta_result_decoder(actions.ServerResultEmpty)
}

fn successful_response_decoder(
  _original_id: jsonrpc.RequestId,
  result_decoder: decode.Decoder(result),
) -> decode.Decoder(jsonrpc.Response(result)) {
  {
    use version <- decode.field("jsonrpc", decode.string)
    use id <- decode.field("id", codec_decode.request_id_decoder())
    use result <- decode.field("result", result_decoder)
    let _ = version
    decode.success(jsonrpc.ResultResponse(id, result))
  }
}

fn failed_response_decoder() -> decode.Decoder(jsonrpc.Response(result)) {
  {
    use version <- decode.field("jsonrpc", decode.string)
    use id <- decode.field(
      "id",
      decode.optional(codec_decode.request_id_decoder()),
    )
    use error <- decode.field("error", codec_decode.error_decoder())
    let _ = version
    decode.success(jsonrpc.ErrorResponse(id, error))
  }
}

fn meta_result_decoder(
  wrap: fn(Option(actions.Meta)) -> result,
) -> decode.Decoder(result) {
  decode.map(meta_only_decoder(), wrap)
}

fn initialize_result_decoder() -> decode.Decoder(actions.InitializeResult) {
  {
    use protocol_version <- decode.field("protocolVersion", decode.string)
    use capabilities <- decode.field(
      "capabilities",
      server_capabilities_decoder(),
    )
    use server_info <- decode.field(
      "serverInfo",
      codec_decode.implementation_decoder(),
    )
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
      decode.map(value_decoder(), Some),
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
  decode.one_of(legacy_create_message_result_decoder(), or: [
    standard_create_message_result_decoder(),
  ])
}

fn standard_create_message_result_decoder() -> decode.Decoder(
  actions.CreateMessageResult,
) {
  {
    use role <- decode.field("role", role_decoder())
    use content <- decode.field("content", sampling_content_decoder())
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
      message: actions.SamplingMessage(role, content, None),
      model: model,
      stop_reason: stop_reason,
      meta: meta,
    ))
  }
}

fn legacy_create_message_result_decoder() -> decode.Decoder(
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
      decode.optional(codec_decode.number_decoder()),
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
      decode.optional(codec_decode.task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.request_meta_decoder()),
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
      decode.optional(codec_decode.request_meta_decoder()),
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
      decode.map(decode.string, Some),
    )
    case mode {
      Some("url") ->
        decode.map(
          elicit_request_url_params_decoder(),
          actions.ElicitRequestUrl,
        )
      None | Some("form") ->
        decode.map(
          elicit_request_form_params_decoder(),
          actions.ElicitRequestForm,
        )
      Some(_) ->
        decode.failure(
          actions.ElicitRequestForm(actions.ElicitRequestFormParams(
            "",
            jsonrpc.VObject([]),
            None,
            None,
          )),
          expected: "Elicitation mode form or url",
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
      decode.optional(codec_decode.task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.request_meta_decoder()),
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
    use elicitation_id <- decode.optional_field(
      "elicitationId",
      None,
      decode.map(decode.string, Some),
    )
    use url <- decode.field("url", decode.string)
    use task <- decode.optional_field(
      "task",
      None,
      decode.optional(codec_decode.task_metadata_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.request_meta_decoder()),
    )
    decode.success(case elicitation_id {
      Some(id) -> actions.ElicitRequestUrlParams(message, id, url, task, meta)
      None -> actions.ElicitRequestUrlParamsWithoutId(message, url, task, meta)
    })
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
      decode.optional(codec_decode.number_decoder()),
    )
    use speed_priority <- decode.optional_field(
      "speedPriority",
      None,
      decode.optional(codec_decode.number_decoder()),
    )
    use intelligence_priority <- decode.optional_field(
      "intelligencePriority",
      None,
      decode.optional(codec_decode.number_decoder()),
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
    decode.map(create_message_result_decoder(), actions.TaskCreateMessage),
    or: [
      decode.map(elicit_result_decoder(), actions.TaskElicit),
      decode.map(call_tool_result_decoder(), actions.TaskCallTool),
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

fn server_capabilities_decoder() -> decode.Decoder(actions.ServerCapabilities) {
  {
    use experimental <- decode.optional_field(
      "experimental",
      None,
      decode.optional(codec_decode.value_dict_decoder()),
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
      decode.list(of: codec_decode.icon_decoder()),
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
      decode.list(of: codec_decode.icon_decoder()),
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
      decode.list(of: codec_decode.icon_decoder()),
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
    use input_schema <- decode.field("inputSchema", tool_input_schema_decoder())
    use execution <- decode.optional_field(
      "execution",
      None,
      decode.optional(tool_execution_decoder()),
    )
    use output_schema <- decode.optional_field(
      "outputSchema",
      None,
      decode.optional(schema_object_decoder()),
    )
    use annotations <- decode.optional_field(
      "annotations",
      None,
      decode.optional(tool_annotations_decoder()),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: codec_decode.icon_decoder()),
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

fn tool_input_schema_decoder() -> decode.Decoder(jsonrpc.Value) {
  use fields <- decode.then(codec_decode.value_dict_decoder())
  use schema_type <- decode.field("type", decode.string)
  case schema_type {
    "object" -> decode.success(jsonrpc.VObject(dict.to_list(fields)))
    _ ->
      decode.failure(
        jsonrpc.VObject([]),
        expected: "JSON Schema with type object",
      )
  }
}

fn schema_object_decoder() -> decode.Decoder(jsonrpc.Value) {
  use fields <- decode.then(codec_decode.value_dict_decoder())
  decode.success(jsonrpc.VObject(dict.to_list(fields)))
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
      decode.optional(codec_decode.number_decoder()),
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
    use input <- decode.field("input", codec_decode.value_dict_decoder())
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
      decode.map(value_decoder(), Some),
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
    decode.map(codec_decode.number_decoder(), actions.ElicitFloat),
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
  decode.map(codec_decode.value_dict_decoder(), actions.Meta)
}

pub fn value_decoder() -> decode.Decoder(jsonrpc.Value) {
  codec_decode.value_decoder()
}

fn append_optional(
  fields: List(#(String, jsonrpc.Value)),
  key: String,
  value: Option(jsonrpc.Value),
) -> List(#(String, jsonrpc.Value)) {
  case value {
    Some(value) -> list.append(fields, [#(key, value)])
    None -> fields
  }
}

fn prepend_optional(
  fields: List(#(String, jsonrpc.Value)),
  key: String,
  value: Option(jsonrpc.Value),
) -> List(#(String, jsonrpc.Value)) {
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
