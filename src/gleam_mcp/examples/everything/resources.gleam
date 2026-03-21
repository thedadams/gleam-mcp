import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server

pub const dynamic_text_template = "demo://everything/resource/dynamic/text/{id}"

pub const dynamic_blob_template = "demo://everything/resource/dynamic/blob/{id}"

const demo_blob = "VGhpcyBpcyBhIGRlbW8gYmxvYiByZXNvdXJjZS4="

pub fn register_resources(app_server: server.Server) -> server.Server {
  app_server
  |> server.add_resource(
    "demo://everything/resource/static/server-overview",
    "Server Overview",
    "A static description of the Everything demo server",
    Some("text/plain"),
    fn() {
      Ok([
        actions.TextResourceContents(
          uri: "demo://everything/resource/static/server-overview",
          mime_type: Some("text/plain"),
          text: "The Gleam Everything server is a best-effort port of the MCP reference demo.",
          meta: None,
        ),
      ])
    },
  )
  |> server.add_resource(
    "demo://everything/resource/static/features",
    "Feature Summary",
    "A static summary of the supported Everything features",
    Some("text/plain"),
    fn() {
      Ok([
        actions.TextResourceContents(
          uri: "demo://everything/resource/static/features",
          mime_type: Some("text/plain"),
          text: "Supported: tools, prompts, resources, templates, completions, image content, resource links, embedded resources, and structured tool responses.",
          meta: None,
        ),
      ])
    },
  )
  |> server.add_resource_template(
    dynamic_text_template,
    "Dynamic Text Resource",
    "A generated text resource for a numeric identifier",
    Some("text/plain"),
    read_dynamic_text_resource,
  )
  |> server.add_resource_template(
    dynamic_blob_template,
    "Dynamic Blob Resource",
    "A generated blob resource for a numeric identifier",
    Some("application/octet-stream"),
    read_dynamic_blob_resource,
  )
}

pub fn text_resource(id: Int) -> actions.Resource {
  actions.Resource(
    uri: text_resource_uri(id),
    name: "Dynamic Text Resource " <> int.to_string(id),
    title: None,
    description: Some("Generated text resource " <> int.to_string(id)),
    mime_type: Some("text/plain"),
    annotations: None,
    size: None,
    icons: [],
    meta: None,
  )
}

pub fn blob_resource(id: Int) -> actions.Resource {
  actions.Resource(
    uri: blob_resource_uri(id),
    name: "Dynamic Blob Resource " <> int.to_string(id),
    title: None,
    description: Some("Generated blob resource " <> int.to_string(id)),
    mime_type: Some("application/octet-stream"),
    annotations: None,
    size: None,
    icons: [],
    meta: None,
  )
}

pub fn text_resource_contents(id: Int) -> actions.ResourceContents {
  actions.TextResourceContents(
    uri: text_resource_uri(id),
    mime_type: Some("text/plain"),
    text: "Dynamic text resource "
      <> int.to_string(id)
      <> ": this content is generated on demand.",
    meta: None,
  )
}

pub fn blob_resource_contents(id: Int) -> actions.ResourceContents {
  actions.BlobResourceContents(
    uri: blob_resource_uri(id),
    mime_type: Some("application/octet-stream"),
    blob: demo_blob,
    meta: None,
  )
}

pub fn text_resource_uri(id: Int) -> String {
  "demo://everything/resource/dynamic/text/" <> int.to_string(id)
}

pub fn blob_resource_uri(id: Int) -> String {
  "demo://everything/resource/dynamic/blob/" <> int.to_string(id)
}

pub fn parse_resource_id(uri: String) -> Result(Int, jsonrpc.RpcError) {
  case list.reverse(string.split(uri, on: "/")) {
    [id_text, ..] ->
      case int.parse(id_text) {
        Ok(id) if id > 0 -> Ok(id)
        _ ->
          Error(jsonrpc.invalid_params_error(
            "resource id must be a positive integer",
          ))
      }
    _ ->
      Error(jsonrpc.invalid_params_error(
        "resource id must be a positive integer",
      ))
  }
}

fn read_dynamic_text_resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  case parse_resource_id(uri) {
    Ok(id) -> Ok([text_resource_contents(id)])
    Error(error) -> Error(error)
  }
}

fn read_dynamic_blob_resource(
  uri: String,
) -> Result(List(actions.ResourceContents), jsonrpc.RpcError) {
  case parse_resource_id(uri) {
    Ok(id) -> Ok([blob_resource_contents(id)])
    Error(error) -> Error(error)
  }
}
