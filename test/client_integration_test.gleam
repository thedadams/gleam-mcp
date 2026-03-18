import client_integration_support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleeunit
import gleeunit/should
import server_sent_request_integration_support

const dynamic_resource_uri = "demo://resource/dynamic/text/1"

pub fn main() {
  gleeunit.main()
}

pub fn initialize_and_basic_requests_test() {
  option.map(
    client_integration_support.http_transport(),
    basic_request_with_transport,
  )
}

pub fn initialize_and_basic_requests_stdio_test() {
  option.map(
    client_integration_support.stdio_transport(),
    basic_request_with_transport,
  )
}

fn basic_request_with_transport(config: transport.Config) {
  let client = client.new(config, capabilities.none())
  let #(client, init) = initialize_client(client)

  let actions.InitializeResult(
    protocol_version: protocol_version,
    server_info: actions.Implementation(
      name: server_name,
      version: server_version,
      ..,
    ),
    ..,
  ) = init

  should.equal(protocol_version, jsonrpc.latest_protocol_version)
  should.be_false(string.is_empty(server_name))
  should.be_false(string.is_empty(server_version))

  let #(client, ping_result) = client.ping(client)
  ping_result |> should.equal(Ok(Nil))

  let #(client, resources_result) =
    client.list_resources(
      client,
      Some(actions.PaginatedRequestParams(None, None)),
    )
  let resources = resources_result |> should.be_ok
  let actions.ListResourcesResult(resources: listed_resources, ..) = resources
  should.be_true(listed_resources != [])

  let #(client, templates_result) =
    client.list_resource_templates(
      client,
      Some(actions.PaginatedRequestParams(None, None)),
    )
  let templates = templates_result |> should.be_ok
  let actions.ListResourceTemplatesResult(resource_templates:, ..) = templates
  should.be_true(has_resource_template(
    resource_templates,
    "demo://resource/dynamic/text/",
  ))

  let #(client, read_result) =
    client.read_resource(
      client,
      actions.ReadResourceRequestParams(dynamic_resource_uri, None),
    )
  let contents = read_result |> should.be_ok
  let actions.ReadResourceResult(contents: resource_contents, ..) = contents
  should.be_true(has_text_resource_content(
    resource_contents,
    dynamic_resource_uri,
  ))

  let #(client, prompts_result) =
    client.list_prompts(
      client,
      Some(actions.PaginatedRequestParams(None, None)),
    )
  let prompts = prompts_result |> should.be_ok
  let actions.ListPromptsResult(prompts: listed_prompts, ..) = prompts
  should.be_true(has_prompt(listed_prompts, "simple-prompt"))

  let #(client, prompt_result) =
    client.get_prompt(
      client,
      actions.GetPromptRequestParams("simple-prompt", None, None),
    )
  let prompt = prompt_result |> should.be_ok
  let actions.GetPromptResult(messages:, ..) = prompt
  should.be_true(has_prompt_text(
    messages,
    "This is a simple prompt without arguments.",
  ))

  let #(client, tools_result) = client.list_tools(client, None)
  let tools = tools_result |> should.be_ok
  let actions.ListToolsResult(tools: listed_tools, ..) = tools
  should.be_true(has_tool(listed_tools, "echo"))
  should.be_true(has_tool(listed_tools, "get-sum"))
  should.be_true(has_tool(listed_tools, "simulate-research-query"))

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("message", jsonrpc.VString("hello"))])),
        None,
        None,
      ),
    )

  case call_result |> should.be_ok {
    actions.ResultCallTool(actions.CallToolResult(content:, ..)) -> {
      should.be_true(has_text_content(content, "Echo: hello"))
    }
    _ -> should.fail()
  }
}

pub fn mutation_requests_succeed_http_test() {
  option.map(
    client_integration_support.http_transport(),
    mutation_request_with_transport,
  )
}

pub fn mutation_requests_succeed_stdio_test() {
  option.map(
    client_integration_support.stdio_transport(),
    mutation_request_with_transport,
  )
}

fn mutation_request_with_transport(config: transport.Config) {
  let client = client.new(config, capabilities.none())
  let #(client, _) = initialize_client(client)

  let #(client, subscribe_result) =
    client.subscribe_resource(
      client,
      actions.SubscribeRequestParams(dynamic_resource_uri, None),
    )
  subscribe_result |> should.equal(Ok(Nil))

  let #(client, unsubscribe_result) =
    client.unsubscribe_resource(
      client,
      actions.UnsubscribeRequestParams(dynamic_resource_uri, None),
    )
  unsubscribe_result |> should.equal(Ok(Nil))

  let #(_, logging_result) =
    client.set_logging_level(
      client,
      actions.SetLevelRequestParams(actions.Info, None),
    )
  logging_result |> should.equal(Ok(Nil))
}

pub fn list_tasks_request_http_test() {
  option.map(
    client_integration_support.http_transport(),
    list_tasks_request_with_transport_test,
  )
}

pub fn list_tasks_request_stdio_test() {
  option.map(
    client_integration_support.stdio_transport(),
    list_tasks_request_with_transport_test,
  )
}

fn list_tasks_request_with_transport_test(config: transport.Config) {
  let client = client.new(config, capabilities.none())
  let #(client, _) = initialize_client(client)

  let #(_, list_result) =
    client.list_tasks(client, Some(actions.PaginatedRequestParams(None, None)))
  let _ = list_result |> should.be_ok
}

pub fn task_lookup_requests_surface_errors_http_test() {
  option.map(
    client_integration_support.http_transport(),
    test_task_for_transport,
  )
}

pub fn task_lookup_requests_surface_errors_stdio_test() {
  option.map(
    client_integration_support.stdio_transport(),
    test_task_for_transport,
  )
}

fn test_task_for_transport(config: transport.Config) {
  let client = client.new(config, capabilities.none())
  let #(client, _) = initialize_client(client)
  let missing_task_id = "missing-task-id"

  let #(client, get_result) =
    client.get_task(client, actions.TaskIdParams(missing_task_id))
  let _ = get_result |> should.be_error

  let #(client, task_result) =
    client.get_task_result(client, actions.TaskIdParams(missing_task_id))
  let _ = task_result |> should.be_error

  let #(_, cancel_result) =
    client.cancel_task(client, actions.TaskIdParams(missing_task_id))
  let _ = cancel_result |> should.be_error
}

pub fn elicitation_server_sent_roundtrip_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_sent_request_integration_support.start_http_server(
        server_sent_request_integration_support.Elicitation,
      ),
      [],
      Some(5000),
    ))

  let capability_config =
    capabilities.none()
    |> capabilities.with_elicit_form(fn(param) {
      Ok(
        capabilities.Elicit(actions.ElicitResult(
          actions.ElicitAccept,
          Some(
            dict.from_list([
              #(
                "answer",
                actions.ElicitString("elicited for " <> param.message),
              ),
            ]),
          ),
          None,
        )),
      )
    })

  let client = client.new(config, capability_config)
  let #(client, _) = initialize_client(client)
  let _ = spawn_listener(client)
  process.sleep(100)

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-elicitation", None, None, None),
    )

  case call_result {
    Ok(actions.ResultCallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(call_result)
  }

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-elicitation-1", None, None, None),
    )

  case call_result {
    Ok(actions.ResultCallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation-1",
      ))
    _ -> panic as string.inspect(call_result)
  }
}

pub fn sampling_server_sent_roundtrip_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_sent_request_integration_support.start_http_server(
        server_sent_request_integration_support.Sampling,
      ),
      [],
      Some(5000),
    ))

  let capability_config =
    capabilities.none()
    |> capabilities.with_create_message(fn(_) {
      Ok(
        capabilities.CreateMessage(actions.CreateMessageResult(
          message: actions.SamplingMessage(
            actions.Assistant,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent(
                "sampled value",
                None,
                None,
              )),
            ),
            None,
          ),
          model: "integration-test-model",
          stop_reason: None,
          meta: None,
        )),
      )
    })

  let client = client.new(config, capability_config)
  let #(client, _) = initialize_client(client)
  let _ = spawn_listener(client)
  process.sleep(100)

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-sampling", None, None, None),
    )

  case call_result {
    Ok(actions.ResultCallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(content, "Sampled: sampled value"))
    _ -> panic as string.inspect(call_result)
  }
}

fn initialize_client(
  created: client.Client,
) -> #(client.Client, actions.InitializeResult) {
  case client.initialize(created, sample_implementation()) {
    Ok(result) -> result
    Error(error) -> panic as string.inspect(error)
  }
}

fn sample_implementation() -> actions.Implementation {
  actions.Implementation(
    name: "gleam-mcp-integration-test",
    version: "0.1.0",
    title: None,
    description: None,
    website_url: None,
    icons: [],
  )
}

fn spawn_listener(
  listening_client: client.Client,
) -> process.Subject(Result(Nil, client.ClientError)) {
  let reply_to = process.new_subject()
  let _ =
    process.spawn(fn() {
      let #(_, result) = client.listen(listening_client)
      process.send(reply_to, result)
    })
  reply_to
}

fn has_resource_template(
  templates: List(actions.ResourceTemplate),
  uri_prefix: String,
) -> Bool {
  list.any(templates, fn(template) {
    let actions.ResourceTemplate(uri_template:, ..) = template
    string.starts_with(uri_template, uri_prefix)
  })
}

fn has_text_resource_content(
  contents: List(actions.ResourceContents),
  expected_uri: String,
) -> Bool {
  list.any(contents, fn(content) {
    case content {
      actions.TextResourceContents(uri:, text:, ..) -> {
        uri == expected_uri && string.contains(text, "Resource 1:")
      }
      _ -> False
    }
  })
}

fn has_prompt(prompts: List(actions.Prompt), name: String) -> Bool {
  list.any(prompts, fn(prompt) {
    let actions.Prompt(name: prompt_name, ..) = prompt
    prompt_name == name
  })
}

fn has_prompt_text(
  messages: List(actions.PromptMessage),
  expected_text: String,
) -> Bool {
  list.any(messages, fn(message) {
    let actions.PromptMessage(content:, ..) = message
    case content {
      actions.TextBlock(actions.TextContent(text:, ..)) -> text == expected_text
      _ -> False
    }
  })
}

fn has_tool(tools: List(actions.Tool), name: String) -> Bool {
  list.any(tools, fn(tool) {
    let actions.Tool(name: tool_name, ..) = tool
    tool_name == name
  })
}

fn has_text_content(
  content: List(actions.ContentBlock),
  expected_text: String,
) -> Bool {
  list.any(content, fn(block) {
    case block {
      actions.TextBlock(actions.TextContent(text:, ..)) -> text == expected_text
      _ -> False
    }
  })
}
