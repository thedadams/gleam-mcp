import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/compression
import gleam_mcp/examples/everything/documents
import gleam_mcp/examples/everything/fetch
import gleam_mcp/examples/everything/prompts
import gleam_mcp/examples/everything/resources
import gleam_mcp/examples/everything/session_resources
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleeunit/should
import mist
import server_test_support

pub fn reference_documents_and_dynamic_resources_test() {
  let app =
    server.new(server_test_support.sample_client_info())
    |> resources.register_resources
  let listed =
    send(
      app,
      actions.ClientRequestListResources(actions.PaginatedRequestParams(
        None,
        None,
      )),
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListResources(result),
  ) = listed
  should.equal(list.length(result.resources), 7)
  list.each(documents.all(), fn(document) {
    let #(name, text) = document
    let response = read(app, "demo://resource/static/document/" <> name)
    let assert jsonrpc.ResultResponse(
      _,
      actions.ClientResultReadResource(actions.ReadResourceResult(
        [actions.TextResourceContents(uri, mime, actual, _)],
        _,
      )),
    ) = response
    should.equal(uri, "demo://resource/static/document/" <> name)
    should.equal(mime, Some("text/markdown"))
    should.equal(actual, text)
  })
  let response = read(app, "demo://resource/dynamic/text/123")
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.TextResourceContents(uri, mime, text, _)],
      _,
    )),
  ) = response
  should.equal(uri, "demo://resource/dynamic/text/123")
  should.equal(mime, Some("text/plain"))
  should.be_true(string.starts_with(
    text,
    "Resource 123: This is a plaintext resource created at ",
  ))
  let response = read(app, "demo://resource/dynamic/blob/123")
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.BlobResourceContents(_, mime, blob, _)],
      _,
    )),
  ) = response
  should.equal(mime, Some("text/plain"))
  let text =
    blob
    |> bit_array.base64_decode
    |> should.be_ok
    |> bit_array.to_string
    |> should.be_ok
  should.be_true(string.starts_with(
    text,
    "Resource 123: This is a base64 blob created at ",
  ))
}

pub fn reference_prompt_messages_and_completion_context_test() {
  let app =
    server.new(server_test_support.sample_client_info())
    |> prompts.register_prompts
  let prompt =
    get_prompt(app, "args-prompt", [#("city", "Portland"), #("state", "")])
  should.equal(prompt.messages, [
    actions.PromptMessage(
      actions.User,
      actions.TextBlock(actions.TextContent(
        "What's weather in Portland?",
        None,
        None,
      )),
    ),
  ])
  let prompt =
    get_prompt(app, "completable-prompt", [
      #("department", "Sales"),
      #("name", "Eve"),
    ])
  should.equal(prompt.messages, [
    actions.PromptMessage(
      actions.User,
      actions.TextBlock(actions.TextContent(
        "Please promote Eve to the head of the Sales team.",
        None,
        None,
      )),
    ),
  ])
  let prompt =
    get_prompt(app, "resource-prompt", [
      #("resourceType", "Blob"),
      #("resourceId", "2"),
    ])
  let assert [
    actions.PromptMessage(actions.User, _),
    actions.PromptMessage(actions.User, actions.EmbeddedResourceBlock(_)),
  ] = prompt.messages
  should.equal(complete("completable-prompt", "department", "", None), [
    "Engineering",
    "Sales",
    "Marketing",
    "Support",
  ])
  should.equal(
    complete("completable-prompt", "department", "engineering", None),
    [],
  )
  should.equal(
    complete(
      "completable-prompt",
      "name",
      "",
      Some(
        actions.CompleteContext(
          Some(dict.from_list([#("department", "Support")])),
        ),
      ),
    ),
    ["John", "Kim", "Lee"],
  )
  should.equal(complete("completable-prompt", "name", "", None), [])
  should.equal(complete("resource-prompt", "resourceId", "123", None), ["123"])
  should.equal(complete("resource-prompt", "resourceId", "1e3", None), ["1e3"])
  should.equal(complete("resource-prompt", "resourceId", "0x10", None), ["0x10"])
  should.equal(complete("resource-prompt", "resourceId", "1.5", None), [])
  should.equal(complete("resource-prompt", "resourceType", "b", None), [])
}

pub fn gzip_matches_external_known_payload_and_fetch_limits_test() {
  let bytes = compression.gzip(<<"hello":utf8>>) |> should.be_ok
  should.equal(
    bit_array.base64_encode(bytes, True),
    "H4sIAAAAAAAAA8tIzcnJBwCGphA2BQAAAA==",
  )
  let limits = fetch.Limits(5, 100, ["example.test"])
  should.equal(fetch.get("data:text/plain,hello", limits), Ok(<<"hello":utf8>>))
  should.equal(
    fetch.get("DATA:text/plain,hi?x#ignored", limits),
    Ok(<<"hi?x":utf8>>),
  )
  should.equal(
    fetch.get("data:application/octet-stream;base64,AP8=", limits),
    Ok(<<0, 255>>),
  )
  should.equal(
    fetch.get("data:application/octet-stream,%00%ff%80", limits),
    Ok(<<0, 255, 128>>),
  )
  should.equal(fetch.get("data:,a%4%41", limits), Ok(<<"a%4A":utf8>>))
  should.equal(fetch.get("data:,a%+1", limits), Ok(<<"a%+1":utf8>>))
  fetch.get("data:text/plain,too%20long", limits) |> should.be_error
  fetch.get("file:///etc/passwd", limits) |> should.be_error
  fetch.validate_url("https://sub.example.test/file", limits) |> should.be_ok
  fetch.validate_url("https://otherexample.test/file", limits)
  |> should.be_error
}

pub fn legacy_generated_resource_names_preserve_spaces_test() {
  let store = session_resources.new(session_resources.StreamableHttp)
  let context = server.RequestContext(Some("legacy"), None)
  let resource =
    session_resources.put_blob(store, context, "space name.gz", "blob")
  should.equal(resource.uri, "demo://resource/session/space name.gz")
  let app =
    session_resources.projection(store)(
      server.new(server_test_support.sample_client_info()),
      context,
    )
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.BlobResourceContents(uri, _, "blob", _)],
      _,
    )),
  ) = read(app, resource.uri)
  should.equal(uri, resource.uri)
  session_resources.stop(store)
}

pub fn gzip_resources_are_scoped_and_removed_with_session_test() {
  let store = session_resources.new(session_resources.StreamableHttp)
  let base = server.new(server_test_support.sample_client_info())
  let alice = server.RequestContext(Some("alice"), None)
  let bob = server.RequestContext(Some("bob"), None)
  let params =
    Some(
      dict.from_list([
        #("data", jsonrpc.VString("data:text/plain,hello")),
        #("name", jsonrpc.VString("hello.gz")),
      ]),
    )
  let outcome =
    compression.run(store, alice, params, fetch.Limits(100, 100, []))
    |> should.be_ok
  let assert [actions.ResourceLinkBlock(actions.ResourceLink(link))] =
    outcome.content
  should.equal(link.uri, "demo://resource/session/hello.gz")
  let project = session_resources.projection(store)
  let app = project(base, alice)
  let response = read(app, link.uri)
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.BlobResourceContents(_, Some("application/gzip"), blob, _)],
      _,
    )),
  ) = response
  should.equal(blob, "H4sIAAAAAAAAA8tIzcnJBwCGphA2BQAAAA==")
  let bob_app = project(base, bob)
  let assert jsonrpc.ErrorResponse(_, _) = read(bob_app, link.uri)
  session_resources.close_session(store, "alice")
  let assert jsonrpc.ErrorResponse(_, _) = read(project(base, alice), link.uri)
  session_resources.stop(store)
}

pub fn anonymous_modern_gzip_links_are_opaque_and_not_listed_test() {
  let store = session_resources.new(session_resources.StreamableHttp)
  let base = server.new(server_test_support.sample_client_info())
  let first = server.modern_request_context(None, "first request", None)
  let next = server.modern_request_context(None, "next request", None)
  let first_link = session_resources.put_blob(store, first, "same.gz", "first")
  let next_link = session_resources.put_blob(store, next, "same.gz", "next")
  should.be_true(first_link.uri != next_link.uri)
  let project = session_resources.projection(store)
  let app = project(base, next)
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultListResources(listed),
  ) =
    send(
      app,
      actions.ClientRequestListResources(actions.PaginatedRequestParams(
        None,
        None,
      )),
    )
  should.equal(listed.resources, [])
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.BlobResourceContents(_, _, "first", _)],
      _,
    )),
  ) = read(app, first_link.uri)
  let assert jsonrpc.ErrorResponse(_, _) =
    read(app, "demo://resource/session/guessed/same.gz")
  session_resources.stop(store)
}

pub fn modern_stdio_and_authenticated_resource_scopes_test() {
  let base = server.new(server_test_support.sample_client_info())
  let stdio = session_resources.new(session_resources.Stdio)
  let first = server.modern_request_context(None, "stdio-one", None)
  let other = server.modern_request_context(None, "stdio-two", None)
  let link = session_resources.put_blob(stdio, first, "same.gz", "first")
  let project = session_resources.projection(stdio)
  let assert jsonrpc.ResultResponse(_, _) = read(project(base, first), link.uri)
  let assert jsonrpc.ErrorResponse(_, _) = read(project(base, other), link.uri)
  let _ = session_resources.put_blob(stdio, first, "same.gz", "replacement")
  let assert jsonrpc.ResultResponse(
    _,
    actions.ClientResultReadResource(actions.ReadResourceResult(
      [actions.BlobResourceContents(_, _, "replacement", _)],
      _,
    )),
  ) = read(project(base, first), link.uri)
  session_resources.close_session(stdio, "stdio-one")
  let assert jsonrpc.ErrorResponse(_, _) = read(project(base, first), link.uri)
  session_resources.stop(stdio)

  let http = session_resources.new(session_resources.StreamableHttp)
  let alice = server.modern_request_context(Some("alice"), "one", None)
  let alice_next = server.modern_request_context(Some("alice"), "two", None)
  let bob = server.modern_request_context(Some("bob"), "three", None)
  let link = session_resources.put_blob(http, alice, "same.gz", "alice")
  let project = session_resources.projection(http)
  let assert jsonrpc.ResultResponse(_, _) =
    read(project(base, alice_next), link.uri)
  let assert jsonrpc.ErrorResponse(_, _) = read(project(base, bob), link.uri)
  session_resources.stop(http)
}

pub fn http_fetch_counts_chunked_bytes_and_bounds_response_time_test() {
  let #(url, service) =
    start_fetch_server(fn(req) {
      case req.path {
        "/redirect" ->
          response.new(302)
          |> response.set_header("location", "/ok")
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        "/slow" -> chunks(req, [<<"late":utf8>>], 1000)
        "/too-large" -> chunks(req, [<<"abc":utf8>>, <<"def":utf8>>], 10)
        _ -> chunks(req, [<<"hello":utf8>>], 10)
      }
    })
  let limits = fetch.Limits(5, 1000, ["127.0.0.1"])
  should.equal(fetch.get(url <> "/redirect", limits), Ok(<<"hello":utf8>>))
  let error = fetch.get(url <> "/too-large", limits) |> should.be_error
  should.be_true(string.contains(error, "exceeds 5 bytes"))
  fetch.get(url <> "/slow", fetch.Limits(5, 100, ["127.0.0.1"]))
  |> should.be_error
  process.kill(service)
}

type ChunkMessage {
  Send
}

fn chunks(
  req: request.Request(mist.Connection),
  values: List(BitArray),
  delay: Int,
) -> response.Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200),
    fn(subject) {
      let _ = process.send_after(subject, delay, Send)
      #(subject, values)
    },
    fn(state, _, connection) {
      let #(subject, values) = state
      case values {
        [] -> mist.chunk_stop()
        [value, ..rest] ->
          case mist.send_chunk(connection, value) {
            Error(_) -> mist.chunk_stop()
            Ok(_) -> {
              let _ = process.send_after(subject, delay, Send)
              mist.chunk_continue(#(subject, rest))
            }
          }
      }
    },
  )
}

fn start_fetch_server(
  handler: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
) -> #(String, process.Pid) {
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let port = process.new_subject()
      let assert Ok(service) =
        mist.new(handler)
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(actual, _, _) { process.send(port, actual) })
        |> mist.start
      process.unlink(service.pid)
      let port = process.receive(port, 1000) |> should.be_ok
      process.send(ready, #(
        "http://127.0.0.1:" <> int.to_string(port),
        service.pid,
      ))
    })
  process.receive(ready, 1000) |> should.be_ok
}

fn complete(
  name: String,
  argument: String,
  value: String,
  context,
) -> List(String) {
  let result =
    prompts.completion_handler(actions.CompleteRequestParams(
      actions.PromptRef(name, None),
      actions.CompleteArgument(argument, value),
      context,
      None,
    ))
    |> should.be_ok
  result.completion.values
}

fn get_prompt(
  app: server.Server,
  name: String,
  arguments: List(#(String, String)),
) -> actions.GetPromptResult {
  let assert jsonrpc.ResultResponse(_, actions.ClientResultGetPrompt(prompt)) =
    send(
      app,
      actions.ClientRequestGetPrompt(actions.GetPromptRequestParams(
        name,
        Some(dict.from_list(arguments)),
        None,
      )),
    )
  prompt
}

fn read(
  app: server.Server,
  uri: String,
) -> jsonrpc.Response(actions.ClientActionResult) {
  send(
    app,
    actions.ClientRequestReadResource(actions.ReadResourceRequestParams(
      uri,
      None,
    )),
  )
}

fn send(
  app: server.Server,
  action: actions.ClientActionRequest,
) -> jsonrpc.Response(actions.ClientActionResult) {
  let #(_, response) =
    server.handle_request(
      app,
      jsonrpc.Request(jsonrpc.StringId("test"), "test", Some(action)),
    )
  response
}
