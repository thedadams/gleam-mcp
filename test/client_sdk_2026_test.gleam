import envoy
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc
import gleeunit/should

pub fn official_2026_http_discovery_headers_scalar_results_and_mrtr_test() {
  case envoy.get("MCP_2026_URL") {
    Ok(url) ->
      exercise(transport.Http(transport.HttpConfig(url, [], Some(5000))))
    Error(_) -> Nil
  }
}

pub fn official_2026_stdio_discovery_scalar_results_and_mrtr_test() {
  case envoy.get("MCP_2026_STDIO_COMMAND") {
    Ok(command) -> {
      let args =
        envoy.get("MCP_2026_STDIO_ARGS")
        |> fn(value) {
          case value {
            Ok(value) ->
              string.split(value, " ") |> list.filter(fn(arg) { arg != "" })
            Error(_) -> []
          }
        }
      exercise(
        transport.Stdio(transport.StdioConfig(
          command,
          args,
          [],
          None,
          Some(5000),
        )),
      )
    }
    Error(_) -> Nil
  }
}

fn exercise(config: transport.Config) {
  let confirmed = process.new_subject()
  let acknowledged = process.new_subject()
  let changed = process.new_subject()
  let caps =
    capabilities.none()
    |> capabilities.with_elicit_form(fn(_) {
      process.send(confirmed, Nil)
      Ok(
        capabilities.Elicit(actions.ElicitResult(
          actions.ElicitAccept,
          Some(dict.from_list([#("confirm", actions.ElicitBool(True))])),
          None,
        )),
      )
    })
    |> capabilities.with_subscription_acknowledged(fn(_) {
      process.send(acknowledged, Nil)
      Ok(Nil)
    })
    |> capabilities.with_notify_tool_list_changed(fn() {
      process.send(changed, Nil)
      Ok(Nil)
    })
  let app = client.new(config, caps)
  let info =
    actions.Implementation(
      "gleam-modern-interop",
      "1.0.0",
      None,
      None,
      None,
      [],
    )
  let #(app, connected) = client.connect(app, info) |> should.be_ok
  case connected {
    client.Modern(discovery) ->
      should.be_true(list.contains(
        discovery.supported_versions,
        jsonrpc.latest_protocol_version,
      ))
    _ -> should.fail()
  }
  let #(app, tools) = client.list_tools(app, None)
  let tools = tools |> should.be_ok
  should.be_true(list.any(tools.tools, fn(tool) { tool.name == "echo" }))
  let message = "Hello, 世界"
  let #(app, echoed) =
    client.call_tool(
      app,
      actions.CallToolRequestParams(
        "echo",
        Some(dict.from_list([#("message", jsonrpc.VString(message))])),
        None,
        None,
      ),
    )
  let assert actions.CallTool(result) = echoed |> should.be_ok
  should.equal(result.structured_content, Some(jsonrpc.VString(message)))
  let #(app, echoed) =
    client.call_tool(
      app,
      actions.CallToolRequestParams(
        "confirm",
        Some(dict.from_list([#("message", jsonrpc.VString("accepted"))])),
        None,
        None,
      ),
    )
  let assert actions.CallTool(result) = echoed |> should.be_ok
  should.equal(result.content, [
    actions.TextBlock(actions.TextContent("accepted", None, None)),
  ])
  process.receive(confirmed, 0) |> should.be_ok
  let listening = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() { process.send(listening, client.listen(app)) })
  process.receive(acknowledged, 5000) |> should.be_ok
  let #(app, invoked) =
    client.call_tool(
      app,
      actions.CallToolRequestParams("change_notification", None, None, None),
    )
  invoked |> should.be_ok
  process.receive(changed, 5000) |> should.be_ok
  let #(_, closed) = client.close(app)
  closed |> should.be_ok
  let #(_, outcome) = process.receive(listening, 1000) |> should.be_ok
  outcome |> should.be_ok
}
