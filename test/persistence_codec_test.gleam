import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/persistence
import gleam_mcp/persistence/codec
import gleeunit/should

fn at(milliseconds: Int) -> timestamp.Timestamp {
  codec.from_milliseconds(milliseconds)
}

fn task(status: actions.TaskStatus) -> actions.Task {
  actions.Task(
    task_id: "task-1",
    status: status,
    status_message: Some("Working on it"),
    created_at: "2026-10-20T10:00:00Z",
    last_updated_at: "2026-10-20T10:00:01Z",
    ttl_ms: Some(60_000),
    poll_interval_ms: Some(5000),
  )
}

fn record(
  outcome: option.Option(Result(actions.TaskResult, jsonrpc.RpcError)),
) -> persistence.TaskRecord {
  persistence.TaskRecord(
    task: task(actions.Completed),
    scope: Some("principal:alice"),
    outcome: outcome,
    inputs: dict.from_list([#("name", jsonrpc.VObject([]))]),
    cancellation_status_message: Some("Stopped"),
    cancellation_meta: Some(
      actions.Meta(dict.from_list([#("reason", jsonrpc.VString("user"))])),
    ),
    expires_at: Some(at(1_790_000_000_123)),
    owner: Some("replica"),
    version: 3,
  )
}

pub fn sessions_round_trip_test() {
  let session =
    persistence.SessionRecord(
      id: "session",
      metadata: Some(persistence.SessionMetadata(
        protocol_version: jsonrpc.legacy_protocol_version,
        client_capabilities: actions.ClientCapabilities(
          None,
          None,
          None,
          None,
          None,
        ),
        initialized: True,
        ready: False,
        principal: Some("alice"),
      )),
      expires_at: at(1_790_000_000_123),
      refreshed_at: at(1_789_000_000_000),
    )
  codec.decode_session(codec.encode_session(session))
  |> should.equal(Ok(session))

  let unbound = persistence.SessionRecord(..session, metadata: None)
  codec.decode_session(codec.encode_session(unbound))
  |> should.equal(Ok(unbound))
}

pub fn task_outcomes_round_trip_test() {
  [
    None,
    Some(
      Ok(actions.TaskResultModern(jsonrpc.VObject([#("n", jsonrpc.VInt(1))]))),
    ),
    Some(
      Ok(
        actions.TaskCallTool(actions.CallToolResult(
          [actions.TextBlock(actions.TextContent("done", None, None))],
          None,
          None,
          None,
        )),
      ),
    ),
    Some(Error(jsonrpc.RpcError(-32_603, "failed", Some(jsonrpc.VString("x"))))),
  ]
  |> list.each(fn(outcome) {
    let record = record(outcome)
    codec.decode_task(codec.encode_task(record)) |> should.equal(Ok(record))
  })
}

pub fn milliseconds_round_trip_test() {
  codec.to_milliseconds(at(1_790_000_000_123))
  |> should.equal(1_790_000_000_123)
}
