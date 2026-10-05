import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/yielder
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/examples/everything/interaction_results
import gleam_mcp/examples/everything/server as everything_server
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec as server_codec
import stdin

type InteractionKind {
  Sampling
  Elicitation
}

type PendingInteraction {
  PendingInteraction(
    tool_call_id: jsonrpc.RequestId,
    request: jsonrpc.Request(actions.ServerActionRequest),
    kind: InteractionKind,
  )
}

type Logger {
  Logger(subject: process.Subject(LoggerMessage))
}

type LoggerMessage {
  Toggle(reply_to: process.Subject(Bool))
  SetLevel(actions.LoggingLevel)
}

type State {
  State(
    app_server: server.Server,
    pending: Option(PendingInteraction),
    logger: Logger,
  )
}

pub fn serve() -> Nil {
  let initial = State(everything_server.make_server(), None, new_logger())
  let _ = stdin.read_lines() |> yielder.fold(from: initial, with: handle_line)
  Nil
}

fn handle_line(state: State, line: String) -> State {
  case server_codec.decode_message(line) {
    Ok(server_codec.ClientActionRequest(request)) ->
      handle_request(state, request)
    Ok(server_codec.ActionNotification(notification)) ->
      handle_notification(state, notification)
    Ok(server_codec.UnknownRequest(id, method)) -> {
      respond(jsonrpc.ErrorResponse(
        Some(id),
        jsonrpc.method_not_found_error(method),
      ))
      state
    }
    Ok(server_codec.UnknownNotification(_)) -> state
    Error(_) -> handle_pending_response(state, line)
  }
}

fn handle_request(
  state: State,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> State {
  case request {
    jsonrpc.Request(id, _, Some(actions.ClientRequestCallTool(params))) ->
      case params.name {
        "toggle-simulated-logging" -> toggle_simulated_logging(state, id)
        "trigger-sampling-request" ->
          start_sampling_interaction(state, id, params)
        "trigger-elicitation-request" ->
          start_elicitation_interaction(state, id)
        _ -> delegate_request(state, request)
      }
    jsonrpc.Request(_, _, Some(actions.ClientRequestSetLoggingLevel(params))) -> {
      let State(app_server, pending, logger) = state
      let actions.SetLevelRequestParams(level, _) = params
      set_logger_level(logger, level)
      let #(next_server, response) = server.handle_request(app_server, request)
      respond(response)
      State(next_server, pending, logger)
    }
    _ -> delegate_request(state, request)
  }
}

fn handle_notification(
  state: State,
  notification: jsonrpc.Request(actions.ActionNotification),
) -> State {
  let State(app_server, pending, logger) = state
  let #(next_server, result) =
    server.handle_notification(app_server, notification)
  case result {
    Ok(_) -> State(next_server, pending, logger)
    Error(error) -> {
      let jsonrpc.RpcError(code: code, message: message, ..) = error
      io.println_error("RPC error " <> int.to_string(code) <> ": " <> message)
      State(next_server, pending, logger)
    }
  }
}

fn delegate_request(
  state: State,
  request: jsonrpc.Request(actions.ClientActionRequest),
) -> State {
  let State(app_server, pending, logger) = state
  let #(next_server, response) = server.handle_request(app_server, request)
  respond(response)
  State(next_server, pending, logger)
}

fn toggle_simulated_logging(
  state: State,
  tool_call_id: jsonrpc.RequestId,
) -> State {
  let State(app_server, pending, logger) = state
  let enabled = toggle_logger(logger)
  let text = case enabled {
    True ->
      "Started simulated, random-leveled logging at a 5 second pace. The selected client logging level will be respected."
    False -> "Stopped simulated logging."
  }
  respond(jsonrpc.ResultResponse(
    tool_call_id,
    actions.ClientResultCallTool(actions.CallToolResult(
      content: [actions.TextBlock(actions.TextContent(text, None, None))],
      structured_content: None,
      is_error: Some(False),
      meta: None,
    )),
  ))
  State(app_server, pending, logger)
}

fn start_sampling_interaction(
  state: State,
  tool_call_id: jsonrpc.RequestId,
  params: actions.CallToolRequestParams,
) -> State {
  let request = sampling_request(params.arguments)
  io.println(client_codec.encode_server_request(request))
  let State(app_server, _, logger) = state
  State(
    app_server,
    Some(PendingInteraction(tool_call_id, request, Sampling)),
    logger,
  )
}

fn start_elicitation_interaction(
  state: State,
  tool_call_id: jsonrpc.RequestId,
) -> State {
  let request = elicitation_request()
  io.println(client_codec.encode_server_request(request))
  let State(app_server, _, logger) = state
  State(
    app_server,
    Some(PendingInteraction(tool_call_id, request, Elicitation)),
    logger,
  )
}

fn handle_pending_response(state: State, line: String) -> State {
  let State(app_server, pending, logger) = state
  case pending {
    None -> state
    Some(interaction) ->
      case decode_interaction_result(interaction, line) {
        Ok(result) -> {
          let PendingInteraction(tool_call_id, _, _) = interaction
          respond(jsonrpc.ResultResponse(
            tool_call_id,
            actions.ClientResultCallTool(result),
          ))
          State(app_server, None, logger)
        }
        Error(Nil) -> state
      }
  }
}

fn new_logger() -> Logger {
  let reply_to = process.new_subject()
  let _ = process.spawn(fn() { start_logger(reply_to) })
  Logger(expect_ok(process.receive(reply_to, within: 1000)))
}

fn start_logger(reply_to: process.Subject(process.Subject(LoggerMessage))) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  logger_loop(subject, False, actions.Debug, 0)
}

fn logger_loop(
  subject: process.Subject(LoggerMessage),
  enabled: Bool,
  level: actions.LoggingLevel,
  tick: Int,
) -> Nil {
  case process.receive(subject, within: 5000) {
    Ok(Toggle(reply_to)) -> {
      let next_enabled = !enabled
      process.send(reply_to, next_enabled)
      let next_tick = case next_enabled && !enabled {
        True -> {
          maybe_emit_log(tick, level)
          tick + 1
        }
        False -> tick
      }
      logger_loop(subject, next_enabled, level, next_tick)
    }
    Ok(SetLevel(next_level)) -> logger_loop(subject, enabled, next_level, tick)
    Error(Nil) -> {
      let _ = case enabled {
        True -> maybe_emit_log(tick, level)
        False -> Nil
      }
      logger_loop(subject, enabled, level, tick + 1)
    }
  }
}

fn toggle_logger(logger: Logger) -> Bool {
  let Logger(subject) = logger
  let reply_to = process.new_subject()
  process.send(subject, Toggle(reply_to))
  expect_ok(process.receive(reply_to, within: 1000))
}

fn set_logger_level(logger: Logger, level: actions.LoggingLevel) -> Nil {
  let Logger(subject) = logger
  process.send(subject, SetLevel(level))
}

fn maybe_emit_log(tick: Int, minimum_level: actions.LoggingLevel) -> Nil {
  let level = logging_level_for_tick(tick)
  case logging_level_priority(level) >= logging_level_priority(minimum_level) {
    True ->
      io.println(
        client_codec.encode_notification(jsonrpc.Notification(
          mcp.method_notify_logging_message,
          Some(
            actions.NotifyLoggingMessage(
              actions.LoggingMessageNotificationParams(
                level,
                Some("gleam-mcp/everything"),
                jsonrpc.VString(logging_message_for_tick(tick)),
                None,
              ),
            ),
          ),
        )),
      )
    False -> Nil
  }
}

fn logging_level_for_tick(tick: Int) -> actions.LoggingLevel {
  case int.remainder(tick, 8) {
    Ok(0) -> actions.Debug
    Ok(1) -> actions.Info
    Ok(2) -> actions.Notice
    Ok(3) -> actions.Warning
    Ok(4) -> actions.Error
    Ok(5) -> actions.Critical
    Ok(6) -> actions.Alert
    _ -> actions.Emergency
  }
}

fn logging_level_priority(level: actions.LoggingLevel) -> Int {
  case level {
    actions.Debug -> 0
    actions.Info -> 1
    actions.Notice -> 2
    actions.Warning -> 3
    actions.Error -> 4
    actions.Critical -> 5
    actions.Alert -> 6
    actions.Emergency -> 7
  }
}

fn logging_message_for_tick(tick: Int) -> String {
  case int.remainder(tick, 4) {
    Ok(0) -> "Simulated Everything log: resource poll complete"
    Ok(1) -> "Simulated Everything log: prompt registry healthy"
    Ok(2) -> "Simulated Everything log: tool execution heartbeat"
    _ -> "Simulated Everything log: session idle"
  }
}

fn expect_ok(result: Result(a, Nil)) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> panic as "Expected Ok, got Error(Nil)"
  }
}

fn decode_interaction_result(
  interaction: PendingInteraction,
  line: String,
) -> Result(actions.CallToolResult, Nil) {
  let PendingInteraction(_, request, kind) = interaction
  case client_codec.decode_server_response(line, request) {
    Ok(jsonrpc.ResultResponse(_, response)) ->
      case kind, response {
        Sampling, actions.ServerResultCreateMessage(result) ->
          Ok(interaction_results.sampling_tool_result(result))
        Elicitation, actions.ServerResultElicit(result) ->
          Ok(interaction_results.elicitation_tool_result(result))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn sampling_request(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
) -> jsonrpc.Request(actions.ServerActionRequest) {
  let prompt = case arguments {
    Some(values) ->
      case dict.get(values, "prompt") {
        Ok(jsonrpc.VString(value)) -> value
        _ -> "Tell me something interesting about MCP."
      }
    None -> "Tell me something interesting about MCP."
  }
  let max_tokens = case arguments {
    Some(values) ->
      case dict.get(values, "maxTokens") {
        Ok(jsonrpc.VInt(value)) if value > 0 -> value
        _ -> 100
      }
    None -> 100
  }

  jsonrpc.Request(
    jsonrpc.StringId("everything-sample-1"),
    mcp.method_create_message,
    Some(
      actions.ServerRequestCreateMessage(actions.CreateMessageRequestParams(
        messages: [
          actions.SamplingMessage(
            actions.User,
            actions.SingleSamplingContent(
              actions.SamplingText(actions.TextContent(
                "Resource trigger-sampling-request context: " <> prompt,
                None,
                None,
              )),
            ),
            None,
          ),
        ],
        model_preferences: None,
        system_prompt: Some("You are a helpful test server."),
        include_context: None,
        temperature: Some(0.7),
        max_tokens: max_tokens,
        stop_sequences: [],
        metadata: None,
        tools: [],
        tool_choice: None,
        task: None,
        meta: None,
      )),
    ),
  )
}

fn elicitation_request() -> jsonrpc.Request(actions.ServerActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("everything-elicit-1"),
    mcp.method_elicit,
    Some(
      actions.ServerRequestElicit(
        actions.ElicitRequestForm(actions.ElicitRequestFormParams(
          "Please provide inputs for the following fields:",
          jsonrpc.VObject([
            #("type", jsonrpc.VString("object")),
            #(
              "properties",
              jsonrpc.VObject([
                #(
                  "name",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("string")),
                    #("description", jsonrpc.VString("Your full, legal name")),
                  ]),
                ),
                #(
                  "check",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("boolean")),
                    #(
                      "description",
                      jsonrpc.VString("Agree to the terms and conditions"),
                    ),
                  ]),
                ),
                #(
                  "email",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("string")),
                    #("format", jsonrpc.VString("email")),
                    #("description", jsonrpc.VString("Your email address")),
                  ]),
                ),
                #(
                  "integer",
                  jsonrpc.VObject([
                    #("type", jsonrpc.VString("integer")),
                    #("description", jsonrpc.VString("Your favorite integer")),
                  ]),
                ),
              ]),
            ),
            #("required", jsonrpc.VArray([jsonrpc.VString("name")])),
          ]),
          None,
          None,
        )),
      ),
    ),
  )
}

fn respond(response: jsonrpc.Response(actions.ClientActionResult)) {
  io.println(server_codec.encode_response(response))
}
