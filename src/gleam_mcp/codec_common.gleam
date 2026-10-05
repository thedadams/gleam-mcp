import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/codec_decode
import gleam_mcp/codec_encode
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc

pub type MessageDecodeError {
  MessageDecodeError(id: Option(jsonrpc.RequestId), error: jsonrpc.RpcError)
}

/// Validate the shared JSON-RPC request/notification envelope before decoding
/// any method-specific parameters.
pub fn request_envelope_decoder() -> decode.Decoder(Nil) {
  use _fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  use _version <- decode.field("jsonrpc", jsonrpc_version_decoder())
  use _method <- decode.field("method", decode.string)
  use _id <- decode.optional_field(
    "id",
    None,
    decode.map(request_id_decoder(), Some),
  )
  decode.success(Nil)
}

pub fn request_parameters_decoder() -> decode.Decoder(Nil) {
  use _params <- decode.optional_field(
    "params",
    None,
    decode.map(decode.dict(decode.string, decode.dynamic), Some),
  )
  decode.success(Nil)
}

/// Responses must contain exactly one result/error and an ID. A null error ID
/// identifies an error whose originating request could not be determined.
pub fn response_envelope_decoder(
  original_id: jsonrpc.RequestId,
) -> decode.Decoder(Nil) {
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  use _version <- decode.field("jsonrpc", jsonrpc_version_decoder())
  case dict.has_key(fields, "result"), dict.has_key(fields, "error") {
    True, False -> {
      use id <- decode.field("id", request_id_decoder())
      use _result <- decode.field(
        "result",
        decode.dict(decode.string, decode.dynamic),
      )
      matching_response_id(id, original_id)
    }
    False, True -> {
      use id <- decode.field("id", decode.optional(request_id_decoder()))
      use _error <- decode.field(
        "error",
        decode.dict(decode.string, decode.dynamic),
      )
      case id {
        Some(id) -> matching_response_id(id, original_id)
        None -> decode.success(Nil)
      }
    }
    _, _ ->
      decode.failure(Nil, expected: "Exactly one JSON-RPC result or error")
  }
}

pub fn request_id_decoder() -> decode.Decoder(jsonrpc.RequestId) {
  codec_decode.request_id_decoder()
}

pub fn jsonrpc_version_decoder() -> decode.Decoder(String) {
  decode.then(decode.string, fn(version) {
    case version == jsonrpc.jsonrpc_version {
      True -> decode.success(version)
      False -> decode.failure("2.0", expected: "JSON-RPC version 2.0")
    }
  })
}

fn matching_response_id(
  id: jsonrpc.RequestId,
  original_id: jsonrpc.RequestId,
) -> decode.Decoder(Nil) {
  case id == original_id {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, expected: "Matching JSON-RPC response ID")
  }
}

/// Identify notifications even when their envelope or parameters are invalid,
/// so transports can avoid sending a response to a notification.
pub fn is_notification(body: String) -> Bool {
  case json.parse(body, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> dict.has_key(fields, "method") && !dict.has_key(fields, "id")
    Error(_) -> False
  }
}

pub fn is_response(body: String) -> Bool {
  case json.parse(body, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      !dict.has_key(fields, "method")
      && { dict.has_key(fields, "result") || dict.has_key(fields, "error") }
    Error(_) -> False
  }
}

pub fn encode_implementation(
  implementation: actions.Implementation,
) -> json.Json {
  codec_encode.encode_implementation(implementation) |> codec_value.to_json
}

pub fn encode_icon(icon: actions.Icon) -> json.Json {
  codec_encode.encode_icon(icon) |> codec_value.to_json
}

pub fn encode_icon_theme(theme: actions.IconTheme) -> json.Json {
  codec_encode.encode_icon_theme(theme) |> codec_value.to_json
}

pub fn encode_tool(tool: actions.Tool) -> json.Json {
  codec_encode.encode_tool(tool) |> codec_value.to_json
}

pub fn encode_tool_execution(execution: actions.ToolExecution) -> json.Json {
  codec_encode.encode_tool_execution(execution) |> codec_value.to_json
}

pub fn encode_tool_annotations(
  annotations: actions.ToolAnnotations,
) -> json.Json {
  codec_encode.encode_tool_annotations(annotations) |> codec_value.to_json
}

pub fn encode_sampling_message_content_block(
  block: actions.SamplingMessageContentBlock,
) -> json.Json {
  codec_encode.encode_sampling_message_content_block(block)
  |> codec_value.to_json
}

pub fn encode_tool_use_content(content: actions.ToolUseContent) -> json.Json {
  codec_encode.encode_tool_use_content(content) |> codec_value.to_json
}

pub fn encode_tool_result_content(
  content: actions.ToolResultContent,
) -> json.Json {
  codec_encode.encode_tool_result_content(content) |> codec_value.to_json
}

pub fn encode_content_block(block: actions.ContentBlock) -> json.Json {
  codec_encode.encode_content_block(block) |> codec_value.to_json
}

pub fn encode_text_content(content: actions.TextContent) -> json.Json {
  codec_encode.encode_text_content(content) |> codec_value.to_json
}

pub fn encode_image_content(content: actions.ImageContent) -> json.Json {
  codec_encode.encode_image_content(content) |> codec_value.to_json
}

pub fn encode_audio_content(content: actions.AudioContent) -> json.Json {
  codec_encode.encode_audio_content(content) |> codec_value.to_json
}

pub fn encode_resource_link(link: actions.ResourceLink) -> json.Json {
  codec_encode.encode_resource_link(link) |> codec_value.to_json
}

pub fn encode_resource(resource: actions.Resource) -> json.Json {
  codec_encode.encode_resource(resource) |> codec_value.to_json
}

pub fn encode_embedded_resource(
  resource: actions.EmbeddedResource,
) -> json.Json {
  codec_encode.encode_embedded_resource(resource) |> codec_value.to_json
}

pub fn encode_annotations(annotations: actions.Annotations) -> json.Json {
  codec_encode.encode_annotations(annotations) |> codec_value.to_json
}

pub fn encode_meta(meta: actions.Meta) -> json.Json {
  codec_encode.encode_meta(meta) |> codec_value.to_json
}

pub fn encode_role(role: actions.Role) -> json.Json {
  codec_encode.encode_role(role) |> codec_value.to_json
}

pub fn encode_cursor(cursor: actions.Cursor) -> json.Json {
  codec_encode.encode_cursor(cursor) |> codec_value.to_json
}

pub fn encode_task_status(status: actions.TaskStatus) -> json.Json {
  codec_encode.encode_task_status(status) |> codec_value.to_json
}

pub fn encode_value(value: jsonrpc.Value) -> json.Json {
  codec_encode.encode_value(value) |> codec_value.to_json
}

pub fn encode_request_id(id: jsonrpc.RequestId) -> json.Json {
  codec_encode.encode_request_id(id) |> codec_value.to_json
}

pub fn encode_value_object(
  fields: List(#(String, jsonrpc.Value)),
) -> json.Json {
  codec_encode.encode_value_object(fields) |> codec_value.to_json
}
