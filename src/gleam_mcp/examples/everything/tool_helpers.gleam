import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc.{type Value, VArray, VFloat, VObject, VString}

pub fn descriptor(
  name: String,
  title: String,
  description: String,
  input_schema: Value,
  output_schema: Option(Value),
  annotations: actions.ToolAnnotations,
) -> actions.Tool {
  actions.Tool(
    name,
    Some(title),
    Some(description),
    input_schema,
    Some(actions.ToolExecution(Some(actions.TaskForbidden))),
    output_schema,
    Some(annotations),
    [],
    None,
  )
}

pub fn read_only_annotations() -> actions.ToolAnnotations {
  actions.ToolAnnotations(
    None,
    Some(True),
    Some(False),
    Some(True),
    Some(False),
  )
}

pub fn interactive_annotations(open_world: Bool) -> actions.ToolAnnotations {
  actions.ToolAnnotations(
    None,
    Some(False),
    Some(False),
    Some(False),
    Some(open_world),
  )
}

pub fn empty_schema() -> Value {
  object_schema([], [])
}

pub fn object_schema(
  properties: List(#(String, Value)),
  required: List(String),
) -> Value {
  let fields = [
    #("$schema", VString("http://json-schema.org/draft-07/schema#")),
    #("type", VString("object")),
    #("properties", VObject(properties)),
  ]
  VObject(case required {
    [] -> fields
    _ ->
      list.append(fields, [#("required", VArray(list.map(required, VString)))])
  })
}

pub fn string_schema(description: String) -> Value {
  VObject([#("type", VString("string")), #("description", VString(description))])
}

pub fn number_schema(description: String) -> Value {
  VObject([#("type", VString("number")), #("description", VString(description))])
}

pub fn with_property(schema: Value, key: String, value: Value) -> Value {
  let assert VObject(fields) = schema
  VObject(list.append(fields, [#(key, value)]))
}

pub fn text_result(text: String) -> actions.CallToolResult {
  content_result([actions.TextBlock(actions.TextContent(text, None, None))])
}

pub fn content_result(
  content: List(actions.ContentBlock),
) -> actions.CallToolResult {
  actions.CallToolResult(content, None, None, None)
}

pub fn tool_result(
  outcome: Result(actions.CallToolResult, jsonrpc.RpcError),
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) if error.code == -32_042 -> Error(error)
    Error(error) -> {
      let result = text_result(error.message)
      Ok(actions.CallToolResult(..result, is_error: Some(True)))
    }
  }
}

/// JSON escaping is provided by gleam_json; only presentation whitespace is
/// added here to match JSON.stringify(value, null, 2) in the reference example.
pub fn pretty_json(value: Value) -> String {
  pretty_value(value, 0)
}

fn pretty_value(value: Value, depth: Int) -> String {
  case value {
    VFloat(value) -> {
      let integer = float.truncate(value)
      case value == int.to_float(integer) {
        True -> int.to_string(integer)
        False -> json.to_string(json.float(value))
      }
    }
    VArray([]) -> "[]"
    VArray(values) ->
      "[\n"
      <> string.join(
        list.map(values, fn(value) {
          indent(depth + 1) <> pretty_value(value, depth + 1)
        }),
        ",\n",
      )
      <> "\n"
      <> indent(depth)
      <> "]"
    VObject([]) -> "{}"
    VObject(fields) ->
      "{\n"
      <> string.join(
        list.map(fields, fn(field) {
          indent(depth + 1)
          <> json.to_string(json.string(field.0))
          <> ": "
          <> pretty_value(field.1, depth + 1)
        }),
        ",\n",
      )
      <> "\n"
      <> indent(depth)
      <> "}"
    _ -> value |> codec_common.encode_value |> json.to_string
  }
}

fn indent(depth: Int) -> String {
  string.repeat("  ", depth)
}

pub fn argument(
  arguments: Option(dict.Dict(String, Value)),
  name: String,
) -> Option(Value) {
  case arguments {
    Some(arguments) -> dict.get(arguments, name) |> result_option
    None -> None
  }
}

fn result_option(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
