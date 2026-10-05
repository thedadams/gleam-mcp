import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/client_tasks
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VObject, VString,
}
import gleam_mcp/server

const stages = [
  "Gathering sources",
  "Analyzing content",
  "Synthesizing findings",
  "Generating report",
]

pub fn register(app: server.Server) -> server.Server {
  app
  |> server.register_context_tool_descriptor(
    helpers.descriptor(
      "trigger-long-running-operation",
      "Trigger Long Running Operation Tool",
      "Demonstrates a long running operation with progress updates.",
      helpers.object_schema(
        [
          #(
            "duration",
            helpers.with_property(
              helpers.number_schema("Duration of the operation in seconds"),
              "default",
              VInt(10),
            ),
          ),
          #(
            "steps",
            helpers.with_property(
              helpers.number_schema("Number of steps in the operation"),
              "default",
              VInt(5),
            ),
          ),
        ],
        [],
      ),
      None,
      helpers.read_only_annotations(),
    ),
    long_running,
  )
  |> server.register_context_tool_descriptor(research_descriptor(), research)
  |> client_tasks.register
}

fn research_descriptor() -> actions.Tool {
  let descriptor =
    helpers.descriptor(
      "simulate-research-query",
      "Simulate Research Query",
      "Simulates a deep research operation that gathers, analyzes, and synthesizes information. Demonstrates MCP task-based operations with progress through multiple stages. If 'ambiguous' is true and client supports elicitation, sends an elicitation request for clarification.",
      helpers.object_schema(
        [
          #("topic", helpers.string_schema("The research topic to investigate")),
          #(
            "ambiguous",
            VObject([
              #("type", VString("boolean")),
              #("default", VBool(False)),
              #(
                "description",
                VString(
                  "Simulate an ambiguous query that requires clarification (triggers input_required status)",
                ),
              ),
            ]),
          ),
        ],
        ["topic"],
      ),
      None,
      helpers.interactive_annotations(False),
    )
  actions.Tool(
    ..descriptor,
    execution: Some(actions.ToolExecution(Some(actions.TaskRequired))),
  )
}

pub fn long_running(
  app: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use duration <- result.try(number_argument(arguments, "duration", 10.0))
  use steps <- result.try(number_argument(arguments, "steps", 5.0))
  run_steps(app, context, duration, steps, 1)
  Ok(helpers.text_result(
    "Long running operation completed. Duration: "
    <> number_text(duration)
    <> " seconds, Steps: "
    <> number_text(steps)
    <> ".",
  ))
}

fn run_steps(
  app: server.Server,
  context: server.RequestContext,
  duration: Float,
  steps: Float,
  index: Int,
) -> Nil {
  case int.to_float(index) <. steps +. 1.0 {
    True -> {
      // Like setTimeout in the reference, nonpositive delays run immediately.
      process.sleep(int.max(float.truncate(duration /. steps *. 1000.0), 0))
      let _ =
        server.report_progress(
          app,
          context,
          int.to_float(index),
          Some(steps),
          None,
        )
      run_steps(app, context, duration, steps, index + 1)
    }
    False -> Nil
  }
}

pub fn research(
  app: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use topic <- result.try(string_argument(arguments, "topic"))
  use ambiguous <- result.try(bool_argument(arguments, "ambiguous", False))
  let ambiguous = ambiguous && supports_elicitation(app, context)
  let clarification =
    research_stages(app, context, topic, ambiguous, stages, 0, None)
  Ok(helpers.text_result(research_report(topic, clarification)))
}

fn research_stages(
  app: server.Server,
  context: server.RequestContext,
  topic: String,
  ambiguous: Bool,
  remaining: List(String),
  index: Int,
  clarification: Option(String),
) -> Option(String) {
  case remaining {
    [] -> clarification
    [stage, ..rest] -> {
      update_status(app, context, actions.Working, stage <> "...")
      let clarification = case index == 2 && ambiguous {
        True -> {
          update_status(
            app,
            context,
            actions.InputRequired,
            "Found multiple interpretations for \""
              <> topic
              <> "\". Requesting clarification...",
          )
          let clarification = clarify(app, context, topic)
          update_status(
            app,
            context,
            actions.Working,
            "Continuing with interpretation: \"" <> clarification <> "\"...",
          )
          Some(clarification)
        }
        False -> clarification
      }
      process.sleep(1000)
      research_stages(
        app,
        context,
        topic,
        ambiguous,
        rest,
        index + 1,
        clarification,
      )
    }
  }
}

fn update_status(
  app: server.Server,
  context: server.RequestContext,
  status: actions.TaskStatus,
  message: String,
) -> Nil {
  case server.task_id(context) {
    Some(id) -> {
      let _ = server.update_task_status(app, context, id, status, Some(message))
      Nil
    }
    None -> Nil
  }
}

fn supports_elicitation(
  app: server.Server,
  context: server.RequestContext,
) -> Bool {
  case server.session_id(context) {
    Some(id) ->
      case server.session_metadata(app, id) {
        Some(metadata) ->
          case metadata.client_capabilities.elicitation {
            Some(_) -> True
            None -> False
          }
        None -> False
      }
    None -> False
  }
}

fn clarify(
  app: server.Server,
  context: server.RequestContext,
  topic: String,
) -> String {
  let schema =
    VObject([
      #("type", VString("object")),
      #(
        "properties",
        VObject([
          #(
            "interpretation",
            VObject([
              #("type", VString("string")),
              #("title", VString("Clarification")),
              #(
                "description",
                VString("Which interpretation of the topic do you mean?"),
              ),
              #("oneOf", VArray(interpretations(topic))),
            ]),
          ),
        ]),
      ),
      #("required", VArray([VString("interpretation")])),
    ])
  let response =
    server.elicit(
      app,
      context,
      actions.ElicitRequestForm(actions.ElicitRequestFormParams(
        "The research query \""
          <> topic
          <> "\" could have multiple interpretations. Please clarify what you're looking for:",
        schema,
        None,
        None,
      )),
    )
  case response {
    Ok(actions.ElicitResult(actions.ElicitAccept, Some(content), _)) ->
      case dict.get(content, "interpretation") {
        Ok(actions.ElicitString(value)) if value != "" -> value
        _ -> "User accepted without selection"
      }
    Ok(actions.ElicitResult(actions.ElicitAccept, None, _)) ->
      "User accepted without selection"
    Ok(actions.ElicitResult(actions.ElicitDecline, _, _)) ->
      "User declined - using default interpretation"
    Ok(actions.ElicitResult(actions.ElicitCancel, _, _)) ->
      "User cancelled - using default interpretation"
    Error(_) -> "technical (default - elicitation unavailable)"
  }
}

pub fn interpretations(topic: String) -> List(Value) {
  let choices = case string.contains(string.lowercase(topic), "python") {
    True -> [
      #("programming", "Python programming language"),
      #("snake", "Python snake species"),
      #("comedy", "Monty Python comedy group"),
    ]
    False -> [
      #("technical", "Technical/scientific perspective"),
      #("historical", "Historical perspective"),
      #("current", "Current events/news perspective"),
    ]
  }
  list.map(choices, fn(choice) {
    VObject([#("const", VString(choice.0)), #("title", VString(choice.1))])
  })
}

pub fn research_report(topic: String, clarification: Option(String)) -> String {
  let display_topic = case clarification {
    Some(value) -> topic <> " (" <> value <> ")"
    None -> topic
  }
  let clarification_parameter = case clarification {
    Some(value) -> "- **Clarification**: " <> value
    None -> ""
  }
  let clarification_status = case clarification {
    Some(_) -> "`input_required` → `working` → "
    None -> ""
  }
  let elicitation_flow = case clarification {
    None -> ""
    Some(value) ->
      "**Elicitation Flow:**\nWhen the query was ambiguous, the server sent an `elicitation/create` request\nto the client. The task status changed to `input_required` while awaiting user input.\n"
      <> case string.contains(value, "unavailable") {
        True ->
          "**Note:** Elicitation failed and a default interpretation was used."
        False ->
          "After receiving clarification (\""
          <> value
          <> "\"), the task resumed processing and completed."
      }
      <> "\n"
  }
  "# Research Report: "
  <> display_topic
  <> "\n\n## Research Parameters\n- **Topic**: "
  <> topic
  <> "\n"
  <> clarification_parameter
  <> "\n\n## Synthesis\nThis research query was processed through 4 stages:\n"
  <> string.join(
    list.index_map(stages, fn(stage, index) {
      "- Stage " <> int.to_string(index + 1) <> ": " <> stage <> " ✓"
    }),
    "\n",
  )
  <> "\n\n---\n\n## About This Demo (SEP-1686: Tasks)\n\nThis tool demonstrates MCP's task-based execution pattern for long-running operations:\n\n**Task Lifecycle Demonstrated:**\n1. `tools/call` with `task` parameter → Server returns `CreateTaskResult` (not the final result)\n2. Client polls `tasks/get` → Server returns current status and `statusMessage`\n3. Status progressed: `working` → "
  <> clarification_status
  <> "`completed`\n4. Client calls `tasks/result` → Server returns this final result\n\n"
  <> elicitation_flow
  <> "\n**Key Concepts:**\n- Tasks enable \"call now, fetch later\" patterns\n- `statusMessage` provides human-readable progress updates\n- Tasks have TTL (time-to-live) for automatic cleanup\n- `pollInterval` suggests how often to check status\n- Elicitation requests use `relatedTask` to queue via tasks/result (works on all transports)\n\n*This is a simulated research report from the Everything MCP Server.*\n"
}

pub fn string_argument(
  arguments: Option(dict.Dict(String, Value)),
  name: String,
) -> Result(String, jsonrpc.RpcError) {
  case helpers.argument(arguments, name) {
    Some(VString(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error(name <> " must be a string"))
  }
}

pub fn number_argument(
  arguments: Option(dict.Dict(String, Value)),
  name: String,
  default: Float,
) -> Result(Float, jsonrpc.RpcError) {
  case helpers.argument(arguments, name) {
    None -> Ok(default)
    Some(VInt(value)) -> Ok(int.to_float(value))
    Some(VFloat(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error(name <> " must be a number"))
  }
}

fn bool_argument(
  arguments: Option(dict.Dict(String, Value)),
  name: String,
  default: Bool,
) -> Result(Bool, jsonrpc.RpcError) {
  case helpers.argument(arguments, name) {
    None -> Ok(default)
    Some(VBool(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error(name <> " must be a boolean"))
  }
}

fn number_text(value: Float) -> String {
  case value == int.to_float(float.truncate(value)) {
    True -> int.to_string(float.truncate(value))
    False -> float.to_string(value)
  }
}
