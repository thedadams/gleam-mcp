import gleam/bit_array
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_decode
import gleam_mcp/examples/everything/form_schema
import gleam_mcp/examples/everything/interaction_results
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/examples/everything/tools
import gleam_mcp/examples/everything/url_elicitation
import gleam_mcp/jsonrpc.{
  type Value, VArray, VBool, VFloat, VInt, VNull, VObject, VString,
}
import gleam_mcp/server
import gleeunit/should
import server_test_support

pub fn reference_core_tool_descriptors_and_conditional_registration_test() {
  let store = url_elicitation.new()
  let app =
    server.new(server_test_support.sample_client_info())
    |> tools.register_tools_with_url_store(None, store)
  let descriptors = listed_tools(app)
  should.equal(list.length(descriptors), 12)
  let echo_descriptor = find_tool(descriptors, "echo")
  should.equal(echo_descriptor.title, Some("Echo Tool"))
  should.equal(
    echo_descriptor.description,
    Some("Echoes back the input string"),
  )
  should.equal(
    echo_descriptor.annotations,
    Some(actions.ToolAnnotations(
      None,
      Some(True),
      Some(False),
      Some(True),
      Some(False),
    )),
  )
  should.equal(
    echo_descriptor.execution,
    Some(actions.ToolExecution(Some(actions.TaskForbidden))),
  )
  should.equal(
    field(echo_descriptor.input_schema, "required"),
    VArray([VString("message")]),
  )
  let links = find_tool(descriptors, "get-resource-links")
  let count = links.input_schema |> field("properties") |> field("count")
  should.equal(field(count, "type"), VString("number"))
  should.equal(field(count, "minimum"), VInt(1))
  should.equal(field(count, "maximum"), VInt(10))
  should.equal(field(count, "default"), VInt(3))
  let weather = find_tool(descriptors, "get-structured-content")
  let output = weather.output_schema |> should.be_some
  should.equal(field(output, "additionalProperties"), VBool(False))
  should.equal(
    field(output, "required"),
    VArray([VString("temperature"), VString("conditions"), VString("humidity")]),
  )
  let caps = actions.ClientCapabilities(None, None, None, None, None)
  should.be_false(tools.is_available("trigger-sampling-request", caps))
  should.be_false(tools.is_available("trigger-elicitation-request", caps))
  should.be_false(tools.is_available("trigger-url-elicitation", caps))
  should.be_true(tools.is_available("echo", caps))
  let url_only =
    actions.ClientCapabilities(
      ..caps,
      elicitation: Some(actions.ClientElicitationCapabilities(
        None,
        Some(VObject([])),
      )),
    )
  should.be_true(tools.is_available("trigger-elicitation-request", url_only))
  should.be_true(tools.is_available("trigger-url-elicitation", url_only))
  let sampling =
    actions.ClientCapabilities(
      ..caps,
      sampling: Some(actions.ClientSamplingCapabilities(None, None)),
    )
  should.be_true(tools.is_available("trigger-sampling-request", sampling))
  url_elicitation.close(store)
}

pub fn reference_weather_text_structured_content_and_validation_test() {
  let app = base_server()
  let result =
    call(app, "get-structured-content", [#("location", VString("Chicago"))])
  should.equal(
    result.structured_content,
    Some(
      VObject([
        #("temperature", VInt(36)),
        #("conditions", VString("Light rain / drizzle")),
        #("humidity", VInt(82)),
      ]),
    ),
  )
  should.equal(
    text_at(result, 0),
    "{\"temperature\":36,\"conditions\":\"Light rain / drizzle\",\"humidity\":82}",
  )
  should.equal(result.is_error, None)
  let invalid =
    call(app, "get-structured-content", [#("location", VString("London"))])
  should.equal(invalid.is_error, Some(True))
  should.equal(invalid.structured_content, None)
  let invalid = call(app, "echo", [#("message", VNull)])
  should.equal(invalid.is_error, Some(True))
  should.equal(
    text_at(call(app, "get-sum", [#("a", VFloat(1.5)), #("b", VInt(2))]), 0),
    "The sum of 1.5 and 2 is 3.5.",
  )
}

pub fn resource_links_number_boundaries_and_reference_defaults_test() {
  let app = base_server()
  let result = call(app, "get-resource-links", [])
  should.equal(list.length(result.content), 4)
  should.equal(
    text_at(result, 0),
    "Here are 3 resource links to resources available in this server:",
  )
  let assert [
    _,
    actions.ResourceLinkBlock(actions.ResourceLink(first)),
    actions.ResourceLinkBlock(actions.ResourceLink(second)),
    _,
  ] = result.content
  should.equal(first.name, "Blob Resource 1")
  should.equal(first.uri, "demo://resource/dynamic/blob/1")
  should.equal(first.mime_type, Some("text/plain"))
  should.equal(first.description, Some("Resource 1: plaintext resource"))
  should.equal(second.name, "Text Resource 2")
  should.equal(second.uri, "demo://resource/dynamic/text/2")
  let fractional = call(app, "get-resource-links", [#("count", VFloat(2.5))])
  should.equal(list.length(fractional.content), 3)
  should.equal(
    text_at(fractional, 0),
    "Here are 2.5 resource links to resources available in this server:",
  )
  should.equal(
    call(app, "get-resource-links", [#("count", VInt(11))]).is_error,
    Some(True),
  )
  let reference = call(app, "get-resource-reference", [])
  let assert [
    _,
    actions.EmbeddedResourceBlock(actions.EmbeddedResource(
      actions.TextResourceContents(uri, mime, text, _),
      _,
      _,
    )),
    _,
  ] = reference.content
  should.equal(uri, "demo://resource/dynamic/text/1")
  should.equal(mime, Some("text/plain"))
  should.be_true(string.starts_with(
    text,
    "Resource 1: This is a plaintext resource created at ",
  ))
  should.equal(
    text_at(reference, 0),
    "Returning resource reference for Resource 1:",
  )
  should.equal(
    text_at(reference, 2),
    "You can access this resource using the URI: demo://resource/dynamic/text/1",
  )
  should.equal(
    call(app, "get-resource-reference", [#("resourceId", VFloat(1.5))]).is_error,
    Some(True),
  )
  should.equal(
    call(app, "get-resource-reference", [#("resourceType", VString("text"))]).is_error,
    Some(True),
  )
}

pub fn image_and_content_annotations_match_reference_test() {
  let app = base_server()
  let result = call(app, "get-tiny-image", [])
  should.equal(text_at(result, 0), "Here's the image you requested:")
  should.equal(text_at(result, 2), "The image above is the MCP logo.")
  let assert [_, actions.ImageBlock(image), _] = result.content
  should.equal(image.mime_type, "image/png")
  let image_bytes = bit_array.base64_decode(image.data) |> should.be_ok
  // PNG IHDR dimensions from the actual upstream logo, rather than a 1x1 placeholder.
  let assert <<_:size(16)-bytes, width:32-big, height:32-big, _:bits>> =
    image_bytes
  should.equal(#(width, height), #(20, 20))
  let annotated =
    call(app, "get-annotated-message", [
      #("messageType", VString("debug")),
      #("includeImage", VBool(True)),
    ])
  let assert [actions.TextBlock(text), actions.ImageBlock(image)] =
    annotated.content
  should.equal(text.text, "Debug: Cache hit ratio 0.95, latency 150ms")
  should.equal(
    text.annotations,
    Some(actions.Annotations([actions.Assistant], Some(0.3), None)),
  )
  should.equal(
    image.annotations,
    Some(actions.Annotations([actions.User], Some(0.5), None)),
  )
  should.equal(image.data, tools.tiny_png)
  should.equal(
    call(app, "get-annotated-message", [
      #("messageType", VString("debug")),
      #("includeImage", VString("true")),
    ]).is_error,
    Some(True),
  )
}

pub fn sampling_request_and_full_result_payload_match_reference_test() {
  tools.sampling_request(None) |> should.be_error
  let params =
    tools.sampling_request(
      Some(dict.from_list([#("prompt", VString("Tell a story"))])),
    )
    |> should.be_ok
  should.equal(params.max_tokens, 100)
  should.equal(params.temperature, Some(0.7))
  should.equal(params.system_prompt, Some("You are a helpful test server."))
  should.equal(params.messages, [
    actions.SamplingMessage(
      actions.User,
      actions.SingleSamplingContent(
        actions.SamplingText(actions.TextContent(
          "Resource trigger-sampling-request context: Tell a story",
          None,
          None,
        )),
      ),
      None,
    ),
  ])
  let meta =
    Some(actions.Meta(dict.from_list([#("trace", VString("preserved"))])))
  let result =
    actions.CreateMessageResult(
      actions.SamplingMessage(
        actions.Assistant,
        actions.MultipleSamplingContent([
          actions.SamplingText(actions.TextContent("story", None, meta)),
          actions.SamplingImage(actions.ImageContent(
            "AA==",
            "image/png",
            None,
            None,
          )),
        ]),
        None,
      ),
      "test-model",
      Some("endTurn"),
      meta,
    )
  let rendered = interaction_results.sampling_tool_result(result)
  let text = text_at(rendered, 0)
  let assert ["", json_text] = string.split(text, "LLM sampling result: \n")
  let decoded =
    json.parse(json_text, codec_decode.value_decoder()) |> should.be_ok
  should.equal(field(decoded, "model"), VString("test-model"))
  should.equal(field(decoded, "stopReason"), VString("endTurn"))
  should.equal(field(decoded, "_meta") |> field("trace"), VString("preserved"))
  let assert VArray([text, image]) = field(decoded, "content")
  should.equal(field(text, "_meta") |> field("trace"), VString("preserved"))
  should.equal(field(image, "type"), VString("image"))
  should.equal(field(image, "data"), VString("AA=="))
  should.equal(rendered.is_error, None)
}

pub fn form_schema_includes_all_enum_variants_and_formats_test() {
  let assert actions.ElicitRequestForm(params) = tools.elicitation_request()
  should.equal(
    params.message,
    "Please provide inputs for the following fields:",
  )
  should.equal(params.requested_schema, form_schema.requested_schema())
  let properties = field(params.requested_schema, "properties")
  let assert VObject(fields) = properties
  should.equal(list.length(fields), 13)
  should.equal(
    field(params.requested_schema, "required"),
    VArray([VString("name")]),
  )
  should.equal(
    properties |> field("firstLine") |> field("default"),
    VString("It was a dark and stormy night."),
  )
  should.equal(
    properties |> field("email") |> field("format"),
    VString("email"),
  )
  should.equal(
    properties |> field("homepage") |> field("format"),
    VString("uri"),
  )
  should.equal(
    properties |> field("birthdate") |> field("format"),
    VString("date"),
  )
  should.equal(properties |> field("integer") |> field("default"), VInt(42))
  should.equal(properties |> field("number") |> field("minimum"), VInt(0))
  should.equal(
    properties |> field("untitledMultipleSelectEnum") |> field("maxItems"),
    VInt(3),
  )
  should.equal(
    properties |> field("titledSingleSelectEnum") |> field("default"),
    VString("hero-1"),
  )
  should.equal(
    properties |> field("titledMultipleSelectEnum") |> field("default"),
    VArray([VString("fish-1")]),
  )
  should.equal(
    properties |> field("legacyTitledEnum") |> field("enumNames"),
    VArray([
      VString("Cats"),
      VString("Dogs"),
      VString("Birds"),
      VString("Fish"),
      VString("Reptiles"),
    ]),
  )
}

pub fn form_and_url_results_preserve_false_zero_arrays_and_metadata_test() {
  let meta =
    Some(actions.Meta(dict.from_list([#("trace", VString("preserved"))])))
  let accepted =
    actions.ElicitResult(
      actions.ElicitAccept,
      Some(
        dict.from_list([
          #("name", actions.ElicitString("Ada")),
          #("check", actions.ElicitBool(False)),
          #("integer", actions.ElicitInt(0)),
          #("number", actions.ElicitFloat(0.0)),
          #(
            "titledMultipleSelectEnum",
            actions.ElicitStringArray(["fish-1", "fish-2"]),
          ),
        ]),
      ),
      meta,
    )
  let rendered = interaction_results.elicitation_tool_result(accepted)
  should.equal(
    text_at(rendered, 0),
    "✅ User provided the requested information!",
  )
  should.equal(
    text_at(rendered, 1),
    "User inputs:\n- Name: Ada\n- Agreed to terms: false\n- Favorite Integer: 0\n- Favorite Number: 0",
  )
  let raw = interaction_results.elicitation_result_value(accepted)
  should.equal(field(raw, "_meta") |> field("trace"), VString("preserved"))
  should.equal(
    field(raw, "content") |> field("titledMultipleSelectEnum"),
    VArray([VString("fish-1"), VString("fish-2")]),
  )
  should.be_true(string.starts_with(text_at(rendered, 2), "\nRaw result: {\n"))
  let declined = actions.ElicitResult(actions.ElicitDecline, None, meta)
  let rendered = interaction_results.elicitation_tool_result(declined)
  should.equal(list.length(rendered.content), 2)
  should.equal(
    text_at(rendered, 0),
    "❌ User declined to provide the requested information.",
  )
  let url =
    interaction_results.url_tool_result(
      accepted,
      "request-id",
      "https://example.test/consent",
    )
  should.equal(
    text_at(url, 0),
    "✅ User completed the URL elicitation flow.\nElicitation ID: request-id\nURL: https://example.test/consent",
  )
  should.equal(url.is_error, None)
}

pub fn url_elicitation_prerequisite_retry_is_one_shot_and_session_scoped_test() {
  let store = url_elicitation.new()
  let alice = server.RequestContext(Some("alice"), None)
  let bob = server.RequestContext(Some("bob"), None)
  let arguments =
    Some(
      dict.from_list([
        #("url", VString("https://example.test/consent")),
        #("errorPath", VBool(True)),
      ]),
    )
  let error =
    url_elicitation.prepare(store, alice, arguments) |> should.be_error
  should.equal(error.code, -32_042)
  should.equal(
    error.message,
    "MCP error -32042: This request requires browser-based authorization.",
  )
  let assert VArray([prerequisite]) =
    error.data |> should.be_some |> field("elicitations")
  should.equal(
    field(prerequisite, "url"),
    VString("https://modelcontextprotocol.io"),
  )
  should.equal(field(prerequisite, "mode"), VString("url"))
  let assert VString(id) = field(prerequisite, "elicitationId")
  should.equal(string.length(id), 36)
  let retry = url_elicitation.prepare(store, alice, arguments) |> should.be_ok
  let assert actions.ElicitRequestUrlParams(message, id, url, _, _) = retry
  should.equal(message, "Please open the link to complete this action.")
  should.equal(url, "https://example.test/consent")
  should.equal(string.length(id), 36)
  url_elicitation.prepare(store, alice, arguments) |> should.be_error
  url_elicitation.prepare(store, bob, arguments) |> should.be_error
  url_elicitation.clear_session(store, "alice")
  url_elicitation.prepare(store, alice, arguments) |> should.be_error
  url_elicitation.prepare(store, bob, arguments) |> should.be_ok
  url_elicitation.prepare(
    store,
    alice,
    Some(dict.from_list([#("url", VString("not a URL"))])),
  )
  |> should.be_error
  url_elicitation.close(store)
}

pub fn pretty_json_uses_reference_indentation_escaping_and_numeric_text_test() {
  should.equal(
    helpers.pretty_json(
      VObject([
        #("quoted\"key", VArray([VFloat(1.0), VNull, VString("line\nnext")])),
      ]),
    ),
    "{\n  \"quoted\\\"key\": [\n    1,\n    null,\n    \"line\\nnext\"\n  ]\n}",
  )
}

fn base_server() -> server.Server {
  server.new(server_test_support.sample_client_info())
  |> tools.register_base_tools(None)
}

fn listed_tools(app: server.Server) -> List(actions.Tool) {
  let #(_, response) =
    server.handle_request(
      app,
      jsonrpc.Request(
        jsonrpc.StringId("list"),
        "tools/list",
        Some(
          actions.ClientRequestListTools(actions.PaginatedRequestParams(
            None,
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultListTools(result)) =
    response
  result.tools
}

fn find_tool(descriptors: List(actions.Tool), name: String) -> actions.Tool {
  list.find(descriptors, fn(tool) { tool.name == name }) |> should.be_ok
}

fn call(
  app: server.Server,
  name: String,
  arguments: List(#(String, Value)),
) -> actions.CallToolResult {
  let assert Ok(actions.ClientResultCallTool(result)) =
    server.dispatch_registered_tool(
      app,
      server.RequestContext(None, None),
      actions.CallToolRequestParams(
        name,
        Some(dict.from_list(arguments)),
        None,
        None,
      ),
    )
  result
}

fn field(value: Value, name: String) -> Value {
  let assert VObject(fields) = value
  dict.get(dict.from_list(fields), name) |> should.be_ok
}

fn text_at(result: actions.CallToolResult, index: Int) -> String {
  let assert actions.TextBlock(text) =
    result.content |> list.drop(index) |> list.first |> should.be_ok
  text.text
}
