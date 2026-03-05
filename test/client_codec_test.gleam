import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/codec
import gleam_mcp/jsonrpc
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn encode_request_serializes_initialize_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "initialize",
      Some(
        actions.RequestInitialize(actions.InitializeRequestParams(
          protocol_version: jsonrpc.latest_protocol_version,
          capabilities: actions.ClientCapabilities(None, None, None, None, None),
          client_info: actions.Implementation(
            name: "test-client",
            version: "1.0.0",
            title: None,
            description: None,
            website_url: None,
            icons: [],
          ),
          meta: None,
        )),
      ),
    )

  codec.encode_request(request)
  |> should.equal(
    "{\"id\":\"req-1\",\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\""
    <> jsonrpc.latest_protocol_version
    <> "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0.0\"}}}",
  )
}

pub fn encode_notification_serializes_jsonrpc_notification_test() {
  let notification = jsonrpc.Notification("notifications/initialized", None)

  codec.encode_notification(notification)
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
  )
}

pub fn decode_response_parses_call_tool_result_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("req-1"),
      "tools/call",
      Some(
        actions.RequestCallTool(actions.CallToolRequestParams(
          "weather",
          None,
          None,
          None,
        )),
      ),
    )

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Sunny\"}],\"isError\":false}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("req-1"),
      actions.ResultCallTool(actions.CallToolResult(
        content: [actions.TextBlock(actions.TextContent("Sunny", None, None))],
        structured_content: None,
        is_error: Some(False),
        meta: None,
      )),
    )),
  )
}

pub fn decode_response_parses_error_response_test() {
  let request = jsonrpc.Request(jsonrpc.StringId("req-1"), "ping", None)

  codec.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"error\":{\"code\":-32601,\"message\":\"missing\"}}",
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ErrorResponse(
      Some(jsonrpc.StringId("req-1")),
      jsonrpc.RpcError(code: -32_601, message: "missing", data: None),
    )),
  )
}
