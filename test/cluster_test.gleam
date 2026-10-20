//// Two servers in one node that share stores and a cluster name behave as two
//// replicas: glyn delivers between them exactly as between connected nodes.

import envoy
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/tool_helpers
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/persistence/memory
import gleam_mcp/server
import gleam_mcp/server/cluster
import gleam_mcp/server/streamable_http_store
import gleeunit/should
import server_test_support

type Replicas {
  Replicas(first: server.Server, second: server.Server)
}

fn replicas() -> Replicas {
  let name = "cluster-test-" <> int.to_string(int.random(1_000_000_000))
  let assert Ok(actor.Started(data: sessions, ..)) =
    memory.start_sessions(process.new_name("cluster_test_sessions"))
  let assert Ok(actor.Started(data: tasks, ..)) =
    memory.start_tasks(process.new_name("cluster_test_tasks"))
  let secret = crypto.strong_random_bytes(32)
  let replica = fn() {
    let app =
      server.new(server_test_support.sample_client_info())
      |> server.with_session_store(sessions)
      |> server.with_task_store(tasks)
      |> server.with_request_state_secret(secret)
      |> result.try(server.with_cluster(_, name))
      |> should.be_ok
    let assert Ok(Nil) = server.start_services(app)
    app
  }
  Replicas(replica(), replica())
}

fn ready_session(app: server.Server) -> String {
  let id = server.ensure_streamable_http_session(app, None)
  server.bind_session(app, id, None) |> should.be_true
  let #(_, response) =
    server.handle_request_with_context(
      app,
      context(id),
      jsonrpc.Request(
        jsonrpc.StringId("initialize"),
        mcp.method_initialize,
        Some(
          actions.ClientRequestInitialize(actions.InitializeRequestParams(
            jsonrpc.legacy_protocol_version,
            actions.ClientCapabilities(None, None, None, None, None),
            server_test_support.sample_client_info(),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultInitialize(_)) =
    response
  server.handle_notification_with_context(
    app,
    context(id),
    jsonrpc.Notification(
      mcp.method_initialized,
      Some(actions.NotifyInitialized(None)),
    ),
  )
  |> should.be_ok
  id
}

fn with_tools_list_changed(app: server.Server) -> server.Server {
  server.with_capabilities(
    app,
    actions.ServerCapabilities(
      ..server.advertised_capabilities(app),
      tools: Some(actions.ServerToolsCapabilities(Some(True))),
    ),
  )
}

fn context(id: String) -> server.RequestContext {
  server.RequestContext(Some(id), None)
}

/// Let events published so far reach the other replica.
fn settle() -> Nil {
  process.sleep(50)
}

fn listen(
  app: server.Server,
  session: String,
) -> process.Subject(streamable_http_store.ListenerMessage) {
  let listener = process.new_subject()
  server.register_streamable_http_listener(
    app,
    session,
    server.new_streamable_http_listener_id(),
    listener,
  )
  listener
}

fn tools_changed() -> jsonrpc.Request(actions.ActionNotification) {
  jsonrpc.Notification(
    mcp.method_notify_tools_list_changed,
    Some(actions.NotifyToolListChanged(None)),
  )
}

pub fn notifications_reach_a_stream_held_by_another_replica_test() {
  let Replicas(first, second) = replicas()
  let first = with_tools_list_changed(first)
  let session = ready_session(first)
  server.attach_session(second, session)
  settle()
  let stream = listen(second, session)
  settle()

  server.send_notification(first, context(session), tools_changed())
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverPayload(payload)) =
    process.receive(stream, 1000)
  should.be_true(payload |> string.contains("notifications/tools/list_changed"))
}

pub fn a_replica_that_never_saw_the_session_still_notifies_it_test() {
  let Replicas(first, second) = replicas()
  let second = with_tools_list_changed(second)
  let session = ready_session(first)
  let stream = listen(first, session)

  server.send_notification(second, context(session), tools_changed())
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverPayload(_)) =
    process.receive(stream, 1000)
}

pub fn server_requests_round_trip_through_another_replica_test() {
  let Replicas(first, second) = replicas()
  let session = ready_session(first)
  // The stream opens on the second replica before the first joins.
  server.attach_session(second, session)
  let stream = listen(second, session)
  server.attach_session(first, session)
  settle()

  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(
      reply,
      server.send_request(
        first,
        context(session),
        jsonrpc.Request(
          jsonrpc.StringId("ping-1"),
          mcp.method_ping,
          Some(actions.ServerRequestPing(None)),
        ),
      ),
    )
  })
  let assert Ok(streamable_http_store.DeliverPayload(payload)) =
    process.receive(stream, 1000)
  should.be_true(payload |> string.contains("ping-1"))

  // The client answers on the replica holding its stream.
  server.handle_server_sent_response(
    second,
    context(session),
    "{\"jsonrpc\":\"2.0\",\"id\":\"ping-1\",\"result\":{}}",
  )
  |> should.be_ok
  process.receive(reply, 1000) |> should.be_ok |> should.be_ok
}

pub fn closing_a_session_closes_streams_on_every_replica_test() {
  let Replicas(first, second) = replicas()
  let session = ready_session(first)
  server.attach_session(second, session)
  settle()
  let stream = listen(second, session)
  settle()

  server.close_session(first, session)
  process.receive(stream, 1000)
  |> should.equal(Ok(streamable_http_store.CloseListener))
  should.be_false(server.has_streamable_http_session(second, session))
}

pub fn subscription_notifications_reach_every_replica_test() {
  let Replicas(first, second) = replicas()
  let second = with_tools_list_changed(second)
  let sink = process.new_subject()
  let context =
    server.modern_request_context(None, "listen", Some(sink))
    |> server.request_context(jsonrpc.StringId("listen"), modern_meta())
  server.listen_subscription(
    second,
    context,
    actions.SubscriptionsListenParams(
      Some(jsonrpc.VObject([#("toolsListChanged", jsonrpc.VBool(True))])),
      modern_meta(),
    ),
  )
  |> should.be_ok
  let assert Ok(streamable_http_store.DeliverNotification(_)) =
    process.receive(sink, 1000)

  server.publish_notification(first, tools_changed())
  let assert Ok(streamable_http_store.DeliverNotification(jsonrpc.Notification(
    "notifications/tools/list_changed",
    _,
  ))) = process.receive(sink, 1000)
}

pub fn resource_subscriptions_are_shared_test() {
  let Replicas(first, second) = replicas()
  let first =
    first
    |> server.register_resource_descriptor(
      actions.Resource(
        "file:///shared",
        "shared",
        None,
        None,
        None,
        None,
        None,
        [],
        None,
      ),
      fn() { Ok([]) },
    )
    |> server.with_resource_subscriptions
  let session = ready_session(first)
  let #(_, response) =
    server.handle_request_with_context(
      first,
      context(session),
      jsonrpc.Request(
        jsonrpc.StringId("subscribe"),
        mcp.method_subscribe_resource,
        Some(
          actions.ClientRequestSubscribeResource(actions.SubscribeRequestParams(
            "file:///shared",
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultEmpty(_)) = response
  server.resource_subscriptions(second, session)
  |> should.equal(["file:///shared"])
}

pub fn replicas_see_each_other_as_alive_test() {
  let shared = cluster.shared("alive-test", "one")
  should.be_true(cluster.alive(shared, "one"))
  should.be_false(cluster.alive(shared, "missing"))
}

pub fn envelopes_round_trip_test() {
  let envelope =
    cluster.Envelope(
      "replica",
      cluster.Broadcast,
      cluster.TaskInputs(
        "task",
        Some("principal:alice"),
        dict.from_list([#("name", jsonrpc.VString("Ada"))]),
      ),
    )
  cluster.decode_envelope(cluster.encode(envelope))
  |> should.equal(Ok(envelope))
  cluster.decode_envelope("{\"v\":2}") |> should.equal(Error(Nil))
}

fn modern_meta() -> option.Option(actions.RequestMeta) {
  Some(actions.RequestMeta(
    None,
    Some(
      actions.Meta(
        dict.from_list([
          #(
            "io.modelcontextprotocol/protocolVersion",
            jsonrpc.VString(jsonrpc.latest_protocol_version),
          ),
          #("io.modelcontextprotocol/clientCapabilities", jsonrpc.VObject([])),
        ]),
      ),
    ),
  ))
}

pub fn waiting_for_a_task_finished_by_another_replica_test() {
  let Replicas(first, second) = replicas()
  let first =
    first
    |> server.register_context_tool_descriptor(
      actions.Tool(
        ..tool_helpers.descriptor(
          "slow",
          "slow",
          "test",
          tool_helpers.empty_schema(),
          None,
          tool_helpers.read_only_annotations(),
        ),
        execution: Some(actions.ToolExecution(Some(actions.TaskOptional))),
      ),
      fn(_, _, _) {
        process.sleep(100)
        Ok(tool_helpers.text_result("done"))
      },
    )
  let session = ready_session(first)
  let #(_, response) =
    server.handle_request_with_context(
      first,
      context(session),
      jsonrpc.Request(
        jsonrpc.StringId("slow"),
        mcp.method_call_tool,
        Some(
          actions.ClientRequestCallTool(actions.CallToolRequestParams(
            "slow",
            None,
            Some(actions.TaskMetadata(Some(60_000))),
            None,
          )),
        ),
      ),
    )
  let assert jsonrpc.ResultResponse(_, actions.ClientResultCreateTask(created)) =
    response

  // The second replica waits; the first runs the worker and announces it.
  let assert actions.TaskCallTool(_) =
    server.task_result(second, created.task.task_id) |> should.be_ok
}

pub fn clustering_requires_a_shared_state_secret_test() {
  server.new(server_test_support.sample_client_info())
  |> server.with_cluster("no-secret")
  |> should.be_error
}

pub fn peers_are_read_from_the_environment_test() {
  envoy.set("CLUSTER_TEST_PEERS", " mcp@a , ,mcp@b")
  cluster.peers_from_env("CLUSTER_TEST_PEERS")
  |> should.equal(["mcp@a", "mcp@b"])
  cluster.peers_from_env("CLUSTER_TEST_UNSET") |> should.equal([])
}

pub fn connecting_to_unreachable_peers_reports_them_test() {
  // A node that is not distributed cannot reach any peer.
  cluster.connect(["mcp@unreachable.invalid"])
  |> should.equal(["mcp@unreachable.invalid"])
}
