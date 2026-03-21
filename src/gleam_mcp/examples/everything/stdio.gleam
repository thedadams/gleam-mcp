import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec as server_codec
import stdin

type InteractionKind {
  Sampling
  Elicitation
}

type PendingInteraction {
  PendingInteraction(
    tool_call_id: jsonrpc.RequestId,
    request: jsonrpc.Request(actions.ServerActionRequest),
    kind: InteractionKind,
  )
}

type State {
  State(app_server: server.Server, pending: Option(PendingInteraction))
}

pub fn serve() -> Nil {
  let initial = State(everything_server.make_server(), None)
  let _ = stdin.read_lines() |> yielder.fold(from: initial, with: handle_line)
  Nil
}

fn handle_line(state: State, line: String) -> State {
  case server_codec.decode_message(line) {
    Ok(server_codec.ClientActionRequest(request)) ->
      handle_request(state, request)
    Ok(server_codec.ActionNotification(notification)) ->
      handle_notification(state, notification)
    Ok(server_codec.UnknownRequest(id, method)) -> {
      respond(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.method_not_found_error(method),
      ))
      state
    }
    Ok(server_codec.UnknownNotification(_)) -> state
    Error(_) -> handle_pending_response(state, line)
  }
}

fn handle_request(
  state: State,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> State {
  case request {
    jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(params))) ->
      case params.name {
        "trigger-sampling-request" ->
          start_sampling_interaction(state, id, params)
        "trigger-elicitation-request" ->
          start_elicitation_interaction(state, id)
        _ -> delegate_request(state, request)
      }
    _ -> delegate_request(state, request)
  }
}

fn handle_notification(
  state: State,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> State {
  let State(app_server, pending) = state
  let #(next_server, result) =
    server.handle_notification(app_server, notification)
  case result {
    Ok(_) -> State(next_server, pending)
    Error(error) -> {
      let jsonrpc.RpcError(code: code, message: message, ..) = error
      io.println_error("RPC error " <> int.to_string(code) <> ": " <> message)
      State(next_server, pending)
    }
  }
}

fn delegate_request(
  state: State,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> State {
  let State(app_server, pending) = state
  let #(next_server, response) = server.handle_request(app_server, request)
  respond(response)
  State(next_server, pending)
}

fn start_sampling_interaction(
  state: State,
  tool_call_id: jsonrpc.RequestId,
  params: actions.CallToolRequestParams,
) -> State {
  let request = sampling_request(params.arguments)
  io.println(client_codec.encode_server_request(request))
  let State(app_server, _) = state
  State(app_server, Some(PendingInteraction(tool_call_id, request, Sampling)))
}

fn start_elicitation_interaction(
  state: State,
  tool_call_id: jsonrpc.RequestId,
) -> State {
  let request = elicitation_request()
  io.println(client_codec.encode_server_request(request))
  let State(app_server, _) = state
  State(
    app_server,
    Some(PendingInteraction(tool_call_id, request, Elicitation)),
  )
}

fn handle_pending_response(state: State, line: String) -> State {
  let State(app_server, pending) = state
  case pending {
    None -> state
    Some(interaction) ->
      case decode_interaction_result(interaction, line) {
        Ok(result) -> {
          let PendingInteraction(tool_call_id, _, _) = interaction
          respond(jsonrpc.ResultResponse(
            tool_call_id,
            actions.ClientResultCallTool(result),
          ))
          State(app_server, None)
        }
        Error(Nil) -> state
      }
  }
}

fn decode_interaction_result(
  interaction: PendingInteraction,
  line: String,
) -> Result(actions.CallToolResult, Nil) {
  let PendingInteraction(_, request, kind) = interaction
  case client_codec.decode_server_response(line, request) {
    Ok(jsonrpc.ResultResponse(_, response)) ->
      case kind, response {
        Sampling, actions.ServerResultCreateMessage(result) ->
          Ok(sampling_tool_result(result))
        Elicitation, actions.ServerResultElicit(result) ->
          Ok(elicitation_tool_result(result))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn sampling_request(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> jsonrpc.Request(actions.ServerActionRequest) {
  let prompt = case arguments {
    Some(values) ->
      case dict.get(values, "prompt") {
        Ok(jsonrpc.VString(value)) -> value
        _ -> "Tell me something interesting about MCP."
      }
    None -> "Tell me something interesting about MCP."
  }
  let max_tokens = case arguments {
    Some(values) ->
      case dict.get(values, "maxTokens") {
        Ok(jsonrpc.VInt(value)) if value > 0 -> value
        _ -> 100
      }
    None -> 100
  }

  jsonrpc.Request(
    jsonrpc.StringId("everything-sample-1"),
    mcp.method_create_message,
    Some(
      actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
        messages: [
          actions.SamplingMessage(
            actions.User,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent(
                "Resource trigger-sampling-request context: " <> prompt,
                None,
                None,
              )),
            ),
            None,
          ),
        ],
        model_preferences: None,
        system_prompt: Some("You are a helpful test server."),
        include_context: None,
        temperature: Some(0.7),
        max_tokens: max_tokens,
        stop_sequences: [],
        metadata: None,
        tools: [],
        tool_choice: None,
        task: None,
        meta: None,
      )),
    ),
  )
}

fn elicitation_request() -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("everything-elicit-1"),
    mcp.method_elicit,
    Some(
      actions.ServerRequestElicit(
        actions.ElicitRequestForm(actions.ElicitRequestFormParams(
          "Please provide inputs for the following fields:",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("object")),
            #(
              "properties",
              jsonrpc.VObject([
                #(
                  "name",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("string")),
                    #("description", jsonrpc.VString("Your full, legal name")),
                  ]),
                ),
                #(
                  "check",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("boolean")),
                    #(
                      "description",
                      jsonrpc.VString("Agree to the terms and conditions"),
                    ),
                  ]),
                ),
                #(
                  "email",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("string")),
                    #("format", jsonrpc.VString("email")),
                    #("description", jsonrpc.VString("Your email address")),
                  ]),
                ),
                #(
                  "integer",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("integer")),
                    #("description", jsonrpc.VString("Your favorite integer")),
                  ]),
                ),
              ]),
            ),
            #("required", jsonrpc.VArray([jsonrpc.VString("name")])),
          ]),
          None,
          None,
        )),
      ),
    ),
  )
}

fn sampling_tool_result(
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

fn elicitation_tool_result(
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

fn respond(response: jsonrpc.Response(actions.ClientActionResult)) {
  io.println(server_codec.encode_response(response))
}

fn bool_to_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
