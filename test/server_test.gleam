import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/examples/example_server
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleeunit
import gleeunit/should
import server_test_support

pub fn main() {
  gleeunit.main()
}

pub fn initialize_infers_capabilities_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      mcp.method_initialize,
      Some(
        actions.ClientRequestInitialize(actions.InitializeRequestParams(
          protocol_version: jsonrpc.latest_protocol_version,
          capabilities: capabilities.none()
            |> capabilities.to_initialize_capabilities,
          client_info: server_test_support.sample_client_info(),
          meta: None,
        )),
      ),
    )

  let #(_, response) =
    server.handle_request(example_server.sample_server(), request)

  case response {
    jsonrpc.ResultResponse(_, actions.ClientResultInitialize(result)) -> {
      should.equal(result.protocol_version, jsonrpc.latest_protocol_version)
      should.equal(result.instructions, Some("Use the Gleam MCP demo server."))

      let actions.ServerCapabilities(
        experimental: experimental,
        logging: logging,
        completions: completions,
        prompts: prompts,
        resources: resources,
        tools: tools,
        tasks: tasks,
      ) = result.capabilities

      experimental |> should.be_none
      logging |> should.be_some
      completions |> should.be_some
      prompts |> should.be_some
      resources |> should.be_some
      tools |> should.be_some
      let _ = tasks |> should.be_some
      Nil
    }
    _ -> should.fail()
  }
}

pub fn resources_prompts_tools_completion_and_logging_test() {
  let sample_server = example_server.sample_server()

  let #(_, resources_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("resources"),
        mcp.method_list_resources,
        Some(
          actions.ClientRequestListResources(actions.PaginatedRequestParams(
            None,
            None,
          )),
        ),
      ),
    )

  case resources_response {
    jsonrpc.ResultResponse(_, actions.ClientResultListResources(result)) -> {
      should.equal(list.length(result.resources), 1)
      case result.resources {
        [actions.Resource(uri:, ..)] ->
          should.equal(uri, "demo://resource/static")
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  let #(_, templates_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("templates"),
        mcp.method_list_resource_templates,
        Some(
          actions.ClientRequestListResourceTemplates(actions.PaginatedRequestParams(
            None,
            None,
          )),
        ),
      ),
    )

  case templates_response {
    jsonrpc.ResultResponse(_, actions.ClientResultListResourceTemplates(result)) -> {
      should.equal(list.length(result.resource_templates), 1)
      case result.resource_templates {
        [actions.ResourceTemplate(uri_template:, ..)] ->
          should.equal(uri_template, "demo://resource/dynamic/{id}")
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  let #(_, read_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("read"),
        mcp.method_read_resource,
        Some(
          actions.ClientRequestReadResource(actions.ReadResourceRequestParams(
            "demo://resource/dynamic/42",
            None,
          )),
        ),
      ),
    )

  case read_response {
    jsonrpc.ResultResponse(_, actions.ClientResultReadResource(result)) -> {
      should.be_true(
        list.any(result.contents, fn(content) {
          case content {
            actions.TextResourceContents(uri:, text:, ..) -> {
              uri == "demo://resource/dynamic/42"
              && string.contains(text, "dynamic/42")
            }
            _ -> False
          }
        }),
      )
    }
    _ -> should.fail()
  }

  let #(_, prompt_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("prompt"),
        mcp.method_get_prompt,
        Some(
          actions.ClientRequestGetPrompt(actions.GetPromptRequestParams(
            "simple-prompt",
            None,
            None,
          )),
        ),
      ),
    )

  case prompt_response {
    jsonrpc.ResultResponse(_, actions.ClientResultGetPrompt(result)) -> {
      should.be_true(
        list.any(result.messages, fn(message) {
          let actions.PromptMessage(content:, ..) = message
          case content {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              string.contains(text, "simple prompt")
            _ -> False
          }
        }),
      )
    }
    _ -> should.fail()
  }

  let #(_, tool_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("tool"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "echo",
            Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
            None,
            None,
          )),
        ),
      ),
    )

  case tool_response {
    jsonrpc.ResultResponse(_, actions.ClientResultCallTool(result)) -> {
      should.be_true(
        list.any(result.content, fn(block) {
          case block {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              text == "Echo: hello"
            _ -> False
          }
        }),
      )
    }
    _ -> should.fail()
  }

  let #(_, complete_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("complete"),
        mcp.method_complete,
        Some(
          actions.ClientRequestComplete(actions.CompleteRequestParams(
            actions.PromptRef("simple-prompt", None),
            actions.CompleteArgument("topic", "gleam"),
            None,
            None,
          )),
        ),
      ),
    )

  case complete_response {
    jsonrpc.ResultResponse(_, actions.ClientResultComplete(result)) -> {
      should.equal(result.completion.values, ["gleam-prompt"])
    }
    _ -> should.fail()
  }

  let #(_, logging_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("logging"),
        mcp.method_set_logging_level,
        Some(
          actions.ClientRequestSetLoggingLevel(actions.SetLevelRequestParams(
            actions.Info,
            None,
          )),
        ),
      ),
    )

  should.equal(
    logging_response,
    jsonrpc.ResultResponse(
      jsonrpc.StringId("logging"),
      actions.ClientResultEmpty(None),
    ),
  )
}

pub fn missing_completion_handler_returns_method_not_found_test() {
  let sample_server = server.new(server_test_support.sample_client_info())
  let #(_, response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("complete"),
        mcp.method_complete,
        Some(
          actions.ClientRequestComplete(actions.CompleteRequestParams(
            actions.PromptRef("simple-prompt", None),
            actions.CompleteArgument("topic", "gleam"),
            None,
            None,
          )),
        ),
      ),
    )

  case response {
    jsonrpc.ErrorResponse(Some(jsonrpc.StringId("complete")), error) ->
      should.equal(error.code, jsonrpc.method_not_found_error_code)
    _ -> should.fail()
  }
}

pub fn task_backed_tool_calls_can_be_polled_test() {
  let sample_server = example_server.sample_server()
  let #(_, create_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-create"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "echo",
            Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
            Some(actions.TaskMetadata(Some(1000))),
            None,
          )),
        ),
      ),
    )

  let task = case create_response {
    jsonrpc.ResultResponse(
      _,
      actions.ClientResultCreateTask(actions.CreateTaskResult(task: task, ..)),
    ) -> task
    _ -> panic as string.inspect(create_response)
  }

  should.equal(task.status, actions.Working)

  let #(_, list_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-list"),
        mcp.method_list_tasks,
        Some(
          actions.ClientRequestListTasks(actions.PaginatedRequestParams(None, None)),
        ),
      ),
    )

  case list_response {
    jsonrpc.ResultResponse(_, actions.ClientResultListTasks(result)) ->
      should.be_true(
        list.any(result.tasks, fn(entry) { entry.task_id == task.task_id }),
      )
    _ -> should.fail()
  }

  let #(_, get_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-get"),
        mcp.method_get_task,
        Some(actions.ClientRequestGetTask(actions.TaskIdParams(task.task_id))),
      ),
    )

  case get_response {
    jsonrpc.ResultResponse(
      _,
      actions.ClientResultGetTask(actions.GetTaskResult(task:, ..)),
    ) -> should.equal(task.status, actions.Completed)
    _ -> should.fail()
  }

  let #(_, result_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-result"),
        mcp.method_get_task_result,
        Some(actions.ClientRequestGetTaskResult(actions.TaskIdParams(task.task_id))),
      ),
    )

  case result_response {
    jsonrpc.ResultResponse(
      _,
      actions.ClientResultTaskResult(actions.TaskCallTool(actions.CallToolResult(
        content:,
        ..,
      ))),
    ) ->
      should.be_true(
        list.any(content, fn(block) {
          case block {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              text == "Echo: hello"
            _ -> False
          }
        }),
      )
    _ -> should.fail()
  }
}

pub fn task_backed_tool_calls_can_be_cancelled_test() {
  let sample_server = example_server.sample_server()
  let #(_, create_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-create"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "echo",
            Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
            Some(actions.TaskMetadata(Some(1000))),
            None,
          )),
        ),
      ),
    )

  let task_id = case create_response {
    jsonrpc.ResultResponse(
      _,
      actions.ClientResultCreateTask(actions.CreateTaskResult(
        task: actions.Task(task_id:, ..),
        ..,
      )),
    ) -> task_id
    _ -> panic as string.inspect(create_response)
  }

  let #(_, cancel_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-cancel"),
        mcp.method_cancel_task,
        Some(actions.ClientRequestCancelTask(actions.TaskIdParams(task_id))),
      ),
    )

  case cancel_response {
    jsonrpc.ResultResponse(
      _,
      actions.ClientResultCancelTask(actions.CancelTaskResult(task:, ..)),
    ) -> should.equal(task.status, actions.Cancelled)
    _ -> should.fail()
  }

  let #(_, result_response) =
    server.handle_request(
      sample_server,
      jsonrpc.Request(
        jsonrpc.StringId("task-result"),
        mcp.method_get_task_result,
        Some(actions.ClientRequestGetTaskResult(actions.TaskIdParams(task_id))),
      ),
    )

  case result_response {
    jsonrpc.ErrorResponse(Some(jsonrpc.StringId("task-result")), error) ->
      should.equal(error.code, jsonrpc.invalid_params_error_code)
    _ -> should.fail()
  }
}
