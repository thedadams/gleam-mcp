import conformance/server_content as content
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VObject, VString,
}
import gleam_mcp/mcp
import gleam_mcp/server

pub fn register(app: server.Server) -> server.Server {
  list.fold(
    [
      #("test_tool_with_logging", content.schema([])),
      #("test_tool_with_progress", content.schema([])),
      #(
        "test_sampling",
        content.schema([#("prompt", VObject([#("type", VString("string"))]))]),
      ),
      #(
        "test_elicitation",
        content.schema([#("message", VObject([#("type", VString("string"))]))]),
      ),
      #("test_elicitation_sep1034_defaults", content.schema([])),
      #("test_elicitation_sep1330_enums", content.schema([])),
      #("test_streaming_elicitation", content.schema([])),
      #("test_logging_tool", content.schema([])),
      #("test_trigger_tool_change", content.schema([])),
      #("test_trigger_prompt_change", content.schema([])),
    ],
    app,
    fn(app, fixture) {
      server.add_tool_with_context(
        app,
        fixture.0,
        "Conformance interaction fixture",
        fixture.1,
        fn(app, context, arguments) { run(app, context, fixture.0, arguments) },
      )
    },
  )
}

pub fn run(
  app: server.Server,
  context: server.RequestContext,
  name: String,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case name {
    "test_tool_with_progress" | "test_streaming_elicitation" -> {
      use _ <- result.try(server.report_progress(
        app,
        context,
        0.0,
        Some(100.0),
        Some("Started"),
      ))
      process.sleep(50)
      use _ <- result.try(server.report_progress(
        app,
        context,
        50.0,
        Some(100.0),
        Some("Processing"),
      ))
      process.sleep(50)
      use _ <- result.try(server.report_progress(
        app,
        context,
        100.0,
        Some(100.0),
        Some("Completed"),
      ))
      Ok(content.text_result("Progress tool completed"))
    }
    "test_tool_with_logging" -> {
      use _ <- result.try(log(app, context, "Tool execution started"))
      process.sleep(50)
      use _ <- result.try(log(app, context, "Tool processing data"))
      process.sleep(50)
      use _ <- result.try(log(app, context, "Tool execution completed"))
      Ok(content.text_result("Tool with logging executed successfully"))
    }
    "test_logging_tool" -> {
      // The SDK gates modern logs using the per-request logLevel metadata.
      let _ = log(app, context, "Diagnostic trace logging activated")
      Ok(content.text_result("Logging evaluated"))
    }
    "test_sampling" -> {
      use prompt <- result.try(content.argument_string(arguments, "prompt"))
      use response <- result.try(server.create_message(
        app,
        context,
        sampling(prompt),
      ))
      case response {
        actions.ServerResultCreateMessage(response) ->
          Ok(content.text_result(
            "LLM response: " <> sampling_text(response.message.content),
          ))
        _ -> Error(jsonrpc.invalid_params_error("Unexpected sampling response"))
      }
    }
    "test_elicitation" -> {
      use message <- result.try(content.argument_string(arguments, "message"))
      elicit(
        app,
        context,
        message,
        content.schema([
          #("username", VObject([#("type", VString("string"))])),
          #("email", VObject([#("type", VString("string"))])),
        ]),
      )
    }
    "test_elicitation_sep1034_defaults" ->
      elicit(
        app,
        context,
        "Please review the fields with defaults",
        defaults_schema(),
      )
    "test_elicitation_sep1330_enums" ->
      elicit(
        app,
        context,
        "Please select options from the enum fields",
        enums_schema(),
      )
    "test_trigger_tool_change" -> {
      server.publish_notification(
        app,
        jsonrpc.Notification(
          mcp.method_notify_tools_list_changed,
          Some(actions.NotifyToolListChanged(None)),
        ),
      )
      Ok(content.text_result("Tool list changed"))
    }
    "test_trigger_prompt_change" -> {
      server.publish_notification(
        app,
        jsonrpc.Notification(
          mcp.method_notify_prompts_list_changed,
          Some(actions.NotifyPromptListChanged(None)),
        ),
      )
      Ok(content.text_result("Prompt list changed"))
    }
    _ -> content.tool(name)
  }
}

fn log(
  app: server.Server,
  context: server.RequestContext,
  text: String,
) -> Result(Nil, jsonrpc.RpcError) {
  server.send_notification(
    app,
    context,
    jsonrpc.Notification(
      mcp.method_notify_logging_message,
      Some(
        actions.NotifyLoggingMessage(actions.LoggingMessageNotificationParams(
          actions.Info,
          Some("conformance-test-server"),
          VString(text),
          None,
        )),
      ),
    ),
  )
}

fn elicit(
  app: server.Server,
  context: server.RequestContext,
  message: String,
  schema: Value,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  server.elicit(
    app,
    context,
    actions.ElicitRequestForm(actions.ElicitRequestFormParams(
      message,
      schema,
      None,
      None,
    )),
  )
  |> result.map(fn(response) {
    content.text_result("Elicitation completed: " <> string.inspect(response))
  })
}

pub fn sampling(prompt: String) -> actions.CreateMessageRequestParams {
  actions.CreateMessageRequestParams(
    messages: [
      actions.SamplingMessage(
        actions.User,
        actions.SingleSamplingContent(
          actions.SamplingText(actions.TextContent(prompt, None, None)),
        ),
        None,
      ),
    ],
    model_preferences: None,
    system_prompt: None,
    include_context: None,
    temperature: None,
    max_tokens: 100,
    stop_sequences: [],
    metadata: None,
    tools: [],
    tool_choice: None,
    task: None,
    meta: None,
  )
}

fn sampling_text(value: actions.SamplingContent) -> String {
  case value {
    actions.SingleSamplingContent(actions.SamplingText(text)) -> text.text
    actions.MultipleSamplingContent(values) ->
      values
      |> list.filter_map(fn(value) {
        case value {
          actions.SamplingText(text) -> Ok(text.text)
          _ -> Error(Nil)
        }
      })
      |> string.join(" ")
    _ -> "Non-text sampling response"
  }
}

fn defaults_schema() -> Value {
  VObject([
    #("type", VString("object")),
    #(
      "properties",
      VObject([
        #("name", field("string", VString("John Doe"))),
        #("age", field("integer", VInt(30))),
        #("score", field("number", VFloat(95.5))),
        #(
          "status",
          VObject([
            #("type", VString("string")),
            #("enum", strings(["active", "inactive", "pending"])),
            #("default", VString("active")),
          ]),
        ),
        #("verified", field("boolean", VBool(True))),
      ]),
    ),
    #("required", VArray([])),
  ])
}

fn field(kind: String, default: Value) -> Value {
  VObject([#("type", VString(kind)), #("default", default)])
}

fn strings(values: List(String)) -> Value {
  VArray(list.map(values, VString))
}

fn enums_schema() -> Value {
  let titled =
    VArray([
      VObject([
        #("const", VString("value1")),
        #("title", VString("First Choice")),
      ]),
      VObject([
        #("const", VString("value2")),
        #("title", VString("Second Choice")),
      ]),
      VObject([
        #("const", VString("value3")),
        #("title", VString("Third Choice")),
      ]),
    ])
  VObject([
    #("type", VString("object")),
    #(
      "properties",
      VObject([
        #(
          "untitledSingle",
          VObject([
            #("type", VString("string")),
            #("enum", strings(["option1", "option2", "option3"])),
          ]),
        ),
        #(
          "titledSingle",
          VObject([#("type", VString("string")), #("oneOf", titled)]),
        ),
        #(
          "legacyEnum",
          VObject([
            #("type", VString("string")),
            #("enum", strings(["opt1", "opt2", "opt3"])),
            #(
              "enumNames",
              strings(["Option One", "Option Two", "Option Three"]),
            ),
          ]),
        ),
        #(
          "untitledMulti",
          VObject([
            #("type", VString("array")),
            #(
              "items",
              VObject([
                #("type", VString("string")),
                #("enum", strings(["option1", "option2", "option3"])),
              ]),
            ),
          ]),
        ),
        #(
          "titledMulti",
          VObject([
            #("type", VString("array")),
            #(
              "items",
              VObject([#("type", VString("string")), #("anyOf", titled)]),
            ),
          ]),
        ),
      ]),
    ),
    #("required", VArray([])),
  ])
}
