import gleam/dict
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{VInt, VObject, VString}
import gleam_mcp/wire
import gleeunit/should

pub fn main() {
  results_require_a_known_discriminator_in_modern_mode_test()
  modern_continuations_require_input_or_opaque_state_test()
  result_encoding_adds_identity_and_conservative_cache_defaults_test()
  explicit_cache_hints_survive_encoding_and_decoding_test()
  modern_requests_require_capabilities_even_for_unknown_methods_test()
  removed_methods_are_rejected_before_sending_test()
  malformed_modern_claims_never_select_legacy_mode_test()
  modern_metadata_validates_known_capabilities_and_identity_test()
  negative_outgoing_cache_ttl_is_clamped_test()
  modern_uncorrelated_errors_omit_the_id_test()
  task_results_are_restricted_to_negotiated_tool_calls_test()
}

pub fn results_require_a_known_discriminator_in_modern_mode_test() {
  let request = tool_call()
  wire.decode_response(
    response("{\"content\":[]}"),
    request,
    jsonrpc.legacy_protocol_version,
  )
  |> should.be_ok
  wire.decode_response(
    response("{\"content\":[]}"),
    request,
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  wire.decode_response(
    response("{\"resultType\":\"other\",\"content\":[]}"),
    request,
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  wire.decode_response(
    response("{\"resultType\":\"complete\"}"),
    request,
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  wire.decode_response(
    response("{\"resultType\":\"complete\",\"content\":[]}"),
    request,
    jsonrpc.latest_protocol_version,
  )
  |> should.be_ok
}

pub fn modern_continuations_require_input_or_opaque_state_test() {
  wire.decode_response(
    response("{\"resultType\":\"input_required\"}"),
    tool_call(),
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  let response =
    wire.decode_response(
      response(
        "{\"resultType\":\"input_required\",\"requestState\":\"opaque\"}",
      ),
      tool_call(),
      jsonrpc.latest_protocol_version,
    )
    |> should.be_ok
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInputRequired(value)) =
    response
  should.equal(value.request_state, Some("opaque"))
  should.equal(value.input_requests, None)
}

pub fn result_encoding_adds_identity_and_conservative_cache_defaults_test() {
  let result =
    actions.ClientResultListTools(actions.ListToolsResult(
      [],
      actions.Page(None),
      None,
    ))
  let body =
    wire.encode_response(
      jsonrpc.ResultResponse(jsonrpc.IntId(1), result),
      jsonrpc.latest_protocol_version,
      implementation(),
    )
  let fields = wire.parse_object(body) |> should.be_ok
  let assert Ok(VObject(fields)) = dict.get(fields, "result")
  let fields = dict.from_list(fields)
  should.equal(dict.get(fields, "resultType"), Ok(VString("complete")))
  should.equal(dict.get(fields, "ttlMs"), Ok(VInt(0)))
  should.equal(dict.get(fields, "cacheScope"), Ok(VString("private")))
  let assert Ok(VObject(meta)) = dict.get(fields, "_meta")
  dict.from_list(meta)
  |> dict.get("io.modelcontextprotocol/serverInfo")
  |> should.be_ok
}

pub fn explicit_cache_hints_survive_encoding_and_decoding_test() {
  let result =
    actions.ClientResultWithCache(
      actions.ClientResultListTools(actions.ListToolsResult(
        [],
        actions.Page(None),
        None,
      )),
      actions.CacheHint(5000, actions.Public),
    )
  let body =
    wire.encode_response(
      jsonrpc.ResultResponse(jsonrpc.IntId(1), result),
      jsonrpc.latest_protocol_version,
      implementation(),
    )
  should.equal(wire.cache_hint(body), actions.CacheHint(5000, actions.Public))
  should.equal(
    wire.cache_hint(response("{\"ttlMs\":-1,\"cacheScope\":\"invalid\"}")),
    actions.CacheHint(0, actions.Private),
  )
}

pub fn modern_requests_require_capabilities_even_for_unknown_methods_test() {
  wire.decode_message_with_error(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown\",\"params\":{}}",
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
  wire.decode_message_with_error(body, jsonrpc.latest_protocol_version)
  |> should.be_ok
}

pub fn removed_methods_are_rejected_before_sending_test() {
  let request =
    jsonrpc.Request(
      jsonrpc.IntId(1),
      "ping",
      Some(actions.ClientRequestPing(None)),
    )
  wire.validate_request(request, jsonrpc.latest_protocol_version)
  |> should.be_error
  wire.validate_request(request, jsonrpc.legacy_protocol_version)
  |> should.be_ok
}

pub fn malformed_modern_claims_never_select_legacy_mode_test() {
  wire.claims_modern(
    "{\"method\":\"initialize\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":null}}}",
  )
  |> should.be_true
  wire.claims_modern("{\"method\":\"server/discover\"}")
  |> should.be_true
  wire.claims_modern("{\"method\":\"initialize\",\"params\":{}}")
  |> should.be_false
}

pub fn modern_metadata_validates_known_capabilities_and_identity_test() {
  let version = #(
    "io.modelcontextprotocol/protocolVersion",
    VString(jsonrpc.latest_protocol_version),
  )
  let base = [
    version,
    #("io.modelcontextprotocol/clientCapabilities", VObject([])),
  ]
  metadata(base) |> wire.validate_request_metadata |> should.be_ok
  metadata([
    #(
      "io.modelcontextprotocol/clientCapabilities",
      VObject([#("sampling", VObject([#("tools", VString("bad"))]))]),
    ),
    version,
  ])
  |> wire.validate_request_metadata
  |> should.be_error
  metadata([
    #(
      "io.modelcontextprotocol/clientCapabilities",
      VObject([#("extensions", VObject([#("invalid", VObject([]))]))]),
    ),
    version,
  ])
  |> wire.validate_request_metadata
  |> should.be_error
  metadata([#("io.modelcontextprotocol/clientInfo", VObject([])), ..base])
  |> wire.validate_request_metadata
  |> should.be_error
}

pub fn negative_outgoing_cache_ttl_is_clamped_test() {
  let result =
    actions.ClientResultWithCache(
      actions.ClientResultListTools(actions.ListToolsResult(
        [],
        actions.Page(None),
        None,
      )),
      actions.CacheHint(-10, actions.Public),
    )
  wire.encode_response(
    jsonrpc.ResultResponse(jsonrpc.IntId(1), result),
    jsonrpc.latest_protocol_version,
    implementation(),
  )
  |> wire.cache_hint
  |> should.equal(actions.CacheHint(0, actions.Public))
}

pub fn modern_uncorrelated_errors_omit_the_id_test() {
  let body =
    wire.encode_response(
      jsonrpc.ErrorResponse(None, jsonrpc.invalid_params_error("bad")),
      jsonrpc.latest_protocol_version,
      implementation(),
    )
  body
  |> wire.parse_object
  |> should.be_ok
  |> dict.has_key("id")
  |> should.be_false
  let decoded =
    wire.decode_response(body, tool_call(), jsonrpc.latest_protocol_version)
    |> should.be_ok
  let assert jsonrpc.ErrorResponse(None, _) = decoded
  wire.decode_response(
    "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32602,\"message\":\"bad\"}}",
    tool_call(),
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
}

pub fn task_results_are_restricted_to_negotiated_tool_calls_test() {
  let meta =
    metadata([
      #(
        "io.modelcontextprotocol/clientCapabilities",
        VObject([
          #(
            "extensions",
            VObject([#("io.modelcontextprotocol/tasks", VObject([]))]),
          ),
        ]),
      ),
    ])
  let assert jsonrpc.Request(id, _, action) = tool_call()
  let assert Some(action) = action
  let request =
    jsonrpc.Request(
      id,
      "resources/read",
      Some(actions.with_request_meta(action, meta)),
    )
  wire.decode_response(
    response("{\"resultType\":\"task\",\"taskId\":\"one\"}"),
    request,
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
  wire.decode_response(
    response("{\"resultType\":\"task\",\"taskId\":\"one\"}"),
    tool_call(),
    jsonrpc.latest_protocol_version,
  )
  |> should.be_error
}

fn metadata(fields) {
  Some(actions.RequestMeta(None, Some(actions.Meta(dict.from_list(fields)))))
}

fn tool_call() {
  jsonrpc.Request(
    jsonrpc.IntId(1),
    "tools/call",
    Some(
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "echo",
        None,
        None,
        None,
      )),
    ),
  )
}

fn response(result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" <> result <> "}"
}

fn implementation() {
  actions.Implementation("test", "1", None, None, None, [])
}
