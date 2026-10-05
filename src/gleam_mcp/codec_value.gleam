/// Internal JSON builders keep objects as fields until the final serialization.
/// In particular, object construction preserves duplicate keys and field order.
import gleam/dict
import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VNull, VObject, VString,
}

pub fn string(value: String) -> Value {
  VString(value)
}

pub fn bool(value: Bool) -> Value {
  VBool(value)
}

pub fn int(value: Int) -> Value {
  VInt(value)
}

pub fn float(value: Float) -> Value {
  VFloat(value)
}

pub fn null() -> Value {
  VNull
}

pub fn nullable(value: Option(a), encode: fn(a) -> Value) -> Value {
  case value {
    None -> VNull
    Some(value) -> encode(value)
  }
}

pub fn object(fields: List(#(String, Value))) -> Value {
  VObject(fields)
}

pub fn array(values: List(a), encode: fn(a) -> Value) -> Value {
  VArray(list.map(values, encode))
}

/// Match the old encode/parse boundary: duplicate keys use their first value,
/// including nested objects. Raw legacy encoding deliberately skips this step.
pub fn normalize(value: Value) -> Value {
  case value {
    VObject(fields) ->
      fields
      |> parsed_object_fields
      |> list.map(fn(field) { #(field.0, normalize(field.1)) })
      |> VObject
    VArray(values) -> VArray(list.map(values, normalize))
    _ -> value
  }
}

pub fn object_fields(value: Value) -> List(#(String, Value)) {
  let assert VObject(fields) = normalize(value)
  fields
}

pub fn to_string(value: Value) -> String {
  value |> to_json |> json.to_string
}

pub fn to_dynamic(value: Value) -> dynamic.Dynamic {
  case value {
    VNull -> dynamic.nil()
    VString(value) -> dynamic.string(value)
    VInt(value) -> dynamic.int(value)
    VFloat(value) -> dynamic.float(value)
    VBool(value) -> dynamic.bool(value)
    VArray(values) -> dynamic.list(list.map(values, to_dynamic))
    VObject(fields) ->
      fields
      |> parsed_object_fields
      |> list.map(fn(field) { #(dynamic.string(field.0), to_dynamic(field.1)) })
      |> dynamic.properties
  }
}

fn parsed_object_fields(
  fields: List(#(String, Value)),
) -> List(#(String, Value)) {
  // Dict construction keeps the last entry; the JSON parser keeps the first.
  fields |> list.reverse |> dict.from_list |> dict.to_list
}

pub fn to_json(value: Value) -> json.Json {
  case value {
    VNull -> json.null()
    VString(value) -> json.string(value)
    VInt(value) -> json.int(value)
    VFloat(value) -> json.float(value)
    VBool(value) -> json.bool(value)
    VArray(values) -> json.array(values, to_json)
    VObject(fields) ->
      fields
      |> list.map(fn(field) { #(field.0, to_json(field.1)) })
      |> json.object
  }
}
