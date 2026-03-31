import envoy
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server
import sceall
import simplifile

const max_workflow_steps = 12

const shell_timeout_ms = 30_000

type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

type DeferredInputStore {
  DeferredInputStore(subject: process.Subject(DeferredInputMessage))
}

type DeferredInput {
  DeferredInput(
    prompt: String,
    reply_to: process.Subject(Result(actions.ElicitResult, jsonrpc.RpcError)),
  )
}

type DeferredInputMessage {
  RegisterDeferredInput(
    task_id: String,
    prompt: String,
    reply_to: process.Subject(Result(actions.ElicitResult, jsonrpc.RpcError)),
    acknowledge: process.Subject(Nil),
  )
  TakeDeferredInput(
    task_id: String,
    reply_to: process.Subject(Option(DeferredInput)),
  )
}

pub fn make_server() -> server.Server {
  let deferred_inputs = new_deferred_input_store()

  server.new(implementation())
  |> server.with_instructions(instructions())
  |> server.set_task_result_request_handler(fn(app_server, context, task_id) {
    handle_task_result_request(deferred_inputs, app_server, context, task_id)
  })
  |> server.add_tool_with_context_execution(
    "run-workflow",
    "Run a markdown workflow using client sampling and internal tools",
    run_workflow_schema(),
    actions.TaskRequired,
    fn(app_server, context, arguments) {
      run_workflow_tool(deferred_inputs, app_server, context, arguments)
    },
  )
}

fn new_deferred_input_store() -> DeferredInputStore {
  let reply_to = process.new_subject()
  let _ = process.spawn(fn() { start_deferred_input_store(reply_to) })
  DeferredInputStore(process.receive_forever(reply_to))
}

fn start_deferred_input_store(
  reply_to: process.Subject(process.Subject(DeferredInputMessage)),
) -> Nil {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  deferred_input_store_loop(subject, dict.new())
}

fn deferred_input_store_loop(
  subject: process.Subject(DeferredInputMessage),
  entries: dict.Dict(String, DeferredInput),
) -> Nil {
  case process.receive_forever(subject) {
    RegisterDeferredInput(task_id, prompt, reply_to, acknowledge) -> {
      process.send(acknowledge, Nil)
      deferred_input_store_loop(
        subject,
        dict.insert(entries, task_id, DeferredInput(prompt, reply_to)),
      )
    }
    TakeDeferredInput(task_id, reply_to) -> {
      case dict.get(entries, task_id) {
        Ok(entry) -> {
          process.send(reply_to, Some(entry))
          deferred_input_store_loop(subject, dict.delete(entries, task_id))
        }
        Error(Nil) -> {
          process.send(reply_to, None)
          deferred_input_store_loop(subject, entries)
        }
      }
    }
  }
}

fn register_deferred_input(
  store: DeferredInputStore,
  task_id: String,
  prompt: String,
  reply_to: process.Subject(Result(actions.ElicitResult, jsonrpc.RpcError)),
) -> Nil {
  let DeferredInputStore(subject) = store
  let acknowledge = process.new_subject()
  process.send(
    subject,
    RegisterDeferredInput(task_id, prompt, reply_to, acknowledge),
  )
  process.receive_forever(acknowledge)
}

fn take_deferred_input(
  store: DeferredInputStore,
  task_id: String,
) -> Option(DeferredInput) {
  let DeferredInputStore(subject) = store
  let reply_to = process.new_subject()
  process.send(subject, TakeDeferredInput(task_id, reply_to))
  process.receive_forever(reply_to)
}

fn handle_task_result_request(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  task_id: String,
) -> Result(Nil, jsonrpc.RpcError) {
  case take_deferred_input(deferred_inputs, task_id) {
    Some(DeferredInput(prompt, reply_to)) -> {
      process.send(
        reply_to,
        server.elicit(
          app_server,
          context,
          ask_the_user_request(prompt, Some(task_id)),
        ),
      )
      Ok(Nil)
    }
    None -> Ok(Nil)
  }
}

fn implementation() -> actions.Implementation {
  actions.Implementation(
    name: "gleam-mcp/workflow-example",
    version: "0.1.0",
    title: Some("Workflow Engine Example"),
    description: Some(
      "A streamable HTTP MCP server that executes markdown workflows via sampling",
    ),
    website_url: None,
    icons: [],
  )
}

fn instructions() -> String {
  "Use the run-workflow tool to execute a markdown workflow file. The workflow is sent to the connected MCP client's sampling implementation along with internal tools that are not exposed as normal server tools."
}

fn run_workflow_tool(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use path <- result.try(required_string(arguments, "path"))
  use markdown <- result.try(read_workflow_file(path))
  use final_text <- result.try(execute_workflow(
    deferred_inputs,
    app_server,
    context,
    initial_messages(markdown),
    max_workflow_steps,
  ))

  Ok(text_result(final_text))
}

fn execute_workflow(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  messages: List(actions.SamplingMessage),
  steps_remaining: Int,
) -> Result(String, jsonrpc.RpcError) {
  case steps_remaining <= 0 {
    True ->
      Error(jsonrpc.invalid_params_error(
        "Workflow exceeded the maximum number of internal tool steps",
      ))
    False ->
      case
        server.create_message(app_server, context, workflow_request(messages))
      {
        Ok(actions.ServerResultCreateMessage(result)) ->
          continue_workflow(
            deferred_inputs,
            app_server,
            context,
            messages,
            result,
            steps_remaining,
          )
        Ok(actions.ServerResultCreateTask(actions.CreateTaskResult(task:, ..))) ->
          case server.task_result(app_server, task.task_id) {
            Ok(actions.TaskCreateMessage(result)) ->
              continue_workflow(
                deferred_inputs,
                app_server,
                context,
                messages,
                result,
                steps_remaining,
              )
            Ok(_) ->
              Error(jsonrpc.invalid_params_error(
                "Client returned an unexpected task result for sampling request",
              ))
            Error(error) -> Error(error)
          }
        Ok(_) ->
          Error(jsonrpc.invalid_params_error(
            "Client returned an unexpected result for sampling request",
          ))
        Error(error) -> Error(error)
      }
  }
}

fn continue_workflow(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  messages: List(actions.SamplingMessage),
  result: actions.CreateMessageResult,
  steps_remaining: Int,
) -> Result(String, jsonrpc.RpcError) {
  let actions.CreateMessageResult(message, _, _, _) = result
  let actions.SamplingMessage(_, content, _) = message
  let tool_uses = tool_use_blocks(content)

  case tool_uses {
    [] -> sampling_text(content)
    _ -> {
      // If the model emitted any tool calls, execute them and continue even if
      // the same response also contained text. Only a response with no tool
      // calls is treated as the workflow's final answer.
      let tool_results =
        tool_uses
        |> list.map(run_internal_tool(deferred_inputs, app_server, context, _))
        |> tool_result_blocks([])
      let next_messages =
        list.append(messages, [message, tool_result_message(tool_results)])

      execute_workflow(
        deferred_inputs,
        app_server,
        context,
        next_messages,
        steps_remaining - 1,
      )
    }
  }
}

fn tool_result_blocks(
  pending: List(Result(actions.SamplingMessageContentBlock, jsonrpc.RpcError)),
  collected: List(actions.SamplingMessageContentBlock),
) -> List(actions.SamplingMessageContentBlock) {
  case pending {
    [] -> list.reverse(collected)
    [Ok(block), ..rest] -> tool_result_blocks(rest, [block, ..collected])
    [Error(error), ..rest] ->
      tool_result_blocks(rest, [tool_error_result(error), ..collected])
  }
}

fn tool_error_result(
  error: jsonrpc.RpcError,
) -> actions.SamplingMessageContentBlock {
  actions.SamplingToolResult(actions.ToolResultContent(
    tool_use_id: "tool-error",
    content: [
      actions.TextBlock(actions.TextContent(string.inspect(error), None, None)),
    ],
    structured_content: None,
    is_error: Some(True),
    meta: None,
  ))
}

fn initial_messages(markdown: String) -> List(actions.SamplingMessage) {
  [
    actions.SamplingMessage(
      actions.User,
      actions.SingleSamplingContent(
        actions.SamplingText(actions.TextContent(markdown, None, None)),
      ),
      None,
    ),
  ]
}

fn workflow_request(
  messages: List(actions.SamplingMessage),
) -> actions.CreateMessageRequestParams {
  actions.CreateMessageRequestParams(
    messages: messages,
    model_preferences: None,
    system_prompt: Some(workflow_system_prompt()),
    include_context: None,
    temperature: Some(0.1),
    max_tokens: 2000,
    stop_sequences: [],
    metadata: None,
    tools: internal_tools(),
    tool_choice: Some(actions.ToolChoice(Some(actions.ToolAuto))),
    task: None,
    meta: None,
  )
}

fn workflow_system_prompt() -> String {
  "You are executing a workflow from a markdown file. Use the provided internal tools when needed. The available internal tools are bash, which accepts a command string and an optional list of string arguments, and ask-the-user, which marks the current task as input_required. The connected user will only be asked that question after the client requests task/result for the workflow task. If you emit any tool calls, those tool calls will be executed and the workflow will continue even if the same response also includes text. Only your first response with no tool calls is treated as the workflow's final answer. When you are done, respond with plain text only and do not emit any more tool calls."
}

fn internal_tools() -> List(actions.Tool) {
  [bash_tool(), ask_the_user_tool()]
}

fn bash_tool() -> actions.Tool {
  actions.Tool(
    name: "bash",
    title: Some("Bash"),
    description: Some(
      "Run a shell command with bash -c using a command string and arguments",
    ),
    input_schema: bash_tool_schema(),
    execution: Some(actions.ToolExecution(Some(actions.TaskForbidden))),
    output_schema: None,
    annotations: Some(actions.ToolAnnotations(
      title: Some("Bash"),
      read_only_hint: Some(False),
      destructive_hint: Some(True),
      idempotent_hint: Some(False),
      open_world_hint: Some(True),
    )),
    icons: [],
    meta: None,
  )
}

fn run_internal_tool(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  tool_use: actions.ToolUseContent,
) -> Result(actions.SamplingMessageContentBlock, jsonrpc.RpcError) {
  let actions.ToolUseContent(id, name, input, _) = tool_use

  case name {
    "bash" -> {
      let result = bash_tool_use_result(id, input)
      Ok(actions.SamplingToolResult(result))
    }
    "ask-the-user" -> {
      let result =
        ask_the_user_tool_use_result(
          deferred_inputs,
          app_server,
          context,
          id,
          input,
        )
      result |> result.map(actions.SamplingToolResult)
    }
    _ ->
      Ok(
        actions.SamplingToolResult(actions.ToolResultContent(
          tool_use_id: id,
          content: [
            actions.TextBlock(actions.TextContent(
              "Unknown internal tool: " <> name,
              None,
              None,
            )),
          ],
          structured_content: None,
          is_error: Some(True),
          meta: None,
        )),
      )
  }
}

fn bash_tool_use_result(
  tool_use_id: String,
  input: dict.Dict(String, jsonrpc.Value),
) -> actions.ToolResultContent {
  let command = required_string(Some(input), "command")
  let arguments = optional_string_list(input, "arguments")

  case command, arguments {
    Ok(command), Ok(arguments) ->
      case run_bash_command(command, arguments) {
        Ok(CommandResult(exit_code:, output:)) ->
          actions.ToolResultContent(
            tool_use_id: tool_use_id,
            content: [
              actions.TextBlock(actions.TextContent(
                command_output_text(exit_code, output),
                None,
                None,
              )),
            ],
            structured_content: Some(
              dict.from_list([
                #("exitCode", jsonrpc.VInt(exit_code)),
                #("output", jsonrpc.VString(output)),
              ]),
            ),
            is_error: Some(exit_code != 0),
            meta: None,
          )
        Error(message) ->
          actions.ToolResultContent(
            tool_use_id: tool_use_id,
            content: [
              actions.TextBlock(actions.TextContent(message, None, None)),
            ],
            structured_content: None,
            is_error: Some(True),
            meta: None,
          )
      }
    Error(error), _ | _, Error(error) ->
      actions.ToolResultContent(
        tool_use_id: tool_use_id,
        content: [
          actions.TextBlock(actions.TextContent(
            string.inspect(error),
            None,
            None,
          )),
        ],
        structured_content: None,
        is_error: Some(True),
        meta: None,
      )
  }
}

fn ask_the_user_tool() -> actions.Tool {
  actions.Tool(
    name: "ask-the-user",
    title: Some("Ask The User"),
    description: Some(
      "Mark the current task as input_required and queue a question for the next task/result request",
    ),
    input_schema: ask_the_user_tool_schema(),
    execution: Some(actions.ToolExecution(Some(actions.TaskForbidden))),
    output_schema: None,
    annotations: Some(actions.ToolAnnotations(
      title: Some("Ask The User"),
      read_only_hint: Some(False),
      destructive_hint: Some(False),
      idempotent_hint: Some(False),
      open_world_hint: Some(True),
    )),
    icons: [],
    meta: None,
  )
}

fn ask_the_user_tool_use_result(
  deferred_inputs: DeferredInputStore,
  app_server: server.Server,
  context: server.RequestContext,
  tool_use_id: String,
  input: dict.Dict(String, jsonrpc.Value),
) -> Result(actions.ToolResultContent, jsonrpc.RpcError) {
  use prompt <- result.try(required_string(Some(input), "message"))
  let current_task_id = server.task_id(context)

  case current_task_id {
    Some(task_id) -> {
      let reply_to = process.new_subject()
      register_deferred_input(deferred_inputs, task_id, prompt, reply_to)
      let _ =
        set_current_task_status(
          app_server,
          context,
          Some(task_id),
          actions.InputRequired,
          Some(prompt),
        )
      let elicitation = process.receive_forever(reply_to)

      case elicitation {
        Ok(elicited) -> {
          let _ =
            set_current_task_status(
              app_server,
              context,
              Some(task_id),
              actions.Working,
              Some("Continuing workflow after user input."),
            )

          Ok(elicitation_result(tool_use_id, elicited))
        }
        Error(error) -> {
          let _ =
            set_current_task_status(
              app_server,
              context,
              Some(task_id),
              actions.Working,
              Some("Continuing workflow after ask-the-user failed."),
            )

          Ok(elicitation_error_result(tool_use_id, error))
        }
      }
    }
    None ->
      Ok(actions.ToolResultContent(
        tool_use_id: tool_use_id,
        content: [
          actions.TextBlock(actions.TextContent(
            "ask-the-user requires the workflow to be running inside a task",
            None,
            None,
          )),
        ],
        structured_content: None,
        is_error: Some(True),
        meta: None,
      ))
  }
}

fn ask_the_user_request(
  prompt: String,
  current_task_id: Option(String),
) -> actions.ElicitRequestParams {
  actions.ElicitRequestForm(actions.ElicitRequestFormParams(
    prompt,
    jsonrpc.VObject([
      #("type", jsonrpc.VString("object")),
      #(
        "properties",
        jsonrpc.VObject([
          #(
            "answer",
            jsonrpc.VObject([
              #("type", jsonrpc.VString("string")),
              #(
                "description",
                jsonrpc.VString("The user's response to the question"),
              ),
            ]),
          ),
        ]),
      ),
      #("required", jsonrpc.VArray([jsonrpc.VString("answer")])),
    ]),
    None,
    related_task_request_meta(current_task_id),
  ))
}

fn set_current_task_status(
  app_server: server.Server,
  context: server.RequestContext,
  current_task_id: Option(String),
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Nil {
  case current_task_id {
    Some(task_id) -> {
      let _ =
        server.update_task_status(
          app_server,
          context,
          task_id,
          status,
          status_message,
        )
      Nil
    }
    None -> Nil
  }
}

fn elicitation_result(
  tool_use_id: String,
  result: actions.ElicitResult,
) -> actions.ToolResultContent {
  let actions.ElicitResult(action, content, _) = result
  let answer = elicited_answer(content)
  let #(text, is_error) = case action {
    actions.ElicitAccept -> #("User response: " <> answer, False)
    actions.ElicitDecline -> #("User declined to answer the question.", True)
    actions.ElicitCancel -> #("User cancelled the question.", True)
  }

  actions.ToolResultContent(
    tool_use_id: tool_use_id,
    content: [actions.TextBlock(actions.TextContent(text, None, None))],
    structured_content: Some(
      dict.from_list([
        #("action", jsonrpc.VString(elicit_action_name(action))),
        #("answer", jsonrpc.VString(answer)),
      ]),
    ),
    is_error: Some(is_error),
    meta: None,
  )
}

fn elicitation_error_result(
  tool_use_id: String,
  error: jsonrpc.RpcError,
) -> actions.ToolResultContent {
  let jsonrpc.RpcError(message:, ..) = error

  actions.ToolResultContent(
    tool_use_id: tool_use_id,
    content: [
      actions.TextBlock(actions.TextContent(
        "Failed to ask the user: " <> message,
        None,
        None,
      )),
    ],
    structured_content: Some(
      dict.from_list([
        #("action", jsonrpc.VString("error")),
        #("message", jsonrpc.VString(message)),
      ]),
    ),
    is_error: Some(True),
    meta: None,
  )
}

fn related_task_request_meta(
  current_task_id: Option(String),
) -> Option(actions.RequestMeta) {
  case current_task_id {
    Some(task_id) ->
      Some(actions.RequestMeta(
        progress_token: None,
        extra: Some(
          actions.Meta(
            dict.from_list([
              #(
                "io.modelcontextprotocol/related-task",
                jsonrpc.VObject([#("taskId", jsonrpc.VString(task_id))]),
              ),
            ]),
          ),
        ),
      ))
    None -> None
  }
}

fn elicited_answer(
  content: Option(dict.Dict(String, actions.ElicitValue)),
) -> String {
  case content {
    Some(fields) -> {
      case dict.get(fields, "answer") {
        Ok(actions.ElicitString(value)) -> value
        _ -> ""
      }
    }
    None -> ""
  }
}

fn elicit_action_name(action: actions.ElicitAction) -> String {
  case action {
    actions.ElicitAccept -> "accept"
    actions.ElicitDecline -> "decline"
    actions.ElicitCancel -> "cancel"
  }
}

fn run_bash_command(
  command: String,
  arguments: List(String),
) -> Result(CommandResult, String) {
  use executable <- result.try(
    sceall.find_executable("bash")
    |> result.map_error(fn(_) { "Unable to find `bash` on PATH" }),
  )

  use handle <- result.try(
    sceall.spawn_program(
      executable_path: executable,
      working_directory: ".",
      command_line_arguments: ["-c", render_shell_command(command, arguments)],
      environment_variables: envoy.all() |> dict.to_list,
    )
    |> result.map_error(spawn_error_message),
  )

  collect_command_output(handle, bit_array.from_string(""))
}

fn collect_command_output(
  handle: sceall.ProgramHandle,
  buffer: BitArray,
) -> Result(CommandResult, String) {
  let selector =
    process.new_selector() |> sceall.select(handle, fn(message) { message })

  case process.selector_receive(selector, shell_timeout_ms) {
    Ok(sceall.Data(_, data)) ->
      collect_command_output(handle, bit_array.append(to: buffer, suffix: data))
    Ok(sceall.Exited(_, status_code)) ->
      bit_array.to_string(buffer)
      |> result.map(fn(output) { CommandResult(status_code, output) })
      |> result.map_error(fn(_) { "Command output was not valid UTF-8" })
    Error(Nil) -> {
      let _ = sceall.exit_program(handle)
      Error("Command timed out after 30000ms")
    }
  }
}

fn render_shell_command(command: String, arguments: List(String)) -> String {
  case arguments {
    [] -> command
    _ -> {
      let escaped = arguments |> list.map(shell_quote) |> string.join(with: " ")
      command <> " " <> escaped
    }
  }
}

fn shell_quote(value: String) -> String {
  "'" <> string.replace(value, each: "'", with: "'\"'\"'") <> "'"
}

fn command_output_text(exit_code: Int, output: String) -> String {
  case string.trim(output) == "" {
    True -> "Exit code: " <> int_to_string(exit_code)
    False -> "Exit code: " <> int_to_string(exit_code) <> "\n" <> output
  }
}

fn tool_use_blocks(
  content: actions.SamplingContent,
) -> List(actions.ToolUseContent) {
  case content {
    actions.SingleSamplingContent(block) -> tool_use_block(block)
    actions.MultipleSamplingContent(blocks) ->
      blocks |> list.flat_map(tool_use_block)
  }
}

fn tool_use_block(
  block: actions.SamplingMessageContentBlock,
) -> List(actions.ToolUseContent) {
  case block {
    actions.SamplingToolUse(tool_use) -> [tool_use]
    _ -> []
  }
}

fn sampling_text(
  content: actions.SamplingContent,
) -> Result(String, jsonrpc.RpcError) {
  let text =
    case content {
      actions.SingleSamplingContent(block) -> text_parts([block])
      actions.MultipleSamplingContent(blocks) -> text_parts(blocks)
    }
    |> string.join(with: "\n")
    |> string.trim

  case text == "" {
    True ->
      Error(jsonrpc.invalid_params_error(
        "Workflow completed without a text response",
      ))
    False -> Ok(text)
  }
}

fn text_parts(blocks: List(actions.SamplingMessageContentBlock)) -> List(String) {
  list.fold(over: blocks, from: [], with: fn(collected, block) {
    case block {
      actions.SamplingText(actions.TextContent(text:, ..)) -> [
        text,
        ..collected
      ]
      _ -> collected
    }
  })
  |> list.reverse
}

fn tool_result_message(
  blocks: List(actions.SamplingMessageContentBlock),
) -> actions.SamplingMessage {
  actions.SamplingMessage(
    actions.User,
    case blocks {
      [block] -> actions.SingleSamplingContent(block)
      _ -> actions.MultipleSamplingContent(blocks)
    },
    None,
  )
}

fn read_workflow_file(path: String) -> Result(String, jsonrpc.RpcError) {
  simplifile.read(path)
  |> result.map_error(fn(error) {
    jsonrpc.invalid_params_error(
      "Unable to read workflow file `" <> path <> "`: " <> string.inspect(error),
    )
  })
}

fn text_result(text: String) -> actions.CallToolResult {
  actions.CallToolResult(
    content: [actions.TextBlock(actions.TextContent(text, None, None))],
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

fn optional_string_list(
  values: dict.Dict(String, jsonrpc.Value),
  key: String,
) -> Result(List(String), jsonrpc.RpcError) {
  case dict.get(values, key) {
    Ok(jsonrpc.VArray(entries)) -> array_strings(entries, [])
    Ok(_) ->
      Error(jsonrpc.invalid_params_error(key <> " must be an array of strings"))
    Error(Nil) -> Ok([])
  }
}

fn array_strings(
  values: List(jsonrpc.Value),
  collected: List(String),
) -> Result(List(String), jsonrpc.RpcError) {
  case values {
    [] -> Ok(list.reverse(collected))
    [jsonrpc.VString(value), ..rest] ->
      array_strings(rest, [value, ..collected])
    [_value, ..] ->
      Error(jsonrpc.invalid_params_error(
        "arguments must be an array of strings",
      ))
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

fn run_workflow_schema() -> jsonrpc.Value {
  jsonrpc.VObject([
    #("type", jsonrpc.VString("object")),
    #(
      "properties",
      jsonrpc.VObject([
        #(
          "path",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("string")),
            #(
              "description",
              jsonrpc.VString("Path to the markdown workflow file to execute"),
            ),
          ]),
        ),
      ]),
    ),
    #("required", jsonrpc.VArray([jsonrpc.VString("path")])),
  ])
}

fn bash_tool_schema() -> jsonrpc.Value {
  jsonrpc.VObject([
    #("type", jsonrpc.VString("object")),
    #(
      "properties",
      jsonrpc.VObject([
        #(
          "command",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("string")),
            #(
              "description",
              jsonrpc.VString("Shell command or snippet to run with bash -c"),
            ),
          ]),
        ),
        #(
          "arguments",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("array")),
            #("items", jsonrpc.VObject([#("type", jsonrpc.VString("string"))])),
          ]),
        ),
      ]),
    ),
    #("required", jsonrpc.VArray([jsonrpc.VString("command")])),
  ])
}

fn ask_the_user_tool_schema() -> jsonrpc.Value {
  jsonrpc.VObject([
    #("type", jsonrpc.VString("object")),
    #(
      "properties",
      jsonrpc.VObject([
        #(
          "message",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("string")),
            #(
              "description",
              jsonrpc.VString("Question or prompt to show to the user"),
            ),
          ]),
        ),
      ]),
    ),
    #("required", jsonrpc.VArray([jsonrpc.VString("message")])),
  ])
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

fn spawn_error_message(error: sceall.SpawnProgramError) -> String {
  case error {
    sceall.NotEnoughBeamPorts -> "Unable to start bash: not enough BEAM ports"
    sceall.NotEnoughMemory -> "Unable to start bash: not enough memory"
    sceall.NotEnoughOsProcesses ->
      "Unable to start bash: not enough OS processes available"
    sceall.ExternalCommandTooLong -> "Unable to start bash: command too long"
    sceall.NotEnoughFileDescriptors ->
      "Unable to start bash: not enough file descriptors"
    sceall.OsFileTableFull -> "Unable to start bash: OS file table is full"
    sceall.FileNotExecutable -> "Unable to start bash: file is not executable"
    sceall.FileDoesNotExist -> "Unable to start bash: executable does not exist"
  }
}
