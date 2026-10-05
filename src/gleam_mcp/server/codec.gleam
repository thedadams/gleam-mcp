import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/codec_encode
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc
import gleam_mcp/mcp

pub type Message {
  ClientActionRequest(jsonrpc.Request(actions.ClientActionRequest))
  ActionNotification(jsonrpc.Request(actions.ActionNotification))
  UnknownRequest(id: jsonrpc.RequestId, method: String)
  UnknownNotification(method: String)
}

pub fn decode_message(body: String) -> Result(Message, String) {
  json.parse(body, message_decoder())
  |> result.map_error(codec_decode.json_error_message)
}

/// Decode incoming requests with JSON-RPC error classifications and recover
/// their request ID when possible. Transports should ignore notifications and
/// responses when deciding whether to send the returned error.
pub fn decode_message_with_error(
  body: String,
) -> Result(Message, codec_common.MessageDecodeError) {
  decode_message_diagnostic(body, None)
}

/// Classify removed methods before trying to decode their former parameters.
pub fn decode_message_with_error_for_version(
  body: String,
  version: String,
) -> Result(Message, codec_common.MessageDecodeError) {
  decode_message_diagnostic(body, Some(version))
}

fn decode_message_diagnostic(
  body: String,
  version: Option(String),
) -> Result(Message, codec_common.MessageDecodeError) {
  case json.parse(body, decode.dynamic) {
    Error(error) ->
      Error(codec_common.MessageDecodeError(
        None,
        jsonrpc.RpcError(-32_700, codec_decode.json_error_message(error), None),
      ))
    Ok(data) -> {
      let id =
        decode.run(data, {
          use id <- decode.optional_field(
            "id",
            None,
            decode.map(codec_decode.request_id_decoder(), Some),
          )
          decode.success(id)
        })
        |> result.unwrap(None)

      case decode.run(data, codec_common.request_envelope_decoder()) {
        Error(_) ->
          Error(codec_common.MessageDecodeError(
            id,
            jsonrpc.RpcError(-32_600, "Invalid JSON-RPC request", None),
          ))
        Ok(_) ->
          case decode.run(data, message_decoder_for_version(version)) {
            Ok(message) -> Ok(message)
            Error(error) -> {
              let method =
                decode.run(data, decode.at(["method"], decode.string))
                |> result.unwrap("")
              let code = case id, is_known_request_method(method) {
                None, True -> -32_600
                _, _ -> -32_602
              }
              Error(codec_common.MessageDecodeError(
                id,
                jsonrpc.RpcError(
                  code,
                  codec_decode.json_error_message(json.UnableToDecode(error)),
                  None,
                ),
              ))
            }
          }
      }
    }
  }
}

fn is_known_request_method(method: String) -> Bool {
  case method {
    "server/discover"
    | "subscriptions/listen"
    | "tasks/update"
    | "initialize"
    | "ping"
    | "resources/list"
    | "resources/templates/list"
    | "resources/read"
    | "resources/subscribe"
    | "resources/unsubscribe"
    | "prompts/list"
    | "prompts/get"
    | "tools/list"
    | "tools/call"
    | "tasks/list"
    | "tasks/get"
    | "tasks/result"
    | "tasks/cancel"
    | "completion/complete"
    | "logging/setLevel" -> True
    _ -> False
  }
}

pub fn encode_response(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> String {
  response |> encode_client_jsonrpc_response |> codec_value.to_string
}

/// Build the wire envelope without serializing it. Version-specific encoding
/// can decorate this value while keeping the legacy serializer unchanged.
pub fn encode_response_value(
  response: jsonrpc.Response(actions.ClientActionResult),
) -> jsonrpc.Value {
  encode_client_jsonrpc_response(response)
}

pub fn encode_client_action_result_value(
  result: actions.ClientActionResult,
) -> jsonrpc.Value {
  encode_client_action_result(result)
}

pub fn encode_server_response(
  response: jsonrpc.Response(actions.ServerActionResult),
) -> String {
  response |> encode_server_jsonrpc_response |> codec_value.to_string
}

fn message_decoder() -> decode.Decoder(Message) {
  message_decoder_for_version(None)
}

fn message_decoder_for_version(
  version: Option(String),
) -> decode.Decoder(Message) {
  use _ <- decode.then(codec_common.request_envelope_decoder())
  use _ <- decode.then(codec_common.request_parameters_decoder())
  let decoder =
    decode.then(decode.at(["method"], decode.string), fn(method) {
      case
        version == Some(jsonrpc.latest_protocol_version)
        && list.contains(mcp.removed_modern_methods, method)
      {
        True -> unknown_message_decoder(method)
        False -> {
          case method {
            "server/discover" ->
              decode_optional_request_message(
                mcp.method_discover,
                None,
                codec_decode.request_meta_only_decoder(),
                actions.ClientRequestDiscover,
              )
            "subscriptions/listen" ->
              decode_required_request_message(
                mcp.method_subscriptions_listen,
                subscriptions_listen_params_decoder(),
                actions.ClientRequestSubscriptionsListen,
              )
            "tasks/update" ->
              decode_required_request_message(
                mcp.method_update_task,
                task_update_params_decoder(),
                actions.ClientRequestUpdateTask,
              )
            "initialize" -> initialize_message_decoder()
            "ping" -> ping_message_decoder()
            "resources/list" -> list_resources_message_decoder()
            "resources/templates/list" ->
              list_resource_templates_message_decoder()
            "resources/read" -> read_resource_message_decoder()
            "resources/subscribe" -> subscribe_resource_message_decoder()
            "resources/unsubscribe" -> unsubscribe_resource_message_decoder()
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
            "notifications/cancelled"
            | "notifications/progress"
            | "notifications/roots/list_changed"
            | "notifications/tasks/status" ->
              client_notification_message_decoder()
            _ -> unknown_message_decoder(method)
          }
        }
      }
    })
  decode.then(decoder, attach_input_responses)
}

fn attach_input_responses(message: Message) -> decode.Decoder(Message) {
  use state <- decode.optional_field("params", None, {
    use state <- decode.optional_field(
      "requestState",
      None,
      decode.map(decode.string, Some),
    )
    decode.success(state)
  })
  use responses <- decode.optional_field("params", None, {
    use responses <- decode.optional_field(
      "inputResponses",
      None,
      decode.map(decode.dict(decode.string, codec_decode.value_decoder()), Some),
    )
    decode.success(responses)
  })
  case message, state, responses {
    _, None, None -> decode.success(message)
    ClientActionRequest(jsonrpc.Request(id, method, Some(action))), _, _
      if method != "tasks/update"
    ->
      decode.success(
        ClientActionRequest(jsonrpc.Request(
          id,
          method,
          Some(actions.ClientRequestWithInput(action, state, responses)),
        )),
      )
    _, _, _ -> decode.success(message)
  }
}

fn subscriptions_listen_params_decoder() -> decode.Decoder(
  actions.SubscriptionsListenParams,
) {
  use notifications <- decode.field(
    "notifications",
    client_codec.subscription_filter_decoder(),
  )
  use meta <- decode.then(codec_decode.request_meta_only_decoder())
  decode.success(actions.SubscriptionsListenParams(Some(notifications), meta))
}

fn task_update_params_decoder() -> decode.Decoder(actions.TaskUpdateParams) {
  use task_id <- decode.field("taskId", decode.string)
  use input <- decode.optional_field(
    "inputResponses",
    None,
    decode.map(
      decode.map(
        decode.dict(decode.string, codec_decode.value_decoder()),
        fn(fields) { jsonrpc.VObject(dict.to_list(fields)) },
      ),
      Some,
    ),
  )
  use meta <- decode.then(codec_decode.request_meta_only_decoder())
  decode.success(actions.TaskUpdateParams(task_id, input, meta))
}

fn client_notification_message_decoder() -> decode.Decoder(Message) {
  decode.then(client_codec.server_message_decoder(), fn(message) {
    case message {
      client_codec.ActionNotification(notification) ->
        decode.success(ActionNotification(notification))
      client_codec.UnknownRequest(id, method) ->
        decode.success(UnknownRequest(id, method))
      client_codec.UnknownNotification(method) ->
        decode.success(UnknownNotification(method))
      client_codec.ServerActionRequest(_) ->
        decode.failure(UnknownNotification(""), expected: "Client notification")
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
    codec_decode.request_meta_only_decoder(),
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

fn subscribe_resource_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_subscribe_resource,
    subscribe_resource_request_params_decoder(),
    actions.ClientRequestSubscribeResource,
  )
}

fn unsubscribe_resource_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_unsubscribe_resource,
    unsubscribe_resource_request_params_decoder(),
    actions.ClientRequestUnsubscribeResource,
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
    codec_decode.task_id_params_decoder(),
    actions.ClientRequestGetTask,
  )
}

fn get_task_result_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_get_task_result,
    codec_decode.task_id_params_decoder(),
    actions.ClientRequestGetTaskResult,
  )
}

fn cancel_task_message_decoder() -> decode.Decoder(Message) {
  decode_required_request_message(
    mcp.method_cancel_task,
    codec_decode.task_id_params_decoder(),
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
      decode.optional(codec_decode.request_id_decoder()),
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
  decode.then(decode.at(["id"], codec_decode.request_id_decoder()), fn(id) {
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
    optional_params_decoder(None, codec_decode.notification_meta_only_decoder()),
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
        decode.optional(codec_decode.request_id_decoder()),
      )
      decode.success(id)
    },
    fn(id) {
      decode.then(params_decoder, fn(params) {
        case id {
          Some(request_id) -> decode.success(UnknownRequest(request_id, method))
          None ->
            decode.success(
              ActionNotification(jsonrpc.Notification(
                method,
                Some(wrap(params)),
              )),
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
) -> jsonrpc.Value {
  encode_jsonrpc_response(response, encode_client_action_result)
}

fn encode_server_jsonrpc_response(
  response: jsonrpc.Response(actions.ServerActionResult),
) -> jsonrpc.Value {
  encode_jsonrpc_response(response, encode_server_action_result)
}

fn encode_jsonrpc_response(
  response: jsonrpc.Response(result),
  encode_result: fn(result) -> jsonrpc.Value,
) -> jsonrpc.Value {
  case response {
    jsonrpc.ResultResponse(id, result) ->
      codec_value.object([
        #("jsonrpc", codec_value.string(jsonrpc.jsonrpc_version)),
        #("id", codec_encode.encode_request_id(id)),
        #("result", encode_result(result)),
      ])
    jsonrpc.ErrorResponse(id, error) ->
      codec_value.object([
        #("jsonrpc", codec_value.string(jsonrpc.jsonrpc_version)),
        #("id", case id {
          Some(id) -> codec_encode.encode_request_id(id)
          None -> codec_value.null()
        }),
        #("error", encode_error(error)),
      ])
  }
}

fn encode_client_action_result(
  result: actions.ClientActionResult,
) -> jsonrpc.Value {
  case result {
    actions.ClientResultWithCache(inner, hint) ->
      encode_client_action_result(inner)
      |> codec_value.object_fields
      |> list.filter(fn(field) { field.0 != "ttlMs" && field.0 != "cacheScope" })
      |> list.append([
        #("ttlMs", codec_value.int(hint.ttl_ms)),
        #(
          "cacheScope",
          codec_value.string(case hint.scope {
            actions.Public -> "public"
            actions.Private -> "private"
          }),
        ),
      ])
      |> codec_value.object
    actions.ClientResultDiscover(value) ->
      [
        #(
          "supportedVersions",
          codec_value.array(value.supported_versions, codec_value.string),
        ),
        #(
          "capabilities",
          codec_encode.encode_value_object(dict.to_list(value.capabilities)),
        ),
      ]
      |> append_optional(
        "instructions",
        option_map(value.instructions, codec_value.string),
      )
      |> append_optional(
        "_meta",
        option_map(value.meta, codec_encode.encode_meta),
      )
      |> codec_value.object
    actions.ClientResultSubscriptionsListen(value) ->
      encode_meta_only(value.meta)
    actions.ClientResultInputRequired(value) ->
      [#("resultType", codec_value.string("input_required"))]
      |> append_optional(
        "inputRequests",
        option_map(value.input_requests, fn(fields) {
          codec_encode.encode_value_object(dict.to_list(fields))
        }),
      )
      |> append_optional(
        "requestState",
        option_map(value.request_state, codec_value.string),
      )
      |> append_optional(
        "_meta",
        option_map(value.meta, codec_encode.encode_meta),
      )
      |> codec_value.object
    actions.ClientResultTaskModern(value) -> codec_encode.encode_value(value)
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

pub fn encode_server_capabilities_value(
  capabilities: actions.ServerCapabilities,
) -> jsonrpc.Value {
  encode_server_capabilities(capabilities) |> codec_value.normalize
}

fn encode_root(root: actions.Root) -> jsonrpc.Value {
  let actions.Root(uri, name, meta) = root
  [#("uri", codec_value.string(uri))]
  |> append_optional("name", option_map(name, codec_value.string))
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_list_roots_result(result: actions.ListRootsResult) -> jsonrpc.Value {
  let actions.ListRootsResult(roots, meta) = result
  [#("roots", codec_value.array(roots, encode_root))]
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_server_action_result(
  result: actions.ServerActionResult,
) -> jsonrpc.Value {
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

fn encode_meta_only(meta: Option(actions.Meta)) -> jsonrpc.Value {
  case meta {
    Some(value) ->
      codec_value.object([#("_meta", codec_encode.encode_meta(value))])
    None -> codec_value.object([])
  }
}

fn encode_initialize_result(result: actions.InitializeResult) -> jsonrpc.Value {
  let actions.InitializeResult(
    protocol_version,
    capabilities,
    server_info,
    instructions,
    meta,
  ) = result

  [
    #("protocolVersion", codec_value.string(protocol_version)),
    #("capabilities", encode_server_capabilities(capabilities)),
    #("serverInfo", codec_encode.encode_implementation(server_info)),
  ]
  |> append_optional(
    "instructions",
    option_map(instructions, codec_value.string),
  )
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_server_capabilities(
  capabilities: actions.ServerCapabilities,
) -> jsonrpc.Value {
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
        #(key, codec_encode.encode_value(value))
      })
      |> codec_value.object
    }),
  )
  |> append_optional("logging", option_map(logging, codec_encode.encode_value))
  |> append_optional(
    "completions",
    option_map(completions, codec_encode.encode_value),
  )
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
  |> codec_value.object
}

fn encode_server_prompts_capabilities(
  capabilities: actions.ServerPromptsCapabilities,
) -> jsonrpc.Value {
  let actions.ServerPromptsCapabilities(list_changed) = capabilities
  []
  |> append_optional("listChanged", option_map(list_changed, codec_value.bool))
  |> codec_value.object
}

fn encode_server_resources_capabilities(
  capabilities: actions.ServerResourcesCapabilities,
) -> jsonrpc.Value {
  let actions.ServerResourcesCapabilities(subscribe, list_changed) =
    capabilities
  []
  |> append_optional("subscribe", option_map(subscribe, codec_value.bool))
  |> append_optional("listChanged", option_map(list_changed, codec_value.bool))
  |> codec_value.object
}

fn encode_server_tools_capabilities(
  capabilities: actions.ServerToolsCapabilities,
) -> jsonrpc.Value {
  let actions.ServerToolsCapabilities(list_changed) = capabilities
  []
  |> append_optional("listChanged", option_map(list_changed, codec_value.bool))
  |> codec_value.object
}

fn encode_server_tasks_capabilities(
  capabilities: actions.ServerTasksCapabilities,
) -> jsonrpc.Value {
  let actions.ServerTasksCapabilities(list, cancel, requests) = capabilities
  []
  |> append_optional("list", option_map(list, codec_encode.encode_value))
  |> append_optional("cancel", option_map(cancel, codec_encode.encode_value))
  |> append_optional(
    "requests",
    option_map(requests, encode_server_task_request_capabilities),
  )
  |> codec_value.object
}

fn encode_server_task_request_capabilities(
  capabilities: actions.ServerTaskRequestCapabilities,
) -> jsonrpc.Value {
  let actions.ServerTaskRequestCapabilities(tools_call) = capabilities
  []
  |> append_optional("tools", case tools_call {
    Some(value) ->
      Some(codec_value.object([#("call", codec_encode.encode_value(value))]))
    None -> None
  })
  |> codec_value.object
}

fn encode_list_resources_result(
  result: actions.ListResourcesResult,
) -> jsonrpc.Value {
  let actions.ListResourcesResult(resources, page, meta) = result
  [#("resources", codec_value.array(resources, codec_encode.encode_resource))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_list_resource_templates_result(
  result: actions.ListResourceTemplatesResult,
) -> jsonrpc.Value {
  let actions.ListResourceTemplatesResult(resource_templates, page, meta) =
    result
  [
    #(
      "resourceTemplates",
      codec_value.array(resource_templates, encode_resource_template),
    ),
  ]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_read_resource_result(
  result: actions.ReadResourceResult,
) -> jsonrpc.Value {
  let actions.ReadResourceResult(contents, meta) = result
  [#("contents", codec_value.array(contents, encode_resource_contents))]
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_list_prompts_result(
  result: actions.ListPromptsResult,
) -> jsonrpc.Value {
  let actions.ListPromptsResult(prompts, page, meta) = result
  [#("prompts", codec_value.array(prompts, encode_prompt))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_get_prompt_result(result: actions.GetPromptResult) -> jsonrpc.Value {
  let actions.GetPromptResult(description, messages, meta) = result
  [#("messages", codec_value.array(messages, encode_prompt_message))]
  |> append_optional("description", option_map(description, codec_value.string))
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_list_tools_result(result: actions.ListToolsResult) -> jsonrpc.Value {
  let actions.ListToolsResult(tools, page, meta) = result
  [#("tools", codec_value.array(tools, codec_encode.encode_tool))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_call_tool_result(result: actions.CallToolResult) -> jsonrpc.Value {
  let actions.CallToolResult(content, structured_content, is_error, meta) =
    result
  [#("content", codec_value.array(content, codec_encode.encode_content_block))]
  |> append_optional(
    "structuredContent",
    option_map(structured_content, codec_encode.encode_value),
  )
  |> append_optional("isError", option_map(is_error, codec_value.bool))
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_complete_result(result: actions.CompleteResult) -> jsonrpc.Value {
  let actions.CompleteResult(completion, meta) = result
  [#("completion", encode_completion_values(completion))]
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_create_task_result(
  result: actions.CreateTaskResult,
) -> jsonrpc.Value {
  let actions.CreateTaskResult(task, meta) = result
  [#("task", encode_task(task))]
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_get_task_result(result: actions.GetTaskResult) -> jsonrpc.Value {
  let actions.GetTaskResult(task, meta) = result
  codec_encode.task_fields(task)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_task_result(result: actions.TaskResult) -> jsonrpc.Value {
  case result {
    actions.TaskResultModern(value) -> codec_encode.encode_value(value)
    actions.TaskCallTool(value) -> encode_call_tool_result(value)
    actions.TaskCreateMessage(value) -> encode_create_message_result(value)
    actions.TaskElicit(value) -> encode_elicit_result(value)
  }
}

fn encode_cancel_task_result(
  result: actions.CancelTaskResult,
) -> jsonrpc.Value {
  let actions.CancelTaskResult(task, meta) = result
  codec_encode.task_fields(task)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_list_tasks_result(result: actions.ListTasksResult) -> jsonrpc.Value {
  let actions.ListTasksResult(tasks, page, meta) = result
  [#("tasks", codec_value.array(tasks, encode_task))]
  |> append_page(page)
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_create_message_result(
  result: actions.CreateMessageResult,
) -> jsonrpc.Value {
  let actions.CreateMessageResult(message, model, stop_reason, meta) = result
  let actions.SamplingMessage(role, content, _) = message
  [
    #("role", encode_role(role)),
    #("content", encode_sampling_content(content)),
    #("model", codec_value.string(model)),
  ]
  |> append_optional("stopReason", option_map(stop_reason, codec_value.string))
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

fn encode_elicit_result(result: actions.ElicitResult) -> jsonrpc.Value {
  let actions.ElicitResult(action, content, meta) = result
  [#("action", encode_elicit_action(action))]
  |> append_optional("content", option_map(content, encode_elicit_content))
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_elicit_action(action: actions.ElicitAction) -> jsonrpc.Value {
  case action {
    actions.ElicitAccept -> codec_value.string("accept")
    actions.ElicitDecline -> codec_value.string("decline")
    actions.ElicitCancel -> codec_value.string("cancel")
  }
}

fn encode_elicit_content(
  content: dict.Dict(String, actions.ElicitValue),
) -> jsonrpc.Value {
  content
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(key, value) = entry
    #(key, encode_elicit_value(value))
  })
  |> codec_value.object
}

fn encode_elicit_value(value: actions.ElicitValue) -> jsonrpc.Value {
  case value {
    actions.ElicitString(value) -> codec_value.string(value)
    actions.ElicitInt(value) -> codec_value.int(value)
    actions.ElicitFloat(value) -> codec_value.float(value)
    actions.ElicitBool(value) -> codec_value.bool(value)
    actions.ElicitStringArray(value) ->
      codec_value.array(value, codec_value.string)
  }
}

fn encode_completion_values(values: actions.CompletionValues) -> jsonrpc.Value {
  let actions.CompletionValues(entries, total, has_more) = values
  [#("values", codec_value.array(entries, codec_value.string))]
  |> append_optional("total", option_map(total, codec_value.int))
  |> append_optional("hasMore", option_map(has_more, codec_value.bool))
  |> codec_value.object
}

fn append_page(
  fields: List(#(String, jsonrpc.Value)),
  page: actions.Page,
) -> List(#(String, jsonrpc.Value)) {
  let actions.Page(next_cursor) = page
  append_optional(
    fields,
    "nextCursor",
    option_map(next_cursor, codec_encode.encode_cursor),
  )
}

fn encode_resource_template(
  template: actions.ResourceTemplate,
) -> jsonrpc.Value {
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

  [
    #("uriTemplate", codec_value.string(uri_template)),
    #("name", codec_value.string(name)),
  ]
  |> append_optional("title", option_map(title, codec_value.string))
  |> append_optional("description", option_map(description, codec_value.string))
  |> append_optional("mimeType", option_map(mime_type, codec_value.string))
  |> append_optional(
    "annotations",
    option_map(annotations, codec_encode.encode_annotations),
  )
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(codec_value.array(icons, codec_encode.encode_icon))
  })
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_resource_contents(
  contents: actions.ResourceContents,
) -> jsonrpc.Value {
  case contents {
    actions.TextResourceContents(uri, mime_type, text, meta) ->
      [#("uri", codec_value.string(uri)), #("text", codec_value.string(text))]
      |> append_optional("mimeType", option_map(mime_type, codec_value.string))
      |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
      |> codec_value.object
    actions.BlobResourceContents(uri, mime_type, blob, meta) ->
      [#("uri", codec_value.string(uri)), #("blob", codec_value.string(blob))]
      |> append_optional("mimeType", option_map(mime_type, codec_value.string))
      |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
      |> codec_value.object
  }
}

fn encode_prompt(prompt: actions.Prompt) -> jsonrpc.Value {
  let actions.Prompt(name, title, description, arguments, icons, meta) = prompt
  [#("name", codec_value.string(name))]
  |> append_optional("title", option_map(title, codec_value.string))
  |> append_optional("description", option_map(description, codec_value.string))
  |> append_optional("arguments", case arguments {
    [] -> None
    _ -> Some(codec_value.array(arguments, encode_prompt_argument))
  })
  |> append_optional("icons", case icons {
    [] -> None
    _ -> Some(codec_value.array(icons, codec_encode.encode_icon))
  })
  |> append_optional("_meta", option_map(meta, codec_encode.encode_meta))
  |> codec_value.object
}

fn encode_prompt_argument(argument: actions.PromptArgument) -> jsonrpc.Value {
  let actions.PromptArgument(name, title, description, required) = argument
  [#("name", codec_value.string(name))]
  |> append_optional("title", option_map(title, codec_value.string))
  |> append_optional("description", option_map(description, codec_value.string))
  |> append_optional("required", option_map(required, codec_value.bool))
  |> codec_value.object
}

fn encode_prompt_message(message: actions.PromptMessage) -> jsonrpc.Value {
  let actions.PromptMessage(role, content) = message
  codec_value.object([
    #("role", encode_role(role)),
    #("content", codec_encode.encode_content_block(content)),
  ])
}

fn encode_role(role: actions.Role) -> jsonrpc.Value {
  case role {
    actions.User -> codec_value.string("user")
    actions.Assistant -> codec_value.string("assistant")
  }
}

fn encode_task(task: actions.Task) -> jsonrpc.Value {
  codec_encode.task_fields(task) |> codec_value.object
}

fn encode_error(error: jsonrpc.RpcError) -> jsonrpc.Value {
  let jsonrpc.RpcError(code, message, data) = error
  [#("code", codec_value.int(code)), #("message", codec_value.string(message))]
  |> append_optional("data", option_map(data, codec_encode.encode_value))
  |> codec_value.object
}

fn initialize_request_params_decoder() -> decode.Decoder(
  actions.InitializeRequestParams,
) {
  {
    use protocol_version <- decode.field("protocolVersion", decode.string)
    use capabilities <- decode.field(
      "capabilities",
      client_capabilities_decoder(),
    )
    use client_info <- decode.field(
      "clientInfo",
      codec_decode.implementation_decoder(),
    )
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.request_meta_decoder()),
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
      decode.optional(codec_decode.value_dict_decoder()),
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
      decode.optional(codec_decode.value_decoder()),
    )
    use tools <- decode.optional_field(
      "tools",
      None,
      decode.optional(codec_decode.value_decoder()),
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
      decode.optional(codec_decode.value_decoder()),
    )
    use url <- decode.optional_field(
      "url",
      None,
      decode.optional(codec_decode.value_decoder()),
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
      decode.optional(codec_decode.value_decoder()),
    )
    use cancel <- decode.optional_field(
      "cancel",
      None,
      decode.optional(codec_decode.value_decoder()),
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
        decode.optional(codec_decode.value_decoder()),
      )
      decode.success(create_message)
    })
    use elicitation_create <- decode.optional_field("elicitation", None, {
      use create <- decode.optional_field(
        "create",
        None,
        decode.optional(codec_decode.value_decoder()),
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
      decode.optional(codec_decode.request_meta_decoder()),
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
      decode.optional(codec_decode.request_meta_decoder()),
    )
    decode.success(actions.ReadResourceRequestParams(uri, meta))
  }
}

fn subscribe_resource_request_params_decoder() -> decode.Decoder(
  actions.SubscribeRequestParams,
) {
  use uri <- decode.field("uri", decode.string)
  use meta <- decode.optional_field(
    "_meta",
    None,
    decode.optional(codec_decode.request_meta_decoder()),
  )
  decode.success(actions.SubscribeRequestParams(uri, meta))
}

fn unsubscribe_resource_request_params_decoder() -> decode.Decoder(
  actions.UnsubscribeRequestParams,
) {
  use uri <- decode.field("uri", decode.string)
  use meta <- decode.optional_field(
    "_meta",
    None,
    decode.optional(codec_decode.request_meta_decoder()),
  )
  decode.success(actions.UnsubscribeRequestParams(uri, meta))
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
      decode.optional(codec_decode.request_meta_decoder()),
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
      decode.optional(codec_decode.value_dict_decoder()),
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
      decode.optional(codec_decode.request_meta_decoder()),
    )
    decode.success(actions.CompleteRequestParams(ref, argument, context, meta))
  }
}

fn set_level_request_params_decoder() -> decode.Decoder(
  actions.SetLevelRequestParams,
) {
  {
    use level <- decode.field("level", codec_decode.logging_level_decoder())
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(codec_decode.request_meta_decoder()),
    )
    decode.success(actions.SetLevelRequestParams(level, meta))
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

fn option_map(input: Option(a), fun: fn(a) -> b) -> Option(b) {
  case input {
    Some(value) -> Some(fun(value))
    None -> None
  }
}
