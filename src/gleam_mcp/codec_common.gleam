import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc

pub fn encode_implementation(
  implementation: actions.Implementation,
) -> json.Json {
  let actions.Implementation(
    name,
    version,
    title,
    description,
    website_url,
    icons,
  ) = implementation

  [#("name", json.string(name)), #("version", json.string(version))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("websiteUrl", option_map(website_url, json.string))
  |> append_optional("icons", maybe_array(icons, encode_icon))
  |> json.object
}

pub fn encode_icon(icon: actions.Icon) -> json.Json {
  let actions.Icon(src, mime_type, sizes, theme) = icon

  [#("src", json.string(src))]
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("sizes", maybe_array(sizes, json.string))
  |> append_optional("theme", option_map(theme, encode_icon_theme))
  |> json.object
}

pub fn encode_icon_theme(theme: actions.IconTheme) -> json.Json {
  case theme {
    actions.LightTheme -> json.string("light")
    actions.DarkTheme -> json.string("dark")
  }
}

pub fn encode_tool(tool: actions.Tool) -> json.Json {
  let actions.Tool(
    name,
    title,
    description,
    input_schema,
    execution,
    output_schema,
    annotations,
    icons,
    meta,
  ) = tool

  [#("name", json.string(name)), #("inputSchema", encode_value(input_schema))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("execution", option_map(execution, encode_tool_execution))
  |> append_optional("outputSchema", option_map(output_schema, encode_value))
  |> append_optional(
    "annotations",
    option_map(annotations, encode_tool_annotations),
  )
  |> append_optional("icons", maybe_array(icons, encode_icon))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_tool_execution(execution: actions.ToolExecution) -> json.Json {
  let actions.ToolExecution(task_support) = execution

  []
  |> append_optional(
    "taskSupport",
    option_map(task_support, fn(task_support) {
      case task_support {
        actions.TaskForbidden -> json.string("forbidden")
        actions.TaskOptional -> json.string("optional")
        actions.TaskRequired -> json.string("required")
      }
    }),
  )
  |> json.object
}

pub fn encode_tool_annotations(
  annotations: actions.ToolAnnotations,
) -> json.Json {
  let actions.ToolAnnotations(
    title,
    read_only_hint,
    destructive_hint,
    idempotent_hint,
    open_world_hint,
  ) = annotations

  []
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("readOnlyHint", option_map(read_only_hint, json.bool))
  |> append_optional("destructiveHint", option_map(destructive_hint, json.bool))
  |> append_optional("idempotentHint", option_map(idempotent_hint, json.bool))
  |> append_optional("openWorldHint", option_map(open_world_hint, json.bool))
  |> json.object
}

pub fn encode_sampling_message_content_block(
  block: actions.SamplingMessageContentBlock,
) -> json.Json {
  case block {
    actions.SamplingText(content) -> encode_text_content(content)
    actions.SamplingImage(content) -> encode_image_content(content)
    actions.SamplingAudio(content) -> encode_audio_content(content)
    actions.SamplingToolUse(content) -> encode_tool_use_content(content)
    actions.SamplingToolResult(content) -> encode_tool_result_content(content)
  }
}

pub fn encode_tool_use_content(content: actions.ToolUseContent) -> json.Json {
  let actions.ToolUseContent(id, name, input, meta) = content

  [
    #("type", json.string("tool_use")),
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("input", encode_value_object(dict.to_list(input))),
  ]
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_tool_result_content(
  content: actions.ToolResultContent,
) -> json.Json {
  let actions.ToolResultContent(
    tool_use_id,
    blocks,
    structured_content,
    is_error,
    meta,
  ) = content

  [
    #("type", json.string("tool_result")),
    #("toolUseId", json.string(tool_use_id)),
    #("content", json.array(blocks, encode_content_block)),
  ]
  |> append_optional(
    "structuredContent",
    option_map(structured_content, fn(fields) {
      encode_value_object(dict.to_list(fields))
    }),
  )
  |> append_optional("isError", option_map(is_error, json.bool))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_content_block(block: actions.ContentBlock) -> json.Json {
  case block {
    actions.TextBlock(content) -> encode_text_content(content)
    actions.ImageBlock(content) -> encode_image_content(content)
    actions.AudioBlock(content) -> encode_audio_content(content)
    actions.ResourceLinkBlock(link) -> encode_resource_link(link)
    actions.EmbeddedResourceBlock(resource) ->
      encode_embedded_resource(resource)
  }
}

pub fn encode_text_content(content: actions.TextContent) -> json.Json {
  let actions.TextContent(text, annotations, meta) = content

  [#("type", json.string("text")), #("text", json.string(text))]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_image_content(content: actions.ImageContent) -> json.Json {
  let actions.ImageContent(data, mime_type, annotations, meta) = content

  [
    #("type", json.string("image")),
    #("data", json.string(data)),
    #("mimeType", json.string(mime_type)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_audio_content(content: actions.AudioContent) -> json.Json {
  let actions.AudioContent(data, mime_type, annotations, meta) = content

  [
    #("type", json.string("audio")),
    #("data", json.string(data)),
    #("mimeType", json.string(mime_type)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_resource_link(link: actions.ResourceLink) -> json.Json {
  let actions.ResourceLink(resource) = link
  resource_fields(resource)
  |> prepend_field(#("type", json.string("resource_link")))
  |> json.object
}

pub fn encode_resource(resource: actions.Resource) -> json.Json {
  resource_fields(resource) |> json.object
}

pub fn encode_embedded_resource(resource: actions.EmbeddedResource) -> json.Json {
  let actions.EmbeddedResource(contents, annotations, meta) = resource

  [
    #("type", json.string("resource")),
    #("resource", encode_resource_contents(contents)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_annotations(annotations: actions.Annotations) -> json.Json {
  let actions.Annotations(audience, priority, last_modified) = annotations

  []
  |> append_optional("audience", maybe_array(audience, encode_role))
  |> append_optional("priority", option_map(priority, json.float))
  |> append_optional("lastModified", option_map(last_modified, json.string))
  |> json.object
}

pub fn encode_meta(meta: actions.Meta) -> json.Json {
  let actions.Meta(fields) = meta
  encode_value_object(dict.to_list(fields))
}

pub fn encode_role(role: actions.Role) -> json.Json {
  case role {
    actions.User -> json.string("user")
    actions.Assistant -> json.string("assistant")
  }
}

pub fn encode_cursor(cursor: actions.Cursor) -> json.Json {
  let actions.Cursor(value) = cursor
  json.string(value)
}

pub fn encode_task_status(status: actions.TaskStatus) -> json.Json {
  case status {
    actions.Working -> json.string("working")
    actions.InputRequired -> json.string("input_required")
    actions.Completed -> json.string("completed")
    actions.Failed -> json.string("failed")
    actions.Cancelled -> json.string("cancelled")
  }
}

pub fn encode_value(value: jsonrpc.Value) -> json.Json {
  case value {
    jsonrpc.VNull -> json.null()
    jsonrpc.VString(value) -> json.string(value)
    jsonrpc.VInt(value) -> json.int(value)
    jsonrpc.VFloat(value) -> json.float(value)
    jsonrpc.VBool(value) -> json.bool(value)
    jsonrpc.VArray(values) -> json.array(values, encode_value)
    jsonrpc.VObject(values) -> encode_value_object(values)
  }
}

pub fn encode_request_id(id: jsonrpc.RequestId) -> json.Json {
  case id {
    jsonrpc.IntId(value) -> json.int(value)
    jsonrpc.StringId(value) -> json.string(value)
  }
}

fn encode_resource_contents(contents: actions.ResourceContents) -> json.Json {
  case contents {
    actions.TextResourceContents(uri, mime_type, text, meta) ->
      [#("uri", json.string(uri)), #("text", json.string(text))]
      |> append_optional("mimeType", option_map(mime_type, json.string))
      |> append_optional("_meta", option_map(meta, encode_meta))
      |> json.object
    actions.BlobResourceContents(uri, mime_type, blob, meta) ->
      [#("uri", json.string(uri)), #("blob", json.string(blob))]
      |> append_optional("mimeType", option_map(mime_type, json.string))
      |> append_optional("_meta", option_map(meta, encode_meta))
      |> json.object
  }
}

fn resource_fields(resource: actions.Resource) -> List(#(String, json.Json)) {
  let actions.Resource(
    uri,
    name,
    title,
    description,
    mime_type,
    annotations,
    size,
    icons,
    meta,
  ) = resource

  [#("uri", json.string(uri)), #("name", json.string(name))]
  |> append_optional("title", option_map(title, json.string))
  |> append_optional("description", option_map(description, json.string))
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("size", option_map(size, json.int))
  |> append_optional("icons", maybe_array(icons, encode_icon))
  |> append_optional("_meta", option_map(meta, encode_meta))
}

fn encode_value_object(fields: List(#(String, jsonrpc.Value))) -> json.Json {
  fields
  |> list.map(fn(entry) {
    let #(key, value) = entry
    #(key, encode_value(value))
  })
  |> json.object
}

fn maybe_array(items: List(a), encode: fn(a) -> json.Json) -> Option(json.Json) {
  case items {
    [] -> None
    _ -> Some(json.array(items, encode))
  }
}

fn option_map(value: Option(a), f: fn(a) -> b) -> Option(b) {
  case value {
    Some(value) -> Some(f(value))
    None -> None
  }
}

fn append_optional(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(json.Json),
) -> List(#(String, json.Json)) {
  case value {
    Some(value) -> list.append(fields, [#(key, value)])
    None -> fields
  }
}

fn prepend_field(
  fields: List(#(String, json.Json)),
  field: #(String, json.Json),
) -> List(#(String, json.Json)) {
  [field, ..fields]
}
