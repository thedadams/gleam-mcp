import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc
import gleam_mcp/mcp

pub type Message {
  ClientActionRequest(jsonrpc.Request(actions.ClientActionRequest))
  ActionNotification(jsonrpc.Request(actions.ActionNotification))
  UnknownRequest(id: jsonrpc.RequestId, method: String)
  UnknownNotification(method: String)
}

pub fn decode_message(body: String) -> Result(Message, String) {
  json.parse(body, message_decoder()) |> result.map_error(json_error_message)
}

pub fn encode_response(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> String {
  response |> encode_client_jsonrpc_response |> json.to_string
}

pub fn encode_server_response(
  response: jsonrpc.Response(actions.ServerActionResult),
) -> String {
  response |> encode_server_jsonrpc_response |> json.to_string
}

fn message_decoder() -> decode.Decoder(Message) {
  decode.then(decode.at(["method"], decode.string), fn(method) {
    case method {
      "initialize" -> initialize_message_decoder()
      "ping" -> ping_message_decoder()
      "resources/list" -> list_resources_message_decoder()
      "resources/templates/list" -> list_resource_templates_message_decoder()
      "resources/read" -> read_resource_message_decoder()
      "prompts/list" -> list_prompts_message_decoder()
      "prompts/get" -> get_prompt_message_decoder()
      "tools/list" -> list_tools_message_decoder()
      "tools/call" -> call_tool_message_decoder()
      "tasks/list" -> list_tasks_message_decoder()
      "tasks/get" -> get_task_message_decoder()
      "tasks/result" -> get_task_result_message_decoder()
      "tasks/cancel" -> cancel_task_message_decoder()
      "completion/complete" -> complete_message_decoder()
      "logging/setLevel" -> set_logging_level_message_decoder()
      "notifications/initialized" -> initialized_notification_decoder()
      _ -> unknown_message_decoder(method)
    }
  })
}

fn initialize_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_initialize,
    initialize_request_params_decoder(),
    actions.ClientRequestInitialize,
  )
}

fn ping_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_ping,
    None,
    decode.optional(request_meta_decoder()),
    actions.ClientRequestPing,
  )
}

fn list_resources_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_list_resources,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ClientRequestListResources,
  )
}

fn list_resource_templates_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_list_resource_templates,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ClientRequestListResourceTemplates,
  )
}

fn read_resource_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_read_resource,
    read_resource_request_params_decoder(),
    actions.ClientRequestReadResource,
  )
}

fn list_prompts_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_list_prompts,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ClientRequestListPrompts,
  )
}

fn get_prompt_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_get_prompt,
    get_prompt_request_params_decoder(),
    actions.ClientRequestGetPrompt,
  )
}

fn list_tools_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_list_tools,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ClientRequestListTools,
  )
}

fn call_tool_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_call_tool,
    call_tool_request_params_decoder(),
    actions.ClientRequestCallTool,
  )
}

fn complete_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_complete,
    complete_request_params_decoder(),
    actions.ClientRequestComplete,
  )
}

fn list_tasks_message_decoder() -> decode.Decoder(Message) {
  decode_optional_request_message(
    mcp.method_list_tasks,
    actions.PaginatedRequestParams(None, None),
    paginated_request_params_decoder(),
    actions.ClientRequestListTasks,
  )
}

fn get_task_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_get_task,
    task_id_params_decoder(),
    actions.ClientRequestGetTask,
  )
}

fn get_task_result_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_get_task_result,
    task_id_params_decoder(),
    actions.ClientRequestGetTaskResult,
  )
}

fn cancel_task_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_cancel_task,
    task_id_params_decoder(),
    actions.ClientRequestCancelTask,
  )
}

fn set_logging_level_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_set_logging_level,
    set_level_request_params_decoder(),
    actions.ClientRequestSetLoggingLevel,
  )
}

fn initialized_notification_decoder() -> decode.Decoder(Message) {
  decode_meta_notification_message(
    mcp.method_initialized,
    actions.NotifyInitialized,
  )
}

fn unknown_message_decoder(method: String) -> decode.Decoder(Message) {
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

fn decode_request_message(
  method: String,
  params_decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ClientActionRequest,
) -> decode.Decoder(Message) {
  decode.then(decode.at(["id"], request_id_decoder()), fn(id) {
    decode.then(params_decoder, fn(params) {
      decode.success(
        ClientActionRequest(jsonrpc.Request(id, method, Some(wrap(params)))),
      )
    })
  })
}

fn decode_required_request_message(
  method: String,
  decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ClientActionRequest,
) -> decode.Decoder(Message) {
  decode_request_message(method, required_params_decoder(decoder), wrap)
}

fn decode_optional_request_message(
  method: String,
  default: params,
  decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ClientActionRequest,
) -> decode.Decoder(Message) {
  decode_request_message(
    method,
    optional_params_decoder(default, decoder),
    wrap,
  )
}

fn decode_meta_notification_message(
  method: String,
  wrap: fn(Option(actions.NotificationMeta)) -> actions.ActionNotification,
) -> decode.Decoder(Message) {
  decode_notification_message(
    method,
    optional_params_decoder(None, notification_meta_only_decoder()),
    wrap,
  )
}

fn decode_notification_message(
  method: String,
  params_decoder: decode.Decoder(params),
  wrap: fn(params) -> actions.ActionNotification,
) -> decode.Decoder(Message) {
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
      decode.then(params_decoder, fn(params) {
        case id {
          Some(request_id) -> decode.success(UnknownRequest(request_id, method))
          None ->
            decode.success(
              ActionNotification(jsonrpc.Notification(method, Some(wrap(params)))),
            )
        }
      })
    },
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

fn encode_client_jsonrpc_response(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> json.Json {
  encode_jsonrpc_response(response, encode_client_action_result)
}

fn encode_server_jsonrpc_response(
  response: jsonrpc.Response(actions.ServerActionResult),
) -> json.Json {
  encode_jsonrpc_response(response, encode_server_action_result)
}

fn encode_jsonrpc_response(
  response: jsonrpc.Response(result),
  encode_result: fn(result) -> json.Json,
) -> json.Json {
  case response {
    jsonrpc.ResultResponse(id, result) ->
      json.object([
        #("jsonrpc", json.string(jsonrpc.jsonrpc_version)),
        #("id", encode_request_id(id)),
        #("result", encode_result(result)),
      ])
    jsonrpc.ErrorResponse(id, error) ->
      [#("jsonrpc", json.string(jsonrpc.jsonrpc_version))]
      |> append_optional("id", option_map(id, encode_request_id))
      |> append_optional("error", Some(encode_error(error)))
      |> json.object
  }
}

fn encode_client_action_result(result: actions.ClientActionResult) -> json.Json {
  case result {
    actions.ClientResultEmpty(meta) -> encode_meta_only(meta)
    actions.ClientResultInitialize(value) -> encode_initialize_result(value)
    actions.ClientResultListResources(value) ->
      encode_list_resources_result(value)
    actions.ClientResultListResourceTemplates(value) ->
      encode_list_resource_templates_result(value)
    actions.ClientResultReadResource(value) ->
      encode_read_resource_result(value)
    actions.ClientResultListPrompts(value) -> encode_list_prompts_result(value)
    actions.ClientResultGetPrompt(value) -> encode_get_prompt_result(value)
    actions.ClientResultListTools(value) -> encode_list_tools_result(value)
    actions.ClientResultCallTool(value) -> encode_call_tool_result(value)
    actions.ClientResultComplete(value) -> encode_complete_result(value)
    actions.ClientResultCreateTask(value) -> encode_create_task_result(value)
    actions.ClientResultGetTask(value) -> encode_get_task_result(value)
    actions.ClientResultTaskResult(value) -> encode_task_result(value)
    actions.ClientResultCancelTask(value) -> encode_cancel_task_result(value)
    actions.ClientResultListTasks(value) -> encode_list_tasks_result(value)
  }
}

fn encode_root(root: actions.Root) -> json.Json {
  let actions.Root(uri, name, meta) = root
  [#("uri", json.string(uri))]
  |> append_optional("name", option_map(name, json.string))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_list_roots_result(result: actions.ListRootsResult) -> json.Json {
  let actions.ListRootsResult(roots, meta) = result
  [#("roots", json.array(roots, encode_root))]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_server_action_result(result: actions.ServerActionResult) -> json.Json {
  case result {
    actions.ServerResultEmpty(meta) -> encode_meta_only(meta)
    actions.ServerResultListRoots(value) -> encode_list_roots_result(value)
    actions.ServerResultCreateMessage(value) ->
      encode_create_message_result(value)
    actions.ServerResultElicit(value) -> encode_elicit_result(value)
    actions.ServerResultCreateTask(value) -> encode_create_task_result(value)
    actions.ServerResultGetTask(value) -> encode_get_task_result(value)
    actions.ServerResultTaskResult(value) -> encode_task_result(value)
    actions.ServerResultCancelTask(value) -> encode_cancel_task_result(value)
    actions.ServerResultListTasks(value) -> encode_list_tasks_result(value)
  }
}

fn encode_meta_only(meta: Option(actions.Meta)) -> json.Json {
  case meta {
    Some(value) -> json.object([#("_meta", encode_meta(value))])
    None -> json.object([])
  }
}

fn encode_initialize_result(result: actions.InitializeResult) -> json.Json {
  let actions.InitializeResult(
    protocol_version,
    capabilities,
    server_info,
    instructions,
    meta,
  ) = result

  [
    #("protocolVersion", json.string(protocol_version)),
    #("capabilities", encode_server_capabilities(capabilities)),
    #("serverInfo", encode_implementation(server_info)),
  ]
  |> append_optional("instructions", option_map(instructions, json.string))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_server_capabilities(
  capabilities: actions.ServerCapabilities,
) -> json.Json {
  let actions.ServerCapabilities(
    experimental,
    logging,
    completions,
    prompts,
    resources,
    tools,
    tasks,
  ) = capabilities

  []
  |> append_optional(
    "experimental",
    option_map(experimental, fn(fields) {
      dict.to_list(fields)
      |> list.map(fn(entry) {
        let #(key, value) = entry
        #(key, encode_value(value))
      })
      |> json.object
    }),
  )
  |> append_optional("logging", option_map(logging, encode_value))
  |> append_optional("completions", option_map(completions, encode_value))
  |> append_optional(
    "prompts",
    option_map(prompts, encode_server_prompts_capabilities),
  )
  |> append_optional(
    "resources",
    option_map(resources, encode_server_resources_capabilities),
  )
  |> append_optional(
    "tools",
    option_map(tools, encode_server_tools_capabilities),
  )
  |> append_optional(
    "tasks",
    option_map(tasks, encode_server_tasks_capabilities),
  )
  |> json.object
}

fn encode_server_prompts_capabilities(
  capabilities: actions.ServerPromptsCapabilities,
) -> json.Json {
  let actions.ServerPromptsCapabilities(list_changed) = capabilities
  []
  |> append_optional("listChanged", option_map(list_changed, json.bool))
  |> json.object
}

fn encode_server_resources_capabilities(
  capabilities: actions.ServerResourcesCapabilities,
) -> json.Json {
  let actions.ServerResourcesCapabilities(subscribe, list_changed) =
    capabilities
  []
  |> append_optional("subscribe", option_map(subscribe, json.bool))
  |> append_optional("listChanged", option_map(list_changed, json.bool))
  |> json.object
}

fn encode_server_tools_capabilities(
  capabilities: actions.ServerToolsCapabilities,
) -> json.Json {
  let actions.ServerToolsCapabilities(list_changed) = capabilities
  []
  |> append_optional("listChanged", option_map(list_changed, json.bool))
  |> json.object
}

fn encode_server_tasks_capabilities(
  capabilities: actions.ServerTasksCapabilities,
) -> json.Json {
  let actions.ServerTasksCapabilities(list, cancel, requests) = capabilities
  []
  |> append_optional("list", option_map(list, encode_value))
  |> append_optional("cancel", option_map(cancel, encode_value))
  |> append_optional(
    "requests",
    option_map(requests, encode_server_task_request_capabilities),
  )
  |> json.object
}

fn encode_server_task_request_capabilities(
  capabilities: actions.ServerTaskRequestCapabilities,
) -> json.Json {
  let actions.ServerTaskRequestCapabilities(tools_call) = capabilities
  []
  |> append_optional("tools", case tools_call {
    Some(value) -> Some(json.object([#("call", encode_value(value))]))
    None -> None
  })
  |> json.object
}

fn encode_list_resources_result(
  result: actions.ListResourcesResult,
) -> json.Json {
  let actions.ListResourcesResult(resources, page, meta) = result
  [#("resources", json.array(resources, encode_resource))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_list_resource_templates_result(
  result: actions.ListResourceTemplatesResult,
) -> json.Json {
  let actions.ListResourceTemplatesResult(resource_templates, page, meta) =
    result
  [
    #(
      "resourceTemplates",
      json.array(resource_templates, encode_resource_template),
    ),
  ]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_read_resource_result(result: actions.ReadResourceResult) -> json.Json {
  let actions.ReadResourceResult(contents, meta) = result
  [#("contents", json.array(contents, encode_resource_contents))]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_list_prompts_result(result: actions.ListPromptsResult) -> json.Json {
  let actions.ListPromptsResult(prompts, page, meta) = result
  [#("prompts", json.array(prompts, encode_prompt))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_get_prompt_result(result: actions.GetPromptResult) -> json.Json {
  let actions.GetPromptResult(description, messages, meta) = result
  [#("messages", json.array(messages, encode_prompt_message))]
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_list_tools_result(result: actions.ListToolsResult) -> json.Json {
  let actions.ListToolsResult(tools, page, meta) = result
  [#("tools", json.array(tools, encode_tool))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_call_tool_result(result: actions.CallToolResult) -> json.Json {
  let actions.CallToolResult(content, structured_content, is_error, meta) =
    result
  [#("content", json.array(content, encode_content_block))]
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

fn encode_complete_result(result: actions.CompleteResult) -> json.Json {
  let actions.CompleteResult(completion, meta) = result
  [#("completion", encode_completion_values(completion))]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_create_task_result(result: actions.CreateTaskResult) -> json.Json {
  let actions.CreateTaskResult(task, meta) = result
  [#("task", encode_task(task))]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_get_task_result(result: actions.GetTaskResult) -> json.Json {
  let actions.GetTaskResult(task, meta) = result
  task_fields(task)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_task_result(result: actions.TaskResult) -> json.Json {
  case result {
    actions.TaskCallTool(value) -> encode_call_tool_result(value)
    actions.TaskCreateMessage(value) -> encode_create_message_result(value)
    actions.TaskElicit(value) -> encode_elicit_result(value)
  }
}

fn encode_cancel_task_result(result: actions.CancelTaskResult) -> json.Json {
  let actions.CancelTaskResult(task, meta) = result
  task_fields(task)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_list_tasks_result(result: actions.ListTasksResult) -> json.Json {
  let actions.ListTasksResult(tasks, page, meta) = result
  [#("tasks", json.array(tasks, encode_task))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_create_message_result(
  result: actions.CreateMessageResult,
) -> json.Json {
  let actions.CreateMessageResult(message, model, stop_reason, meta) = result
  let actions.SamplingMessage(role, content, _) = message
  let content = case content {
    actions.SingleSamplingContent(block) -> block
    actions.MultipleSamplingContent([block, ..]) -> block
    actions.MultipleSamplingContent([]) ->
      actions.SamplingText(actions.TextContent("", None, None))
  }

  [
    #("role", encode_role(role)),
    #("content", encode_sampling_message_content_block(content)),
    #("model", json.string(model)),
  ]
  |> append_optional("stopReason", option_map(stop_reason, json.string))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_elicit_result(result: actions.ElicitResult) -> json.Json {
  let actions.ElicitResult(action, content, meta) = result
  [#("action", encode_elicit_action(action))]
  |> append_optional("content", option_map(content, encode_elicit_content))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_sampling_message_content_block(
  block: actions.SamplingMessageContentBlock,
) -> json.Json {
  codec_common.encode_sampling_message_content_block(block)
}

fn encode_elicit_action(action: actions.ElicitAction) -> json.Json {
  case action {
    actions.ElicitAccept -> json.string("accept")
    actions.ElicitDecline -> json.string("decline")
    actions.ElicitCancel -> json.string("cancel")
  }
}

fn encode_elicit_content(
  content: dict.Dict(String, actions.ElicitValue),
) -> json.Json {
  content
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(key, value) = entry
    #(key, encode_elicit_value(value))
  })
  |> json.object
}

fn encode_elicit_value(value: actions.ElicitValue) -> json.Json {
  case value {
    actions.ElicitString(value) -> json.string(value)
    actions.ElicitInt(value) -> json.int(value)
    actions.ElicitFloat(value) -> json.float(value)
    actions.ElicitBool(value) -> json.bool(value)
    actions.ElicitStringArray(value) -> json.array(value, json.string)
  }
}

fn encode_completion_values(values: actions.CompletionValues) -> json.Json {
  let actions.CompletionValues(entries, total, has_more) = values
  [#("values", json.array(entries, json.string))]
  |> append_optional("total", option_map(total, json.int))
  |> append_optional("hasMore", option_map(has_more, json.bool))
  |> json.object
}

fn append_page(
  fields: List(#(String, json.Json)),
  page: actions.Page,
) -> List(#(String, json.Json)) {
  let actions.Page(next_cursor) = page
  append_optional(fields, "nextCursor", option_map(next_cursor, encode_cursor))
}

fn encode_implementation(implementation: actions.Implementation) -> json.Json {
  codec_common.encode_implementation(implementation)
}

fn encode_icon(icon: actions.Icon) -> json.Json {
  codec_common.encode_icon(icon)
}

fn encode_resource(resource: actions.Resource) -> json.Json {
  codec_common.encode_resource(resource)
}

fn encode_resource_template(template: actions.ResourceTemplate) -> json.Json {
  let actions.ResourceTemplate(
    uri_template,
    name,
    title,
    description,
    mime_type,
    annotations,
    icons,
    meta,
  ) = template

  [#("uriTemplate", json.string(uri_template)), #("name", json.string(name))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(json.array(icons, encode_icon))
  })
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

fn encode_prompt(prompt: actions.Prompt) -> json.Json {
  let actions.Prompt(name, title, description, arguments, icons, meta) = prompt
  [#("name", json.string(name))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("arguments", case arguments {
    [] -> None
    _ -> Some(json.array(arguments, encode_prompt_argument))
  })
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(json.array(icons, encode_icon))
  })
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

fn encode_prompt_argument(argument: actions.PromptArgument) -> json.Json {
  let actions.PromptArgument(name, title, description, required) = argument
  [#("name", json.string(name))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("required", option_map(required, json.bool))
  |> json.object
}

fn encode_prompt_message(message: actions.PromptMessage) -> json.Json {
  let actions.PromptMessage(role, content) = message
  json.object([
    #("role", encode_role(role)),
    #("content", encode_content_block(content)),
  ])
}

fn encode_tool(tool: actions.Tool) -> json.Json {
  codec_common.encode_tool(tool)
}

fn encode_content_block(block: actions.ContentBlock) -> json.Json {
  codec_common.encode_content_block(block)
}

fn encode_annotations(annotations: actions.Annotations) -> json.Json {
  codec_common.encode_annotations(annotations)
}

fn encode_meta(meta: actions.Meta) -> json.Json {
  codec_common.encode_meta(meta)
}

fn encode_role(role: actions.Role) -> json.Json {
  case role {
    actions.User -> json.string("user")
    actions.Assistant -> json.string("assistant")
  }
}

fn encode_cursor(cursor: actions.Cursor) -> json.Json {
  codec_common.encode_cursor(cursor)
}

fn encode_task(task: actions.Task) -> json.Json {
  task_fields(task) |> json.object
}

fn encode_task_status(status: actions.TaskStatus) -> json.Json {
  codec_common.encode_task_status(status)
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

fn encode_error(error: jsonrpc.RpcError) -> json.Json {
  let jsonrpc.RpcError(code, message, data) = error
  [#("code", json.int(code)), #("message", json.string(message))]
  |> append_optional("data", option_map(data, encode_value))
  |> json.object
}

fn encode_value(value: jsonrpc.Value) -> json.Json {
  codec_common.encode_value(value)
}

fn encode_request_id(id: jsonrpc.RequestId) -> json.Json {
  codec_common.encode_request_id(id)
}

fn initialize_request_params_decoder() -> decode.Decoder(
  actions.InitializeRequestParams,
) {
  {
    use protocol_version <- decode.field("protocolVersion", decode.string)
    use capabilities <- decode.optional_field(
      "capabilities",
      actions.ClientCapabilities(None, None, None, None, None),
      client_capabilities_decoder(),
    )
    use client_info <- decode.field("clientInfo", implementation_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.InitializeRequestParams(
      protocol_version: protocol_version,
      capabilities: capabilities,
      client_info: client_info,
      meta: meta,
    ))
  }
}

fn client_capabilities_decoder() -> decode.Decoder(actions.ClientCapabilities) {
  {
    use experimental <- decode.optional_field(
      "experimental",
      None,
      decode.optional(value_dict_decoder()),
    )
    use roots <- decode.optional_field(
      "roots",
      None,
      decode.optional(client_roots_capabilities_decoder()),
    )
    use sampling <- decode.optional_field(
      "sampling",
      None,
      decode.optional(client_sampling_capabilities_decoder()),
    )
    use elicitation <- decode.optional_field(
      "elicitation",
      None,
      decode.optional(client_elicitation_capabilities_decoder()),
    )
    use tasks <- decode.optional_field(
      "tasks",
      None,
      decode.optional(client_tasks_capabilities_decoder()),
    )
    decode.success(actions.ClientCapabilities(
      experimental,
      roots,
      sampling,
      elicitation,
      tasks,
    ))
  }
}

fn client_roots_capabilities_decoder() -> decode.Decoder(
  actions.ClientRootsCapabilities,
) {
  {
    use list_changed <- decode.optional_field(
      "listChanged",
      None,
      decode.optional(decode.bool),
    )
    decode.success(actions.ClientRootsCapabilities(list_changed: list_changed))
  }
}

fn client_sampling_capabilities_decoder() -> decode.Decoder(
  actions.ClientSamplingCapabilities,
) {
  {
    use context <- decode.optional_field(
      "context",
      None,
      decode.optional(value_decoder()),
    )
    use tools <- decode.optional_field(
      "tools",
      None,
      decode.optional(value_decoder()),
    )
    decode.success(actions.ClientSamplingCapabilities(context, tools))
  }
}

fn client_elicitation_capabilities_decoder() -> decode.Decoder(
  actions.ClientElicitationCapabilities,
) {
  {
    use form <- decode.optional_field(
      "form",
      None,
      decode.optional(value_decoder()),
    )
    use url <- decode.optional_field(
      "url",
      None,
      decode.optional(value_decoder()),
    )
    decode.success(actions.ClientElicitationCapabilities(form, url))
  }
}

fn client_tasks_capabilities_decoder() -> decode.Decoder(
  actions.ClientTasksCapabilities,
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
      decode.optional(client_task_request_capabilities_decoder()),
    )
    decode.success(actions.ClientTasksCapabilities(list, cancel, requests))
  }
}

fn client_task_request_capabilities_decoder() -> decode.Decoder(
  actions.ClientTaskRequestCapabilities,
) {
  {
    use sampling_create_message <- decode.optional_field("sampling", None, {
      use create_message <- decode.optional_field(
        "createMessage",
        None,
        decode.optional(value_decoder()),
      )
      decode.success(create_message)
    })
    use elicitation_create <- decode.optional_field("elicitation", None, {
      use create <- decode.optional_field(
        "create",
        None,
        decode.optional(value_decoder()),
      )
      decode.success(create)
    })
    decode.success(actions.ClientTaskRequestCapabilities(
      sampling_create_message,
      elicitation_create,
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

fn read_resource_request_params_decoder() -> decode.Decoder(
  actions.ReadResourceRequestParams,
) {
  {
    use uri <- decode.field("uri", decode.string)
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.ReadResourceRequestParams(uri, meta))
  }
}

fn get_prompt_request_params_decoder() -> decode.Decoder(
  actions.GetPromptRequestParams,
) {
  {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.optional_field(
      "arguments",
      None,
      decode.optional(decode.dict(decode.string, decode.string)),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.GetPromptRequestParams(name, arguments, meta))
  }
}

fn call_tool_request_params_decoder() -> decode.Decoder(
  actions.CallToolRequestParams,
) {
  {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.optional_field(
      "arguments",
      None,
      decode.optional(value_dict_decoder()),
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
    decode.success(actions.CallToolRequestParams(name, arguments, task, meta))
  }
}

fn complete_request_params_decoder() -> decode.Decoder(
  actions.CompleteRequestParams,
) {
  {
    use ref <- decode.field("ref", completion_ref_decoder())
    use argument <- decode.field("argument", complete_argument_decoder())
    use context <- decode.optional_field(
      "context",
      None,
      decode.optional(complete_context_decoder()),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.CompleteRequestParams(ref, argument, context, meta))
  }
}

fn set_level_request_params_decoder() -> decode.Decoder(
  actions.SetLevelRequestParams,
) {
  {
    use level <- decode.field("level", logging_level_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(request_meta_decoder()),
    )
    decode.success(actions.SetLevelRequestParams(level, meta))
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

fn completion_ref_decoder() -> decode.Decoder(actions.CompletionRef) {
  decode.then(decode.at(["type"], decode.string), fn(kind) {
    case kind {
      "ref/prompt" -> {
        use name <- decode.field("name", decode.string)
        use title <- decode.optional_field(
          "title",
          None,
          decode.optional(decode.string),
        )
        decode.success(actions.PromptRef(name, title))
      }
      "ref/resource" -> {
        use uri <- decode.field("uri", decode.string)
        decode.success(actions.ResourceTemplateRef(uri))
      }
      _ ->
        decode.failure(
          actions.PromptRef("", None),
          expected: "Known completion ref type",
        )
    }
  })
}

fn complete_argument_decoder() -> decode.Decoder(actions.CompleteArgument) {
  {
    use name <- decode.field("name", decode.string)
    use value <- decode.field("value", decode.string)
    decode.success(actions.CompleteArgument(name, value))
  }
}

fn complete_context_decoder() -> decode.Decoder(actions.CompleteContext) {
  {
    use arguments <- decode.optional_field(
      "arguments",
      None,
      decode.optional(decode.dict(decode.string, decode.string)),
    )
    decode.success(actions.CompleteContext(arguments))
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

fn option_map(input: Option(a), fun: fn(a) -> b) -> Option(b) {
  case input {
    Some(value) -> Some(fun(value))
    None -> None
  }
}
