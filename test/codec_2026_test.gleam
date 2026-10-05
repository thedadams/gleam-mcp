import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc.{VArray, VBool, VInt, VNull, VObject, VString}
import gleam_mcp/server/codec as server_codec
import gleeunit/should

/// Run the modern codec regressions without starting transport fixtures.
pub fn main() {
  discovery_preserves_extension_capabilities_and_metadata_test()
  discovery_requires_supported_versions_and_capabilities_test()
  continuation_roundtrip_preserves_bare_input_responses_test()
  continuation_replaces_prior_state_and_input_test()
  input_required_accepts_state_only_and_preserves_input_requests_test()
  malformed_input_required_never_falls_back_to_complete_tool_result_test()
  subscriptions_filter_roundtrip_and_required_filter_test()
  subscription_acknowledgment_preserves_filter_and_subscription_id_test()
  modern_url_elicitation_omits_legacy_identifier_test()
  structured_tool_output_preserves_all_json_types_and_explicit_null_test()
  task_update_uses_input_responses_and_preserves_request_metadata_test()
  modern_task_notification_preserves_detailed_task_and_metadata_test()
  cache_wrapper_emits_explicit_scope_and_ttl_without_losing_result_test()
  tool_schema_preserves_composition_and_non_object_output_keywords_test()
  tool_descriptor_rejects_invalid_schema_roots_test()
}

pub fn discovery_preserves_extension_capabilities_and_metadata_test() {
  let request = request("server/discover", actions.ClientRequestDiscover(None))
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":\"modern\",\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"],\"capabilities\":{\"tools\":{},\"extensions\":{\"org.example/extra\":{\"enabled\":true}}},\"instructions\":\"Use the tools\",\"_meta\":{\"org.example/trace\":\"trace-1\"}}}"
  let assert jsonrpc.ResultResponse(_, actions.ClientResultDiscover(result)) =
    client_codec.decode_response(body, request) |> should.be_ok
  result.supported_versions
  |> should.equal(jsonrpc.supported_protocol_versions)
  dict.get(result.capabilities, "extensions")
  |> should.equal(
    Ok(VObject([#("org.example/extra", VObject([#("enabled", VBool(True))]))])),
  )
  result.instructions |> should.equal(Some("Use the tools"))
  result.meta
  |> should.equal(
    Some(
      actions.Meta(dict.from_list([#("org.example/trace", VString("trace-1"))])),
    ),
  )
}

pub fn discovery_requires_supported_versions_and_capabilities_test() {
  let request = request("server/discover", actions.ClientRequestDiscover(None))
  [
    "{\"capabilities\":{}}",
    "{\"supportedVersions\":[\"2026-07-28\"]}",
    "{\"supportedVersions\":[42],\"capabilities\":{}}",
  ]
  |> list.each(fn(result) {
    client_codec.decode_response(envelope(result), request) |> should.be_error
  })
}

pub fn continuation_roundtrip_preserves_bare_input_responses_test() {
  let responses =
    dict.from_list([
      #(
        "consent",
        VObject([
          #("action", VString("accept")),
          #("content", VObject([#("allowed", VBool(True))])),
        ]),
      ),
      #("roots", VObject([#("roots", VArray([]))])),
    ])
  let meta =
    actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #(
              "io.modelcontextprotocol/protocolVersion",
              VString(jsonrpc.latest_protocol_version),
            ),
            #("io.modelcontextprotocol/clientCapabilities", VObject([])),
          ]),
        ),
      ),
    )
  let action =
    actions.ClientRequestWithInput(
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "confirm",
        None,
        None,
        Some(meta),
      )),
      Some("opaque-state"),
      Some(responses),
    )
  let request = request("tools/call", action)
  let encoded = client_codec.encode_request(request)
  server_codec.decode_message(encoded)
  |> should.equal(Ok(server_codec.ClientActionRequest(request)))
  actions.request_meta(action) |> should.equal(Some(meta))
  actions.input_responses(action) |> should.equal(Some(responses))
}

pub fn continuation_replaces_prior_state_and_input_test() {
  let original =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "confirm",
      None,
      None,
      None,
    ))
  let old =
    actions.ClientRequestWithInput(
      original,
      Some("old-state"),
      Some(dict.from_list([#("old", VNull)])),
    )
  let latest =
    actions.ClientRequestWithInput(
      old,
      None,
      Some(dict.from_list([#("new", VBool(True))])),
    )
  let encoded = client_codec.encode_request(request("tools/call", latest))
  let assert VObject(fields) =
    json.parse(encoded, client_codec.value_decoder()) |> should.be_ok
  let assert Ok(VObject(params)) = list.key_find(fields, "params")
  list.key_find(params, "requestState") |> should.be_error
  list.key_find(params, "inputResponses")
  |> should.equal(Ok(VObject([#("new", VBool(True))])))
}

pub fn input_required_accepts_state_only_and_preserves_input_requests_test() {
  let request =
    request(
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "confirm",
        None,
        None,
        None,
      )),
    )
  client_codec.decode_response(
    envelope("{\"resultType\":\"input_required\",\"requestState\":\"resume\"}"),
    request,
  )
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("modern"),
      actions.ClientResultInputRequired(actions.InputRequiredResult(
        None,
        Some("resume"),
        None,
      )),
    )),
  )
  let inputs =
    dict.from_list([
      #(
        "consent",
        VObject([
          #("method", VString("elicitation/create")),
          #(
            "params",
            VObject([
              #("mode", VString("url")),
              #("message", VString("Continue")),
              #("url", VString("https://example.com/consent")),
            ]),
          ),
        ]),
      ),
    ])
    |> dict.map_values(fn(_, value) { decoded_value(value) })
  let result =
    actions.ClientResultInputRequired(actions.InputRequiredResult(
      Some(inputs),
      None,
      None,
    ))
  server_codec.encode_response(jsonrpc.ResultResponse(
    jsonrpc.StringId("modern"),
    result,
  ))
  |> client_codec.decode_response(request)
  |> should.equal(
    Ok(jsonrpc.ResultResponse(jsonrpc.StringId("modern"), result)),
  )
}

pub fn malformed_input_required_never_falls_back_to_complete_tool_result_test() {
  let request =
    request(
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "confirm",
        None,
        None,
        None,
      )),
    )
  [
    "{\"resultType\":\"input_required\",\"content\":[]}",
    "{\"resultType\":\"input_required\",\"requestState\":42,\"content\":[]}",
    "{\"resultType\":\"input_required\",\"inputRequests\":[],\"content\":[]}",
  ]
  |> list.each(fn(result) {
    client_codec.decode_response(envelope(result), request) |> should.be_error
  })
}

pub fn subscriptions_filter_roundtrip_and_required_filter_test() {
  let filter =
    VObject([
      #("toolsListChanged", VBool(True)),
      #("resourceSubscriptions", VArray([VString("file:///tmp/readme")])),
    ])
    |> decoded_value
  let request =
    request(
      "subscriptions/listen",
      actions.ClientRequestSubscriptionsListen(
        actions.SubscriptionsListenParams(Some(filter), None),
      ),
    )
  request
  |> client_codec.encode_request
  |> server_codec.decode_message
  |> should.equal(Ok(server_codec.ClientActionRequest(request)))
  [
    "{\"jsonrpc\":\"2.0\",\"id\":\"modern\",\"method\":\"subscriptions/listen\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"modern\",\"method\":\"subscriptions/listen\",\"params\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":\"modern\",\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":\"yes\"}}}",
  ]
  |> list.each(fn(body) { server_codec.decode_message(body) |> should.be_error })
}

pub fn subscription_acknowledgment_preserves_filter_and_subscription_id_test() {
  let notification =
    jsonrpc.Notification(
      "notifications/subscriptions/acknowledged",
      Some(actions.NotifySubscriptionsAcknowledgedWithFilter(
        Some(VObject([#("toolsListChanged", VBool(True))])),
        Some(
          actions.NotificationMeta(
            Some(
              actions.Meta(
                dict.from_list([
                  #(
                    "io.modelcontextprotocol/subscriptionId",
                    VString("stream-1"),
                  ),
                ]),
              ),
            ),
          ),
        ),
      )),
    )
  notification
  |> client_codec.encode_notification
  |> client_codec.decode_server_message
  |> should.equal(Ok(client_codec.ActionNotification(notification)))
  client_codec.decode_server_message(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{}}",
  )
  |> should.be_error
}

pub fn modern_url_elicitation_omits_legacy_identifier_test() {
  let params =
    actions.ElicitRequestUrlParamsWithoutId(
      "Open consent",
      "https://example.com/consent",
      None,
      None,
    )
  let request =
    jsonrpc.Request(
      jsonrpc.StringId("input"),
      "elicitation/create",
      Some(actions.ServerRequestElicit(actions.ElicitRequestUrl(params))),
    )
  let encoded = client_codec.encode_server_request(request)
  let assert VObject(fields) =
    json.parse(encoded, client_codec.value_decoder()) |> should.be_ok
  let assert Ok(VObject(params)) = list.key_find(fields, "params")
  list.key_find(params, "elicitationId") |> should.be_error
  client_codec.decode_server_message(encoded)
  |> should.equal(Ok(client_codec.ServerActionRequest(request)))
}

pub fn structured_tool_output_preserves_all_json_types_and_explicit_null_test() {
  let request =
    request(
      "tools/call",
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "any-output",
        None,
        None,
        None,
      )),
    )
  [
    VNull,
    VString("text"),
    VInt(42),
    VBool(False),
    VArray([VInt(1)]),
    VObject([#("ok", VBool(True))]),
  ]
  |> list.each(fn(value) {
    let response =
      jsonrpc.ResultResponse(
        jsonrpc.StringId("modern"),
        actions.ClientResultCallTool(actions.CallToolResult(
          [],
          Some(value),
          None,
          None,
        )),
      )
    response
    |> server_codec.encode_response
    |> client_codec.decode_response(request)
    |> should.equal(Ok(response))
  })
  client_codec.decode_response(envelope("{\"content\":[]}"), request)
  |> should.equal(
    Ok(jsonrpc.ResultResponse(
      jsonrpc.StringId("modern"),
      actions.ClientResultCallTool(actions.CallToolResult([], None, None, None)),
    )),
  )
}

pub fn task_update_uses_input_responses_and_preserves_request_metadata_test() {
  let meta =
    actions.RequestMeta(
      None,
      Some(
        actions.Meta(
          dict.from_list([
            #(
              "io.modelcontextprotocol/protocolVersion",
              VString(jsonrpc.latest_protocol_version),
            ),
          ]),
        ),
      ),
    )
  let input = VObject([#("form", VObject([#("action", VString("accept"))]))])
  let request =
    request(
      "tasks/update",
      actions.ClientRequestUpdateTask(actions.TaskUpdateParams(
        "task-1",
        Some(input),
        Some(meta),
      )),
    )
  request
  |> client_codec.encode_request
  |> server_codec.decode_message
  |> should.equal(Ok(server_codec.ClientActionRequest(request)))
}

pub fn modern_task_notification_preserves_detailed_task_and_metadata_test() {
  let value =
    VObject([
      #(
        "task",
        VObject([
          #("taskId", VString("task-1")),
          #("status", VString("input_required")),
        ]),
      ),
      #("inputRequests", VObject([])),
    ])
    |> decoded_value
  let meta =
    Some(
      actions.NotificationMeta(
        Some(
          actions.Meta(
            dict.from_list([
              #("io.modelcontextprotocol/subscriptionId", VString("stream-1")),
            ]),
          ),
        ),
      ),
    )
  let notification =
    jsonrpc.Notification(
      "notifications/tasks",
      Some(actions.NotifyTaskModern(value, meta)),
    )
  notification
  |> client_codec.encode_notification
  |> client_codec.decode_server_message
  |> should.equal(Ok(client_codec.ActionNotification(notification)))
}

pub fn cache_wrapper_emits_explicit_scope_and_ttl_without_losing_result_test() {
  let response =
    jsonrpc.ResultResponse(
      jsonrpc.StringId("modern"),
      actions.ClientResultWithCache(
        actions.ClientResultListTools(actions.ListToolsResult(
          [],
          actions.Page(None),
          None,
        )),
        actions.CacheHint(2500, actions.Public),
      ),
    )
  let assert VObject(fields) =
    response
    |> server_codec.encode_response
    |> json.parse(client_codec.value_decoder())
    |> should.be_ok
  let assert Ok(VObject(result)) = list.key_find(fields, "result")
  list.key_find(result, "ttlMs") |> should.equal(Ok(VInt(2500)))
  list.key_find(result, "cacheScope") |> should.equal(Ok(VString("public")))
  list.key_find(result, "tools") |> should.equal(Ok(VArray([])))
}

pub fn tool_schema_preserves_composition_and_non_object_output_keywords_test() {
  let request =
    request(
      "tools/list",
      actions.ClientRequestListTools(actions.PaginatedRequestParams(None, None)),
    )
  let body =
    envelope(
      "{\"tools\":[{\"name\":\"composite-input\",\"inputSchema\":{\"type\":\"object\",\"oneOf\":[{\"required\":[\"x\"]},{\"required\":[\"y\"]}]},\"outputSchema\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}}]}",
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListTools(result)) =
    client_codec.decode_response(body, request) |> should.be_ok
  let assert [tool] = result.tools
  tool.input_schema
  |> should.equal(
    decoded_value(
      VObject([
        #("type", VString("object")),
        #(
          "oneOf",
          VArray([
            VObject([#("required", VArray([VString("x")]))]),
            VObject([#("required", VArray([VString("y")]))]),
          ]),
        ),
      ]),
    ),
  )
  tool.output_schema
  |> should.equal(
    Some(
      decoded_value(
        VObject([
          #("type", VString("array")),
          #("items", VObject([#("type", VString("number"))])),
        ]),
      ),
    ),
  )
}

pub fn tool_descriptor_rejects_invalid_schema_roots_test() {
  let request =
    request(
      "tools/list",
      actions.ClientRequestListTools(actions.PaginatedRequestParams(None, None)),
    )
  [
    "{\"tools\":[{\"name\":\"bad\",\"inputSchema\":{\"type\":\"array\"}}]}",
    "{\"tools\":[{\"name\":\"bad\",\"inputSchema\":true}]}",
    "{\"tools\":[{\"name\":\"bad\",\"inputSchema\":{}}]}",
    "{\"tools\":[{\"name\":\"bad\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":false}]}",
  ]
  |> list.each(fn(result) {
    client_codec.decode_response(envelope(result), request) |> should.be_error
  })
}

fn request(
  method: String,
  action: actions.ClientActionRequest,
) -> jsonrpc.Request(actions.ClientActionRequest) {
  jsonrpc.Request(jsonrpc.StringId("modern"), method, Some(action))
}

fn envelope(result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\"modern\",\"result\":" <> result <> "}"
}

fn decoded_value(value: jsonrpc.Value) -> jsonrpc.Value {
  value
  |> codec_common.encode_value
  |> json.to_string
  |> json.parse(client_codec.value_decoder())
  |> should.be_ok
}
