import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/examples/example_server
import gleam_mcp/jsonrpc.{type Value, VArray, VObject, VString}
import gleam_mcp/server
import gleam_mcp/task_store
import gleeunit/should
import server_test_support

pub fn modern_http_tasks_poll_submit_input_and_enforce_owner_test() {
  let app =
    example_server.sample_server()
    |> server.with_identity_authorization("x-user", Some)
    |> server.with_extensions(
      dict.from_list([#("io.modelcontextprotocol/tasks", VObject([]))]),
    )
    |> server.with_modern_request_handler(fn(app, context, _) {
      server.create_modern_task(app, context, Some(60_000), fn() {
        Ok(
          task_store.ModernInputRequired(
            dict.from_list([
              #(
                "roots",
                VObject([
                  #("method", VString("roots/list")),
                  #("params", VObject([])),
                ]),
              ),
            ]),
            fn(input) {
              should.equal(
                dict.get(input, "roots"),
                Ok(VObject([#("roots", VArray([]))])),
              )
              Ok(
                task_store.ModernComplete(
                  VObject([
                    #("resultType", VString("complete")),
                    #("content", VArray([])),
                  ]),
                ),
              )
            },
          ),
        )
      })
    })
  let url = server_test_support.start_http_server_with_server(app)
  let caps =
    capabilities.none() |> capabilities.with_list_roots(fn(_) { Ok([]) })
  let alice =
    client.new(
      transport.Http(transport.HttpConfig(
        url,
        [#("x-user", "alice")],
        Some(5000),
      )),
      caps,
    )
    |> client.with_tasks_extension
  let #(alice, _) =
    client.connect(alice, server_test_support.sample_client_info())
    |> should.be_ok
  let #(alice, called) =
    client.call_tool(
      alice,
      actions.CallToolRequestParams("echo", None, None, None),
    )
  let assert actions.CallToolTaskModern(task) = called |> should.be_ok
  let assert VString(id) = field(task, "taskId")
  let #(alice, waiting) = wait_status(alice, id, "input_required", 50)
  let assert VObject(_) = field(waiting, "inputRequests")
  let #(alice, updated) =
    client.update_task(
      alice,
      id,
      dict.from_list([#("roots", VObject([#("roots", VArray([]))]))]),
    )
  updated |> should.be_ok
  let #(alice, completed) = wait_status(alice, id, "completed", 50)
  should.equal(
    field(field(completed, "result"), "resultType"),
    VString("complete"),
  )
  let bob =
    client.new(
      transport.Http(transport.HttpConfig(url, [#("x-user", "bob")], Some(5000))),
      caps,
    )
    |> client.with_tasks_extension
  let #(bob, _) =
    client.connect(bob, server_test_support.sample_client_info())
    |> should.be_ok
  let #(bob, inaccessible) = client.get_task_modern(bob, id)
  inaccessible |> should.be_error
  let #(_, closed) = client.close(bob)
  closed |> should.be_ok
  let #(_, closed) = client.close(alice)
  closed |> should.be_ok
}

fn wait_status(
  app: client.Client,
  id: String,
  status: String,
  remaining: Int,
) -> #(client.Client, Value) {
  let #(app, result) = client.get_task_modern(app, id)
  let value = result |> should.be_ok
  case field(value, "status") == VString(status) {
    True -> #(app, value)
    False -> {
      should.be_true(remaining > 0)
      process.sleep(10)
      wait_status(app, id, status, remaining - 1)
    }
  }
}

fn field(value: Value, key: String) -> Value {
  let assert VObject(fields) = value
  dict.from_list(fields) |> dict.get(key) |> should.be_ok
}
