import conformance/client_callbacks
import conformance/client_support as support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleam_mcp/mcp

pub fn run(
  server_url: String,
  scenario: String,
  protocol_version: String,
  context: jsonrpc.Value,
) -> Result(Nil, String) {
  use _ <- result.try(supported_scenario(scenario))
  use app <- result.try(support.bootstrap(
    transport.HttpConfig(server_url, [], Some(10_000)),
    protocol_version,
    client_callbacks.configuration(scenario),
  ))
  let #(app, outcome) = case scenario {
    "initialize" -> #(app, Ok(Nil))
    "tools_call" -> tools_call(app)
    "sse-retry" -> listed_call(app, "test_reconnection")
    "elicitation-sep1034-client-defaults" -> elicitation_defaults(app)
    "request-metadata" -> request_metadata(app)
    "sep-2322-client-request-state" -> mrtr(app)
    "http-standard-headers" -> standard_headers(app)
    "http-custom-headers" -> custom_headers(app, context)
    "http-invalid-tool-headers" -> invalid_tool_headers(app)
    "json-schema-ref-no-deref" ->
      client.list_tools(app, None) |> support.step |> support.finish
    "json-schema-2020-12-preservation" -> schema_preservation(app)
    _ -> #(app, Error("Unsupported core conformance scenario: " <> scenario))
  }
  support.close(app, outcome)
}

fn supported_scenario(scenario: String) -> Result(Nil, String) {
  case scenario {
    "initialize"
    | "tools_call"
    | "sse-retry"
    | "elicitation-sep1034-client-defaults"
    | "request-metadata"
    | "sep-2322-client-request-state"
    | "http-standard-headers"
    | "http-custom-headers"
    | "http-invalid-tool-headers"
    | "json-schema-ref-no-deref"
    | "json-schema-2020-12-preservation" -> Ok(Nil)
    _ -> Error("Unsupported core conformance scenario: " <> scenario)
  }
}

fn schema_preservation(
  app: client.Client,
) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.then(fn(app, tools) {
    case
      list.find(tools.tools, fn(tool) {
        tool.name == "json_schema_2020_12_tool"
      })
    {
      Ok(tool) ->
        call(
          app,
          "json_schema_echo",
          dict.from_list([#("schema", tool.input_schema)]),
        )
      Error(_) -> #(
        app,
        Error("Conformance server did not advertise json_schema_2020_12_tool"),
      )
    }
  })
}

fn tools_call(app: client.Client) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.then(fn(app, tools) {
    case list.any(tools.tools, fn(tool) { tool.name == "add_numbers" }) {
      True ->
        call(
          app,
          "add_numbers",
          dict.from_list([
            #("a", jsonrpc.VInt(5)),
            #("b", jsonrpc.VInt(3)),
          ]),
        )
      False -> #(app, Error("Conformance server did not advertise add_numbers"))
    }
  })
}

fn listed_call(
  app: client.Client,
  name: String,
) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.then(fn(app, _) { call(app, name, dict.new()) })
}

fn elicitation_defaults(
  app: client.Client,
) -> #(client.Client, Result(Nil, String)) {
  let completed = process.new_subject()
  let listener =
    process.spawn_unlinked(fn() {
      let #(_, outcome) = client.listen(app)
      process.send(completed, outcome)
    })
  // This legacy fixture sends unsolicited requests on the session's GET
  // stream. Give its background SDK listener time to establish that stream.
  process.sleep(100)
  let #(app, outcome) = listed_call(app, "test_client_elicitation_defaults")
  let #(app, closed) = client.close(app)
  let outcome =
    result.try(outcome, fn(_) { result.map_error(closed, support.client_error) })
  case process.receive(completed, within: 1000) {
    // Closing the client deliberately interrupts its long-lived GET stream.
    Ok(_) -> #(app, outcome)
    Error(_) -> {
      process.kill(listener)
      #(
        app,
        result.try(outcome, fn(_) {
          Error("Legacy conformance listener did not stop after client.close")
        }),
      )
    }
  }
}

fn request_metadata(
  app: client.Client,
) -> #(client.Client, Result(Nil, String)) {
  // Discovery advertised no tool capability. A second permitted discovery
  // exercises per-request metadata without asserting an unsupported feature.
  client.request(
    app,
    jsonrpc.Request(
      jsonrpc.StringId("conformance-metadata-followup"),
      mcp.method_discover,
      Some(actions.ClientRequestDiscover(None)),
    ),
  )
  |> support.step
  |> support.finish
}

fn mrtr(app: client.Client) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.finish
  |> support.then(fn(app, _) { call(app, "test_mrtr_echo_state", dict.new()) })
  |> support.then(fn(app, _) { call(app, "test_mrtr_unrelated", dict.new()) })
  |> support.then(fn(app, _) { call(app, "test_mrtr_no_state", dict.new()) })
  |> support.then(fn(app, _) {
    call(app, "test_mrtr_no_result_type", dict.new())
  })
}

fn standard_headers(
  app: client.Client,
) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.then(fn(app, tools) {
    list.fold(tools.tools, #(app, Ok(Nil)), fn(outcome, tool) {
      support.then(outcome, fn(app, _) { call(app, tool.name, dict.new()) })
    })
  })
  |> support.then(fn(app, _) {
    client.list_resources(app, None)
    |> support.step
    |> support.then(fn(app, resources) {
      list.fold(resources.resources, #(app, Ok(Nil)), fn(outcome, resource) {
        support.then(outcome, fn(app, _) {
          client.read_resource(
            app,
            actions.ReadResourceRequestParams(resource.uri, None),
          )
          |> support.step
          |> support.finish
        })
      })
    })
  })
  |> support.then(fn(app, _) {
    client.list_prompts(app, None)
    |> support.step
    |> support.then(fn(app, prompts) {
      list.fold(prompts.prompts, #(app, Ok(Nil)), fn(outcome, prompt) {
        support.then(outcome, fn(app, _) {
          client.get_prompt(
            app,
            actions.GetPromptRequestParams(prompt.name, None, None),
          )
          |> support.step
          |> support.finish
        })
      })
    })
  })
}

fn custom_headers(
  app: client.Client,
  context: jsonrpc.Value,
) -> #(client.Client, Result(Nil, String)) {
  case tool_calls(context) {
    Error(error) -> #(app, Error(error))
    Ok(calls) ->
      client.list_tools(app, None)
      |> support.step
      |> support.then(fn(app, listed) {
        list.fold(calls, #(app, Ok(Nil)), fn(outcome, params) {
          support.then(outcome, fn(app, _) {
            case list.any(listed.tools, fn(tool) { tool.name == params.name }) {
              True ->
                client.call_tool(app, params)
                |> support.step
                |> support.finish
              False -> #(
                app,
                Error(
                  "Conformance custom-header tool was not surfaced: "
                  <> params.name,
                ),
              )
            }
          })
        })
      })
  }
}

fn invalid_tool_headers(
  app: client.Client,
) -> #(client.Client, Result(Nil, String)) {
  client.list_tools(app, None)
  |> support.step
  |> support.then(fn(app, listed) {
    case listed.tools {
      [tool] if tool.name == "valid_tool" ->
        call(
          app,
          tool.name,
          dict.from_list([#("region", jsonrpc.VString("us-west1"))]),
        )
      _ -> #(
        app,
        Error(
          "SDK must surface only valid_tool after rejecting invalid header annotations",
        ),
      )
    }
  })
}

fn tool_calls(
  context: jsonrpc.Value,
) -> Result(List(actions.CallToolRequestParams), String) {
  let calls = case context {
    jsonrpc.VObject(fields) -> list.key_find(fields, "toolCalls")
    _ -> Error(Nil)
  }
  case calls {
    Ok(jsonrpc.VArray([_, ..] as calls)) -> list.try_map(calls, tool_call)
    _ ->
      Error(
        "Custom-header conformance context requires a nonempty toolCalls array",
      )
  }
}

fn tool_call(
  value: jsonrpc.Value,
) -> Result(actions.CallToolRequestParams, String) {
  case value {
    jsonrpc.VObject(fields) -> {
      use name <- result.try(case list.key_find(fields, "name") {
        Ok(jsonrpc.VString(name)) -> Ok(name)
        _ -> Error("Conformance tool call requires a string name")
      })
      use arguments <- result.try(case list.key_find(fields, "arguments") {
        Ok(jsonrpc.VObject(arguments)) -> Ok(dict.from_list(arguments))
        Error(_) -> Ok(dict.new())
        _ -> Error("Conformance tool arguments must be an object")
      })
      Ok(actions.CallToolRequestParams(name, Some(arguments), None, None))
    }
    _ -> Error("Conformance tool call must be an object")
  }
}

fn call(
  app: client.Client,
  name: String,
  arguments: dict.Dict(String, jsonrpc.Value),
) -> #(client.Client, Result(Nil, String)) {
  client.call_tool(
    app,
    actions.CallToolRequestParams(name, Some(arguments), None, None),
  )
  |> support.step
  |> support.finish
}
