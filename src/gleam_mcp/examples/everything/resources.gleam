import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri
import gleam_mcp/actions
import gleam_mcp/examples/everything/documents
import gleam_mcp/jsonrpc
import gleam_mcp/server

pub const dynamic_text_template = "demo://resource/dynamic/text/{resourceId}"

pub const dynamic_blob_template = "demo://resource/dynamic/blob/{resourceId}"

pub fn register_resources(app: server.Server) -> server.Server {
  let app =
    list.fold(documents.all(), app, fn(app, document) {
      let #(name, text) = document
      let uri = "demo://resource/static/document/" <> uri.percent_encode(name)
      let mime = document_mime_type(name)
      server.add_resource(
        app,
        uri,
        name,
        "Static document file exposed from /docs: " <> name,
        Some(mime),
        fn() { Ok([actions.TextResourceContents(uri, Some(mime), text, None)]) },
      )
    })
  app
  |> server.add_resource_template(
    dynamic_text_template,
    "Dynamic Text Resource",
    "Plaintext dynamic resource fabricated from the {resourceId} variable, which must be an integer.",
    Some("text/plain"),
    read_dynamic_text_resource,
  )
  |> server.add_resource_template(
    dynamic_blob_template,
    "Dynamic Blob Resource",
    "Binary (base64) dynamic resource fabricated from the {resourceId} variable, which must be an integer.",
    Some("application/octet-stream"),
    read_dynamic_blob_resource,
  )
}

pub fn instructions() -> String {
  documents.instructions()
}

pub fn text_resource(id: Int) -> actions.Resource {
  descriptor(
    text_resource_uri(id),
    "Dynamic Text Resource " <> int.to_string(id),
    "Generated text resource " <> int.to_string(id),
    "text/plain",
  )
}

pub fn blob_resource(id: Int) -> actions.Resource {
  descriptor(
    blob_resource_uri(id),
    "Dynamic Blob Resource " <> int.to_string(id),
    "Generated blob resource " <> int.to_string(id),
    "text/plain",
  )
}

fn descriptor(
  uri: String,
  name: String,
  description: String,
  mime: String,
) -> actions.Resource {
  actions.Resource(
    uri,
    name,
    None,
    Some(description),
    Some(mime),
    None,
    None,
    [],
    None,
  )
}

pub fn text_resource_contents(id: Int) -> actions.ResourceContents {
  actions.TextResourceContents(
    text_resource_uri(id),
    Some("text/plain"),
    "Resource "
      <> int.to_string(id)
      <> ": This is a plaintext resource created at "
      <> current_time(),
    None,
  )
}

pub fn blob_resource_contents(id: Int) -> actions.ResourceContents {
  let text =
    "Resource "
    <> int.to_string(id)
    <> ": This is a base64 blob created at "
    <> current_time()
  actions.BlobResourceContents(
    blob_resource_uri(id),
    Some("text/plain"),
    bit_array.base64_encode(<<text:utf8>>, True),
    None,
  )
}

pub fn text_resource_uri(id: Int) -> String {
  "demo://resource/dynamic/text/" <> int.to_string(id)
}

pub fn blob_resource_uri(id: Int) -> String {
  "demo://resource/dynamic/blob/" <> int.to_string(id)
}

pub fn positive_resource_id(value: String) -> Result(Int, jsonrpc.RpcError) {
  let value = string.trim(value)
  case integer_value(value) {
    Ok(id) if id > 0 -> Ok(id)
    _ ->
      case float.parse(decimal_value(value)) {
        Ok(number) if number >. 0.0 -> {
          let id = float.truncate(number)
          case int.to_float(id) == number {
            True -> Ok(id)
            False -> invalid_id()
          }
        }
        _ -> invalid_id()
      }
  }
}

// The reference accepts Number(value), including numeric prefixes and
// scientific notation, rather than only decimal integer strings.
fn integer_value(value: String) -> Result(Int, Nil) {
  case string.lowercase(value) {
    "0x" <> digits -> int.base_parse(digits, 16)
    "0o" <> digits -> int.base_parse(digits, 8)
    "0b" <> digits -> int.base_parse(digits, 2)
    _ -> int.parse(value)
  }
}

fn decimal_value(value: String) -> String {
  let #(mantissa, exponent) = case
    string.split_once(string.lowercase(value), "e")
  {
    Ok(#(mantissa, exponent)) -> #(mantissa, "e" <> exponent)
    Error(_) -> #(value, "")
  }
  let mantissa = case mantissa {
    "." <> rest -> "0." <> rest
    "-." <> rest -> "-0." <> rest
    "+." <> rest -> "+0." <> rest
    _ -> mantissa
  }
  let mantissa = case string.contains(mantissa, ".") {
    False -> mantissa <> ".0"
    True ->
      case string.ends_with(mantissa, ".") {
        True -> mantissa <> "0"
        False -> mantissa
      }
  }
  mantissa <> exponent
}

fn invalid_id() -> Result(Int, jsonrpc.RpcError) {
  Error(jsonrpc.invalid_params_error(
    "resource id must be a finite positive integer",
  ))
}

pub fn parse_resource_id(uri: String) -> Result(Int, jsonrpc.RpcError) {
  case list.reverse(string.split(uri, on: "/")) {
    [value, ..] ->
      uri.percent_decode(value)
      |> result.map_error(fn(_) {
        jsonrpc.invalid_params_error("Invalid resource identifier")
      })
      |> result.try(positive_resource_id)
    _ -> invalid_id()
  }
}

fn read_dynamic_text_resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  parse_resource_id(uri)
  |> result.map(fn(id) {
    let assert actions.TextResourceContents(_, mime, text, meta) =
      text_resource_contents(id)
    [actions.TextResourceContents(uri, mime, text, meta)]
  })
}

fn read_dynamic_blob_resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  parse_resource_id(uri)
  |> result.map(fn(id) {
    let assert actions.BlobResourceContents(_, mime, blob, meta) =
      blob_resource_contents(id)
    [actions.BlobResourceContents(uri, mime, blob, meta)]
  })
}

fn document_mime_type(name: String) -> String {
  let name = string.lowercase(name)
  case string.ends_with(name, ".md") || string.ends_with(name, ".markdown") {
    True -> "text/markdown"
    False ->
      case string.ends_with(name, ".json") {
        True -> "application/json"
        False -> "text/plain"
      }
  }
}

fn current_time() -> String {
  let #(_, calendar.TimeOfDay(hours, minutes, seconds, _)) =
    timestamp.to_calendar(timestamp.system_time(), calendar.local_offset())
  let hour = case hours % 12 {
    0 -> 12
    hour -> hour
  }
  int.to_string(hour)
  <> ":"
  <> pad(minutes)
  <> ":"
  <> pad(seconds)
  <> case hours < 12 {
    True -> " AM"
    False -> " PM"
  }
}

fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
