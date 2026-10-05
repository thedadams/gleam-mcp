import conformance/server_content as content
import conformance/server_interactions as interactions
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{type Value, VArray, VBool, VInt, VObject, VString}
import gleam_mcp/server

pub fn register(app: server.Server) -> server.Server {
  let app =
    list.fold(
      [
        "test_missing_capability",
        "test_input_required_result_elicitation",
        "test_input_required_result_sampling",
        "test_input_required_result_list_roots",
        "test_input_required_result_request_state",
        "test_input_required_result_multiple_inputs",
        "test_input_required_result_multi_round",
        "test_input_required_result_tampered_state",
        "test_input_required_result_capabilities",
      ],
      app,
      fn(app, name) {
        server.add_tool(
          app,
          name,
          "Conformance MRTR fixture",
          content.schema([]),
          fn(_) {
            Error(jsonrpc.invalid_params_error(
              "This fixture requires the modern protocol",
            ))
          },
        )
      },
    )
  server.add_prompt(
    app,
    "test_input_required_result_prompt",
    "MRTR prompt fixture",
    [],
    fn(_) {
      Error(jsonrpc.invalid_params_error(
        "This fixture requires the modern protocol",
      ))
    },
  )
}

pub fn handle(
  app: server.Server,
  context: server.RequestContext,
  request: actions.ClientActionRequest,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  let inputs = actions.input_responses(request) |> content.option_to_dict
  case actions.request_without_input(request) {
    actions.ClientRequestCallTool(params) ->
      tool(app, context, request, params.name, params.arguments, inputs)
    actions.ClientRequestGetPrompt(params) -> {
      case params.name {
        "test_input_required_result_prompt" -> {
          case elicited_text(inputs, "user_context", "context") {
            Some(text) ->
              Ok(
                actions.ClientResultGetPrompt(actions.GetPromptResult(
                  None,
                  [
                    actions.PromptMessage(
                      actions.User,
                      content.text_block("Prompt with context: " <> text),
                    ),
                  ],
                  None,
                )),
              )
            None ->
              pending(
                [
                  #(
                    "user_context",
                    form(
                      "What context should the prompt use?",
                      "context",
                      "string",
                    ),
                  ),
                ],
                None,
              )
          }
        }
        _ ->
          content.prompt(params.name, params.arguments)
          |> result.map(actions.ClientResultGetPrompt)
      }
    }
    actions.ClientRequestReadResource(params) ->
      content.resource(params.uri)
      |> result.map(fn(contents) {
        actions.ClientResultReadResource(actions.ReadResourceResult(
          contents,
          None,
        ))
      })
    _ -> Error(jsonrpc.method_not_found_error("Unsupported fixture request"))
  }
}

fn tool(
  app: server.Server,
  context: server.RequestContext,
  request: actions.ClientActionRequest,
  name: String,
  arguments: Option(dict.Dict(String, Value)),
  inputs: dict.Dict(String, Value),
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  case name {
    "test_missing_capability" -> {
      case supports(context, "sampling") {
        True -> complete("Success")
        // The SDK validates this MRTR result and returns its public missing
        // capability error. The fixture does not construct protocol responses.
        False ->
          pending(
            [#("sample", sample("Test required sampling capability"))],
            None,
          )
      }
    }
    "test_input_required_result_elicitation" -> {
      case elicited_text(inputs, "user_name", "name") {
        Some(name) -> complete("Hello, " <> name <> "!")
        None ->
          pending(
            [#("user_name", form("What is your name?", "name", "string"))],
            None,
          )
      }
    }
    "test_input_required_result_sampling" -> {
      case sampled_text(inputs, "capital_question") {
        Some(text) -> complete("Sampling result: " <> text)
        None ->
          pending(
            [#("capital_question", sample("What is the capital of France?"))],
            None,
          )
      }
    }
    "test_input_required_result_list_roots" -> {
      case roots_count(inputs, "client_roots") {
        Some(count) -> complete("Found " <> int.to_string(count) <> " root(s)")
        None -> pending([#("client_roots", roots())], None)
      }
    }
    "test_input_required_result_request_state"
    | "test_input_required_result_tampered_state" -> {
      use state <- result.try(verified_state(app, context, name, request))
      case state, accepted_boolean(inputs, "confirm", "ok") {
        Some("confirm"), Some(True) ->
          complete("state-ok: integrity-ok: requestState validated")
        _, _ ->
          pending(
            [#("confirm", form("Please confirm", "ok", "boolean"))],
            Some(sign(app, context, name, "confirm")),
          )
      }
    }
    "test_input_required_result_multiple_inputs" -> {
      use state <- result.try(verified_state(app, context, name, request))
      case
        state,
        elicited_text(inputs, "user_name", "name"),
        sampled_text(inputs, "greeting"),
        roots_count(inputs, "client_roots")
      {
        Some("multiple"), Some(user), Some(greeting), Some(count) ->
          complete(
            "Name: "
            <> user
            <> "; Greeting: "
            <> greeting
            <> "; Roots: "
            <> int.to_string(count),
          )
        _, _, _, _ ->
          pending(
            [
              #("user_name", form("What is your name?", "name", "string")),
              #("greeting", sample("Generate a greeting")),
              #("client_roots", roots()),
            ],
            Some(sign(app, context, name, "multiple")),
          )
      }
    }
    "test_input_required_result_multi_round" -> {
      use state <- result.try(verified_state(app, context, name, request))
      case state {
        None ->
          pending(
            [#("step1", form("Step 1: What is your name?", "name", "string"))],
            Some(sign(app, context, name, "round1")),
          )
        Some("round1") -> {
          case elicited_text(inputs, "step1", "name") {
            Some(user) ->
              pending(
                [
                  #(
                    "step2",
                    form(
                      "Step 2: What is your favorite color?",
                      "color",
                      "string",
                    ),
                  ),
                ],
                Some(sign(app, context, name, "round2:" <> user)),
              )
            None ->
              pending(
                [
                  #(
                    "step1",
                    form("Step 1: What is your name?", "name", "string"),
                  ),
                ],
                actions.request_state(request),
              )
          }
        }
        Some(state) -> {
          case
            string.starts_with(state, "round2:"),
            elicited_text(inputs, "step2", "color")
          {
            True, Some(color) ->
              complete(
                "Multi-round complete for "
                <> string.drop_start(state, 7)
                <> " who likes "
                <> color,
              )
            True, None ->
              pending(
                [
                  #(
                    "step2",
                    form(
                      "Step 2: What is your favorite color?",
                      "color",
                      "string",
                    ),
                  ),
                ],
                actions.request_state(request),
              )
            _, _ ->
              Error(jsonrpc.invalid_params_error(
                "Unexpected continuation state",
              ))
          }
        }
      }
    }
    "test_input_required_result_capabilities" -> {
      let requests =
        [
          #("sampling", "sample_input", sample("Sample request")),
          #(
            "elicitation",
            "elicit_input",
            form("Elicitation input", "value", "string"),
          ),
        ]
        |> list.filter(fn(entry) { supports(context, entry.0) })
        |> list.map(fn(entry) { #(entry.1, entry.2) })
      case requests, dict.size(inputs) > 0 {
        [], _ -> complete("No supported capabilities declared")
        _, True -> complete("capabilities-ok: received inputs")
        _, False -> pending(requests, None)
      }
    }
    _ ->
      interactions.run(app, context, name, arguments)
      |> result.map(actions.ClientResultCallTool)
  }
}

fn verified_state(
  app: server.Server,
  context: server.RequestContext,
  binding: String,
  request: actions.ClientActionRequest,
) -> Result(Option(String), jsonrpc.RpcError) {
  case actions.request_state(request) {
    None -> Ok(None)
    Some(state) ->
      server.verify_request_state(app, context, binding, state)
      |> result.map(Some)
  }
}

fn sign(
  app: server.Server,
  context: server.RequestContext,
  binding: String,
  state: String,
) -> String {
  server.sign_request_state(app, context, binding, state, 60_000)
}

fn pending(
  requests: List(#(String, Value)),
  state: Option(String),
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  Ok(
    actions.ClientResultInputRequired(actions.InputRequiredResult(
      Some(dict.from_list(requests)),
      state,
      None,
    )),
  )
}

fn complete(
  text: String,
) -> Result(actions.ClientActionResult, jsonrpc.RpcError) {
  Ok(actions.ClientResultCallTool(content.text_result(text)))
}

fn form(message: String, field: String, kind: String) -> Value {
  VObject([
    #("method", VString("elicitation/create")),
    #(
      "params",
      VObject([
        #("message", VString(message)),
        #(
          "requestedSchema",
          content.schema([#(field, VObject([#("type", VString(kind))]))]),
        ),
      ]),
    ),
  ])
}

fn sample(prompt: String) -> Value {
  VObject([
    #("method", VString("sampling/createMessage")),
    #(
      "params",
      VObject([
        #(
          "messages",
          VArray([
            VObject([
              #("role", VString("user")),
              #(
                "content",
                VObject([#("type", VString("text")), #("text", VString(prompt))]),
              ),
            ]),
          ]),
        ),
        #("maxTokens", VInt(100)),
      ]),
    ),
  ])
}

fn roots() -> Value {
  VObject([#("method", VString("roots/list")), #("params", VObject([]))])
}

fn response(inputs: dict.Dict(String, Value), key: String) -> Option(Value) {
  dict.get(inputs, key) |> option.from_result
}

fn response_content(
  inputs: dict.Dict(String, Value),
  key: String,
) -> Option(Value) {
  case response(inputs, key) {
    Some(value) -> content.at(value, "content")
    None -> None
  }
}

fn elicited_text(
  inputs: dict.Dict(String, Value),
  key: String,
  field: String,
) -> Option(String) {
  case response(inputs, key), response_content(inputs, key) {
    Some(response), Some(value) -> {
      case content.at(response, "action") {
        Some(VString("accept")) ->
          content.at(value, field) |> content.string_value
        _ -> None
      }
    }
    _, _ -> None
  }
}

fn sampled_text(
  inputs: dict.Dict(String, Value),
  key: String,
) -> Option(String) {
  case response_content(inputs, key) {
    Some(value) -> content.at(value, "text") |> content.string_value
    None -> None
  }
}

fn accepted_boolean(
  inputs: dict.Dict(String, Value),
  key: String,
  field: String,
) -> Option(Bool) {
  case response_content(inputs, key) {
    Some(value) ->
      case content.at(value, field) {
        Some(VBool(value)) -> Some(value)
        _ -> None
      }
    _ -> None
  }
}

fn roots_count(inputs: dict.Dict(String, Value), key: String) -> Option(Int) {
  case response(inputs, key) {
    Some(value) ->
      case content.at(value, "roots") {
        Some(VArray(roots)) -> Some(list.length(roots))
        _ -> None
      }
    _ -> None
  }
}

fn supports(context: server.RequestContext, name: String) -> Bool {
  let capabilities =
    server.request_meta(context)
    |> option.then(fn(meta) { meta.extra })
    |> option.then(fn(meta) {
      dict.get(meta.fields, "io.modelcontextprotocol/clientCapabilities")
      |> option.from_result
    })
  case capabilities {
    Some(value) -> option.is_some(content.at(value, name))
    None -> False
  }
}
