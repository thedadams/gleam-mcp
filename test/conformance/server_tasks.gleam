import conformance/server_content as content
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{type Value, VBool, VInt, VObject, VString}
import gleam_mcp/server
import gleam_mcp/task_store
import gleam_mcp/wire
import youid/uuid

/// Application behaviors for the official SEP-2663 task scenarios. All task
/// lifecycle, capability, transport, and wire handling remains in the SDK.
pub fn register(app: server.Server) -> server.Server {
  let app =
    server.add_tool_with_execution(
      app,
      "greet",
      "Return a greeting synchronously",
      content.schema([#("name", VObject([#("type", VString("string"))]))]),
      actions.TaskForbidden,
      fn(arguments) {
        content.argument_string(arguments, "name")
        |> result.map(fn(name) { tool_result("Hello, " <> name <> "!", False) })
      },
    )
  let app =
    server.add_tool_with_execution(
      app,
      "slow_compute",
      "Compute after the requested number of seconds",
      content.schema([
        #("seconds", VObject([#("type", VString("integer"))])),
        #("label", VObject([#("type", VString("string"))])),
      ]),
      actions.TaskOptional,
      fn(arguments) {
        use seconds <- result.try(seconds(arguments))
        process.sleep(seconds * 1000)
        Ok(tool_result("Computation complete", False))
      },
    )
  let app =
    server.add_tool_with_execution(
      app,
      "failing_job",
      "Complete a task with a tool execution error",
      content.schema([]),
      actions.TaskRequired,
      fn(_) {
        process.sleep(1000)
        Ok(tool_result("The requested job failed", True))
      },
    )
  let app =
    server.add_tool_with_execution(
      app,
      "protocol_error_job",
      "Crash a task worker to exercise the SDK monitor",
      content.schema([]),
      actions.TaskOptional,
      fn(_) { panic as "Conformance task worker crashed" },
    )
  let app =
    list.fold(
      [
        #(
          "confirm_delete",
          content.schema([
            #("filename", VObject([#("type", VString("string"))])),
          ]),
        ),
        #("multi_input", content.schema([])),
        #("test_tool_with_task", content.schema([])),
      ],
      app,
      fn(app, fixture) {
        server.add_tool_with_execution(
          app,
          fixture.0,
          "Collect input before completing an asynchronous task",
          fixture.1,
          actions.TaskRequired,
          fn(_) {
            Error(jsonrpc.invalid_params_error(
              "This application flow requires a modern task handler",
            ))
          },
        )
      },
    )
  server.with_extensions(
    app,
    dict.from_list([#("io.modelcontextprotocol/tasks", VObject([]))]),
  )
}

/// Route these fixture tools before the general MRTR fixture handler. None
/// leaves other tools, resources, and prompts to their existing handlers.
pub fn handle(
  app: server.Server,
  context: server.RequestContext,
  request: actions.ClientActionRequest,
) -> Option(Result(actions.ClientActionResult, jsonrpc.RpcError)) {
  case actions.request_without_input(request) {
    actions.ClientRequestCallTool(params) ->
      case params.name {
        "greet" | "slow_compute" | "failing_job" | "protocol_error_job" ->
          Some(server.dispatch_registered_tool(app, context, params))
        "confirm_delete" -> Some(confirm_delete(app, context, params.arguments))
        "multi_input" -> Some(multi_input(app, context))
        "test_tool_with_task" -> Some(compose(app, context, request))
        _ -> None
      }
    _ -> None
  }
}

fn confirm_delete(
  app: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  use filename <- result.try(content.argument_string(arguments, "filename"))
  let key = uuid.v4_string()
  server.create_modern_task(app, context, Some(60_000), fn() {
    Ok(
      task_store.ModernInputRequired(
        dict.from_list([
          #(key, form("Delete " <> filename <> "?", "confirm", "boolean")),
        ]),
        fn(inputs) {
          let confirmed =
            dict.get(inputs, key)
            |> option.from_result
            |> option.then(fn(value) { content.at(value, "content") })
            |> option.then(fn(value) { content.at(value, "confirm") })
          let message = case confirmed {
            Some(VBool(True)) -> "Deleted " <> filename
            _ -> "Deletion declined for " <> filename
          }
          Ok(completed(app, message))
        },
      ),
    )
  })
}

fn multi_input(
  app: server.Server,
  context: server.RequestContext,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let first = uuid.v4_string()
  let second = uuid.v4_string()
  server.create_modern_task(app, context, Some(60_000), fn() {
    Ok(
      task_store.ModernInputRequired(
        dict.from_list([
          #(first, form("What is your name?", "name", "string")),
          #(second, form("Please confirm", "confirm", "boolean")),
        ]),
        fn(_) { Ok(completed(app, "Both inputs received")) },
      ),
    )
  })
}

fn compose(
  app: server.Server,
  context: server.RequestContext,
  request: actions.ClientActionRequest,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let binding = "tools/call:test_tool_with_task"
  case actions.request_state(request) {
    None -> {
      let key = uuid.v4_string()
      Ok(
        actions.ClientResultInputRequired(actions.InputRequiredResult(
          Some(
            dict.from_list([
              #(key, form("What is your name?", "name", "string")),
            ]),
          ),
          Some(server.sign_request_state(app, context, binding, key, 60_000)),
          None,
        )),
      )
    }
    Some(state) -> {
      use key <- result.try(server.verify_request_state(
        app,
        context,
        binding,
        state,
      ))
      let name =
        actions.input_responses(request)
        |> option.then(fn(inputs) {
          dict.get(inputs, key) |> option.from_result
        })
        |> option.then(fn(value) {
          case content.at(value, "action") {
            Some(VString("accept")) -> content.at(value, "content")
            _ -> None
          }
        })
        |> option.then(fn(value) { content.at(value, "name") })
        |> content.string_value
      use name <- result.try(option.to_result(
        name,
        jsonrpc.invalid_params_error(
          "A name is required before creating the task",
        ),
      ))
      server.create_modern_task(app, context, Some(60_000), fn() {
        process.sleep(30)
        Ok(completed(app, "Hello, " <> name <> "!"))
      })
    }
  }
}

fn completed(app: server.Server, text: String) -> task_store.ModernOutcome {
  task_store.ModernComplete(wire.result_value(
    actions.ClientResultCallTool(tool_result(text, False)),
    jsonrpc.latest_protocol_version,
    server.implementation(app),
  ))
}

fn tool_result(text: String, error: Bool) -> actions.CallToolResult {
  actions.CallToolResult([content.text_block(text)], None, Some(error), None)
}

fn form(message: String, field: String, kind: String) -> Value {
  VObject([
    #("method", VString("elicitation/create")),
    #(
      "params",
      VObject([
        #("mode", VString("form")),
        #("message", VString(message)),
        #(
          "requestedSchema",
          content.schema([#(field, VObject([#("type", VString(kind))]))]),
        ),
      ]),
    ),
  ])
}

fn seconds(
  arguments: Option(dict.Dict(String, Value)),
) -> Result(Int, jsonrpc.RpcError) {
  case dict.get(content.option_to_dict(arguments), "seconds") {
    Ok(VInt(seconds)) if seconds >= 0 && seconds <= 60 -> Ok(seconds)
    _ ->
      Error(jsonrpc.invalid_params_error(
        "seconds must be an integer from 0 to 60",
      ))
  }
}
