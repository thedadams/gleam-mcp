import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/examples/example_server
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleeunit
import gleeunit/should
import server_test_support

pub fn main() {
  gleeunit.main()
}

pub fn client_can_talk_to_sdk_http_server_test() {
  let base_url = server_test_support.start_http_server()
  let app_client =
    client.new(
      transport.Http(transport.HttpConfig(base_url, [], Some(5000))),
      capabilities.none(),
    )

  let #(app_client, initialized) = case
    client.initialize(app_client, server_test_support.sample_client_info())
  {
    Ok(value) -> value
    Error(error) -> panic as string.inspect(error)
  }

  should.equal(initialized.server_info.name, "gleam-mcp-test-server")
  should.be_some(initialized.capabilities.tools)
  should.be_some(initialized.capabilities.resources)
  should.be_some(initialized.capabilities.prompts)

  let #(app_client, tools_result) = client.list_tools(app_client, None)
  let tools = tools_result |> should.be_ok
  should.be_true(list.any(tools.tools, fn(tool) { tool.name == "echo" }))

  let #(app_client, resources_result) = client.list_resources(app_client, None)
  let resources = resources_result |> should.be_ok
  should.be_true(
    list.any(resources.resources, fn(resource) {
      resource.uri == "demo://resource/static"
    }),
  )

  let #(app_client, templates_result) =
    client.list_resource_templates(app_client, None)
  let templates = templates_result |> should.be_ok
  should.be_true(
    list.any(templates.resource_templates, fn(template) {
      template.uri_template == "demo://resource/dynamic/{id}"
    }),
  )

  let #(app_client, read_result) =
    client.read_resource(
      app_client,
      actions.ReadResourceRequestParams("demo://resource/dynamic/42", None),
    )
  let read = read_result |> should.be_ok
  should.be_true(
    list.any(read.contents, fn(content) {
      case content {
        actions.TextResourceContents(uri:, text:, ..) -> {
          uri == "demo://resource/dynamic/42"
          && string.contains(text, "dynamic/42")
        }
        _ -> False
      }
    }),
  )

  let #(app_client, prompts_result) = client.list_prompts(app_client, None)
  let prompts = prompts_result |> should.be_ok
  should.be_true(
    list.any(prompts.prompts, fn(prompt) { prompt.name == "simple-prompt" }),
  )

  let #(app_client, prompt_result) =
    client.get_prompt(
      app_client,
      actions.GetPromptRequestParams("simple-prompt", None, None),
    )
  let prompt = prompt_result |> should.be_ok
  should.be_true(
    list.any(prompt.messages, fn(message) {
      let actions.PromptMessage(content:, ..) = message
      case content {
        actions.TextBlock(actions.TextContent(text:, ..)) ->
          string.contains(text, "simple prompt")
        _ -> False
      }
    }),
  )

  let #(app_client, tool_result) =
    client.call_tool(
      app_client,
      actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
        None,
        None,
      ),
    )

  case tool_result |> should.be_ok {
    actions.CallTool(actions.CallToolResult(content:, ..)) -> {
      should.be_true(
        list.any(content, fn(block) {
          case block {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              text == "Echo: hello"
            _ -> False
          }
        }),
      )
    }
    actions.CallToolTask(_) -> should.fail()
  }

  let #(app_client, complete_result) =
    client.complete(
      app_client,
      actions.CompleteRequestParams(
        actions.PromptRef("simple-prompt", None),
        actions.CompleteArgument("topic", "gleam"),
        None,
        None,
      ),
    )
  let complete = complete_result |> should.be_ok
  should.equal(complete.completion.values, ["gleam-prompt"])

  let #(_, logging_result) =
    client.set_logging_level(
      app_client,
      actions.SetLevelRequestParams(actions.Info, None),
    )
  logging_result |> should.equal(Ok(Nil))
}

pub fn client_can_talk_to_sdk_stdio_server_test() {
  let app_client =
    client.new(
      transport.Stdio(transport.StdioConfig(
        "gleam",
        ["run", "-m", "gleam_mcp/examples/example_server"],
        [],
        None,
        Some(5000),
      )),
      capabilities.none(),
    )

  let #(app_client, initialized) = case
    client.initialize(app_client, server_test_support.sample_client_info())
  {
    Ok(value) -> value
    Error(error) -> panic as string.inspect(error)
  }

  should.equal(initialized.server_info.name, "gleam-mcp-test-server")

  let #(app_client, tools_result) = client.list_tools(app_client, None)
  let tools = tools_result |> should.be_ok
  should.be_true(list.any(tools.tools, fn(tool) { tool.name == "echo" }))

  let #(app_client, resources_result) = client.list_resources(app_client, None)
  let resources = resources_result |> should.be_ok
  should.be_true(
    list.any(resources.resources, fn(resource) {
      resource.uri == "demo://resource/static"
    }),
  )

  let #(app_client, prompt_result) =
    client.get_prompt(
      app_client,
      actions.GetPromptRequestParams("simple-prompt", None, None),
    )
  let prompt = prompt_result |> should.be_ok
  should.be_true(
    list.any(prompt.messages, fn(message) {
      let actions.PromptMessage(content:, ..) = message
      case content {
        actions.TextBlock(actions.TextContent(text:, ..)) ->
          string.contains(text, "simple prompt")
        _ -> False
      }
    }),
  )

  let #(app_client, tool_result) =
    client.call_tool(
      app_client,
      actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
        None,
        None,
      ),
    )

  case tool_result |> should.be_ok {
    actions.CallTool(actions.CallToolResult(content:, ..)) -> {
      should.be_true(
        list.any(content, fn(block) {
          case block {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              text == "Echo: hello"
            _ -> False
          }
        }),
      )
    }
    actions.CallToolTask(_) -> should.fail()
  }

  let #(_, logging_result) =
    client.set_logging_level(
      app_client,
      actions.SetLevelRequestParams(actions.Info, None),
    )
  logging_result |> should.equal(Ok(Nil))
}

pub fn client_can_roundtrip_task_backed_tool_calls_over_http_test() {
  task_backed_tool_roundtrip_with_transport(
    transport.Http(transport.HttpConfig(
      server_test_support.start_http_server(),
      [],
      Some(5000),
    )),
  )
}

pub fn client_can_roundtrip_task_backed_tool_calls_over_stdio_test() {
  task_backed_tool_roundtrip_with_transport(
    transport.Stdio(transport.StdioConfig(
      "gleam",
      ["run", "-m", "gleam_mcp/examples/example_server"],
      [],
      None,
      Some(5000),
    )),
  )
}

pub fn http_server_rejects_requests_with_invalid_authorization_header_test() {
  let base_url =
    server_test_support.start_http_server_with_server(authorized_server(
      "x-api-key",
      "secret",
    ))

  let app_client =
    client.new(
      transport.Http(transport.HttpConfig(base_url, [], Some(5000))),
      capabilities.none(),
    )

  case client.initialize(app_client, server_test_support.sample_client_info()) {
    Error(client.Transport(transport.HttpError(message))) ->
      should.be_true(string.contains(message, "status 401"))
    _ -> should.fail()
  }
}

pub fn http_server_accepts_requests_with_valid_authorization_header_test() {
  let base_url =
    server_test_support.start_http_server_with_server(authorized_server(
      "x-api-key",
      "secret",
    ))

  let app_client =
    client.new(
      transport.Http(transport.HttpConfig(
        base_url,
        [#("x-api-key", "secret")],
        Some(5000),
      )),
      capabilities.none(),
    )

  let #(_, initialized) = case
    client.initialize(app_client, server_test_support.sample_client_info())
  {
    Ok(value) -> value
    Error(error) -> panic as string.inspect(error)
  }

  should.equal(initialized.server_info.name, "gleam-mcp-test-server")
}

fn authorized_server(header: String, token: String) -> server.Server {
  example_server.sample_server()
  |> server.with_header_authorization(header, fn(value) { value == token })
}

fn task_backed_tool_roundtrip_with_transport(config: transport.Config) {
  let app_client = client.new(config, capabilities.none())
  let #(app_client, _) = case
    client.initialize(app_client, server_test_support.sample_client_info())
  {
    Ok(value) -> value
    Error(error) -> panic as string.inspect(error)
  }

  let #(app_client, call_result) =
    client.call_tool(
      app_client,
      actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("message", jsonrpc.VString("hello task"))])),
        Some(actions.TaskMetadata(Some(1000))),
        None,
      ),
    )

  let task_id = case call_result |> should.be_ok {
    actions.CallToolTask(actions.CreateTaskResult(task:, ..)) -> task.task_id
    _ -> panic as string.inspect(call_result)
  }

  let #(app_client, list_result) =
    client.list_tasks(
      app_client,
      Some(actions.PaginatedRequestParams(None, None)),
    )
  let listed = list_result |> should.be_ok
  should.be_true(list.any(listed.tasks, fn(task) { task.task_id == task_id }))

  let #(app_client, get_result) =
    client.get_task(app_client, actions.TaskIdParams(task_id))
  let task = get_result |> should.be_ok
  should.equal(task.task.status, actions.Completed)

  let #(_, result_response) =
    client.get_task_result(app_client, actions.TaskIdParams(task_id))

  case result_response |> should.be_ok {
    actions.TaskCallTool(actions.CallToolResult(content:, ..)) ->
      should.be_true(
        list.any(content, fn(block) {
          case block {
            actions.TextBlock(actions.TextContent(text:, ..)) ->
              text == "Echo: hello task"
            _ -> False
          }
        }),
      )
    _ -> should.fail()
  }
}
