import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_decode
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc.{type Value, VArray, VFloat, VInt, VObject, VString}
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec
import youid/uuid

type Kind {
  Sampling
  Elicitation
}

type PollResult {
  PollResult(task: actions.Task, attempts: Int, history: List(String))
}

type ChildMessage {
  Finished(reply: process.Subject(Nil))
  ParentDown
}

type Child {
  Child(subject: process.Subject(ChildMessage))
}

pub fn register(app: server.Server) -> server.Server {
  app
  |> server.register_context_tool_descriptor(
    helpers.descriptor(
      "trigger-sampling-request-async",
      "Trigger Async Sampling Request Tool",
      "Trigger an async sampling request that the CLIENT executes as a background task. Demonstrates bidirectional MCP tasks where the server sends a request and the client executes it asynchronously, allowing the server to poll for progress and results.",
      helpers.object_schema(
        [
          #("prompt", helpers.string_schema("The prompt to send to the LLM")),
          #(
            "maxTokens",
            helpers.with_property(
              helpers.number_schema("Maximum number of tokens to generate"),
              "default",
              VInt(100),
            ),
          ),
        ],
        ["prompt"],
      ),
      None,
      helpers.interactive_annotations(True),
    ),
    sampling,
  )
  |> server.register_context_tool_descriptor(
    helpers.descriptor(
      "trigger-elicitation-request-async",
      "Trigger Async Elicitation Request Tool",
      "Trigger an async elicitation request that the CLIENT executes as a background task. Demonstrates bidirectional MCP tasks where the server sends an elicitation request and the client handles user input asynchronously, allowing the server to poll for completion.",
      helpers.empty_schema(),
      None,
      helpers.interactive_annotations(False),
    ),
    elicitation,
  )
}

pub fn sampling(
  app: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use prompt <- result.try(case helpers.argument(arguments, "prompt") {
    Some(VString(value)) -> Ok(value)
    _ -> Error(jsonrpc.invalid_params_error("prompt must be a string"))
  })
  use max_tokens <- result.try(case helpers.argument(arguments, "maxTokens") {
    None -> Ok(100)
    Some(VInt(value)) -> Ok(value)
    Some(VFloat(value)) -> {
      let integral = float.truncate(value)
      case value == int.to_float(integral) {
        True -> Ok(integral)
        False ->
          Error(jsonrpc.invalid_params_error("maxTokens must be an integer"))
      }
    }
    _ -> Error(jsonrpc.invalid_params_error("maxTokens must be a number"))
  })
  use response <- result.try(server.create_message(
    app,
    context,
    actions.CreateMessageRequestParams(
      [
        actions.SamplingMessage(
          actions.User,
          actions.SingleSamplingContent(
            actions.SamplingText(actions.TextContent(
              "Resource trigger-sampling-request-async context: " <> prompt,
              None,
              None,
            )),
          ),
          None,
        ),
      ],
      None,
      Some("You are a helpful test server."),
      None,
      Some(0.7),
      max_tokens,
      [],
      None,
      [],
      None,
      Some(actions.TaskMetadata(Some(300_000))),
      None,
    ),
  ))
  case response {
    actions.ServerResultCreateTask(created) ->
      follow(app, context, created.task, Sampling)
    actions.ServerResultCreateMessage(_) ->
      Ok(helpers.text_result(
        "[SYNC] Client executed synchronously:\n" <> pretty_result(response),
      ))
    _ ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected sampling result",
      ))
  }
}

pub fn elicitation(
  app: server.Server,
  context: server.RequestContext,
  _arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use response <- result.try(server.elicit_with_tasks(
    app,
    context,
    actions.ElicitRequestForm(actions.ElicitRequestFormParams(
      "Please provide inputs for the following fields (async task demo):",
      elicitation_schema(),
      Some(actions.TaskMetadata(Some(600_000))),
      None,
    )),
  ))
  case response {
    actions.ElicitTask(created) ->
      follow(app, context, created.task, Elicitation)
    actions.Elicit(value) ->
      Ok(helpers.text_result(
        "[SYNC] Client executed synchronously:\n"
        <> pretty_result(actions.ServerResultElicit(value)),
      ))
  }
}

pub fn elicitation_schema() -> Value {
  VObject([
    #("type", VString("object")),
    #(
      "properties",
      VObject([
        #(
          "name",
          VObject([
            #("title", VString("Your Name")),
            #("type", VString("string")),
            #("description", VString("Your full name")),
          ]),
        ),
        #(
          "favoriteColor",
          VObject([
            #("title", VString("Favorite Color")),
            #("type", VString("string")),
            #("description", VString("What is your favorite color?")),
            #(
              "enum",
              VArray(list.map(
                ["Red", "Blue", "Green", "Yellow", "Purple"],
                VString,
              )),
            ),
          ]),
        ),
        #(
          "agreeToTerms",
          VObject([
            #("title", VString("Terms Agreement")),
            #("type", VString("boolean")),
            #(
              "description",
              VString("Do you agree to the terms and conditions?"),
            ),
          ]),
        ),
      ]),
    ),
    #("required", VArray([VString("name")])),
  ])
}

fn follow(
  app: server.Server,
  context: server.RequestContext,
  task: actions.Task,
  kind: Kind,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let child = track_child(app, context, task.task_id)
  let max_attempts = case kind {
    Sampling -> 60
    Elicitation -> 600
  }
  let polled =
    poll(app, context, task, kind, 0, max_attempts, [
      "Task created: " <> task.task_id,
    ])
  let output = case polled {
    Error(error) -> Error(error)
    Ok(PollResult(task, attempts, history)) -> {
      let history = string.join(list.reverse(history), "\n")
      case attempts >= max_attempts {
        True ->
          Ok(helpers.text_result(
            "[TIMEOUT] Task timed out after "
            <> int.to_string(max_attempts)
            <> " poll attempts\n\nProgress:\n"
            <> history,
          ))
        False ->
          case task.status {
            actions.Failed | actions.Cancelled ->
              Ok(helpers.text_result(
                "["
                <> string.uppercase(status_name(task.status))
                <> "] "
                <> option.unwrap(task.status_message, "No message")
                <> "\n\nProgress:\n"
                <> history,
              ))
            _ -> {
              use result <- result.try(task_result(app, context, task.task_id))
              case kind, result {
                Sampling, actions.TaskCreateMessage(_) ->
                  Ok(helpers.text_result(
                    "[COMPLETED] Async sampling completed!\n\n**Progress:**\n"
                    <> history
                    <> "\n\n**Result:**\n"
                    <> pretty_result(actions.ServerResultTaskResult(result)),
                  ))
                Elicitation, actions.TaskElicit(value) ->
                  Ok(elicitation_result(value, history))
                _, _ ->
                  Error(jsonrpc.invalid_params_error(
                    "Client task returned an unexpected result",
                  ))
              }
            }
          }
      }
    }
  }
  finish_child(child)
  output
}

fn poll(
  app: server.Server,
  context: server.RequestContext,
  task: actions.Task,
  kind: Kind,
  attempts: Int,
  maximum: Int,
  history: List(String),
) -> Result(PollResult, jsonrpc.RpcError) {
  case terminal(task.status) || attempts >= maximum {
    True -> Ok(PollResult(task, attempts, history))
    False -> {
      process.sleep(1000)
      use task <- result.try(get_task(app, context, task.task_id))
      let attempts = attempts + 1
      let history = case
        kind == Sampling
        || attempts == 1
        || attempts % 10 == 0
        || task.status != actions.InputRequired
      {
        True -> [
          "Poll "
            <> int.to_string(attempts)
            <> ": "
            <> status_name(task.status)
            <> case task.status_message {
            Some(message) if message != "" -> " - " <> message
            _ -> ""
          },
          ..history
        ]
        False -> history
      }
      poll(app, context, task, kind, attempts, maximum, history)
    }
  }
}

fn get_task(
  app: server.Server,
  context: server.RequestContext,
  id: String,
) -> Result(actions.Task, jsonrpc.RpcError) {
  case
    send(
      app,
      context,
      mcp.method_get_task,
      actions.ServerRequestGetTask(actions.TaskIdParams(id)),
    )
  {
    Ok(actions.ServerResultGetTask(result)) -> Ok(result.task)
    Error(error) -> Error(error)
    _ ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected task status",
      ))
  }
}

fn task_result(
  app: server.Server,
  context: server.RequestContext,
  id: String,
) -> Result(actions.TaskResult, jsonrpc.RpcError) {
  case
    send(
      app,
      context,
      mcp.method_get_task_result,
      actions.ServerRequestGetTaskResult(actions.TaskIdParams(id)),
    )
  {
    Ok(actions.ServerResultTaskResult(result)) -> Ok(result)
    Error(error) -> Error(error)
    _ ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected task result",
      ))
  }
}

fn send(
  app: server.Server,
  context: server.RequestContext,
  method: String,
  action: actions.ServerActionRequest,
) -> Result(actions.ServerActionResult, jsonrpc.RpcError) {
  case
    server.send_request(
      app,
      context,
      jsonrpc.Request(jsonrpc.StringId(uuid.v4_string()), method, Some(action)),
    )
  {
    Ok(jsonrpc.ResultResponse(_, result)) -> Ok(result)
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(error)
    Error(error) -> Error(error)
  }
}

fn terminal(status: actions.TaskStatus) -> Bool {
  case status {
    actions.Completed | actions.Failed | actions.Cancelled -> True
    _ -> False
  }
}

fn status_name(status: actions.TaskStatus) -> String {
  case status {
    actions.Working -> "working"
    actions.InputRequired -> "input_required"
    actions.Completed -> "completed"
    actions.Failed -> "failed"
    actions.Cancelled -> "cancelled"
  }
}

fn pretty_result(result: actions.ServerActionResult) -> String {
  let encoded =
    codec.encode_server_response(jsonrpc.ResultResponse(
      jsonrpc.IntId(0),
      result,
    ))
  let decoder = {
    use value <- decode.field("result", codec_decode.value_decoder())
    decode.success(value)
  }
  let assert Ok(value) = json.parse(encoded, decoder)
  helpers.pretty_json(value)
}

pub fn elicitation_result(
  value: actions.ElicitResult,
  history: String,
) -> actions.CallToolResult {
  let content = case value.action, value.content {
    actions.ElicitAccept, Some(fields) -> {
      let lines =
        [
          field_line(fields, "name", "Name"),
          field_line(fields, "favoriteColor", "Favorite Color"),
          field_line(fields, "agreeToTerms", "Agreed to terms"),
        ]
        |> list.filter_map(fn(value) {
          case value {
            Some(text) -> Ok(text)
            None -> Error(Nil)
          }
        })
      [
        text("[COMPLETED] User provided the requested information!"),
        text("User inputs:\n" <> string.join(lines, "\n")),
      ]
    }
    actions.ElicitDecline, _ -> [
      text("[DECLINED] User declined to provide the requested information."),
    ]
    actions.ElicitCancel, _ -> [
      text("[CANCELLED] User cancelled the elicitation dialog."),
    ]
    _, _ -> []
  }
  helpers.content_result(
    list.append(content, [
      text(
        "\nProgress:\n"
        <> history
        <> "\n\nRaw result: "
        <> pretty_result(actions.ServerResultElicit(value)),
      ),
    ]),
  )
}

fn field_line(
  fields: dict.Dict(String, actions.ElicitValue),
  key: String,
  label: String,
) -> Option(String) {
  case dict.get(fields, key) {
    Ok(actions.ElicitString(value)) if value != "" ->
      Some("- " <> label <> ": " <> value)
    Ok(actions.ElicitBool(value)) ->
      Some(
        "- "
        <> label
        <> ": "
        <> case value {
          True -> "true"
          False -> "false"
        },
      )
    _ -> None
  }
}

fn text(value: String) -> actions.ContentBlock {
  actions.TextBlock(actions.TextContent(value, None, None))
}

// A cancelled incoming tool worker must not leave its client-side task running.
// This monitor only sends tasks/cancel when the peer advertises that method.
fn track_child(
  app: server.Server,
  context: server.RequestContext,
  id: String,
) -> Child {
  let parent = process.self()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      let monitor = process.monitor(parent)
      process.send(ready, subject)
      let message =
        process.new_selector()
        |> process.select(subject)
        |> process.select_specific_monitor(monitor, fn(_) { ParentDown })
        |> process.selector_receive_forever
      case message {
        Finished(reply) -> {
          process.demonitor_process(monitor)
          process.send(reply, Nil)
        }
        ParentDown ->
          case supports_cancel(app, context) {
            True -> {
              let _ =
                send(
                  app,
                  context,
                  mcp.method_cancel_task,
                  actions.ServerRequestCancelTask(actions.TaskIdParams(id)),
                )
              Nil
            }
            False -> Nil
          }
      }
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Child(subject)
}

fn finish_child(child: Child) -> Nil {
  let reply = process.new_subject()
  process.send(child.subject, Finished(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

fn supports_cancel(app: server.Server, context: server.RequestContext) -> Bool {
  case server.session_id(context) {
    Some(id) ->
      case server.session_metadata(app, id) {
        Some(meta) ->
          case meta.client_capabilities.tasks {
            Some(tasks) ->
              case tasks.cancel {
                Some(_) -> True
                None -> False
              }
            None -> False
          }
        None -> False
      }
    None -> False
  }
}
