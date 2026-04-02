import client_integration_support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleeunit
import gleeunit/should
import server_test_support

const dynamic_resource_uri = "demo://resource/dynamic/text/1"

type InteractionKind {
  Elicitation
  Sampling
}

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
    actions.CallTool(actions.CallToolResult(content:, ..)) -> {
      should.be_true(has_text_content(content, "Echo: hello"))
    }
    actions.CallToolTask(_) -> should.fail()
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

pub fn simulate_research_query_runs_as_task_http_test() {
  option.map(
    client_integration_support.http_transport(),
    simulate_research_query_runs_as_task_with_transport,
  )
}

pub fn simulate_research_query_runs_as_task_stdio_test() {
  option.map(
    client_integration_support.stdio_transport(),
    simulate_research_query_runs_as_task_with_transport,
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

fn simulate_research_query_runs_as_task_with_transport(config: transport.Config) {
  let client = client.new(config, capabilities.none())
  let #(client, _) = initialize_client(client)

  let #(client, tools_result) = client.list_tools(client, None)
  let tools = tools_result |> should.be_ok
  let actions.ListToolsResult(tools: listed_tools, ..) = tools
  should.be_true(has_task_required_tool(listed_tools, "simulate-research-query"))

  let #(client, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams(
        "simulate-research-query",
        Some(
          dict.from_list([
            #("topic", jsonrpc.VString("mcp tasks over http transport")),
            #("ambiguous", jsonrpc.VBool(False)),
          ]),
        ),
        Some(actions.TaskMetadata(Some(10_000))),
        None,
      ),
    )

  let task_id = case call_result |> should.be_ok {
    actions.CallToolTask(actions.CreateTaskResult(task:, ..)) -> task.task_id
    _ -> panic as string.inspect(call_result)
  }

  let #(client, completed_task) = wait_for_completed_task(client, task_id, 8)
  should.equal(completed_task.status, actions.Completed)

  let #(_, task_result) =
    client.get_task_result(client, actions.TaskIdParams(task_id))

  case task_result |> should.be_ok {
    actions.TaskCallTool(actions.CallToolResult(content:, ..)) -> {
      should.be_true(has_text_content_containing(content, "# Research Report:"))
      should.be_true(has_text_content_containing(
        content,
        "mcp tasks over http transport",
      ))
      should.be_true(has_text_content_containing(
        content,
        "This is a simulated research report from the Everything MCP Server.",
      ))
    }
    _ -> should.fail()
  }
}

pub fn elicitation_server_sent_roundtrip_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_test_support.start_http_server_with_server(
        server_sent_request_server(Elicitation),
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
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(call_result)
  }

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-elicitation", None, None, None),
    )

  case call_result {
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(call_result)
  }
}

pub fn sampling_server_sent_roundtrip_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_test_support.start_http_server_with_server(
        server_sent_request_server(Sampling),
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
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(content, "Sampled: sampled value"))
    _ -> panic as string.inspect(call_result)
  }
}

pub fn task_result_streams_elicitation_for_input_required_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_test_support.start_http_server_with_server(
        server_sent_request_server(Elicitation),
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

  let #(client, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams(
        "roundtrip-elicitation",
        None,
        Some(actions.TaskMetadata(Some(1000))),
        None,
      ),
    )

  let task_id = case call_result |> should.be_ok {
    actions.CallToolTask(actions.CreateTaskResult(task:, ..)) -> task.task_id
    _ -> panic as "Expected task-backed elicitation call"
  }

  let #(client, task) =
    wait_for_task_status(client, task_id, actions.InputRequired, 8)
  should.equal(task.status, actions.InputRequired)

  let #(_, result) =
    client.get_task_result(client, actions.TaskIdParams(task_id))

  case result {
    Ok(actions.TaskCallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(result)
  }
}

pub fn task_result_streams_create_message_for_input_required_http_test() {
  let config =
    transport.Http(transport.HttpConfig(
      server_test_support.start_http_server_with_server(
        server_sent_request_server(Sampling),
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

  let #(client, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams(
        "roundtrip-sampling",
        None,
        Some(actions.TaskMetadata(Some(1000))),
        None,
      ),
    )

  let task_id = case call_result |> should.be_ok {
    actions.CallToolTask(actions.CreateTaskResult(task:, ..)) -> task.task_id
    _ -> panic as "Expected task-backed sampling call"
  }

  let #(client, task) =
    wait_for_task_status(client, task_id, actions.InputRequired, 8)
  should.equal(task.status, actions.InputRequired)

  let #(_, result) =
    client.get_task_result(client, actions.TaskIdParams(task_id))

  case result {
    Ok(actions.TaskCallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(content, "Sampled: sampled value"))
    _ -> panic as string.inspect(result)
  }
}

pub fn server_sent_requests_use_matching_http_session_test() {
  let base_url =
    server_test_support.start_http_server_with_server(
      server_sent_request_server(Elicitation),
    )

  let client_a =
    client.new(
      transport.Http(transport.HttpConfig(base_url, [], Some(5000))),
      elicitation_capabilities("client-a"),
    )
  let client_b =
    client.new(
      transport.Http(transport.HttpConfig(base_url, [], Some(5000))),
      elicitation_capabilities("client-b"),
    )

  let #(client_a, _) = initialize_client(client_a)
  let #(client_b, _) = initialize_client(client_b)

  let _ = spawn_listener(client_a)
  let _ = spawn_listener(client_b)
  process.sleep(100)

  let #(_, result_a) =
    client.call_tool(
      client_a,
      actions.CallToolRequestParams("roundtrip-elicitation", None, None, None),
    )
  let #(_, result_b) =
    client.call_tool(
      client_b,
      actions.CallToolRequestParams("roundtrip-elicitation", None, None, None),
    )

  case result_a {
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: client-a for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(result_a)
  }

  case result_b {
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: client-b for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(result_b)
  }
}

pub fn elicitation_server_sent_roundtrip_stdio_test() {
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

  let client =
    client.new(
      client_integration_support.local_server_sent_stdio_transport(),
      capability_config,
    )
  let #(client, _) = initialize_client(client)
  let _ = spawn_listener(client)
  process.sleep(100)

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-elicitation", None, None, None),
    )

  case call_result {
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
      should.be_true(has_text_content(
        content,
        "Elicited: elicited for Please provide a value for requst roundtrip-elicitation",
      ))
    _ -> panic as string.inspect(call_result)
  }
}

pub fn sampling_server_sent_roundtrip_stdio_test() {
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

  let client =
    client.new(
      client_integration_support.local_server_sent_stdio_transport(),
      capability_config,
    )
  let #(client, _) = initialize_client(client)
  let _ = spawn_listener(client)
  process.sleep(100)

  let #(_, call_result) =
    client.call_tool(
      client,
      actions.CallToolRequestParams("roundtrip-sampling", None, None, None),
    )

  case call_result {
    Ok(actions.CallTool(actions.CallToolResult(content:, ..))) ->
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

fn server_sent_request_server(kind: InteractionKind) -> server.Server {
  server.new(
    actions.Implementation(
      name: "server-sent-request-http-test-server",
      version: "0.1.0",
      title: None,
      description: None,
      website_url: None,
      icons: [],
    ),
  )
  |> server.add_tool_with_context(
    tool_name(kind),
    "Roundtrip test tool",
    jsonrpc.VObject([]),
    fn(app_server, context, _) {
      case kind {
        Elicitation ->
          elicitation_tool_result(app_server, context, tool_name(kind))
        Sampling -> sampling_tool_result(app_server, context)
      }
    },
  )
}

fn elicitation_tool_result(
  app_server: server.Server,
  context: server.RequestContext,
  tool: String,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let _ =
    set_task_status(
      app_server,
      context,
      actions.InputRequired,
      Some("Waiting for elicitation input."),
    )
  server.elicit(
    app_server,
    context,
    actions.ElicitRequestForm(actions.ElicitRequestFormParams(
      "Please provide a value for requst " <> tool,
      jsonrpc.VObject([
        #("type", jsonrpc.VString("object")),
        #(
          "properties",
          jsonrpc.VObject([
            #("answer", jsonrpc.VObject([#("type", jsonrpc.VString("string"))])),
          ]),
        ),
        #("required", jsonrpc.VArray([jsonrpc.VString("answer")])),
      ]),
      None,
      None,
    )),
  )
  |> result.map(fn(elicited) {
    let _ =
      set_task_status(
        app_server,
        context,
        actions.Working,
        Some("Continuing after elicitation input."),
      )
    let actions.ElicitResult(_, content, _) = elicited
    let answer = case content {
      Some(fields) ->
        case dict.get(fields, "answer") {
          Ok(actions.ElicitString(value)) -> value
          _ -> "missing answer"
        }
      None -> "missing answer"
    }

    actions.CallToolResult(
      content: [
        actions.TextBlock(actions.TextContent(
          "Elicited: " <> answer,
          None,
          None,
        )),
      ],
      structured_content: None,
      is_error: Some(False),
      meta: None,
    )
  })
}

fn sampling_tool_result(
  app_server: server.Server,
  context: server.RequestContext,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  let _ =
    set_task_status(
      app_server,
      context,
      actions.InputRequired,
      Some("Waiting for sampled message."),
    )
  case
    server.create_message(
      app_server,
      context,
      actions.CreateMessageRequestParams(
        messages: [
          actions.SamplingMessage(
            actions.User,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent(
                "Return the integration-test sample",
                None,
                None,
              )),
            ),
            None,
          ),
        ],
        model_preferences: None,
        system_prompt: None,
        include_context: None,
        temperature: None,
        max_tokens: 32,
        stop_sequences: [],
        metadata: None,
        tools: [],
        tool_choice: None,
        task: None,
        meta: None,
      ),
    )
  {
    Ok(actions.ServerResultCreateMessage(actions.CreateMessageResult(
      message:,
      ..,
    ))) -> {
      let _ =
        set_task_status(
          app_server,
          context,
          actions.Working,
          Some("Continuing after sampled message."),
        )
      let actions.SamplingMessage(content:, ..) = message
      case content {
        actions.SingleSamplingContent(actions.SamplingText(actions.TextContent(
          text:,
          ..,
        ))) ->
          Ok(actions.CallToolResult(
            content: [
              actions.TextBlock(actions.TextContent(
                "Sampled: " <> text,
                None,
                None,
              )),
            ],
            structured_content: None,
            is_error: Some(False),
            meta: None,
          ))
        _ ->
          Error(jsonrpc.invalid_params_error(
            "Client returned unsupported sampling content",
          ))
      }
    }
    Ok(_) ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected result for sampling request",
      ))
    Error(error) -> Error(error)
  }
}

fn set_task_status(
  app_server: server.Server,
  context: server.RequestContext,
  status: actions.TaskStatus,
  status_message: Option(String),
) -> Nil {
  case server.task_id(context) {
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

fn elicitation_capabilities(prefix: String) -> capabilities.Config {
  capabilities.none()
  |> capabilities.with_elicit_form(fn(param) {
    Ok(
      capabilities.Elicit(actions.ElicitResult(
        actions.ElicitAccept,
        Some(
          dict.from_list([
            #(
              "answer",
              actions.ElicitString(prefix <> " for " <> param.message),
            ),
          ]),
        ),
        None,
      )),
    )
  })
}

fn tool_name(kind: InteractionKind) -> String {
  case kind {
    Elicitation -> "roundtrip-elicitation"
    Sampling -> "roundtrip-sampling"
  }
}

fn wait_for_completed_task(
  current_client: client.Client,
  task_id: String,
  attempts_left: Int,
) -> #(client.Client, actions.Task) {
  case attempts_left {
    0 -> panic as "Timed out waiting for task completion"
    _ -> {
      let #(next_client, task_result) =
        client.get_task(current_client, actions.TaskIdParams(task_id))
      let task = task_result |> should.be_ok

      case task.task.status {
        actions.Completed -> #(next_client, task.task)
        actions.Failed -> panic as "Task failed before returning a result"
        actions.Cancelled -> panic as "Task was cancelled before completion"
        actions.Working | actions.InputRequired -> {
          let poll_interval_ms = case task.task.poll_interval_ms {
            Some(value) -> value
            None -> 1000
          }

          process.sleep(poll_interval_ms)
          wait_for_completed_task(next_client, task_id, attempts_left - 1)
        }
      }
    }
  }
}

fn wait_for_task_status(
  current_client: client.Client,
  task_id: String,
  expected_status: actions.TaskStatus,
  attempts_left: Int,
) -> #(client.Client, actions.Task) {
  case attempts_left {
    0 -> panic as "Timed out waiting for expected task status"
    _ -> {
      let #(next_client, task_result) =
        client.get_task(current_client, actions.TaskIdParams(task_id))
      let task = task_result |> should.be_ok

      case task.task.status == expected_status {
        True -> #(next_client, task.task)
        False -> {
          let poll_interval_ms = case task.task.poll_interval_ms {
            Some(value) -> value
            None -> 1000
          }

          process.sleep(poll_interval_ms)
          wait_for_task_status(
            next_client,
            task_id,
            expected_status,
            attempts_left - 1,
          )
        }
      }
    }
  }
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

fn has_task_required_tool(tools: List(actions.Tool), name: String) -> Bool {
  list.any(tools, fn(tool) {
    case tool {
      actions.Tool(
        name: tool_name,
        execution: Some(actions.ToolExecution(task_support: Some(
          actions.TaskRequired,
        ))),
        ..,
      ) -> tool_name == name
      _ -> False
    }
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

fn has_text_content_containing(
  content: List(actions.ContentBlock),
  expected_text: String,
) -> Bool {
  list.any(content, fn(block) {
    case block {
      actions.TextBlock(actions.TextContent(text:, ..)) ->
        string.contains(text, expected_text)
      _ -> False
    }
  })
}
