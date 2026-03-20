import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server/capabilities as server_capabilities
import gleam_mcp/server/codec as server_codec
import mist

pub type InteractionKind {
  Elicitation
  Sampling
  SamplingTask
}

type BrokerMessage {
  PushListenerRequest(String)
  PopListenerRequest(process.Subject(Result(String, Nil)))
  PushClientResponse(String)
  PopClientResponse(process.Subject(Result(String, Nil)))
}

pub fn start_http_server(kind: InteractionKind) -> String {
  let broker_reply = process.new_subject()
  let reply_to = process.new_subject()
  let _broker_pid = process.spawn(fn() { broker_process(broker_reply) })
  let broker = case process.receive(broker_reply, 1000) {
    Ok(subject) -> subject
    Error(Nil) -> panic as "Timed out waiting for interaction broker to start"
  }

  let handler = interaction_handler(kind, broker)
  let _server_pid =
    process.spawn(fn() {
      let builder =
        mist.new(handler)
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(port, _, _) { process.send(reply_to, port) })

      let assert Ok(_) = mist.start(builder)
      process.sleep_forever()
    })

  case process.receive(reply_to, 1000) {
    Ok(port) -> "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
    Error(Nil) -> panic as "Timed out waiting for integration server to start"
  }
}

fn broker_process(reply_to: process.Subject(process.Subject(BrokerMessage))) {
  let subject = process.new_subject()
  process.send(reply_to, subject)
  broker_loop(subject, [], [], [], [])
}

fn broker_loop(
  subject: process.Subject(BrokerMessage),
  listener_requests: List(String),
  listener_waiters: List(process.Subject(Result(String, Nil))),
  client_responses: List(String),
  client_waiters: List(process.Subject(Result(String, Nil))),
) -> Nil {
  case process.receive_forever(subject) {
    PushListenerRequest(payload) ->
      case listener_waiters {
        [waiter, ..rest] -> {
          process.send(waiter, Ok(payload))
          broker_loop(
            subject,
            listener_requests,
            rest,
            client_responses,
            client_waiters,
          )
        }
        [] ->
          broker_loop(
            subject,
            list.append(listener_requests, [payload]),
            listener_waiters,
            client_responses,
            client_waiters,
          )
      }
    PopListenerRequest(reply) ->
      case listener_requests {
        [payload, ..rest] -> {
          process.send(reply, Ok(payload))
          broker_loop(
            subject,
            rest,
            listener_waiters,
            client_responses,
            client_waiters,
          )
        }
        [] ->
          broker_loop(
            subject,
            listener_requests,
            list.append(listener_waiters, [reply]),
            client_responses,
            client_waiters,
          )
      }
    PushClientResponse(payload) ->
      case client_waiters {
        [waiter, ..rest] -> {
          process.send(waiter, Ok(payload))
          broker_loop(
            subject,
            listener_requests,
            listener_waiters,
            client_responses,
            rest,
          )
        }
        [] ->
          broker_loop(
            subject,
            listener_requests,
            listener_waiters,
            list.append(client_responses, [payload]),
            client_waiters,
          )
      }
    PopClientResponse(reply) ->
      case client_responses {
        [payload, ..rest] -> {
          process.send(reply, Ok(payload))
          broker_loop(
            subject,
            listener_requests,
            listener_waiters,
            rest,
            client_waiters,
          )
        }
        [] ->
          broker_loop(
            subject,
            listener_requests,
            listener_waiters,
            client_responses,
            list.append(client_waiters, [reply]),
          )
      }
  }
}

fn interaction_handler(
  kind: InteractionKind,
  broker: process.Subject(BrokerMessage),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req) {
    let request.Request(method: method, ..) = req

    case method {
      http.Get -> handle_get(broker)
      http.Post -> handle_post(kind, broker, req)
      _ -> plain_response(405, "Method Not Allowed")
    }
  }
}

fn handle_get(
  broker: process.Subject(BrokerMessage),
) -> response.Response(mist.ResponseData) {
  case process.call(broker, 5000, PopListenerRequest) {
    Ok(payload) -> sse_response(payload)
    Error(Nil) ->
      plain_response(500, "Timed out waiting for server-sent request")
  }
}

fn handle_post(
  kind: InteractionKind,
  broker: process.Subject(BrokerMessage),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_048_576) {
    Ok(body_request) ->
      case bit_array.to_string(body_request.body) {
        Ok(body) -> handle_post_body(kind, broker, body)
        Error(_) -> plain_response(400, "Request body was not valid UTF-8")
      }
    Error(_) -> plain_response(400, "Unable to read request body")
  }
}

fn handle_post_body(
  kind: InteractionKind,
  broker: process.Subject(BrokerMessage),
  body: String,
) -> response.Response(mist.ResponseData) {
  case decode_client_response(kind, body) {
    Ok(value) -> {
      process.send(broker, PushClientResponse(value))
      accepted_response()
    }
    Error(_) ->
      case server_codec.decode_message(body) {
        Ok(server_codec.ActionRequest(rpc_request)) ->
          handle_client_request(kind, broker, rpc_request)
        Ok(server_codec.ActionNotification(notification)) ->
          handle_client_notification(notification)
        Ok(server_codec.UnknownRequest(id, method)) ->
          json_response(
            server_codec.encode_response(jsonrpc.ErrorResponse(
              Some(id),
              jsonrpc.method_not_found_error(method),
            )),
          )
        Ok(server_codec.UnknownNotification(_)) -> accepted_response()
        Error(_message) -> plain_response(400, body)
      }
  }
}

fn handle_client_request(
  kind: InteractionKind,
  broker: process.Subject(BrokerMessage),
  rpc_request: jsonrpc.Request(actions.ActionRequest),
) -> response.Response(mist.ResponseData) {
  case rpc_request {
    jsonrpc.Request(id, _, Some(actions.RequestInitialize(_))) ->
      json_response(
        server_codec.encode_response(jsonrpc.ResultResponse(
          id,
          initialize_result(),
        )),
      )
    jsonrpc.Request(id, _, Some(actions.RequestListTools(_))) ->
      json_response(
        server_codec.encode_response(jsonrpc.ResultResponse(
          id,
          list_tools_result(kind),
        )),
      )
    jsonrpc.Request(id, _, Some(actions.RequestCallTool(params))) -> {
      process.send(
        broker,
        PushListenerRequest(
          interaction_request(kind, params.name) |> client_codec.encode_request,
        ),
      )
      tool_call_response(kind, broker, id)
    }
    jsonrpc.Request(id, method, _) ->
      json_response(
        server_codec.encode_response(jsonrpc.ErrorResponse(
          Some(id),
          jsonrpc.method_not_found_error(method),
        )),
      )
    jsonrpc.Notification(method, _) ->
      json_response(
        server_codec.encode_response(jsonrpc.ErrorResponse(
          None,
          jsonrpc.method_not_found_error(method),
        )),
      )
  }
}

fn tool_call_response(
  kind: InteractionKind,
  broker: process.Subject(BrokerMessage),
  id: jsonrpc.RequestId,
) -> response.Response(mist.ResponseData) {
  let response_text = case kind {
    SamplingTask -> task_roundtrip_response_text(broker)
    _ ->
      case process.call(broker, 5000, PopClientResponse) {
        Ok(value) -> value
        Error(Nil) -> "Timed out waiting for client response"
      }
  }

  json_response(
    server_codec.encode_response(jsonrpc.ResultResponse(
      id,
      actions.ResultCallTool(actions.CallToolResult(
        content: [
          actions.TextBlock(actions.TextContent(
            result_prefix(kind) <> response_text,
            None,
            None,
          )),
        ],
        structured_content: None,
        is_error: Some(False),
        meta: None,
      )),
    )),
  )
}

fn handle_client_notification(
  notification: jsonrpc.Request(actions.ActionNotification),
) -> response.Response(mist.ResponseData) {
  case notification {
    jsonrpc.Notification(method, _) ->
      case method == mcp.method_initialized {
        True -> accepted_response()
        False -> plain_response(400, "Unsupported notification")
      }
    jsonrpc.Request(_, _, _) -> plain_response(400, "Expected notification")
  }
}

fn initialize_result() -> actions.ActionResult {
  actions.ResultInitialize(actions.InitializeResult(
    protocol_version: jsonrpc.latest_protocol_version,
    capabilities: server_capabilities.infer(
      has_tools: True,
      has_resources: False,
      has_prompts: False,
      has_completion: False,
      has_logging: False,
      has_tasks: False,
    ),
    server_info: actions.Implementation(
      name: "server-sent-request-test-server",
      version: "0.1.0",
      title: None,
      description: None,
      website_url: None,
      icons: [],
    ),
    instructions: None,
    meta: None,
  ))
}

fn list_tools_result(kind: InteractionKind) -> actions.ActionResult {
  actions.ResultListTools(actions.ListToolsResult(
    tools: [
      actions.Tool(
        name: tool_name(kind),
        title: None,
        description: Some("Roundtrip test tool"),
        input_schema: jsonrpc.VObject([]),
        execution: None,
        output_schema: None,
        annotations: None,
        icons: [],
        meta: None,
      ),
    ],
    page: actions.Page(None),
    meta: None,
  ))
}

fn interaction_request(
  kind: InteractionKind,
  name: String,
) -> jsonrpc.Request(actions.ActionRequest) {
  case kind {
    Elicitation ->
      jsonrpc.Request(
        jsonrpc.StringId("elicit-1"),
        mcp.method_elicit,
        Some(
          actions.RequestElicit(
            actions.ElicitRequestForm(actions.ElicitRequestFormParams(
              "Please provide a value for requst " <> name,
              jsonrpc.VObject([
                #("type", jsonrpc.VString("object")),
                #(
                  "properties",
                  jsonrpc.VObject([
                    #(
                      "answer",
                      jsonrpc.VObject([
                        #("type", jsonrpc.VString("string")),
                      ]),
                    ),
                  ]),
                ),
                #("required", jsonrpc.VArray([jsonrpc.VString("answer")])),
              ]),
              None,
              None,
            )),
          ),
        ),
      )
    Sampling | SamplingTask ->
      jsonrpc.Request(
        jsonrpc.StringId("sample-1"),
        mcp.method_create_message,
        Some(
          actions.RequestCreateMessage(actions.CreateMessageRequestParams(
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
            task: case kind {
              SamplingTask -> Some(actions.TaskMetadata(Some(1000)))
              _ -> None
            },
            meta: None,
          )),
        ),
      )
  }
}

fn decode_client_response(
  kind: InteractionKind,
  body: String,
) -> Result(String, Nil) {
  case kind {
    Elicitation -> extract_json_string(body, "answer")
    Sampling -> extract_json_string(body, "text")
    SamplingTask -> Error(Nil)
  }
}

fn extract_json_string(body: String, field: String) -> Result(String, Nil) {
  let marker = "\"" <> field <> "\":\""

  case string.split(body, on: marker) {
    [_before, after, ..] ->
      case string.split(after, on: "\"") {
        [value, ..] -> Ok(value)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn tool_name(kind: InteractionKind) -> String {
  case kind {
    Elicitation -> "roundtrip-elicitation"
    Sampling -> "roundtrip-sampling"
    SamplingTask -> "roundtrip-sampling-task"
  }
}

fn result_prefix(kind: InteractionKind) -> String {
  case kind {
    Elicitation -> "Elicited: "
    Sampling -> "Sampled: "
    SamplingTask -> "Task sampled: "
  }
}

fn task_roundtrip_response_text(
  broker: process.Subject(BrokerMessage),
) -> String {
  let created = case process.call(broker, 5000, PopClientResponse) {
    Ok(value) -> value
    Error(Nil) -> "Timed out waiting for client task creation"
  }

  case extract_json_string(created, "taskId") {
    Ok(task_id) -> {
      process.send(
        broker,
        PushListenerRequest(
          task_get_request(task_id) |> client_codec.encode_request,
        ),
      )
      let _ = process.call(broker, 5000, PopClientResponse)

      process.send(
        broker,
        PushListenerRequest(
          task_result_request(task_id) |> client_codec.encode_request,
        ),
      )

      case process.call(broker, 5000, PopClientResponse) {
        Ok(value) ->
          case extract_json_string(value, "text") {
            Ok(text) -> text
            Error(Nil) -> value
          }
        Error(Nil) -> "Timed out waiting for client task result"
      }
    }
    Error(Nil) -> created
  }
}

fn task_get_request(task_id: String) -> jsonrpc.Request(actions.ActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("task-get-1"),
    mcp.method_get_task,
    Some(actions.RequestGetTask(actions.TaskIdParams(task_id))),
  )
}

fn task_result_request(
  task_id: String,
) -> jsonrpc.Request(actions.ActionRequest) {
  jsonrpc.Request(
    jsonrpc.StringId("task-result-1"),
    mcp.method_get_task_result,
    Some(actions.RequestGetTaskResult(actions.TaskIdParams(task_id))),
  )
}

fn sse_response(payload: String) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string("data: " <> payload <> "\n\n")),
  )
}

fn json_response(body: String) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn accepted_response() -> response.Response(mist.ResponseData) {
  response.new(202)
  |> response.set_header(
    "mcp-protocol-version",
    jsonrpc.latest_protocol_version,
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
}

fn plain_response(
  status: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}
