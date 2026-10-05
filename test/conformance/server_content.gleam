import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{type Value, VArray, VObject, VString}
import gleam_mcp/server

pub const image =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

pub const audio = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="

pub fn register(app: server.Server) -> server.Server {
  let app =
    list.fold(
      [
        "test_simple_text",
        "test_image_content",
        "test_audio_content",
        "test_embedded_resource",
        "test_multiple_content_types",
        "test_error_handling",
      ],
      app,
      fn(app, name) {
        server.add_tool(
          app,
          name,
          "Conformance content fixture",
          schema([]),
          fn(_) { tool(name) },
        )
      },
    )
  let app =
    list.fold(
      [
        #("test://static-text", "Static Text", "text/plain"),
        #("test://static-binary", "Static Binary", "image/png"),
        #("test://watched-resource", "Watched Resource", "text/plain"),
        #("test://stateless-static-text", "Stateless Text", "text/plain"),
      ],
      app,
      fn(app, fixture) {
        server.add_resource(
          app,
          fixture.0,
          fixture.1,
          "Conformance resource fixture",
          Some(fixture.2),
          fn() { resource(fixture.0) },
        )
      },
    )
  app
  |> server.add_resource_template(
    "test://template/{id}/data",
    "Resource Template",
    "Conformance parameter substitution fixture",
    Some("application/json"),
    resource,
  )
  |> server.add_prompt(
    "test_simple_prompt",
    "A simple prompt without arguments",
    [],
    fn(arguments) { prompt("test_simple_prompt", arguments) },
  )
  |> server.add_prompt(
    "test_prompt_with_arguments",
    "A prompt with required arguments",
    [argument("arg1"), argument("arg2")],
    fn(arguments) { prompt("test_prompt_with_arguments", arguments) },
  )
  |> server.add_prompt(
    "test_prompt_with_embedded_resource",
    "A prompt that embeds a resource",
    [argument("resourceUri")],
    fn(arguments) { prompt("test_prompt_with_embedded_resource", arguments) },
  )
  |> server.add_prompt(
    "test_prompt_with_image",
    "A prompt that includes an image",
    [],
    fn(arguments) { prompt("test_prompt_with_image", arguments) },
  )
}

pub fn tool(name: String) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case name {
    "test_simple_text" ->
      Ok(text_result("This is a simple text response for testing."))
    "test_image_content" -> Ok(content_result([image_block()]))
    "test_audio_content" ->
      Ok(
        content_result([
          actions.AudioBlock(actions.AudioContent(
            audio,
            "audio/wav",
            None,
            None,
          )),
        ]),
      )
    "test_embedded_resource" ->
      Ok(
        content_result([
          embedded(
            "test://embedded-resource",
            "This is an embedded resource content.",
          ),
        ]),
      )
    "test_multiple_content_types" ->
      Ok(
        content_result([
          text_block("Multiple content types test:"),
          image_block(),
          embedded("test://mixed-content-resource", "Mixed content resource"),
        ]),
      )
    "test_error_handling" ->
      Ok(actions.CallToolResult(
        [text_block("This tool intentionally returns an error for testing")],
        None,
        Some(True),
        None,
      ))
    _ -> Error(jsonrpc.invalid_params_error("Unknown tool: " <> name))
  }
}

pub fn resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  case uri {
    "test://static-binary" ->
      Ok([actions.BlobResourceContents(uri, Some("image/png"), image, None)])
    "test://static-text" ->
      Ok([
        text_resource(
          uri,
          "This is the content of the static text resource.",
          "text/plain",
        ),
      ])
    "test://stateless-static-text" ->
      Ok([
        text_resource(
          uri,
          "Static text content from the stateless path.",
          "text/plain",
        ),
      ])
    "test://watched-resource" ->
      Ok([text_resource(uri, "Watched resource content", "text/plain")])
    _ -> {
      case
        string.starts_with(uri, "test://template/")
        && string.ends_with(uri, "/data")
      {
        True -> {
          let id = uri |> string.drop_start(16) |> string.drop_end(5)
          let text =
            json.object([
              #("id", json.string(id)),
              #("templateTest", json.bool(True)),
              #("data", json.string("Data for ID: " <> id)),
            ])
            |> json.to_string
          Ok([text_resource(uri, text, "application/json")])
        }
        False ->
          Error(jsonrpc.RpcError(
            -32_602,
            "Resource not found",
            Some(VObject([#("uri", VString(uri))])),
          ))
      }
    }
  }
}

pub fn prompt(
  name: String,
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  let messages = case name {
    "test_simple_prompt" ->
      Ok([text_block("This is a simple prompt for testing.")])
    "test_prompt_with_image" ->
      Ok([image_block(), text_block("Please analyze the image above.")])
    "test_prompt_with_arguments" -> {
      use arg1 <- result.try(prompt_argument(arguments, "arg1"))
      use arg2 <- result.try(prompt_argument(arguments, "arg2"))
      Ok([
        text_block(
          "Prompt with arguments: arg1='" <> arg1 <> "', arg2='" <> arg2 <> "'",
        ),
      ])
    }
    "test_prompt_with_embedded_resource" -> {
      use uri <- result.try(prompt_argument(arguments, "resourceUri"))
      Ok([
        embedded(uri, "Embedded resource content for testing."),
        text_block("Please process the embedded resource above."),
      ])
    }
    _ -> Error(jsonrpc.invalid_params_error("Unknown prompt: " <> name))
  }
  messages
  |> result.map(fn(blocks) {
    actions.GetPromptResult(
      Some("Conformance prompt"),
      list.map(blocks, fn(block) { actions.PromptMessage(actions.User, block) }),
      None,
    )
  })
}

pub fn text_result(text: String) -> actions.CallToolResult {
  content_result([text_block(text)])
}

pub fn content_result(
  content: List(actions.ContentBlock),
) -> actions.CallToolResult {
  actions.CallToolResult(content, None, Some(False), None)
}

pub fn text_block(text: String) -> actions.ContentBlock {
  actions.TextBlock(actions.TextContent(text, None, None))
}

fn image_block() -> actions.ContentBlock {
  actions.ImageBlock(actions.ImageContent(image, "image/png", None, None))
}

fn embedded(uri: String, text: String) -> actions.ContentBlock {
  actions.EmbeddedResourceBlock(actions.EmbeddedResource(
    text_resource(uri, text, "text/plain"),
    None,
    None,
  ))
}

fn text_resource(
  uri: String,
  text: String,
  mime: String,
) -> actions.ResourceContents {
  actions.TextResourceContents(uri, Some(mime), text, None)
}

fn argument(name: String) -> actions.PromptArgument {
  actions.PromptArgument(name, None, Some("Conformance argument"), Some(True))
}

fn prompt_argument(
  arguments: Option(dict.Dict(String, String)),
  name: String,
) -> Result(String, jsonrpc.RpcError) {
  arguments
  |> option_to_dict
  |> dict.get(name)
  |> result.map_error(fn(_) {
    jsonrpc.invalid_params_error("Missing argument: " <> name)
  })
}

pub fn schema(fields: List(#(String, Value))) -> Value {
  VObject([
    #("type", VString("object")),
    #("properties", VObject(fields)),
    #("required", VArray(list.map(fields, fn(field) { VString(field.0) }))),
  ])
}

pub fn option_to_dict(value: Option(dict.Dict(k, v))) -> dict.Dict(k, v) {
  case value {
    Some(value) -> value
    None -> dict.new()
  }
}

pub fn at(value: Value, name: String) -> Option(Value) {
  case value {
    VObject(fields) ->
      dict.get(dict.from_list(fields), name) |> option.from_result
    _ -> None
  }
}

pub fn string_value(value: Option(Value)) -> Option(String) {
  case value {
    Some(VString(value)) -> Some(value)
    _ -> None
  }
}

pub fn argument_string(
  arguments: Option(dict.Dict(String, Value)),
  name: String,
) -> Result(String, jsonrpc.RpcError) {
  case dict.get(option_to_dict(arguments), name) {
    Ok(VString(value)) -> Ok(value)
    _ ->
      Error(jsonrpc.invalid_params_error("Missing string argument: " <> name))
  }
}
