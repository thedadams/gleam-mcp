import gleam/dict
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities as server_capabilities
import gleam_mcp/server/codec as server_codec
import stdin

type PendingInteraction {
  PendingInteraction(
    tool_call_id: jsonrpc.RequestId,
    request: jsonrpc.Request(actions.ServerActionRequest),
    prefix: String,
  )
}

type State {
  State(pending: Option(PendingInteraction))
}

pub fn main() -> Nil {
  let _ =
    stdin.read_lines() |> yielder.fold(from: State(None), with: handle_line)
  Nil
}

fn handle_line(state: State, line: String) -> State {
  case server_codec.decode_message(line) {
    Ok(server_codec.ClientActionRequest(request)) ->
      handle_request(state, request)
    Ok(server_codec.ActionNotification(_)) -> state
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
    jsonrpc.Request(id, _, Some(actions.ClientRequestInitialize(_))) -> {
      respond(jsonrpc.ResultResponse(id, initialize_result()))
      state
    }
    jsonrpc.Request(id, _, Some(actions.ClientRequestListTools(_))) -> {
      respond(jsonrpc.ResultResponse(id, list_tools_result()))
      state
    }
    jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(params))) ->
      start_interaction(id, params.name)
    jsonrpc.Request(id, method, _) -> {
      respond(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.method_not_found_error(method),
      ))
      state
    }
    jsonrpc.Notification(_, _) -> state
  }
}

fn start_interaction(tool_call_id: jsonrpc.RequestId, name: String) -> State {
  let pending = case name {
    "roundtrip-sampling" ->
      PendingInteraction(tool_call_id, sampling_request(), "Sampled: ")
    _ ->
      PendingInteraction(tool_call_id, elicitation_request(name), "Elicited: ")
  }

  let PendingInteraction(request:, ..) = pending
  io.println(client_codec.encode_server_request(request))
  State(Some(pending))
}

fn handle_pending_response(state: State, line: String) -> State {
  let State(pending) = state
  case pending {
    None -> state
    Some(interaction) ->
      case interaction_response(interaction, line) {
        Ok(text) -> {
          let PendingInteraction(tool_call_id, _, prefix) = interaction
          respond(jsonrpc.ResultResponse(
            tool_call_id,
            actions.ClientResultCallTool(actions.CallToolResult(
              content: [
                actions.TextBlock(actions.TextContent(
                  prefix <> text,
                  None,
                  None,
                )),
              ],
              structured_content: None,
              is_error: Some(False),
              meta: None,
            )),
          ))
          State(None)
        }
        Error(Nil) -> state
      }
  }
}

fn interaction_response(
  interaction: PendingInteraction,
  line: String,
) -> Result(String, Nil) {
  let PendingInteraction(_, request, _) = interaction
  case request {
    jsonrpc.Request(_, _, Some(actions.ServerRequestCreateMessage(_))) ->
      extract_json_string(line, "text")
    _ ->
      case client_codec.decode_server_response(line, request) {
        Ok(jsonrpc.ResultResponse(_, actions.ServerResultElicit(result))) ->
          extract_elicitation_text(result)
        Ok(jsonrpc.ResultResponse(_, actions.ServerResultCreateMessage(result))) ->
          extract_sampling_text(result)
        _ -> Error(Nil)
      }
  }
}

fn extract_json_string(body: String, field: String) -> Result(String, Nil) {
  let marker = "\"" <> field <> "\":\""
  case string.split(body, on: marker) {
    [_before, after, ..] ->
      case string.split(after, on: "\"") {
        [value, ..] -> Ok(value)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn extract_elicitation_text(result: actions.ElicitResult) -> Result(String, Nil) {
  let actions.ElicitResult(_, content, _) = result
  case content {
    Some(fields) ->
      case dict.get(fields, "answer") {
        Ok(actions.ElicitString(value)) -> Ok(value)
        _ -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

fn extract_sampling_text(
  result: actions.CreateMessageResult,
) -> Result(String, Nil) {
  let actions.CreateMessageResult(message:, ..) = result
  let actions.SamplingMessage(content:, ..) = message
  case content {
    actions.SingleSamplingContent(actions.SamplingText(actions.TextContent(
      text:,
      ..,
    ))) -> Ok(text)
    _ -> Error(Nil)
  }
}

fn initialize_result() -> actions.ClientActionResult {
  actions.ClientResultInitialize(actions.InitializeResult(
    protocol_version: jsonrpc.latest_protocol_version,
    capabilities: server_capabilities.infer(
      has_tools: True,
      has_resources: False,
      has_prompts: False,
      has_completion: False,
      has_logging: False,
      has_tasks: False,
    ),
    server_info: actions.Implementation(
      name: "server-sent-stdio-test-server",
      version: "0.1.0",
      title: None,
      description: None,
      website_url: None,
      icons: [],
    ),
    instructions: None,
    meta: None,
  ))
}

fn list_tools_result() -> actions.ClientActionResult {
  actions.ClientResultListTools(actions.ListToolsResult(
    tools: [
      actions.Tool(
        name: "roundtrip-elicitation",
        title: None,
        description: Some("Roundtrip test tool"),
        input_schema: jsonrpc.VObject([]),
        execution: None,
        output_schema: None,
        annotations: None,
        icons: [],
        meta: None,
      ),
      actions.Tool(
        name: "roundtrip-sampling",
        title: None,
        description: Some("Roundtrip test tool"),
        input_schema: jsonrpc.VObject([]),
        execution: None,
        output_schema: None,
        annotations: None,
        icons: [],
        meta: None,
      ),
    ],
    page: actions.Page(None),
    meta: None,
  ))
}

fn elicitation_request(
  name: String,
) -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("elicit-1"),
    mcp.method_elicit,
    Some(
      actions.ServerRequestElicit(
        actions.ElicitRequestForm(actions.ElicitRequestFormParams(
          "Please provide a value for requst " <> name,
          jsonrpc.VObject([
            #("type", jsonrpc.VString("object")),
            #(
              "properties",
              jsonrpc.VObject([
                #(
                  "answer",
                  jsonrpc.VObject([#("type", jsonrpc.VString("string"))]),
                ),
              ]),
            ),
            #("required", jsonrpc.VArray([jsonrpc.VString("answer")])),
          ]),
          None,
          None,
        )),
      ),
    ),
  )
}

fn sampling_request() -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("sample-1"),
    mcp.method_create_message,
    Some(
      actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
        messages: [
          actions.SamplingMessage(
            actions.User,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent(
                "Return the integration-test sample",
                None,
                None,
              )),
            ),
            None,
          ),
        ],
        model_preferences: None,
        system_prompt: None,
        include_context: None,
        temperature: None,
        max_tokens: 32,
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

fn respond(response: jsonrpc.Response(actions.ClientActionResult)) {
  io.println(server_codec.encode_response(response))
}
