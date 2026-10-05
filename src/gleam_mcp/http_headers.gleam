import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/jsonrpc.{type Value, VBool, VInt, VObject, VString}

pub type Mapping {
  Mapping(name: String, path: List(String), kind: String)
}

pub type ParamHeader =
  Mapping

pub fn definitions(schema: Value) -> Result(List(ParamHeader), String) {
  mappings(schema)
}

/// Validate all annotations before exposing a tool through an HTTP client.
pub fn mappings(schema: Value) -> Result(List(Mapping), String) {
  use _ <- result.try(case schema {
    VObject(fields) ->
      case list.key_find(fields, "type") {
        Ok(VString("object")) -> Ok(Nil)
        _ -> Error("Tool input schema requires type object")
      }
    _ -> Error("Tool input schema must be a JSON Schema object")
  })
  use scanned <- result.try(walk(schema, [], True, 0, 4096))
  let #(mappings, _) = scanned
  let names = list.map(mappings, fn(mapping) { string.lowercase(mapping.name) })
  case list.length(names) == list.length(list.unique(names)) {
    True -> Ok(mappings)
    False -> Error("Duplicate x-mcp-header name")
  }
}

fn walk(
  value: Value,
  path: List(String),
  allowed: Bool,
  depth: Int,
  budget: Int,
) -> Result(#(List(Mapping), Int), String) {
  use _ <- result.try(case depth <= 64 && budget > 0 {
    True -> Ok(Nil)
    False -> Error("Tool header schema exceeds traversal limits")
  })
  case value {
    VObject(fields) -> {
      let annotation = list.key_find(fields, "x-mcp-header")
      use own <- result.try(case annotation {
        Error(_) -> Ok([])
        Ok(VString(name)) if allowed && path != [] -> {
          use _ <- result.try(validate_name(name))
          case list.key_find(fields, "type") {
            Ok(VString(kind))
              if kind == "string" || kind == "integer" || kind == "boolean"
            -> Ok([Mapping(name, path, kind)])
            _ ->
              Error(
                "x-mcp-header requires a single string, integer, or boolean type",
              )
          }
        }
        _ -> Error("Invalid x-mcp-header annotation location or value")
      })
      list.try_fold(fields, #(own, budget - 1), fn(state, field) {
        let #(key, child) = field
        case key, child {
          "properties", VObject(properties) ->
            list.try_fold(properties, state, fn(state, property) {
              let #(name, schema) = property
              scan_child(
                state,
                schema,
                list.append(path, [name]),
                allowed,
                depth,
              )
            })
          "$defs", VObject(children)
          | "definitions", VObject(children)
          | "patternProperties", VObject(children)
          | "dependentSchemas", VObject(children)
          ->
            list.try_fold(children, state, fn(state, child) {
              scan_child(state, child.1, path, False, depth)
            })
          "allOf", jsonrpc.VArray(children)
          | "anyOf", jsonrpc.VArray(children)
          | "oneOf", jsonrpc.VArray(children)
          | "prefixItems", jsonrpc.VArray(children)
          | "items", jsonrpc.VArray(children)
          ->
            list.try_fold(children, state, fn(state, child) {
              scan_child(state, child, path, False, depth)
            })
          "items", _
          | "contains", _
          | "not", _
          | "if", _
          | "then", _
          | "else", _
          | "additionalProperties", _
          | "unevaluatedProperties", _
          | "unevaluatedItems", _
          | "propertyNames", _
          | "contentSchema", _
          -> scan_child(state, child, path, False, depth)
          _, _ -> Ok(state)
        }
      })
    }
    _ -> Ok(#([], budget - 1))
  }
}

fn scan_child(
  state: #(List(Mapping), Int),
  child: Value,
  path: List(String),
  allowed: Bool,
  depth: Int,
) -> Result(#(List(Mapping), Int), String) {
  use nested <- result.try(walk(child, path, allowed, depth + 1, state.1))
  Ok(#(list.append(state.0, nested.0), nested.1))
}

fn validate_name(name: String) -> Result(Nil, String) {
  case name != "" && token_bytes(<<name:utf8>>) {
    True -> Ok(Nil)
    False -> Error("x-mcp-header name must be a non-empty HTTP token")
  }
}

fn token_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<b, rest:bits>>
      if b >= 48 && b <= 57 || b >= 65 && b <= 90 || b >= 97 && b <= 122
    -> token_bytes(rest)
    <<b, rest:bits>>
      if b == 33
      || b == 35
      || b == 36
      || b == 37
      || b == 38
      || b == 39
      || b == 42
      || b == 43
      || b == 45
      || b == 46
      || b == 94
      || b == 95
      || b == 96
      || b == 124
      || b == 126
    -> token_bytes(rest)
    _ -> False
  }
}

pub fn from_arguments(
  mappings: List(Mapping),
  arguments: Option(Dict(String, Value)),
) -> Result(List(#(String, String)), String) {
  let root = VObject(arguments |> option.map(dict.to_list) |> option.unwrap([]))
  from_value(mappings, root)
}

pub fn parameters(
  schema: Value,
  arguments: Value,
) -> Result(List(http.Header), String) {
  use mappings <- result.try(definitions(schema))
  from_value(mappings, arguments)
}

fn from_value(
  mappings: List(Mapping),
  root: Value,
) -> Result(List(http.Header), String) {
  list.try_fold(mappings, [], fn(headers, mapping) {
    case at_path(root, mapping.path) {
      None | Some(jsonrpc.VNull) -> Ok(headers)
      Some(value) -> {
        use value <- result.try(render(value, mapping.kind))
        Ok([
          #("mcp-param-" <> string.lowercase(mapping.name), encode_value(value)),
          ..headers
        ])
      }
    }
  })
}

fn at_path(value: Value, path: List(String)) -> Option(Value) {
  case path, value {
    [], _ -> Some(value)
    [key, ..rest], VObject(fields) ->
      list.key_find(fields, key)
      |> option.from_result
      |> option.then(fn(child) { at_path(child, rest) })
    _, _ -> None
  }
}

fn render(value: Value, kind: String) -> Result(String, String) {
  case value, kind {
    VString(value), "string" -> Ok(value)
    VBool(True), "boolean" -> Ok("true")
    VBool(False), "boolean" -> Ok("false")
    VInt(value), "integer"
      if value >= -9_007_199_254_740_991 && value <= 9_007_199_254_740_991
    -> Ok(int.to_string(value))
    jsonrpc.VFloat(value), "integer" -> {
      let integer = float.truncate(value)
      case
        int.to_float(integer) == value
        && integer >= -9_007_199_254_740_991
        && integer <= 9_007_199_254_740_991
      {
        True -> Ok(int.to_string(integer))
        False ->
          Error("Tool header integer is outside the safe range or fractional")
      }
    }
    _, _ -> Error("Tool argument does not match x-mcp-header scalar type")
  }
}

/// Encode unsafe field values and strings resembling the encoding sentinel.
pub fn encode_value(value: String) -> String {
  let sentinel =
    string.starts_with(value, "=?base64?") && string.ends_with(value, "?=")
  case !sentinel && value == string.trim(value) && safe_bytes(<<value:utf8>>) {
    True -> value
    False ->
      "=?base64?" <> bit_array.base64_encode(<<value:utf8>>, True) <> "?="
  }
}

pub fn decode_value(value: String) -> Result(String, String) {
  let value = trim_ows(value)
  use _ <- result.try(case safe_bytes(<<value:utf8>>) {
    True -> Ok(Nil)
    False -> Error("Invalid plain HTTP header value")
  })
  case string.starts_with(value, "=?base64?") && string.ends_with(value, "?=") {
    True -> {
      let encoded = value |> string.drop_start(9) |> string.drop_end(2)
      use bytes <- result.try(
        encoded
        |> bit_array.base64_decode
        |> result.map_error(fn(_) { "Invalid Base64 header sentinel" }),
      )
      use _ <- result.try(case bit_array.base64_encode(bytes, True) == encoded {
        True -> Ok(Nil)
        False -> Error("Invalid Base64 header sentinel")
      })
      bit_array.to_string(bytes)
      |> result.map_error(fn(_) { "Header sentinel does not contain UTF-8" })
    }
    False -> Ok(value)
  }
}

/// HTTP field parsing removes only optional SP and HTAB at the boundaries.
/// Other whitespace remains visible to the ASCII/control validation.
pub fn trim_ows(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.drop_while(is_ows)
  |> list.reverse
  |> list.drop_while(is_ows)
  |> list.reverse
  |> string.concat
}

fn is_ows(value: String) -> Bool {
  value == " " || value == "\t"
}

pub fn standard(
  version: String,
  method: String,
  name: Option(String),
) -> List(http.Header) {
  let headers = [#("mcp-protocol-version", version), #("mcp-method", method)]
  case name {
    None -> headers
    Some(name) -> [#("mcp-name", encode_value(name)), ..headers]
  }
}

pub fn validate_standard(
  headers: List(http.Header),
  version: String,
  method: String,
  name: Option(String),
) -> Result(Nil, String) {
  use _ <- result.try(compare_required(
    headers,
    "mcp-protocol-version",
    version,
    False,
  ))
  use _ <- result.try(compare_required(headers, "mcp-method", method, False))
  case name {
    Some(name) -> compare_required(headers, "mcp-name", name, True)
    None ->
      case find_header(headers, "mcp-name") {
        Ok(None) -> Ok(Nil)
        Ok(Some(_)) -> Error("Mcp-Name has no corresponding request field")
        Error(error) -> Error(error)
      }
  }
}

fn find_header(
  headers: List(http.Header),
  name: String,
) -> Result(Option(String), String) {
  case list.filter(headers, fn(header) { string.lowercase(header.0) == name }) {
    [] -> Ok(None)
    [#(_, value)] -> Ok(Some(trim_ows(value)))
    _ -> Error("Duplicate mirrored HTTP header: " <> name)
  }
}

fn compare_required(
  headers: List(http.Header),
  name: String,
  expected: String,
  encoded: Bool,
) -> Result(Nil, String) {
  use header <- result.try(find_header(headers, name))
  use header <- result.try(option.to_result(
    header,
    "Missing required HTTP header: " <> name,
  ))
  use actual <- result.try(case encoded {
    True -> decode_value(header)
    False ->
      case safe_bytes(<<header:utf8>>) {
        True -> Ok(header)
        False -> Error("Invalid HTTP header: " <> name)
      }
  })
  case actual == expected {
    True -> Ok(Nil)
    False -> Error("HTTP header does not match the request body: " <> name)
  }
}

pub fn validate_parameters(
  headers: List(http.Header),
  schema: Value,
  arguments: Value,
) -> Result(Nil, String) {
  use mappings <- result.try(definitions(schema))
  list.try_each(mappings, fn(mapping) {
    let name = "mcp-param-" <> string.lowercase(mapping.name)
    use header <- result.try(find_header(headers, name))
    case at_path(arguments, mapping.path), header {
      None, None | Some(jsonrpc.VNull), None -> Ok(Nil)
      None, Some(_) | Some(jsonrpc.VNull), Some(_) ->
        Error("HTTP header has no corresponding argument: " <> name)
      Some(_), None -> Error("Missing required tool argument header: " <> name)
      Some(value), Some(header) -> {
        use expected <- result.try(render(value, mapping.kind))
        use actual <- result.try(decode_value(header))
        let equal = case mapping.kind {
          "integer" ->
            case int.parse(actual), int.parse(expected) {
              Ok(actual), Ok(expected) -> actual == expected
              Error(_), Ok(expected) ->
                case float.parse(actual) {
                  Ok(actual) -> actual == int.to_float(expected)
                  Error(_) -> False
                }
              _, _ -> False
            }
          _ -> actual == expected
        }
        case equal {
          True -> Ok(Nil)
          False ->
            Error(
              "Tool argument header does not match the request body: " <> name,
            )
        }
      }
    }
  })
}

fn safe_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<b, rest:bits>> if b == 9 || b >= 32 && b <= 126 -> safe_bytes(rest)
    _ -> False
  }
}
