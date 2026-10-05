/// Revision-aware wire boundaries. The neutral codecs remain usable for legacy
/// messages; these helpers enforce the July 2026 envelope and result rules.
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/codec_encode
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc.{type Value, VInt, VObject, VString}
import gleam_mcp/mcp
import gleam_mcp/server/codec as server_codec

pub type CacheHint =
  actions.CacheHint

pub fn is_modern(version: String) -> Bool {
  version == jsonrpc.latest_protocol_version
}

pub fn validate_request(
  request: jsonrpc.Request(actions.ClientActionRequest),
  version: String,
) -> Result(Nil, String) {
  case request {
    jsonrpc.Request(_, method, _) | jsonrpc.Notification(method, _) -> {
      case version {
        _ if version == jsonrpc.legacy_protocol_version ->
          case
            method == "server/discover"
            || method == "subscriptions/listen"
            || method == "tasks/update"
          {
            True ->
              Error(
                "Method requires protocol " <> jsonrpc.latest_protocol_version,
              )
            False -> Ok(Nil)
          }
        _ if version == jsonrpc.latest_protocol_version ->
          case removed_method(method) {
            True ->
              Error(
                "Method is unavailable in protocol "
                <> version
                <> ": "
                <> method,
              )
            False -> Ok(Nil)
          }
        _ -> Error("Unsupported protocol version: " <> version)
      }
    }
  }
}

pub fn encode_request(
  request: jsonrpc.Request(actions.ClientActionRequest),
  _version: String,
) -> String {
  client_codec.encode_request(request)
}

pub fn encode_request_checked(
  request: jsonrpc.Request(actions.ClientActionRequest),
  version: String,
) -> Result(String, String) {
  use _ <- result.try(validate_request(request, version))
  Ok(encode_request(request, version))
}

pub fn decode_response(
  body: String,
  request: jsonrpc.Request(actions.ClientActionRequest),
  version: String,
) -> Result(jsonrpc.Response(actions.ClientActionResult), String) {
  use fields <- result.try(parse_object(body))
  use _ <- result.try(case dict.get(fields, "result") {
    Ok(VObject(fields)) ->
      validate_result(dict.from_list(fields), request, version)
    _ -> Ok(Nil)
  })
  use body <- result.try(normalize_response(body, fields, version))
  use response <- result.try(
    case modern_task_response(fields, request, version) {
      Some(value) -> {
        let assert jsonrpc.Request(id, _, _) = request
        use _ <- result.try(
          json.parse(body, codec_common.response_envelope_decoder(id))
          |> result.map_error(fn(_) { "Invalid task response envelope or ID" }),
        )
        Ok(jsonrpc.ResultResponse(id, actions.ClientResultTaskModern(value)))
      }
      None -> client_codec.decode_response(body, request)
    },
  )
  case response, request, is_modern(version) {
    jsonrpc.ResultResponse(id, result), jsonrpc.Request(_, method, _), True ->
      case cacheable_method(method), result {
        True, actions.ClientResultInputRequired(_) -> Ok(response)
        True, _ ->
          Ok(jsonrpc.ResultResponse(
            id,
            actions.ClientResultWithCache(
              result,
              case has_continuation(request) {
                True -> actions.CacheHint(0, actions.Private)
                False -> cache_hint(body)
              },
            ),
          ))
        False, _ -> Ok(response)
      }
    _, _, _ -> Ok(response)
  }
}

fn modern_task_response(
  fields: Dict(String, Value),
  request: jsonrpc.Request(actions.ClientActionRequest),
  version: String,
) -> Option(Value) {
  case request, dict.get(fields, "result"), is_modern(version) {
    jsonrpc.Request(_, method, _), Ok(VObject(result)), True -> {
      case list.key_find(result, "resultType"), method {
        Ok(VString("task")), _ -> Some(VObject(result))
        _, "tasks/get" | _, "tasks/update" | _, "tasks/cancel" ->
          Some(VObject(result))
        _, _ -> None
      }
    }
    _, _, _ -> None
  }
}

fn normalize_response(
  body: String,
  fields: Dict(String, Value),
  version: String,
) -> Result(String, String) {
  case
    is_modern(version),
    dict.has_key(fields, "error"),
    dict.get(fields, "id")
  {
    True, True, Ok(jsonrpc.VNull) ->
      Error("Modern JSON-RPC error IDs must be omitted or non-null")
    True, True, Error(_) ->
      Ok(
        fields
        |> dict.insert("id", jsonrpc.VNull)
        |> dict.to_list
        |> VObject
        |> codec_common.encode_value
        |> json.to_string,
      )
    _, _, _ -> Ok(body)
  }
}

fn validate_result(
  fields: Dict(String, Value),
  request: jsonrpc.Request(actions.ClientActionRequest),
  version: String,
) -> Result(Nil, String) {
  let discriminator = dict.get(fields, "resultType")
  use kind <- result.try(case discriminator {
    Error(_) -> Ok("complete")
    Ok(VString(kind)) -> Ok(kind)
    _ -> Error("Result requires a string resultType")
  })
  case kind {
    "complete" ->
      case request, is_modern(version) {
        jsonrpc.Request(_, "tools/call", _), True ->
          case dict.get(fields, "content") {
            Ok(jsonrpc.VArray(_)) -> Ok(Nil)
            _ -> Error("Complete tools/call result requires content")
          }
        _, _ -> Ok(Nil)
      }
    "input_required" ->
      case is_modern(version), request {
        True, jsonrpc.Request(_, method, _)
          if method == "tools/call"
          || method == "prompts/get"
          || method == "resources/read"
        -> validate_input_required(fields)
        _, _ -> Error("input_required is unavailable for this request")
      }
    "task" ->
      case request, is_modern(version) && supports_tasks(request) {
        jsonrpc.Request(_, "tools/call", _), True -> Ok(Nil)
        _, _ -> Error("Task results require a negotiated tools/call request")
      }
    _ -> Error("Unsupported resultType: " <> kind)
  }
}

fn supports_tasks(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> Bool {
  let meta = case request {
    jsonrpc.Request(_, _, Some(action)) -> actions.request_meta(action)
    _ -> None
  }
  let extras =
    meta
    |> option.then(fn(meta) { meta.extra })
    |> option.map(fn(meta) { meta.fields })
    |> option.unwrap(dict.new())
  case dict.get(extras, "io.modelcontextprotocol/clientCapabilities") {
    Ok(VObject(capabilities)) ->
      case list.key_find(capabilities, "extensions") {
        Ok(VObject(extensions)) ->
          case list.key_find(extensions, "io.modelcontextprotocol/tasks") {
            Ok(VObject(_)) -> True
            _ -> False
          }
        _ -> False
      }
    _ -> False
  }
}

fn validate_input_required(fields: Dict(String, Value)) -> Result(Nil, String) {
  let inputs = dict.get(fields, "inputRequests")
  let state = dict.get(fields, "requestState")
  use _ <- result.try(case inputs {
    Error(_) | Ok(VObject(_)) -> Ok(Nil)
    _ -> Error("inputRequests must be an object")
  })
  use _ <- result.try(case state {
    Error(_) | Ok(VString(_)) -> Ok(Nil)
    _ -> Error("requestState must be a string")
  })
  case inputs, state {
    Error(_), Error(_) ->
      Error("input_required requires inputRequests or requestState")
    _, _ -> Ok(Nil)
  }
}

/// Modern transports deliver notifications and results, never reverse requests.
pub fn decode_server_message(
  body: String,
  version: String,
) -> Result(client_codec.ServerMessage, String) {
  use message <- result.try(client_codec.decode_server_message(body))
  case is_modern(version), message {
    True, client_codec.ServerActionRequest(_)
    | True, client_codec.UnknownRequest(_, _)
    -> Error("Server-to-client requests are unavailable in the modern protocol")
    _, _ -> Ok(message)
  }
}

pub fn decode_message_with_error(
  body: String,
  version: String,
) -> Result(server_codec.Message, codec_common.MessageDecodeError) {
  use message <- result.try(server_codec.decode_message_with_error_for_version(
    body,
    version,
  ))
  case is_modern(version) {
    False -> Ok(message)
    True -> {
      use _ <- result.try(validate_modern_request(body))
      Ok(message)
    }
  }
}

fn validate_modern_request(
  body: String,
) -> Result(Nil, codec_common.MessageDecodeError) {
  use fields <- result.try(
    parse_object(body)
    |> result.map_error(fn(message) {
      codec_common.MessageDecodeError(
        None,
        jsonrpc.invalid_params_error(message),
      )
    }),
  )
  let id = case dict.get(fields, "id") {
    Ok(VInt(id)) -> Some(jsonrpc.IntId(id))
    Ok(VString(id)) -> Some(jsonrpc.StringId(id))
    _ -> None
  }
  // Client cancellation notifications on stdio may omit the request envelope.
  case id {
    None -> Ok(Nil)
    Some(_) -> {
      use _ <- result.try(
        request_envelope(fields)
        |> result.map_error(fn(error) {
          codec_common.MessageDecodeError(id, error)
        }),
      )
      case dict.get(fields, "method") {
        Ok(VString(method)) ->
          case removed_method(method) {
            True ->
              Error(codec_common.MessageDecodeError(
                id,
                jsonrpc.method_not_found_error(
                  "Method unavailable in this protocol: " <> method,
                ),
              ))
            False -> Ok(Nil)
          }
        _ -> Ok(Nil)
      }
    }
  }
}

/// Read and validate the reserved per-request envelope, including on unknown
/// methods whose neutral decoder intentionally does not keep parameters.
pub fn request_meta(
  body: String,
) -> Result(Dict(String, Value), jsonrpc.RpcError) {
  use fields <- result.try(
    parse_object(body) |> result.map_error(jsonrpc.invalid_params_error),
  )
  request_envelope(fields)
}

/// Recognize modern claims before trying to decode their values.
pub fn claims_modern(body: String) -> Bool {
  let fields = parse_object(body) |> result.unwrap(dict.new())
  let method_claim = case dict.get(fields, "method") {
    Ok(VString("server/discover"))
    | Ok(VString("subscriptions/listen"))
    | Ok(VString("tasks/update")) -> True
    _ -> False
  }
  let envelope_claim = case dict.get(fields, "params") {
    Ok(VObject(params)) ->
      case list.key_find(params, "_meta") {
        Ok(VObject(meta)) ->
          list.key_find(meta, "io.modelcontextprotocol/protocolVersion")
          |> result.is_ok
        _ -> False
      }
    _ -> False
  }
  method_claim || envelope_claim
}

pub fn validate_request_metadata(
  meta: Option(actions.RequestMeta),
) -> Result(Nil, jsonrpc.RpcError) {
  let fields =
    meta
    |> option.then(fn(meta) { meta.extra })
    |> option.map(fn(meta) { dict.to_list(meta.fields) })
    |> option.unwrap([])
  request_envelope(
    dict.from_list([#("params", VObject([#("_meta", VObject(fields))]))]),
  )
  |> result.map(fn(_) { Nil })
}

fn request_envelope(
  fields: Dict(String, Value),
) -> Result(Dict(String, Value), jsonrpc.RpcError) {
  use params <- result.try(object_field(fields, "params"))
  use meta <- result.try(object_field(params, "_meta"))
  use version <- result.try(
    case dict.get(meta, "io.modelcontextprotocol/protocolVersion") {
      Ok(VString(version)) -> Ok(version)
      _ ->
        Error(jsonrpc.invalid_params_error(
          "Request _meta requires protocolVersion",
        ))
    },
  )
  use _ <- result.try(case is_modern(version) {
    True -> Ok(Nil)
    False ->
      Error(jsonrpc.RpcError(
        -32_022,
        "Unsupported protocol version",
        Some(
          VObject([
            #(
              "supported",
              jsonrpc.VArray([VString(jsonrpc.latest_protocol_version)]),
            ),
            #("requested", VString(version)),
          ]),
        ),
      ))
  })
  use capabilities <- result.try(object_field(
    meta,
    "io.modelcontextprotocol/clientCapabilities",
  ))
  use _ <- result.try(validate_capabilities(capabilities))
  use _ <- result.try(
    case dict.get(meta, "io.modelcontextprotocol/clientInfo") {
      Error(_) -> Ok(Nil)
      Ok(info) ->
        client_codec.decode_implementation(info)
        |> result.map(fn(_) { Nil })
        |> result.map_error(jsonrpc.invalid_params_error)
    },
  )
  use _ <- result.try(case dict.get(meta, "io.modelcontextprotocol/logLevel") {
    Error(_) -> Ok(Nil)
    Ok(VString(level)) ->
      case
        list.contains(
          [
            "debug",
            "info",
            "notice",
            "warning",
            "error",
            "critical",
            "alert",
            "emergency",
          ],
          level,
        )
      {
        True -> Ok(Nil)
        False -> Error(jsonrpc.invalid_params_error("Invalid logLevel"))
      }
    _ -> Error(jsonrpc.invalid_params_error("logLevel must be a string"))
  })
  Ok(meta)
}

fn validate_capabilities(
  capabilities: Dict(String, Value),
) -> Result(Nil, jsonrpc.RpcError) {
  list.try_each(dict.to_list(capabilities), fn(pair) {
    case pair {
      #("roots", value) -> require_object(value)
      #("sampling", value) -> capability_settings(value, ["tools"])
      #("elicitation", value) -> capability_settings(value, ["form", "url"])
      #("experimental", value) -> require_object(value)
      #("extensions", VObject(extensions)) ->
        list.try_each(extensions, fn(extension) {
          use _ <- result.try(case string.split_once(extension.0, "/") {
            Ok(#(prefix, name)) if prefix != "" && name != "" -> Ok(Nil)
            _ ->
              Error(jsonrpc.invalid_params_error(
                "Extension identifiers require a namespace prefix and name",
              ))
          })
          require_object(extension.1)
        })
      #("extensions", _) ->
        Error(jsonrpc.invalid_params_error("extensions must be an object"))
      _ -> Ok(Nil)
    }
  })
}

fn require_object(value: Value) -> Result(Nil, jsonrpc.RpcError) {
  case value {
    VObject(_) -> Ok(Nil)
    _ ->
      Error(jsonrpc.invalid_params_error("Capability settings must be objects"))
  }
}

fn capability_settings(
  value: Value,
  keys: List(String),
) -> Result(Nil, jsonrpc.RpcError) {
  use _ <- result.try(require_object(value))
  let assert VObject(fields) = value
  list.try_each(fields, fn(field) {
    case list.contains(keys, field.0) {
      True -> require_object(field.1)
      False -> Ok(Nil)
    }
  })
}

fn object_field(
  fields: Dict(String, Value),
  key: String,
) -> Result(Dict(String, Value), jsonrpc.RpcError) {
  case dict.get(fields, key) {
    Ok(VObject(fields)) -> Ok(dict.from_list(fields))
    _ -> Error(jsonrpc.invalid_params_error("Required object: " <> key))
  }
}

fn removed_method(method: String) -> Bool {
  list.contains(mcp.removed_modern_methods, method)
}

pub fn encode_response(
  response: jsonrpc.Response(actions.ClientActionResult),
  version: String,
  server_info: actions.Implementation,
) -> String {
  case response, is_modern(version) {
    jsonrpc.ResultResponse(id, result), True ->
      json.object([
        #("jsonrpc", json.string(jsonrpc.jsonrpc_version)),
        #("id", codec_common.encode_request_id(id)),
        #(
          "result",
          codec_common.encode_value(result_value(result, version, server_info)),
        ),
      ])
      |> json.to_string
    jsonrpc.ErrorResponse(None, _), True -> {
      let fields =
        response
        |> server_codec.encode_response_value
        |> codec_value.object_fields
        |> dict.from_list
      fields
      |> dict.delete("id")
      |> dict.to_list
      |> VObject
      |> codec_common.encode_value
      |> json.to_string
    }
    _, _ -> server_codec.encode_response(response)
  }
}

pub fn result_value(
  result: actions.ClientActionResult,
  version: String,
  server_info: actions.Implementation,
) -> Value {
  let raw =
    result
    |> server_codec.encode_client_action_result_value
    |> codec_value.normalize
  case raw, is_modern(version) {
    VObject(fields), True -> {
      let fields = dict.from_list(fields)
      let discriminator = case unwrap_cache(result) {
        actions.ClientResultInputRequired(_) -> "input_required"
        actions.ClientResultTaskModern(_) ->
          fields
          |> dict.get("resultType")
          |> result.unwrap(VString("task"))
          |> string_value
        _ -> "complete"
      }
      let meta = case dict.get(fields, "_meta") {
        Ok(VObject(meta)) -> dict.from_list(meta)
        _ -> dict.new()
      }
      let server_info =
        codec_encode.encode_implementation(server_info)
        |> codec_value.normalize
      let meta =
        dict.insert(meta, "io.modelcontextprotocol/serverInfo", server_info)
      let fields =
        fields
        |> dict.insert("resultType", VString(discriminator))
        |> dict.insert("_meta", VObject(dict.to_list(meta)))
      let fields = case cacheable_result(unwrap_cache(result)) {
        True ->
          fields
          |> dict.insert("ttlMs", case dict.get(fields, "ttlMs") {
            Ok(VInt(ttl)) if ttl >= 0 -> VInt(ttl)
            _ -> VInt(0)
          })
          |> default_field("cacheScope", VString("private"))
        False -> fields
      }
      VObject(dict.to_list(fields))
    }
    _, _ -> raw
  }
}

fn string_value(value: Value) -> String {
  case value {
    VString(value) -> value
    _ -> "task"
  }
}

fn default_field(
  fields: Dict(String, Value),
  key: String,
  value: Value,
) -> Dict(String, Value) {
  case dict.has_key(fields, key) {
    True -> fields
    False -> dict.insert(fields, key, value)
  }
}

fn cacheable_result(result: actions.ClientActionResult) -> Bool {
  case result {
    actions.ClientResultDiscover(_)
    | actions.ClientResultListResources(_)
    | actions.ClientResultListResourceTemplates(_)
    | actions.ClientResultReadResource(_)
    | actions.ClientResultListPrompts(_)
    | actions.ClientResultListTools(_) -> True
    _ -> False
  }
}

fn unwrap_cache(
  result: actions.ClientActionResult,
) -> actions.ClientActionResult {
  case result {
    actions.ClientResultWithCache(result, _) -> unwrap_cache(result)
    _ -> result
  }
}

fn cacheable_method(method: String) -> Bool {
  case method {
    "server/discover"
    | "tools/list"
    | "prompts/list"
    | "resources/list"
    | "resources/templates/list"
    | "resources/read" -> True
    _ -> False
  }
}

fn has_continuation(
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> Bool {
  case request {
    jsonrpc.Request(_, _, Some(action)) ->
      option.is_some(actions.request_state(action))
      || option.is_some(actions.input_responses(action))
    _ -> False
  }
}

pub fn cache_hint(body: String) -> CacheHint {
  let fields = body |> parse_object |> result.unwrap(dict.new())
  let result = case dict.get(fields, "result") {
    Ok(VObject(fields)) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let ttl_ms = case dict.get(result, "ttlMs") {
    Ok(VInt(ttl)) if ttl >= 0 -> ttl
    _ -> 0
  }
  let scope = case dict.get(result, "cacheScope") {
    Ok(VString("public")) -> actions.Public
    _ -> actions.Private
  }
  actions.CacheHint(ttl_ms, scope)
}

pub fn parse_value(body: String) -> Result(Value, String) {
  json.parse(body, codec_decode.value_decoder())
  |> result.map_error(fn(_) { "Invalid JSON value" })
}

pub fn parse_object(body: String) -> Result(Dict(String, Value), String) {
  use value <- result.try(parse_value(body))
  case value {
    VObject(fields) -> Ok(dict.from_list(fields))
    _ -> Error("Expected a JSON object")
  }
}
