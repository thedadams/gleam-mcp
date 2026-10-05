import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VNull, VObject, VString,
}
import gleam_mcp/server/codec as server_codec
import gleam_mcp/wire
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn legacy_encoding_preserves_order_duplicates_and_explicit_null_test() {
  server_codec.encode_response(jsonrpc.ResultResponse(
    jsonrpc.StringId("legacy"),
    actions.ClientResultCallTool(actions.CallToolResult(
      [],
      Some(duplicate_value()),
      Some(False),
      None,
    )),
  ))
  |> should.equal(
    "{\"jsonrpc\":\"2.0\",\"id\":\"legacy\",\"result\":{\"content\":[],\"structuredContent\":{\"duplicate\":1,\"duplicate\":2,\"nullable\":null,\"numeric\":1.0},\"isError\":false}}",
  )
  client_codec.encode_request(jsonrpc.Notification("ping", None))
  |> should.equal("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}")
}

pub fn continuation_builder_matches_former_roundtrip_and_outer_precedence_test() {
  let meta =
    actions.RequestMeta(
      Some(jsonrpc.IntId(7)),
      Some(
        actions.Meta(
          dict.from_list([
            #("progressToken", VInt(9)),
            #("extension", VArray([duplicate_value(), VNull])),
          ]),
        ),
      ),
    )
  let inner =
    actions.ClientRequestWithInput(
      actions.ClientRequestCallTool(actions.CallToolRequestParams(
        "confirm",
        Some(dict.from_list([#("argument", duplicate_value())])),
        None,
        Some(meta),
      )),
      Some("obsolete"),
      Some(dict.from_list([#("obsolete", VNull)])),
    )
  let responses = dict.from_list([#("answer", duplicate_value())])
  let request =
    jsonrpc.Request(jsonrpc.StringId("request"), "tools/call", Some(inner))
  let fields =
    client_codec.encode_request(request)
    |> json.parse(client_codec.value_decoder())
    |> should.be_ok
    |> object_field("params")
    |> object_fields
    |> list.filter(fn(field) {
      field.0 != "requestState" && field.0 != "inputResponses"
    })
    |> list.map(fn(field) { #(field.0, codec_common.encode_value(field.1)) })
    |> list.append([
      #(
        "inputResponses",
        codec_common.encode_value_object(dict.to_list(responses)),
      ),
    ])
  let expected =
    request_envelope("tools/call", json.object(fields)) |> json.to_string
  client_codec.encode_request(jsonrpc.Request(
    jsonrpc.StringId("request"),
    "tools/call",
    Some(actions.ClientRequestWithInput(inner, None, Some(responses))),
  ))
  |> should.equal(expected)
}

pub fn cache_builder_matches_former_roundtrip_and_outer_hint_wins_test() {
  let inner =
    actions.ClientResultWithCache(
      actions.ClientResultCallTool(actions.CallToolResult(
        [],
        Some(duplicate_value()),
        None,
        Some(
          actions.Meta(
            dict.from_list([
              #("extension", VArray([duplicate_value(), VNull])),
            ]),
          ),
        ),
      )),
      actions.CacheHint(10, actions.Private),
    )
  let fields =
    server_codec.encode_response(jsonrpc.ResultResponse(jsonrpc.IntId(1), inner))
    |> json.parse(client_codec.value_decoder())
    |> should.be_ok
    |> object_field("result")
    |> object_fields
    |> list.filter(fn(field) { field.0 != "ttlMs" && field.0 != "cacheScope" })
    |> list.map(fn(field) { #(field.0, codec_common.encode_value(field.1)) })
    |> list.append([
      #("ttlMs", json.int(200)),
      #("cacheScope", json.string("public")),
    ])
  let expected =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(1)),
      #("result", json.object(fields)),
    ])
    |> json.to_string
  server_codec.encode_response(jsonrpc.ResultResponse(
    jsonrpc.IntId(1),
    actions.ClientResultWithCache(inner, actions.CacheHint(200, actions.Public)),
  ))
  |> should.equal(expected)
}

pub fn task_notification_builder_replaces_metadata_after_normalizing_test() {
  let raw =
    VObject([
      #("extension", VArray([duplicate_value(), VNull])),
      #("_meta", VObject([#("obsolete", VBool(True))])),
      #("taskId", VString("task")),
    ])
  let fields =
    raw
    |> codec_common.encode_value
    |> json.to_string
    |> json.parse(client_codec.value_decoder())
    |> should.be_ok
    |> object_fields
    |> list.filter(fn(field) { field.0 != "_meta" })
    |> list.map(fn(field) { #(field.0, codec_common.encode_value(field.1)) })
    |> list.append([#("_meta", json.object([]))])
  let expected =
    request_envelope("notifications/tasks", json.object(fields))
    |> json.to_string
  client_codec.encode_notification(jsonrpc.Request(
    jsonrpc.StringId("request"),
    "notifications/tasks",
    Some(actions.NotifyTaskModern(raw, Some(actions.NotificationMeta(None)))),
  ))
  |> should.equal(expected)
}

pub fn direct_value_decoding_preserves_json_decoder_results_and_errors_test() {
  [
    VObject([
      #("name", VString("previous")),
      #("name", VString("client")),
      #("version", VString("1")),
      #("title", VNull),
      #(
        "icons",
        VArray([
          VObject([
            #("src", VString("https://example.com/icon.svg")),
            #("theme", VString("dark")),
            #("sizes", VArray([VString("any")])),
          ]),
        ]),
      ),
    ]),
    VObject([#("name", VNull), #("version", VString("1"))]),
    VObject([
      #("name", VString("client")),
      #("version", VString("1")),
      #(
        "icons",
        VArray([
          VObject([
            #("src", VString("icon.svg")),
            #("theme", VString("invalid")),
          ]),
        ]),
      ),
    ]),
    VNull,
  ]
  |> list.each(fn(value) {
    let expected =
      value
      |> codec_common.encode_value
      |> json.to_string
      |> json.parse(codec_decode.implementation_decoder())
      |> result.map_error(codec_decode.json_error_message)
    client_codec.decode_implementation(value) |> should.equal(expected)
  })
}

pub fn task_id_and_metadata_decode_identically_in_both_directions_test() {
  [
    "{\"taskId\":\"task\",\"_meta\":{\"progressToken\":7,\"extension\":{\"nullable\":null,\"numeric\":1.5}}}",
    "{\"taskId\":\"task\",\"_meta\":{}}",
    "{\"taskId\":\"task\",\"_meta\":null}",
    "{\"taskId\":\"task\",\"_meta\":{\"progressToken\":null}}",
  ]
  |> list.each(fn(params) {
    let body =
      "{\"jsonrpc\":\"2.0\",\"id\":\"request\",\"method\":\"tasks/get\",\"params\":"
      <> params
      <> "}"
    let client_params = case client_codec.decode_server_message(body) {
      Ok(client_codec.ServerActionRequest(jsonrpc.Request(
        _,
        _,
        Some(actions.ServerRequestGetTask(value)),
      ))) -> Ok(value)
      Error(error) -> Error(error)
      _ -> panic as "Expected a server task request"
    }
    let server_params = case server_codec.decode_message(body) {
      Ok(server_codec.ClientActionRequest(jsonrpc.Request(
        _,
        _,
        Some(actions.ClientRequestGetTask(value)),
      ))) -> Ok(value)
      Error(error) -> Error(error)
      _ -> panic as "Expected a client task request"
    }
    client_params |> should.equal(server_params)
  })
}

pub fn server_diagnostics_preserve_method_decoder_error_messages_test() {
  [
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":[]}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/get\",\"params\":{\"taskId\":null}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"invalid\"}}",
  ]
  |> list.each(fn(body) {
    let expected = server_codec.decode_message(body) |> should.be_error
    let codec_common.MessageDecodeError(id, error) =
      server_codec.decode_message_with_error(body) |> should.be_error
    id |> should.equal(Some(jsonrpc.IntId(1)))
    error.code |> should.equal(-32_602)
    error.message |> should.equal(expected)
  })
}

pub fn wire_result_value_matches_legacy_parse_boundary_test() {
  let result =
    actions.ClientResultCallTool(actions.CallToolResult(
      [],
      Some(duplicate_value()),
      None,
      None,
    ))
  let expected =
    server_codec.encode_response(jsonrpc.ResultResponse(
      jsonrpc.IntId(0),
      result,
    ))
    |> json.parse(client_codec.value_decoder())
    |> should.be_ok
    |> object_field("result")
  wire.result_value(
    result,
    jsonrpc.legacy_protocol_version,
    actions.Implementation("server", "1", None, None, None, []),
  )
  |> should.equal(expected)
}

fn duplicate_value() -> Value {
  VObject([
    #("duplicate", VInt(1)),
    #("duplicate", VInt(2)),
    #("nullable", VNull),
    #("numeric", VFloat(1.0)),
  ])
}

fn object_fields(value: Value) -> List(#(String, Value)) {
  let assert VObject(fields) = value
  fields
}

fn object_field(value: Value, name: String) -> Value {
  value |> object_fields |> list.key_find(name) |> should.be_ok
}

fn request_envelope(method: String, params: json.Json) -> json.Json {
  json.object([
    #("id", json.string("request")),
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", params),
  ])
}
