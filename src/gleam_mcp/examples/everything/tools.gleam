import envoy
import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/codec_common
import gleam_mcp/examples/everything/form_schema
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/interaction_results
import gleam_mcp/examples/everything/resources
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/examples/everything/url_elicitation
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VObject, VString,
}
import gleam_mcp/server

pub const tiny_png =
  "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"

pub fn register_tools(
  app: server.Server,
  logger: Option(http_logging.Logger),
) -> server.Server {
  register_tools_with_url_store(app, logger, url_elicitation.new())
}

/// The factory retains the store to clear it when sessions close.
pub fn register_tools_with_url_store(
  app: server.Server,
  logger: Option(http_logging.Logger),
  store: url_elicitation.Store,
) -> server.Server {
  app
  |> register_base_tools(logger)
  |> register_sampling_tool
  |> register_form_elicitation_tool
  |> url_elicitation.register(store)
}

pub fn register_base_tools(
  app: server.Server,
  logger: Option(http_logging.Logger),
) -> server.Server {
  app
  |> register_read_only(
    "echo",
    "Echo Tool",
    "Echoes back the input string",
    helpers.object_schema(
      [#("message", helpers.string_schema("Message to echo"))],
      ["message"],
    ),
    None,
    echo_tool,
  )
  |> register_read_only(
    "get-sum",
    "Get Sum Tool",
    "Returns the sum of two numbers",
    helpers.object_schema(
      [
        #("a", helpers.number_schema("First number")),
        #("b", helpers.number_schema("Second number")),
      ],
      ["a", "b"],
    ),
    None,
    get_sum_tool,
  )
  |> register_read_only(
    "get-env",
    "Print Environment Tool",
    "Returns all environment variables, helpful for debugging MCP server configuration",
    helpers.empty_schema(),
    None,
    get_env_tool,
  )
  |> register_read_only(
    "get-structured-content",
    "Get Structured Content Tool",
    "Returns structured content along with an output schema for client data validation",
    helpers.object_schema(
      [
        #(
          "location",
          enum_schema(["New York", "Chicago", "Los Angeles"], "Choose city"),
        ),
      ],
      ["location"],
    ),
    Some(weather_output_schema()),
    get_structured_content_tool,
  )
  |> register_read_only(
    "get-tiny-image",
    "Get Tiny Image Tool",
    "Returns a tiny MCP logo image.",
    helpers.empty_schema(),
    None,
    get_tiny_image_tool,
  )
  |> register_read_only(
    "get-annotated-message",
    "Get Annotated Message Tool",
    "Demonstrates how annotations can be used to provide metadata about content.",
    helpers.object_schema(
      [
        #(
          "messageType",
          enum_schema(
            ["error", "success", "debug"],
            "Type of message to demonstrate different annotation patterns",
          ),
        ),
        #(
          "includeImage",
          VObject([
            #("type", VString("boolean")),
            #("default", VBool(False)),
            #("description", VString("Whether to include an example image")),
          ]),
        ),
      ],
      ["messageType"],
    ),
    None,
    get_annotated_message_tool,
  )
  |> register_read_only(
    "get-resource-links",
    "Get Resource Links Tool",
    "Returns up to ten resource links that reference different types of resources",
    helpers.object_schema(
      [
        #(
          "count",
          helpers.number_schema("Number of resource links to return (1-10)")
            |> helpers.with_property("minimum", VInt(1))
            |> helpers.with_property("maximum", VInt(10))
            |> helpers.with_property("default", VInt(3)),
        ),
      ],
      [],
    ),
    None,
    get_resource_links_tool,
  )
  |> register_read_only(
    "get-resource-reference",
    "Get Resource Reference Tool",
    "Returns a resource reference that can be used by MCP clients",
    helpers.object_schema(
      [
        #(
          "resourceType",
          VObject([
            #("type", VString("string")),
            #("enum", VArray([VString("Text"), VString("Blob")])),
            #("default", VString("Text")),
          ]),
        ),
        #(
          "resourceId",
          helpers.number_schema("ID of the text resource to fetch")
            |> helpers.with_property("default", VInt(1)),
        ),
      ],
      [],
    ),
    None,
    get_resource_reference_tool,
  )
  |> server.register_context_tool_descriptor(
    helpers.descriptor(
      "toggle-simulated-logging",
      "Toggle Simulated Logging",
      "Toggles simulated, random-leveled logging on or off.",
      helpers.empty_schema(),
      None,
      helpers.interactive_annotations(False),
    ),
    fn(server, context, arguments) {
      case logger {
        Some(logger) ->
          http_logging.toggle_tool(logger, server, context, arguments)
        None ->
          Error(jsonrpc.invalid_params_error(
            "toggle-simulated-logging is not available for this transport",
          ))
      }
      |> helpers.tool_result
    },
  )
}

pub fn register_conditional_tools(
  app: server.Server,
  capabilities: actions.ClientCapabilities,
) -> server.Server {
  let app = case capabilities.sampling {
    Some(_) -> register_sampling_tool(app)
    None -> app
  }
  let app = case capabilities.elicitation {
    Some(_) -> register_form_elicitation_tool(app)
    None -> app
  }
  case capabilities.elicitation {
    Some(actions.ClientElicitationCapabilities(url: Some(_), ..)) ->
      url_elicitation.register(app, url_elicitation.new())
    _ -> app
  }
}

pub fn is_available(
  name: String,
  capabilities: actions.ClientCapabilities,
) -> Bool {
  case name {
    "trigger-sampling-request" -> capabilities.sampling != None
    "trigger-elicitation-request" -> capabilities.elicitation != None
    "trigger-url-elicitation" ->
      case capabilities.elicitation {
        Some(actions.ClientElicitationCapabilities(url: Some(_), ..)) -> True
        _ -> False
      }
    _ -> True
  }
}

fn register_read_only(
  app: server.Server,
  name: String,
  title: String,
  description: String,
  input_schema: Value,
  output_schema: Option(Value),
  handler: server.ToolHandler,
) -> server.Server {
  server.register_tool_descriptor(
    app,
    helpers.descriptor(
      name,
      title,
      description,
      input_schema,
      output_schema,
      helpers.read_only_annotations(),
    ),
    fn(arguments) { handler(arguments) |> helpers.tool_result },
  )
}

fn register_sampling_tool(app: server.Server) -> server.Server {
  server.register_context_tool_descriptor(
    app,
    helpers.descriptor(
      "trigger-sampling-request",
      "Trigger Sampling Request Tool",
      "Trigger a Request from the Server for LLM Sampling",
      helpers.object_schema(
        [
          #("prompt", helpers.string_schema("The prompt to send to the LLM")),
          #(
            "maxTokens",
            helpers.number_schema("Maximum number of tokens to generate")
              |> helpers.with_property("default", VInt(100)),
          ),
        ],
        ["prompt"],
      ),
      None,
      helpers.interactive_annotations(True),
    ),
    fn(app, context, arguments) {
      trigger_sampling_request_tool(app, context, arguments)
      |> helpers.tool_result
    },
  )
}

fn register_form_elicitation_tool(app: server.Server) -> server.Server {
  server.register_context_tool_descriptor(
    app,
    helpers.descriptor(
      "trigger-elicitation-request",
      "Trigger Elicitation Request Tool",
      "Trigger a Request from the Server for User Elicitation",
      helpers.empty_schema(),
      None,
      helpers.interactive_annotations(False),
    ),
    fn(app, context, _) {
      server.elicit(
        server.with_request_timeout(app, 600_000),
        context,
        elicitation_request(),
      )
      |> result.map(interaction_results.elicitation_tool_result)
      |> helpers.tool_result
    },
  )
}

fn echo_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use message <- result.try(required_string(arguments, "message"))
  Ok(helpers.text_result("Echo: " <> message))
}

fn get_sum_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use a <- result.try(required_number(arguments, "a"))
  use b <- result.try(required_number(arguments, "b"))
  Ok(helpers.text_result(
    "The sum of "
    <> float_to_string(a)
    <> " and "
    <> float_to_string(b)
    <> " is "
    <> float_to_string(a +. b)
    <> ".",
  ))
}

fn get_env_tool(_) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let value =
    envoy.all()
    |> dict.to_list
    |> list.map(fn(field) { #(field.0, VString(field.1)) })
    |> VObject
  Ok(helpers.text_result(helpers.pretty_json(value)))
}

fn get_structured_content_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use location <- result.try(required_string(arguments, "location"))
  use weather <- result.try(structured_forecast(location))
  let text = weather |> codec_common.encode_value |> json.to_string
  let result = helpers.text_result(text)
  Ok(actions.CallToolResult(..result, structured_content: Some(weather)))
}

fn get_tiny_image_tool(_) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  Ok(
    helpers.content_result([
      text_block("Here's the image you requested:"),
      actions.ImageBlock(actions.ImageContent(tiny_png, "image/png", None, None)),
      text_block("The image above is the MCP logo."),
    ]),
  )
}

fn get_annotated_message_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use message_type <- result.try(required_string(arguments, "messageType"))
  use include_image <- result.try(optional_bool(
    arguments,
    "includeImage",
    False,
  ))
  use main <- result.try(annotated_message(message_type))
  let image = case include_image {
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
  Ok(helpers.content_result([main, ..image]))
}

fn get_resource_links_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use count <- result.try(optional_number(arguments, "count", 3.0))
  case count <. 1.0 || count >. 10.0 {
    True ->
      Error(jsonrpc.invalid_params_error("count must be between 1 and 10"))
    False -> {
      let links =
        int.range(
          from: 1,
          to: float.truncate(count) + 1,
          with: [],
          run: fn(acc, id) {
            let resource = case int.is_even(id) {
              True -> resources.text_resource(id)
              False -> resources.blob_resource(id)
            }
            let resource =
              actions.Resource(
                ..resource,
                name: case int.is_even(id) {
                    True -> "Text"
                    False -> "Blob"
                  }
                  <> " Resource "
                  <> int.to_string(id),
                description: Some(
                  "Resource "
                  <> int.to_string(id)
                  <> ": "
                  <> case resource.mime_type {
                    Some("text/plain") -> "plaintext resource"
                    _ -> "binary blob resource"
                  },
                ),
              )
            [actions.ResourceLinkBlock(actions.ResourceLink(resource)), ..acc]
          },
        )
        |> list.reverse
      Ok(
        helpers.content_result([
          text_block(
            "Here are "
            <> float_to_string(count)
            <> " resource links to resources available in this server:",
          ),
          ..links
        ]),
      )
    }
  }
}

fn get_resource_reference_tool(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use resource_type <- result.try(optional_string(
    arguments,
    "resourceType",
    "Text",
  ))
  use id <- result.try(optional_number(arguments, "resourceId", 1.0))
  let integer = float.truncate(id)
  case id == int.to_float(integer) && integer > 0 {
    False ->
      Error(jsonrpc.invalid_params_error(
        "resourceId must be a finite positive integer",
      ))
    True -> {
      use resource <- result.try(case resource_type {
        "Text" -> Ok(resources.text_resource_contents(integer))
        "Blob" -> Ok(resources.blob_resource_contents(integer))
        _ ->
          Error(jsonrpc.invalid_params_error(
            "resourceType must be Text or Blob",
          ))
      })
      let uri = case resource {
        actions.TextResourceContents(uri: uri, ..)
        | actions.BlobResourceContents(uri: uri, ..) -> uri
      }
      Ok(
        helpers.content_result([
          text_block(
            "Returning resource reference for Resource "
            <> int.to_string(integer)
            <> ":",
          ),
          actions.EmbeddedResourceBlock(actions.EmbeddedResource(
            resource,
            None,
            None,
          )),
          text_block("You can access this resource using the URI: " <> uri),
        ]),
      )
    }
  }
}

fn trigger_sampling_request_tool(
  app: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use params <- result.try(sampling_request(arguments))
  case server.create_message(app, context, params) {
    Ok(actions.ServerResultCreateMessage(value)) ->
      Ok(interaction_results.sampling_tool_result(value))
    Ok(_) ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected result for sampling request",
      ))
    Error(error) -> Error(error)
  }
}

pub fn sampling_request(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CreateMessageRequestParams, jsonrpc.RpcError) {
  use prompt <- result.try(required_string(arguments, "prompt"))
  use max_tokens <- result.try(optional_number(arguments, "maxTokens", 100.0))
  let integer = float.truncate(max_tokens)
  case max_tokens == int.to_float(integer) {
    False -> Error(jsonrpc.invalid_params_error("maxTokens must be an integer"))
    True ->
      Ok(actions.CreateMessageRequestParams(
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
        max_tokens: integer,
        stop_sequences: [],
        metadata: None,
        tools: [],
        tool_choice: None,
        task: None,
        meta: None,
      ))
  }
}

pub fn elicitation_request() -> actions.ElicitRequestParams {
  actions.ElicitRequestForm(actions.ElicitRequestFormParams(
    "Please provide inputs for the following fields:",
    form_schema.requested_schema(),
    None,
    None,
  ))
}

fn annotated_message(
  message_type: String,
) -> Result(actions.ContentBlock, jsonrpc.RpcError) {
  let outcome = case message_type {
    "error" ->
      Ok(#("Error: Operation failed", [actions.User, actions.Assistant], 1.0))
    "success" -> Ok(#("Operation completed successfully", [actions.User], 0.7))
    "debug" ->
      Ok(#(
        "Debug: Cache hit ratio 0.95, latency 150ms",
        [actions.Assistant],
        0.3,
      ))
    _ ->
      Error(jsonrpc.invalid_params_error(
        "messageType must be error, success, or debug",
      ))
  }
  use #(text, audience, priority) <- result.try(outcome)
  Ok(
    actions.TextBlock(actions.TextContent(
      text,
      Some(actions.Annotations(audience, Some(priority), None)),
      None,
    )),
  )
}

fn structured_forecast(location: String) -> Result(Value, jsonrpc.RpcError) {
  case location {
    "New York" -> Ok(weather(33, "Cloudy", 82))
    "Chicago" -> Ok(weather(36, "Light rain / drizzle", 82))
    "Los Angeles" -> Ok(weather(73, "Sunny / Clear", 48))
    _ ->
      Error(jsonrpc.invalid_params_error(
        "location must be New York, Chicago, or Los Angeles",
      ))
  }
}

fn weather(temperature: Int, conditions: String, humidity: Int) -> Value {
  VObject([
    #("temperature", VInt(temperature)),
    #("conditions", VString(conditions)),
    #("humidity", VInt(humidity)),
  ])
}

fn weather_output_schema() -> Value {
  helpers.object_schema(
    [
      #("temperature", helpers.number_schema("Temperature in celsius")),
      #("conditions", helpers.string_schema("Weather conditions description")),
      #("humidity", helpers.number_schema("Humidity percentage")),
    ],
    ["temperature", "conditions", "humidity"],
  )
  |> helpers.with_property("additionalProperties", VBool(False))
}

fn enum_schema(values: List(String), description: String) -> Value {
  helpers.string_schema(description)
  |> helpers.with_property("enum", VArray(list.map(values, VString)))
}

fn text_block(text: String) -> actions.ContentBlock {
  actions.TextBlock(actions.TextContent(text, None, None))
}

pub fn required_string(
  arguments: Option(dict.Dict(String, Value)),
  key: String,
) -> Result(String, jsonrpc.RpcError) {
  case helpers.argument(arguments, key) {
    Some(VString(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error(key <> " must be a string"))
  }
}

pub fn optional_string(
  arguments: Option(dict.Dict(String, Value)),
  key: String,
  default: String,
) -> Result(String, jsonrpc.RpcError) {
  case helpers.argument(arguments, key) {
    Some(VString(value)) -> Ok(value)
    None -> Ok(default)
    _ -> Error(jsonrpc.invalid_params_error(key <> " must be a string"))
  }
}

fn required_number(
  arguments: Option(dict.Dict(String, Value)),
  key: String,
) -> Result(Float, jsonrpc.RpcError) {
  case helpers.argument(arguments, key) {
    Some(VInt(value)) -> Ok(int.to_float(value))
    Some(VFloat(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error(key <> " must be a number"))
  }
}

fn optional_number(
  arguments: Option(dict.Dict(String, Value)),
  key: String,
  default: Float,
) -> Result(Float, jsonrpc.RpcError) {
  case helpers.argument(arguments, key) {
    None -> Ok(default)
    _ -> required_number(arguments, key)
  }
}

pub fn optional_bool(
  arguments: Option(dict.Dict(String, Value)),
  key: String,
  default: Bool,
) -> Result(Bool, jsonrpc.RpcError) {
  case helpers.argument(arguments, key) {
    Some(VBool(value)) -> Ok(value)
    None -> Ok(default)
    _ -> Error(jsonrpc.invalid_params_error(key <> " must be a boolean"))
  }
}

pub fn float_to_string(value: Float) -> String {
  let integer = float.truncate(value)
  case value == int.to_float(integer) {
    True -> int.to_string(integer)
    False -> float.to_string(value)
  }
}
