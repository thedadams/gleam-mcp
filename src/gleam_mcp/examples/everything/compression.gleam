//// RFC 1952 framing around package-owned DEFLATE compression and CRC32.

import gleam/bit_array
import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/examples/everything/fetch
import gleam_mcp/examples/everything/session_resources
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gzlib

const default_data = "https://raw.githubusercontent.com/modelcontextprotocol/servers/refs/heads/main/README.md"

pub fn register_tools(
  app: server.Server,
  store: session_resources.Store,
) -> server.Server {
  let schema =
    helpers.object_schema(
      [
        #(
          "name",
          helpers.string_schema("Name of the output file")
            |> helpers.with_property("default", jsonrpc.VString("README.md.gz")),
        ),
        #(
          "data",
          helpers.string_schema(
            "URL or data URI of the file content to compress",
          )
            |> helpers.with_property("format", jsonrpc.VString("uri"))
            |> helpers.with_property("default", jsonrpc.VString(default_data)),
        ),
        #(
          "outputType",
          helpers.string_schema(
            "How the resulting gzipped file should be returned. 'resourceLink' returns a link to a resource that can be read later, 'resource' returns a full resource object.",
          )
            |> helpers.with_property(
              "enum",
              jsonrpc.VArray([
                jsonrpc.VString("resourceLink"),
                jsonrpc.VString("resource"),
              ]),
            )
            |> helpers.with_property("default", jsonrpc.VString("resourceLink")),
        ),
      ],
      [],
    )
  let descriptor =
    helpers.descriptor(
      "gzip-file-as-resource",
      "GZip File as Resource Tool",
      "Compresses a single file using gzip compression. Depending upon the selected output type, returns either the compressed data as a gzipped resource or a resource link, allowing it to be downloaded in a subsequent request during the current session.",
      schema,
      None,
      actions.ToolAnnotations(
        None,
        Some(False),
        Some(False),
        Some(True),
        Some(True),
      ),
    )
  let limits = fetch.limits_from_environment()
  server.register_context_tool_descriptor(
    app,
    descriptor,
    fn(app, context, arguments) {
      run(store, context, arguments, limits)
      |> result.map(fn(value) {
        let _ =
          server.send_notification(
            app,
            context,
            jsonrpc.Notification(
              mcp.method_notify_resource_list_changed,
              Some(actions.NotifyResourceListChanged(None)),
            ),
          )
        value
      })
      |> helpers.tool_result
    },
  )
}

pub fn run(
  store: session_resources.Store,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  limits: fetch.Limits,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  use name <- result.try(argument(arguments, "name", "README.md.gz"))
  use data <- result.try(argument(arguments, "data", default_data))
  use output <- result.try(argument(arguments, "outputType", "resourceLink"))
  use _ <- result.try(case output == "resourceLink" || output == "resource" {
    True -> Ok(Nil)
    False ->
      Error(jsonrpc.invalid_params_error("Unknown outputType: " <> output))
  })
  use input <- result.try(
    fetch.get(data, limits) |> result.map_error(jsonrpc.invalid_params_error),
  )
  use compressed <- result.try(
    gzip(input) |> result.map_error(jsonrpc.invalid_params_error),
  )
  let blob = bit_array.base64_encode(compressed, True)
  let resource = session_resources.put_blob(store, context, name, blob)
  let content = case output {
    "resourceLink" -> actions.ResourceLinkBlock(actions.ResourceLink(resource))
    _ ->
      actions.EmbeddedResourceBlock(actions.EmbeddedResource(
        actions.BlobResourceContents(
          resource.uri,
          Some("application/gzip"),
          blob,
          None,
        ),
        None,
        None,
      ))
  }
  Ok(helpers.content_result([content]))
}

pub fn gzip(input: BitArray) -> Result(BitArray, String) {
  use compressed <- result.try(
    gzlib.compress(input)
    |> result.map_error(fn(_) { "Unable to compress input" }),
  )
  use checksum <- result.try(
    gzlib.crc32(input) |> result.map_error(fn(_) { "Unable to checksum input" }),
  )
  // zlib wraps DEFLATE with two header bytes and a four-byte Adler checksum.
  use deflate <- result.try(
    bit_array.slice(compressed, 2, bit_array.byte_size(compressed) - 6)
    |> result.map_error(fn(_) { "Invalid compressed payload" }),
  )
  let size = bit_array.byte_size(input)
  Ok(<<
    0x1f,
    0x8b,
    8,
    0,
    0:size(32)-little,
    0,
    3,
    deflate:bits,
    checksum:size(32)-little,
    size:size(32)-little,
  >>)
}

fn argument(
  arguments: Option(dict.Dict(String, jsonrpc.Value)),
  key: String,
  default: String,
) -> Result(String, jsonrpc.RpcError) {
  case
    arguments
    |> option.then(fn(values) { dict.get(values, key) |> option.from_result })
  {
    None -> Ok(default)
    Some(jsonrpc.VString(value)) -> Ok(value)
    Some(_) -> Error(jsonrpc.invalid_params_error(key <> " must be a string"))
  }
}
