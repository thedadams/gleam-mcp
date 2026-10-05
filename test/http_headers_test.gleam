import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/http_headers
import gleam_mcp/jsonrpc.{VArray, VBool, VFloat, VInt, VNull, VObject, VString}
import gleeunit/should

pub fn annotated_properties_round_trip_http_values_test() {
  let schema =
    schema([
      #("account", schema([#("name", annotation("Account", "string"))])),
      #("limit", annotation("Limit", "integer")),
      #("active", annotation("Active", "boolean")),
      #("optional", annotation("Optional", "string")),
    ])
  let arguments =
    VObject([
      #("account", VObject([#("name", VString(" Montréal\t"))])),
      #("limit", VFloat(42.0)),
      #("active", VBool(True)),
      #("optional", VNull),
    ])
  let headers = http_headers.parameters(schema, arguments) |> should.be_ok
  should.equal(list.length(headers), 3)
  should.equal(list.key_find(headers, "mcp-param-limit"), Ok("42"))
  http_headers.validate_parameters(headers, schema, arguments) |> should.be_ok
  http_headers.validate_parameters(
    [
      #("Mcp-Param-Limit", "42.0"),
      ..list.filter(headers, fn(header) { header.0 != "mcp-param-limit" })
    ],
    schema,
    arguments,
  )
  |> should.be_ok
}

pub fn header_encoding_handles_unicode_controls_and_literal_sentinels_test() {
  list.each(
    ["plain ASCII", "a\tb", "", "é", "\r\n", " padded ", "=?base64?YWJj?="],
    fn(value) {
      value
      |> http_headers.encode_value
      |> http_headers.decode_value
      |> should.equal(Ok(value))
    },
  )
  should.equal(http_headers.encode_value("plain ASCII"), "plain ASCII")
  list.each(["=?base64?bad!?=", "=?base64?/w==?=", "raw\r\n", "é"], fn(value) {
    http_headers.decode_value(value) |> should.be_error
  })
  let encoded =
    "=?base64?" <> bit_array.base64_encode(<<"é":utf8>>, True) <> "?="
  should.equal(http_headers.encode_value("é"), encoded)
}

pub fn header_decoding_trims_only_http_optional_whitespace_test() {
  http_headers.decode_value(" \tAlice\t ") |> should.equal(Ok("Alice"))
  http_headers.decode_value(" \t=?base64?IHBhZGRlZCA=?=\t ")
  |> should.equal(Ok(" padded "))
  list.each(
    ["\rAlice", "Alice\n", "\u{000b}Alice", "\u{00a0}Alice", "Alice\u{2003}"],
    fn(value) { http_headers.decode_value(value) |> should.be_error },
  )
  http_headers.validate_standard(
    [
      #("MCP-PROTOCOL-VERSION", " \t2026-07-28\t "),
      #("MCP-METHOD", "\t tools/call \t"),
      #("MCP-NAME", "  echo\t"),
    ],
    "2026-07-28",
    "tools/call",
    Some("echo"),
  )
  |> should.be_ok
  http_headers.validate_parameters(
    [#("Mcp-Param-Value", " \tAlice\t ")],
    schema([#("value", annotation("Value", "string"))]),
    VObject([#("value", VString("Alice"))]),
  )
  |> should.be_ok
}

pub fn header_sentinels_require_padded_base64_alphabet_test() {
  http_headers.decode_value("=?base64?SGVsbG8=?=") |> should.equal(Ok("Hello"))
  list.each(
    [
      "=?base64?SGVsbG8?=",
      "=?base64?SGVs!!!bG8=?=",
      "=?base64?SGVs bG8=?=",
      "=?base64?SGVsbG8===?=",
      "=?base64?SGVsbG9=?=",
    ],
    fn(value) { http_headers.decode_value(value) |> should.be_error },
  )
  // Only a complete sentinel is interpreted as encoded data.
  http_headers.decode_value("SGVsbG8=") |> should.equal(Ok("SGVsbG8="))
  http_headers.decode_value("=?base64?SGVsbG8=")
  |> should.equal(Ok("=?base64?SGVsbG8="))
}

pub fn invalid_header_annotations_are_rejected_test() {
  list.each(
    [
      annotation("Root", "string"),
      schema([#("name", annotation("", "string"))]),
      schema([#("name", annotation("bad name", "string"))]),
      schema([#("name", annotation("Name", "number"))]),
      schema([
        #("a", annotation("Same", "string")),
        #("b", annotation("same", "string")),
      ]),
      VObject([
        #("allOf", VArray([schema([#("name", annotation("Name", "string"))])])),
      ]),
      schema([#("list", VObject([#("items", annotation("Item", "string"))]))]),
      VObject([
        #(
          "$defs",
          VObject([
            #("named", schema([#("name", annotation("Name", "string"))])),
          ]),
        ),
      ]),
    ],
    fn(schema) { http_headers.definitions(schema) |> should.be_error },
  )
  // Literal data in annotations is not itself a JSON Schema location.
  http_headers.definitions(
    VObject([
      #("type", VString("object")),
      #("default", annotation("ignored", "number")),
    ]),
  )
  |> should.equal(Ok([]))
}

pub fn parameter_headers_match_body_and_reject_duplicates_test() {
  let schema = schema([#("name", annotation("Name", "string"))])
  let arguments = VObject([#("name", VString("Alice"))])
  list.each(
    [
      [],
      [#("mcp-param-name", "Bob")],
      [#("mcp-param-name", "Alice"), #("Mcp-Param-Name", "Alice")],
    ],
    fn(headers) {
      http_headers.validate_parameters(headers, schema, arguments)
      |> should.be_error
    },
  )
  http_headers.validate_parameters(
    [#("mcp-param-other", "ignored"), #("MCP-PARAM-NAME", "Alice")],
    schema,
    arguments,
  )
  |> should.be_ok
  http_headers.validate_parameters(
    [#("mcp-param-name", "Alice")],
    schema,
    VObject([]),
  )
  |> should.be_error
}

pub fn mirrored_standard_headers_are_required_and_case_sensitive_test() {
  let headers = http_headers.standard("2026-07-28", "tools/call", Some("écho"))
  http_headers.validate_standard(
    headers,
    "2026-07-28",
    "tools/call",
    Some("écho"),
  )
  |> should.be_ok
  http_headers.validate_standard(
    headers,
    "2026-07-28",
    "Tools/Call",
    Some("écho"),
  )
  |> should.be_error
  http_headers.validate_standard([], "2026-07-28", "tools/list", None)
  |> should.be_error
  http_headers.validate_standard(
    [#("MCP-PROTOCOL-VERSION", "2026-07-28"), #("MCP-METHOD", "tools/list")],
    "2026-07-28",
    "tools/list",
    None,
  )
  |> should.be_ok
}

pub fn mirrored_integers_observe_the_json_safe_range_test() {
  let schema = schema([#("n", annotation("N", "integer"))])
  http_headers.parameters(
    schema,
    VObject([#("n", VInt(9_007_199_254_740_991))]),
  )
  |> should.be_ok
  list.each([VInt(9_007_199_254_740_992), VFloat(1.5), VBool(True)], fn(value) {
    http_headers.parameters(schema, VObject([#("n", value)])) |> should.be_error
  })
}

fn schema(properties) {
  VObject([#("type", VString("object")), #("properties", VObject(properties))])
}

fn annotation(name, kind) {
  VObject([#("type", VString(kind)), #("x-mcp-header", VString(name))])
}
