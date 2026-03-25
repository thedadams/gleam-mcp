import envoy
import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/resources
import gleam_mcp/jsonrpc
import gleam_mcp/server

pub const tiny_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII="

pub fn register_tools(app_server: server.Server) -> server.Server {
  app_server
  |> server.add_tool(
    "echo",
    "Echo a message back to the caller",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #("message", jsonrpc.VObject([#("type", jsonrpc.VString("string"))])),
        ]),
      ),
      #("required", jsonrpc.VArray([jsonrpc.VString("message")])),
    ]),
    echo_tool,
  )
  |> server.add_tool(
    "get-sum",
    "Add two numbers and return the result",
    number_pair_schema(),
    get_sum_tool,
  )
  |> server.add_tool(
    "get-env",
    "Return the current process environment as JSON text",
    empty_object_schema(),
    get_env_tool,
  )
  |> server.add_tool(
    "get-structured-content",
    "Return structured weather-like content and text",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #("location", jsonrpc.VObject([#("type", jsonrpc.VString("string"))])),
        ]),
      ),
      #("required", jsonrpc.VArray([jsonrpc.VString("location")])),
    ]),
    get_structured_content_tool,
  )
  |> server.add_tool(
    "get-tiny-image",
    "Return a tiny PNG image with surrounding text",
    empty_object_schema(),
    get_tiny_image_tool,
  )
  |> server.add_tool(
    "get-annotated-message",
    "Return annotated text and optional image content",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #(
            "messageType",
            jsonrpc.VObject([
              #("type", jsonrpc.VString("string")),
              #(
                "enum",
                jsonrpc.VArray([
                  jsonrpc.VString("error"),
                  jsonrpc.VString("success"),
                  jsonrpc.VString("debug"),
                ]),
              ),
            ]),
          ),
          #(
            "includeImage",
            jsonrpc.VObject([#("type", jsonrpc.VString("boolean"))]),
          ),
        ]),
      ),
      #("required", jsonrpc.VArray([jsonrpc.VString("messageType")])),
    ]),
    get_annotated_message_tool,
  )
  |> server.add_tool(
    "get-resource-links",
    "Return resource links for generated text and blob resources",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #("count", jsonrpc.VObject([#("type", jsonrpc.VString("integer"))])),
        ]),
      ),
    ]),
    get_resource_links_tool,
  )
  |> server.add_tool(
    "get-resource-reference",
    "Return an embedded text or blob resource",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #(
            "resourceType",
            jsonrpc.VObject([#("type", jsonrpc.VString("string"))]),
          ),
          #(
            "resourceId",
            jsonrpc.VObject([#("type", jsonrpc.VString("integer"))]),
          ),
        ]),
      ),
      #(
        "required",
        jsonrpc.VArray([
          jsonrpc.VString("resourceType"),
          jsonrpc.VString("resourceId"),
        ]),
      ),
    ]),
    get_resource_reference_tool,
  )
  |> server.add_tool_with_context(
    "trigger-sampling-request",
    "Ask the connected MCP client to create a sampled message",
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #("prompt", jsonrpc.VObject([#("type", jsonrpc.VString("string"))])),
          #(
            "maxTokens",
            jsonrpc.VObject([#("type", jsonrpc.VString("integer"))]),
          ),
        ]),
      ),
      #("required", jsonrpc.VArray([jsonrpc.VString("prompt")])),
    ]),
    trigger_sampling_request_tool,
  )
  |> server.add_tool_with_context(
    "trigger-elicitation-request",
    "Ask the connected MCP client to collect elicited input",
    empty_object_schema(),
    trigger_elicitation_request_tool,
  )
  |> server.add_tool(
    "toggle-simulated-logging",
    "Toggle periodic simulated logging notifications for the current session",
    empty_object_schema(),
    unsupported_server_interaction_tool,
  )
}

fn echo_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case required_string(arguments, "message") {
    Ok(message) ->
      Ok(
        text_result([
          actions.TextBlock(actions.TextContent("Echo: " <> message, None, None)),
        ]),
      )
    Error(error) -> Error(error)
  }
}

fn get_sum_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case required_number(arguments, "a"), required_number(arguments, "b") {
    Ok(a), Ok(b) -> {
      let total = a +. b
      Ok(
        text_result([
          actions.TextBlock(actions.TextContent(
            "The sum of "
              <> float_to_string(a)
              <> " and "
              <> float_to_string(b)
              <> " is "
              <> float_to_string(total)
              <> ".",
            None,
            None,
          )),
        ]),
      )
    }
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}

fn get_env_tool(
  _arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let payload =
    envoy.all()
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(key, value) = entry
      #(key, json.string(value))
    })
    |> json.object
    |> json.to_string

  Ok(
    text_result([
      actions.TextBlock(actions.TextContent(payload, None, None)),
    ]),
  )
}

fn get_structured_content_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case required_string(arguments, "location") {
    Ok(location) -> {
      let structured_content = structured_forecast(location)
      Ok(actions.CallToolResult(
        content: [
          actions.TextBlock(actions.TextContent(
            structured_content
              |> dict.to_list
              |> list.map(value_pair_to_json)
              |> json.object
              |> json.to_string,
            None,
            None,
          )),
        ],
        structured_content: Some(structured_content),
        is_error: Some(False),
        meta: None,
      ))
    }
    Error(error) -> Error(error)
  }
}

fn get_tiny_image_tool(
  _arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  Ok(
    text_result([
      actions.TextBlock(actions.TextContent(
        "Here's the image you requested:",
        None,
        None,
      )),
      actions.ImageBlock(actions.ImageContent(tiny_png, "image/png", None, None)),
      actions.TextBlock(actions.TextContent(
        "The image above is a tiny demo PNG.",
        None,
        None,
      )),
    ]),
  )
}

fn get_annotated_message_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case required_string(arguments, "messageType") {
    Ok(message_type) -> {
      let include_image = optional_bool(arguments, "includeImage", False)
      let #(text, annotations) =
        annotated_message(string.lowercase(message_type))
      let image_blocks = case include_image {
        True -> [
          actions.ImageBlock(actions.ImageContent(
            tiny_png,
            "image/png",
            Some(actions.Annotations([actions.User], Some(0.5), None)),
            None,
          )),
        ]
        False -> []
      }

      Ok(
        text_result([
          actions.TextBlock(actions.TextContent(text, Some(annotations), None)),
          ..image_blocks
        ]),
      )
    }
    Error(error) -> Error(error)
  }
}

fn get_resource_links_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let count = optional_int(arguments, "count", 3)
  case count >= 1 && count <= 10 {
    False ->
      Error(jsonrpc.invalid_params_error("count must be between 1 and 10"))
    True -> {
      let intro =
        actions.TextBlock(actions.TextContent(
          "Returning " <> int.to_string(count) <> " resource links.",
          None,
          None,
        ))
      let links =
        int.range(from: 1, to: count + 1, with: [], run: fn(acc, index) {
          [
            case int.is_even(index) {
              True ->
                actions.ResourceLinkBlock(
                  actions.ResourceLink(resources.text_resource(index)),
                )
              False ->
                actions.ResourceLinkBlock(
                  actions.ResourceLink(resources.blob_resource(index)),
                )
            },
            ..acc
          ]
        })
        |> list.reverse
      Ok(text_result([intro, ..links]))
    }
  }
}

fn get_resource_reference_tool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case
    required_string(arguments, "resourceType"),
    required_int(arguments, "resourceId")
  {
    Ok(resource_type), Ok(resource_id) if resource_id > 0 -> {
      let lowered = string.lowercase(resource_type)
      case lowered {
        "text" ->
          Ok(
            text_result([
              actions.TextBlock(actions.TextContent(
                "Embedding text resource " <> int.to_string(resource_id) <> ".",
                None,
                None,
              )),
              actions.EmbeddedResourceBlock(actions.EmbeddedResource(
                resources.text_resource_contents(resource_id),
                None,
                None,
              )),
              actions.TextBlock(actions.TextContent(
                "URI: " <> resources.text_resource_uri(resource_id),
                None,
                None,
              )),
            ]),
          )
        "blob" ->
          Ok(
            text_result([
              actions.TextBlock(actions.TextContent(
                "Embedding blob resource " <> int.to_string(resource_id) <> ".",
                None,
                None,
              )),
              actions.EmbeddedResourceBlock(actions.EmbeddedResource(
                resources.blob_resource_contents(resource_id),
                None,
                None,
              )),
              actions.TextBlock(actions.TextContent(
                "URI: " <> resources.blob_resource_uri(resource_id),
                None,
                None,
              )),
            ]),
          )
        _ ->
          Error(jsonrpc.invalid_params_error(
            "resourceType must be Text or Blob",
          ))
      }
    }
    Ok(_), Ok(_) ->
      Error(jsonrpc.invalid_params_error(
        "resourceId must be a positive integer",
      ))
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}

fn trigger_sampling_request_tool(
  app_server: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case server.create_message(app_server, context, sampling_request(arguments)) {
    Ok(actions.ServerResultCreateMessage(result)) ->
      Ok(sampling_tool_result(result))
    Ok(_) ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected result for sampling request",
      ))
    Error(error) -> Error(error)
  }
}

fn trigger_elicitation_request_tool(
  app_server: server.Server,
  context: server.RequestContext,
  _arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  server.elicit(app_server, context, elicitation_request())
  |> result.map(elicitation_tool_result)
}

fn unsupported_server_interaction_tool(
  _arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  Ok(actions.CallToolResult(
    content: [
      actions.TextBlock(actions.TextContent(
        "This tool needs a transport-specific interactive loop. Use the stdio Everything server entrypoint to exercise it.",
        None,
        None,
      )),
    ],
    structured_content: None,
    is_error: Some(True),
    meta: None,
  ))
}

fn sampling_request(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> actions.CreateMessageRequestParams {
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

  actions.CreateMessageRequestParams(
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
  )
}

fn elicitation_request() -> actions.ElicitRequestParams {
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
  ))
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

fn bool_to_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn text_result(content: List(actions.ContentBlock)) -> actions.CallToolResult {
  actions.CallToolResult(
    content: content,
    structured_content: None,
    is_error: Some(False),
    meta: None,
  )
}

fn required_string(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
) -> Result(String, jsonrpc.RpcError) {
  case value(arguments, key) {
    Ok(jsonrpc.VString(value)) -> Ok(value)
    Ok(_) -> Error(jsonrpc.invalid_params_error(key <> " must be a string"))
    Error(error) -> Error(error)
  }
}

fn required_int(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
) -> Result(Int, jsonrpc.RpcError) {
  case value(arguments, key) {
    Ok(jsonrpc.VInt(value)) -> Ok(value)
    Ok(_) -> Error(jsonrpc.invalid_params_error(key <> " must be an integer"))
    Error(error) -> Error(error)
  }
}

fn required_number(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
) -> Result(Float, jsonrpc.RpcError) {
  case value(arguments, key) {
    Ok(jsonrpc.VInt(value)) -> Ok(int.to_float(value))
    Ok(jsonrpc.VFloat(value)) -> Ok(value)
    Ok(_) -> Error(jsonrpc.invalid_params_error(key <> " must be a number"))
    Error(error) -> Error(error)
  }
}

fn optional_bool(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
  fallback: Bool,
) -> Bool {
  case arguments {
    Some(values) ->
      case dict.get(values, key) {
        Ok(jsonrpc.VBool(value)) -> value
        _ -> fallback
      }
    None -> fallback
  }
}

fn optional_int(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
  fallback: Int,
) -> Int {
  case arguments {
    Some(values) ->
      case dict.get(values, key) {
        Ok(jsonrpc.VInt(value)) -> value
        _ -> fallback
      }
    None -> fallback
  }
}

fn value(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
) -> Result(jsonrpc.Value, jsonrpc.RpcError) {
  case arguments {
    Some(values) ->
      case dict.get(values, key) {
        Ok(value) -> Ok(value)
        Error(Nil) -> Error(jsonrpc.invalid_params_error(key <> " is required"))
      }
    None -> Error(jsonrpc.invalid_params_error(key <> " is required"))
  }
}

fn annotated_message(message_type: String) -> #(String, actions.Annotations) {
  case message_type {
    "error" -> #(
      "Error: Operation failed",
      actions.Annotations([actions.User, actions.Assistant], Some(1.0), None),
    )
    "success" -> #(
      "Operation completed successfully",
      actions.Annotations([actions.User], Some(0.7), None),
    )
    _ -> #(
      "Debug: Detailed diagnostic output",
      actions.Annotations([actions.Assistant], Some(0.3), None),
    )
  }
}

fn structured_forecast(location: String) -> dict.Dict(String, jsonrpc.Value) {
  let normalized = string.lowercase(location)
  case normalized {
    "new york" ->
      dict.from_list([
        #("temperature", jsonrpc.VInt(33)),
        #("conditions", jsonrpc.VString("Cloudy")),
        #("humidity", jsonrpc.VInt(82)),
      ])
    "chicago" ->
      dict.from_list([
        #("temperature", jsonrpc.VInt(36)),
        #("conditions", jsonrpc.VString("Light rain / drizzle")),
        #("humidity", jsonrpc.VInt(82)),
      ])
    "los angeles" ->
      dict.from_list([
        #("temperature", jsonrpc.VInt(73)),
        #("conditions", jsonrpc.VString("Sunny / Clear")),
        #("humidity", jsonrpc.VInt(48)),
      ])
    _ ->
      dict.from_list([
        #("temperature", jsonrpc.VInt(68)),
        #("conditions", jsonrpc.VString("Partly cloudy")),
        #("humidity", jsonrpc.VInt(55)),
      ])
  }
}

fn value_pair_to_json(entry: #(String, jsonrpc.Value)) -> #(String, json.Json) {
  let #(key, value) = entry
  #(key, jsonrpc_value_to_json(value))
}

fn jsonrpc_value_to_json(value: jsonrpc.Value) -> json.Json {
  case value {
    jsonrpc.VNull -> json.null()
    jsonrpc.VString(text) -> json.string(text)
    jsonrpc.VInt(number) -> json.int(number)
    jsonrpc.VFloat(number) -> json.float(number)
    jsonrpc.VBool(boolean) -> json.bool(boolean)
    jsonrpc.VArray(values) ->
      json.array(from: values, of: jsonrpc_value_to_json)
    jsonrpc.VObject(entries) ->
      entries
      |> list.map(value_pair_to_json)
      |> json.object
  }
}

fn empty_object_schema() -> jsonrpc.Value {
  jsonrpc.VObject([#("type", jsonrpc.VString("object"))])
}

fn number_pair_schema() -> jsonrpc.Value {
  jsonrpc.VObject([
    #("type", jsonrpc.VString("object")),
    #(
      "properties",
      jsonrpc.VObject([
        #("a", jsonrpc.VObject([#("type", jsonrpc.VString("number"))])),
        #("b", jsonrpc.VObject([#("type", jsonrpc.VString("number"))])),
      ]),
    ),
    #("required", jsonrpc.VArray([jsonrpc.VString("a"), jsonrpc.VString("b")])),
  ])
}

fn float_to_string(value: Float) -> String {
  case value == int.to_float(float_to_int(value)) {
    True -> int.to_string(float_to_int(value))
    False -> float.to_string(value)
  }
}

@external(erlang, "erlang", "trunc")
fn float_to_int(value: Float) -> Int
