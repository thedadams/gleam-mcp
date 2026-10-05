/// Shared Value encoders; serialize only at a public wire boundary.
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/codec_value as json
import gleam_mcp/jsonrpc

pub fn encode_implementation(
  implementation: actions.Implementation,
) -> jsonrpc.Value {
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

pub fn encode_icon(icon: actions.Icon) -> jsonrpc.Value {
  let actions.Icon(src, mime_type, sizes, theme) = icon

  [#("src", json.string(src))]
  |> append_optional("mimeType", option_map(mime_type, json.string))
  |> append_optional("sizes", maybe_array(sizes, json.string))
  |> append_optional("theme", option_map(theme, encode_icon_theme))
  |> json.object
}

pub fn encode_icon_theme(theme: actions.IconTheme) -> jsonrpc.Value {
  case theme {
    actions.LightTheme -> json.string("light")
    actions.DarkTheme -> json.string("dark")
  }
}

pub fn encode_tool(tool: actions.Tool) -> jsonrpc.Value {
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

pub fn encode_tool_execution(
  execution: actions.ToolExecution,
) -> jsonrpc.Value {
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
) -> jsonrpc.Value {
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
) -> jsonrpc.Value {
  case block {
    actions.SamplingText(content) -> encode_text_content(content)
    actions.SamplingImage(content) -> encode_image_content(content)
    actions.SamplingAudio(content) -> encode_audio_content(content)
    actions.SamplingToolUse(content) -> encode_tool_use_content(content)
    actions.SamplingToolResult(content) -> encode_tool_result_content(content)
  }
}

pub fn encode_tool_use_content(
  content: actions.ToolUseContent,
) -> jsonrpc.Value {
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
) -> jsonrpc.Value {
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
    option_map(structured_content, encode_value),
  )
  |> append_optional("isError", option_map(is_error, json.bool))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_content_block(block: actions.ContentBlock) -> jsonrpc.Value {
  case block {
    actions.TextBlock(content) -> encode_text_content(content)
    actions.ImageBlock(content) -> encode_image_content(content)
    actions.AudioBlock(content) -> encode_audio_content(content)
    actions.ResourceLinkBlock(link) -> encode_resource_link(link)
    actions.EmbeddedResourceBlock(resource) ->
      encode_embedded_resource(resource)
  }
}

pub fn encode_text_content(content: actions.TextContent) -> jsonrpc.Value {
  let actions.TextContent(text, annotations, meta) = content

  [#("type", json.string("text")), #("text", json.string(text))]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_image_content(content: actions.ImageContent) -> jsonrpc.Value {
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

pub fn encode_audio_content(content: actions.AudioContent) -> jsonrpc.Value {
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

pub fn encode_resource_link(link: actions.ResourceLink) -> jsonrpc.Value {
  let actions.ResourceLink(resource) = link
  resource_fields(resource)
  |> prepend_field(#("type", json.string("resource_link")))
  |> json.object
}

pub fn encode_resource(resource: actions.Resource) -> jsonrpc.Value {
  resource_fields(resource) |> json.object
}

pub fn encode_embedded_resource(
  resource: actions.EmbeddedResource,
) -> jsonrpc.Value {
  let actions.EmbeddedResource(contents, annotations, meta) = resource

  [
    #("type", json.string("resource")),
    #("resource", encode_resource_contents(contents)),
  ]
  |> append_optional("annotations", option_map(annotations, encode_annotations))
  |> append_optional("_meta", option_map(meta, encode_meta))
  |> json.object
}

pub fn encode_annotations(annotations: actions.Annotations) -> jsonrpc.Value {
  let actions.Annotations(audience, priority, last_modified) = annotations

  []
  |> append_optional("audience", maybe_array(audience, encode_role))
  |> append_optional("priority", option_map(priority, json.float))
  |> append_optional("lastModified", option_map(last_modified, json.string))
  |> json.object
}

pub fn encode_meta(meta: actions.Meta) -> jsonrpc.Value {
  let actions.Meta(fields) = meta
  encode_value_object(dict.to_list(fields))
}

pub fn encode_role(role: actions.Role) -> jsonrpc.Value {
  case role {
    actions.User -> json.string("user")
    actions.Assistant -> json.string("assistant")
  }
}

pub fn encode_cursor(cursor: actions.Cursor) -> jsonrpc.Value {
  let actions.Cursor(value) = cursor
  json.string(value)
}

pub fn encode_task_status(status: actions.TaskStatus) -> jsonrpc.Value {
  case status {
    actions.Working -> json.string("working")
    actions.InputRequired -> json.string("input_required")
    actions.Completed -> json.string("completed")
    actions.Failed -> json.string("failed")
    actions.Cancelled -> json.string("cancelled")
  }
}

pub fn encode_value(value: jsonrpc.Value) -> jsonrpc.Value {
  value
}

pub fn encode_request_id(id: jsonrpc.RequestId) -> jsonrpc.Value {
  case id {
    jsonrpc.IntId(value) -> json.int(value)
    jsonrpc.StringId(value) -> json.string(value)
  }
}

fn encode_resource_contents(
  contents: actions.ResourceContents,
) -> jsonrpc.Value {
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

fn resource_fields(
  resource: actions.Resource,
) -> List(#(String, jsonrpc.Value)) {
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

pub fn encode_value_object(
  fields: List(#(String, jsonrpc.Value)),
) -> jsonrpc.Value {
  jsonrpc.VObject(fields)
}

fn maybe_array(
  items: List(a),
  encode: fn(a) -> jsonrpc.Value,
) -> Option(jsonrpc.Value) {
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
  fields: List(#(String, jsonrpc.Value)),
  key: String,
  value: Option(jsonrpc.Value),
) -> List(#(String, jsonrpc.Value)) {
  case value {
    Some(value) -> list.append(fields, [#(key, value)])
    None -> fields
  }
}

fn prepend_field(
  fields: List(#(String, jsonrpc.Value)),
  field: #(String, jsonrpc.Value),
) -> List(#(String, jsonrpc.Value)) {
  [field, ..fields]
}

pub fn task_fields(task: actions.Task) -> List(#(String, jsonrpc.Value)) {
  let actions.Task(
    task_id,
    status,
    status_message,
    created_at,
    last_updated_at,
    ttl_ms,
    poll_interval_ms,
  ) = task

  [
    #("taskId", json.string(task_id)),
    #("status", encode_task_status(status)),
    #("createdAt", json.string(created_at)),
    #("lastUpdatedAt", json.string(last_updated_at)),
    #("ttl", json.nullable(ttl_ms, json.int)),
  ]
  |> append_optional("statusMessage", option_map(status_message, json.string))
  |> append_optional("pollInterval", option_map(poll_interval_ms, json.int))
}
