import conformance/server_tasks
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/jsonrpc.{VBool, VInt, VObject, VString}
import gleam_mcp/server
import gleeunit/should

pub fn required_task_capability_is_checked_before_custom_handler_test() {
  let called = process.new_subject()
  let app =
    server.new(actions.Implementation("required", "1", None, None, None, []))
    |> server.add_tool_with_execution(
      "required",
      "required",
      VObject([#("type", VString("object"))]),
      actions.TaskRequired,
      fn(_) {
        process.send(called, Nil)
        Ok(actions.CallToolResult([], None, None, None))
      },
    )
    |> server.with_modern_request_handler(fn(_, _, _) {
      process.send(called, Nil)
      Ok(
        actions.ClientResultCallTool(actions.CallToolResult(
          [],
          None,
          None,
          None,
        )),
      )
    })
  let response = call(app, "required", [], False)
  let assert jsonrpc.ErrorResponse(_, error) = response
  should.equal(error.code, -32_021)
  should.equal(
    error.data,
    Some(
      VObject([
        #(
          "requiredCapabilities",
          VObject([
            #(
              "extensions",
              VObject([#("io.modelcontextprotocol/tasks", VObject([]))]),
            ),
          ]),
        ),
      ]),
    ),
  )
  should.equal(process.receive(called, 10), Error(Nil))
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCallTool(_)) =
    call(app, "required", [], True)
  should.equal(process.receive(called, 1000), Ok(Nil))
}

pub fn task_fixture_dispatch_preserves_sync_and_server_directed_creation_test() {
  let app = app()
  let request =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "greet",
      Some(dict.from_list([#("name", VString("World"))])),
      Some(actions.TaskMetadata(Some(60_000))),
      meta(True),
    ))
  let assert actions.ClientResultCallTool(greeting) =
    invoke(app, "tools/call", request) |> success
  let assert [actions.TextBlock(text)] = greeting.content
  should.equal(text.text, "Hello, World!")
  let assert actions.ClientResultCallTool(_) =
    call(app, "slow_compute", [#("seconds", VInt(0))], False) |> success
  let created = call(app, "slow_compute", [#("seconds", VInt(0))], True) |> task
  let id = task_id(created)
  should.equal(dict.get(created, "resultType"), Ok(VString("task")))
  should.be_false(dict.has_key(created, "task"))
  should.be_false(dict.has_key(created, "requestState"))
  should.be_false(dict.has_key(created, "ttl"))
  should.be_false(dict.has_key(created, "pollInterval"))
  let assert Ok(VInt(ttl)) = dict.get(created, "ttlMs")
  should.be_true(ttl > 0)
  // Creation is acknowledged only after the store can resolve the ID.
  let immediate = get(app, id)
  should.equal(dict.get(immediate, "taskId"), Ok(VString(id)))
  let completed = poll(app, id, "completed", 200)
  let assert Ok(VObject(result)) = dict.get(completed, "result")
  should.equal(dict.get(dict.from_list(result), "isError"), Ok(VBool(False)))
  should.be_false(dict.has_key(completed, "requestState"))
  let assert actions.ClientResultEmpty(_) = cancel(app, id) |> success
  should.equal(dict.get(get(app, id), "status"), Ok(VString("completed")))
}

pub fn task_fixture_errors_and_cancellation_have_distinct_terminal_shapes_test() {
  let app = app()
  let failure = call(app, "failing_job", [], True) |> task |> task_id
  let failed_tool = poll(app, failure, "completed", 300)
  let assert Ok(VObject(result)) = dict.get(failed_tool, "result")
  should.equal(dict.get(dict.from_list(result), "isError"), Ok(VBool(True)))
  should.be_false(dict.has_key(failed_tool, "error"))
  let crash = call(app, "protocol_error_job", [], True) |> task |> task_id
  let failed_protocol = poll(app, crash, "failed", 200)
  let assert Ok(VObject(error)) = dict.get(failed_protocol, "error")
  let assert Ok(VInt(_)) = dict.get(dict.from_list(error), "code")
  should.be_false(dict.has_key(failed_protocol, "result"))
  let waiting =
    call(app, "slow_compute", [#("seconds", VInt(60))], True)
    |> task
    |> task_id
  let assert actions.ClientResultEmpty(_) = cancel(app, waiting) |> success
  let assert actions.ClientResultEmpty(_) = cancel(app, waiting) |> success
  should.equal(dict.get(get(app, waiting), "status"), Ok(VString("cancelled")))
}

pub fn task_fixture_partial_inputs_remain_pending_until_all_answers_test() {
  let app = app()
  let id = call(app, "multi_input", [], True) |> task |> task_id
  let waiting = poll(app, id, "input_required", 200)
  let assert Ok(VObject(pending)) = dict.get(waiting, "inputRequests")
  let assert [#(first, _), #(second, _)] = pending
  let answer =
    VObject([
      #("action", VString("accept")),
      #(
        "content",
        VObject([#("name", VString("Alice")), #("confirm", VBool(True))]),
      ),
    ])
  let assert actions.ClientResultEmpty(_) =
    update(app, id, [#(first, answer)]) |> success
  let waiting = get(app, id)
  should.equal(dict.get(waiting, "status"), Ok(VString("input_required")))
  let assert Ok(VObject(pending)) = dict.get(waiting, "inputRequests")
  should.equal(list.map(pending, fn(field) { field.0 }), [second])
  let assert actions.ClientResultEmpty(_) =
    update(app, id, [#("unknown", answer)]) |> success
  should.equal(dict.get(get(app, id), "inputRequests"), Ok(VObject(pending)))
  let assert actions.ClientResultEmpty(_) =
    update(app, id, [#(second, answer)]) |> success
  should.equal(
    dict.get(poll(app, id, "completed", 200), "status"),
    Ok(VString("completed")),
  )
}

pub fn task_fixture_mrtr_gathers_input_before_async_creation_test() {
  let app = app()
  let original =
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      "test_tool_with_task",
      Some(dict.new()),
      None,
      meta(True),
    ))
  let assert actions.ClientResultInputRequired(first) =
    invoke(app, "tools/call", original) |> success
  let assert Some(requests) = first.input_requests
  let assert [key] = dict.keys(requests)
  let response =
    VObject([
      #("action", VString("accept")),
      #("content", VObject([#("name", VString("Alice"))])),
    ])
  let retry =
    actions.ClientRequestWithInput(
      original,
      first.request_state,
      Some(dict.from_list([#(key, response)])),
    )
  let created = invoke(app, "tools/call", retry) |> task
  should.be_false(dict.has_key(created, "requestState"))
  should.be_false(dict.has_key(created, "inputRequests"))
  let completed = poll(app, task_id(created), "completed", 200)
  let assert Ok(VObject(result)) = dict.get(completed, "result")
  let assert Ok(jsonrpc.VArray([VObject(block)])) =
    dict.get(dict.from_list(result), "content")
  let assert Ok(VString(text)) = dict.get(dict.from_list(block), "text")
  should.be_true(string.contains(text, "Alice"))
  let assert Some(state) = first.request_state
  let tampered =
    actions.ClientRequestWithInput(
      original,
      Some(state <> "x"),
      Some(dict.from_list([#(key, response)])),
    )
  let assert jsonrpc.ErrorResponse(_, error) =
    invoke(app, "tools/call", tampered)
  should.equal(error.code, -32_602)
}

fn app() {
  server.new(actions.Implementation("task-fixture", "1", None, None, None, []))
  |> server_tasks.register
  |> server.with_modern_request_handler(fn(app, context, request) {
    server_tasks.handle(app, context, request)
    |> option.unwrap(
      Error(jsonrpc.method_not_found_error("Unknown fixture tool")),
    )
  })
}

fn meta(tasks: Bool) {
  let capabilities = case tasks {
    True -> [
      #("elicitation", VObject([])),
      #(
        "extensions",
        VObject([#("io.modelcontextprotocol/tasks", VObject([]))]),
      ),
    ]
    False -> []
  }
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #(
            "io.modelcontextprotocol/protocolVersion",
            VString(jsonrpc.latest_protocol_version),
          ),
          #("io.modelcontextprotocol/clientCapabilities", VObject(capabilities)),
        ]),
      ),
    ),
  ))
}

fn call(app, name, arguments, tasks) {
  invoke(
    app,
    "tools/call",
    actions.ClientRequestCallTool(actions.CallToolRequestParams(
      name,
      Some(dict.from_list(arguments)),
      None,
      meta(tasks),
    )),
  )
}

fn invoke(app, method, action) {
  let #(_, response) =
    server.handle_request_with_context(
      app,
      server.modern_request_context(None, "task-fixture", None),
      jsonrpc.Request(jsonrpc.IntId(1), method, Some(action)),
    )
  response
}

fn success(response) {
  let assert jsonrpc.ResultResponse(_, result) = response
  result
}

fn task(response) {
  let assert actions.ClientResultTaskModern(VObject(fields)) = success(response)
  dict.from_list(fields)
}

fn task_id(fields) {
  let assert Ok(VString(id)) = dict.get(fields, "taskId")
  id
}

fn get(app, id) {
  invoke(
    app,
    "tasks/get",
    actions.ClientRequestGetTask(actions.TaskIdParamsWithMeta(id, meta(True))),
  )
  |> task
}

fn cancel(app, id) {
  invoke(
    app,
    "tasks/cancel",
    actions.ClientRequestCancelTask(actions.TaskIdParamsWithMeta(id, meta(True))),
  )
}

fn update(app, id, inputs) {
  invoke(
    app,
    "tasks/update",
    actions.ClientRequestUpdateTask(actions.TaskUpdateParams(
      id,
      Some(VObject(inputs)),
      meta(True),
    )),
  )
}

fn poll(app, id, status, attempts) {
  let task = get(app, id)
  case dict.get(task, "status") == Ok(VString(status)), attempts > 0 {
    True, _ -> task
    _, False -> panic as "Task did not reach the expected status"
    _, True -> {
      process.sleep(10)
      poll(app, id, status, attempts - 1)
    }
  }
}
