import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/task_store
import gleeunit/should

pub fn task_result_matches_protocol_retrieval_and_preserves_metadata_test() {
  let original =
    actions.CallToolResult(
      [actions.TextBlock(actions.TextContent("finished", None, None))],
      Some(jsonrpc.VArray([jsonrpc.VInt(42)])),
      Some(False),
      Some(
        actions.Meta(
          dict.from_list([
            #("custom", jsonrpc.VString("preserved")),
            #(
              "io.modelcontextprotocol/related-task",
              jsonrpc.VObject([#("taskId", jsonrpc.VString("old-task"))]),
            ),
          ]),
        ),
      ),
    )
  list.each(
    [Ok(original), Error(jsonrpc.RpcError(-32_603, "worker failed", None))],
    fn(outcome) {
      let app =
        app()
        |> server.add_tool("job", "job", jsonrpc.VObject([]), fn(_) { outcome })
      let created =
        invoke(
          app,
          mcp.method_call_tool,
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "job",
            None,
            Some(actions.TaskMetadata(Some(1000))),
            None,
          )),
        )
      let assert jsonrpc.ResultResponse(
        _,
        actions.ClientResultCreateTask(created),
      ) = created
      let id = created.task.task_id
      let retrieved = server.task_result(app, id)
      let protocol =
        invoke(
          app,
          mcp.method_get_task_result,
          actions.ClientRequestGetTaskResult(actions.TaskIdParams(id)),
        )
      case retrieved, protocol {
        Ok(result),
          jsonrpc.ResultResponse(_, actions.ClientResultTaskResult(payload))
        -> {
          should.equal(result, payload)
          let assert actions.TaskCallTool(result) = result
          should.equal(result.content, original.content)
          should.equal(result.structured_content, original.structured_content)
          should.equal(result.is_error, original.is_error)
          let actions.Meta(fields) = result.meta |> should.be_some
          should.equal(
            dict.get(fields, "custom"),
            Ok(jsonrpc.VString("preserved")),
          )
          should.equal(
            dict.get(fields, "io.modelcontextprotocol/related-task"),
            Ok(jsonrpc.VObject([#("taskId", jsonrpc.VString(id))])),
          )
        }
        Error(error), jsonrpc.ErrorResponse(_, protocol_error) -> {
          should.equal(error, protocol_error)
          should.equal(error, jsonrpc.RpcError(-32_603, "worker failed", None))
        }
        _, _ -> panic as "Public and protocol task results diverged"
      }
    },
  )
}

pub fn modern_task_result_wrapper_returns_the_original_payload_test() {
  let app =
    app()
    |> server.with_extensions(
      dict.from_list([
        #("io.modelcontextprotocol/tasks", jsonrpc.VObject([])),
      ]),
    )
  let metadata = modern_meta()
  let context =
    server.modern_request_context(None, "wrapper", None)
    |> server.request_context(jsonrpc.IntId(1), metadata)
  let value =
    jsonrpc.VObject([
      #("resultType", jsonrpc.VString("complete")),
      #("content", jsonrpc.VArray([])),
      #("custom", jsonrpc.VString("preserved")),
    ])
  let created =
    server.create_modern_task(app, context, Some(1000), fn() {
      Ok(task_store.ModernComplete(value))
    })
    |> should.be_ok
  let assert actions.ClientResultTaskModern(jsonrpc.VObject(fields)) = created
  let assert Ok(jsonrpc.VString(id)) =
    dict.get(dict.from_list(fields), "taskId")
  should.equal(server.task_result(app, id), Ok(actions.TaskResultModern(value)))
}

pub fn discovery_preserves_explicit_capabilities_and_extension_settings_test() {
  list.each(
    [None, Some(actions.ServerTasksCapabilities(None, None, None))],
    fn(tasks) {
      let extensions =
        dict.from_list([
          #(
            "com.example/feature",
            jsonrpc.VObject([#("mode", jsonrpc.VString("custom"))]),
          ),
          #(
            "io.modelcontextprotocol/tasks",
            jsonrpc.VObject([#("custom", jsonrpc.VBool(True))]),
          ),
        ])
      let app =
        app()
        |> server.add_tool("hidden", "hidden", jsonrpc.VObject([]), fn(_) {
          Ok(actions.CallToolResult([], None, None, None))
        })
        |> server.with_capabilities(actions.ServerCapabilities(
          None,
          None,
          Some(jsonrpc.VObject([])),
          Some(actions.ServerPromptsCapabilities(Some(False))),
          Some(actions.ServerResourcesCapabilities(Some(True), Some(False))),
          None,
          tasks,
        ))
        |> server.with_extensions(extensions)
      let assert jsonrpc.ResultResponse(_, actions.ClientResultDiscover(found)) =
        invoke(
          app,
          "server/discover",
          actions.ClientRequestDiscover(modern_meta()),
        )
      should.be_false(dict.has_key(found.capabilities, "tasks"))
      should.be_false(dict.has_key(found.capabilities, "tools"))
      should.equal(
        dict.get(found.capabilities, "completions"),
        Ok(jsonrpc.VObject([])),
      )
      should.equal(
        dict.get(found.capabilities, "prompts"),
        Ok(jsonrpc.VObject([#("listChanged", jsonrpc.VBool(False))])),
      )
      let assert Ok(jsonrpc.VObject(resources)) =
        dict.get(found.capabilities, "resources")
      should.equal(
        dict.from_list(resources),
        dict.from_list([
          #("subscribe", jsonrpc.VBool(True)),
          #("listChanged", jsonrpc.VBool(False)),
        ]),
      )
      let assert Ok(jsonrpc.VObject(fields)) =
        dict.get(found.capabilities, "extensions")
      let fields = dict.from_list(fields)
      should.equal(
        dict.get(fields, "com.example/feature"),
        dict.get(extensions, "com.example/feature"),
      )
      should.equal(
        dict.get(fields, "io.modelcontextprotocol/tasks"),
        case tasks {
          None -> dict.get(extensions, "io.modelcontextprotocol/tasks")
          Some(_) -> Ok(jsonrpc.VObject([]))
        },
      )
    },
  )
}

fn app() -> server.Server {
  server.new(actions.Implementation("refactor-test", "1", None, None, None, []))
}

fn invoke(
  app: server.Server,
  method: String,
  action: actions.ClientActionRequest,
) {
  server.handle_request(
    app,
    jsonrpc.Request(jsonrpc.IntId(1), method, Some(action)),
  ).1
}

fn modern_meta() {
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #(
            "io.modelcontextprotocol/protocolVersion",
            jsonrpc.VString(jsonrpc.latest_protocol_version),
          ),
          #(
            "io.modelcontextprotocol/clientCapabilities",
            jsonrpc.VObject([
              #(
                "extensions",
                jsonrpc.VObject([
                  #("io.modelcontextprotocol/tasks", jsonrpc.VObject([])),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ),
  ))
}
