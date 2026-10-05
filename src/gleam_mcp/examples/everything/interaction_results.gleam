import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions

pub fn sampling_tool_result(
  result: actions.CreateMessageResult,
) -> actions.CallToolResult {
  let pretty = sampling_result_text(result)
  actions.CallToolResult(
    content: [
      actions.TextBlock(actions.TextContent(
        "LLM sampling result:\n" <> pretty,
        None,
        None,
      )),
    ],
    structured_content: None,
    is_error: Some(False),
    meta: None,
  )
}

pub fn elicitation_tool_result(
  result: actions.ElicitResult,
) -> actions.CallToolResult {
  let actions.ElicitResult(action, content, _) = result
  let lead = case action {
    actions.ElicitAccept -> "Accepted elicitation request."
    actions.ElicitDecline -> "User declined the elicitation request."
    actions.ElicitCancel -> "User cancelled the elicitation request."
  }
  let details = case content {
    Some(fields) ->
      fields
      |> dict.to_list
      |> list.map(fn(entry) {
        let #(key, value) = entry
        "- " <> key <> ": " <> elicit_value_to_string(value)
      })
      |> string.join(with: "\n")
    None -> ""
  }

  actions.CallToolResult(
    content: [
      actions.TextBlock(actions.TextContent(
        case details == "" {
          True -> lead
          False -> lead <> "\n" <> details
        },
        None,
        None,
      )),
    ],
    structured_content: None,
    is_error: Some(False),
    meta: None,
  )
}

fn sampling_result_text(result: actions.CreateMessageResult) -> String {
  let actions.CreateMessageResult(message, model, stop_reason, _) = result
  let body = case message {
    actions.SamplingMessage(role, content, _) ->
      "role="
      <> role_name(role)
      <> ", content="
      <> sampling_content_to_string(content)
  }
  let stop = case stop_reason {
    Some(reason) -> reason
    None -> "none"
  }
  "model=" <> model <> ", stop_reason=" <> stop <> ", " <> body
}

fn sampling_content_to_string(content: actions.SamplingContent) -> String {
  case content {
    actions.SingleSamplingContent(block) -> sampling_block_to_string(block)
    actions.MultipleSamplingContent(blocks) ->
      blocks |> list.map(sampling_block_to_string) |> string.join(with: ", ")
  }
}

fn sampling_block_to_string(
  block: actions.SamplingMessageContentBlock,
) -> String {
  case block {
    actions.SamplingText(actions.TextContent(text:, ..)) -> text
    actions.SamplingImage(_) -> "[image]"
    actions.SamplingAudio(_) -> "[audio]"
    actions.SamplingToolUse(actions.ToolUseContent(name:, ..)) ->
      "[tool_use:" <> name <> "]"
    actions.SamplingToolResult(actions.ToolResultContent(content:, ..)) ->
      content |> list.map(content_block_to_string) |> string.join(with: ", ")
  }
}

fn content_block_to_string(block: actions.ContentBlock) -> String {
  case block {
    actions.TextBlock(actions.TextContent(text:, ..)) -> text
    actions.ImageBlock(_) -> "[image]"
    actions.AudioBlock(_) -> "[audio]"
    actions.ResourceLinkBlock(actions.ResourceLink(resource)) -> resource.uri
    actions.EmbeddedResourceBlock(actions.EmbeddedResource(resource, _, _)) ->
      case resource {
        actions.TextResourceContents(uri:, ..) -> uri
        actions.BlobResourceContents(uri:, ..) -> uri
      }
  }
}

fn elicit_value_to_string(value: actions.ElicitValue) -> String {
  case value {
    actions.ElicitString(text) -> text
    actions.ElicitInt(number) -> int.to_string(number)
    actions.ElicitFloat(number) -> float.to_string(number)
    actions.ElicitBool(boolean) -> bool_to_string(boolean)
    actions.ElicitStringArray(values) -> string.join(values, with: ", ")
  }
}

fn role_name(role: actions.Role) -> String {
  case role {
    actions.User -> "user"
    actions.Assistant -> "assistant"
  }
}

fn bool_to_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
