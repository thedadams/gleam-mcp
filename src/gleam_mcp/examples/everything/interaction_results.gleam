import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_encode
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VObject, VString,
}

pub fn sampling_tool_result(
  result: actions.CreateMessageResult,
) -> actions.CallToolResult {
  helpers.text_result(
    "LLM sampling result: \n"
    <> helpers.pretty_json(sampling_result_value(result)),
  )
}

pub fn sampling_result_value(result: actions.CreateMessageResult) -> Value {
  let actions.CreateMessageResult(
    actions.SamplingMessage(role, content, _),
    model,
    stop_reason,
    meta,
  ) = result
  VObject(
    [
      #("role", codec_encode.encode_role(role)),
      #("content", sampling_content_value(content)),
      #("model", VString(model)),
    ]
    |> append_optional("stopReason", map_option(stop_reason, VString))
    |> append_optional("_meta", map_option(meta, codec_encode.encode_meta)),
  )
}

pub fn elicitation_tool_result(
  result: actions.ElicitResult,
) -> actions.CallToolResult {
  let actions.ElicitResult(action, content, _) = result
  let blocks = case action, content {
    actions.ElicitAccept, Some(fields) -> [
      text_block("✅ User provided the requested information!"),
      text_block("User inputs:\n" <> user_input_lines(fields)),
    ]
    actions.ElicitDecline, _ -> [
      text_block("❌ User declined to provide the requested information."),
    ]
    actions.ElicitCancel, _ -> [
      text_block("⚠️ User cancelled the elicitation dialog."),
    ]
    _, _ -> []
  }
  helpers.content_result(list.append(blocks, [raw_result_block(result)]))
}

pub fn url_tool_result(
  result: actions.ElicitResult,
  elicitation_id: String,
  url: String,
) -> actions.CallToolResult {
  let text = case result.action {
    actions.ElicitAccept ->
      "✅ User completed the URL elicitation flow.\nElicitation ID: "
      <> elicitation_id
      <> "\nURL: "
      <> url
    actions.ElicitDecline ->
      "❌ User declined to open the URL (Elicitation ID: "
      <> elicitation_id
      <> ")."
    actions.ElicitCancel ->
      "⚠️ User cancelled the URL elicitation (Elicitation ID: "
      <> elicitation_id
      <> ")."
  }
  helpers.content_result([text_block(text), raw_result_block(result)])
}

pub fn elicitation_result_value(result: actions.ElicitResult) -> Value {
  let actions.ElicitResult(action, content, meta) = result
  VObject(
    [
      #(
        "action",
        VString(case action {
          actions.ElicitAccept -> "accept"
          actions.ElicitDecline -> "decline"
          actions.ElicitCancel -> "cancel"
        }),
      ),
    ]
    |> append_optional(
      "content",
      map_option(content, fn(fields) {
        VObject(
          fields
          |> dict.to_list
          |> list.map(fn(field) { #(field.0, elicit_value(field.1)) }),
        )
      }),
    )
    |> append_optional("_meta", map_option(meta, codec_encode.encode_meta)),
  )
}

fn raw_result_block(result: actions.ElicitResult) -> actions.ContentBlock {
  text_block(
    "\nRaw result: " <> helpers.pretty_json(elicitation_result_value(result)),
  )
}

fn user_input_lines(fields: dict.Dict(String, actions.ElicitValue)) -> String {
  [
    #("name", "Name", True),
    #("check", "Agreed to terms", False),
    #("color", "Favorite Color", True),
    #("email", "Email", True),
    #("homepage", "Homepage", True),
    #("birthdate", "Birthdate", True),
    #("integer", "Favorite Integer", False),
    #("number", "Favorite Number", False),
    #("petType", "Pet Type", True),
  ]
  |> list.filter_map(fn(field) {
    case dict.get(fields, field.0) {
      Ok(value) ->
        case field.2 && !is_truthy(value) {
          True -> Error(Nil)
          False -> Ok("- " <> field.1 <> ": " <> elicit_value_to_string(value))
        }
      Error(_) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn is_truthy(value: actions.ElicitValue) -> Bool {
  case value {
    actions.ElicitString(value) -> value != ""
    actions.ElicitBool(value) -> value
    actions.ElicitInt(value) -> value != 0
    actions.ElicitFloat(value) -> value != 0.0
    actions.ElicitStringArray(_) -> True
  }
}

fn elicit_value_to_string(value: actions.ElicitValue) -> String {
  case value {
    actions.ElicitString(value) -> value
    actions.ElicitInt(value) -> int.to_string(value)
    actions.ElicitFloat(value) -> {
      let integer = float.truncate(value)
      case value == int.to_float(integer) {
        True -> int.to_string(integer)
        False -> float.to_string(value)
      }
    }
    actions.ElicitBool(True) -> "true"
    actions.ElicitBool(False) -> "false"
    actions.ElicitStringArray(values) -> string.join(values, ",")
  }
}

fn elicit_value(value: actions.ElicitValue) -> Value {
  case value {
    actions.ElicitString(value) -> VString(value)
    actions.ElicitInt(value) -> VInt(value)
    actions.ElicitFloat(value) -> VFloat(value)
    actions.ElicitBool(value) -> VBool(value)
    actions.ElicitStringArray(values) -> VArray(list.map(values, VString))
  }
}

fn sampling_content_value(content: actions.SamplingContent) -> Value {
  case content {
    actions.SingleSamplingContent(content) ->
      codec_encode.encode_sampling_message_content_block(content)
    actions.MultipleSamplingContent(contents) ->
      VArray(list.map(
        contents,
        codec_encode.encode_sampling_message_content_block,
      ))
  }
}

fn text_block(text: String) -> actions.ContentBlock {
  actions.TextBlock(actions.TextContent(text, None, None))
}

fn map_option(value: Option(a), map: fn(a) -> b) -> Option(b) {
  case value {
    Some(value) -> Some(map(value))
    None -> None
  }
}

fn append_optional(
  fields: List(#(String, Value)),
  name: String,
  value: Option(Value),
) -> List(#(String, Value)) {
  case value {
    Some(value) -> list.append(fields, [#(name, value)])
    None -> fields
  }
}
