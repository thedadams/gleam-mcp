import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/persistence
import gleam_mcp/persistence/codec
import gleam_mcp/server
import gleam_mcp_sqlite
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn database_path() -> String {
  "build/" <> unique("test") <> ".sqlite3"
}

fn open(path: String) -> gleam_mcp_sqlite.Stores {
  let assert Ok(started) =
    gleam_mcp_sqlite.start(process.new_name("gleam_mcp_sqlite_test"), path)
  started.data
}

fn with_stores(run: fn(gleam_mcp_sqlite.Stores) -> Nil) -> Nil {
  run(open(database_path()))
}

fn unique(prefix: String) -> String {
  prefix <> "-" <> int.to_string(int.random(1_000_000_000))
}

/// Stores keep times to the millisecond.
fn later(seconds: Int) -> timestamp.Timestamp {
  timestamp.add(timestamp.system_time(), duration.seconds(seconds))
  |> codec.to_milliseconds
  |> codec.from_milliseconds
}

pub fn sessions_round_trip_test() {
  use stores <- with_stores
  let sessions = stores.sessions
  let id = unique("session")
  let record =
    persistence.SessionRecord(
      id: id,
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
        ready: True,
        principal: Some("alice"),
      )),
      expires_at: later(3600),
      refreshed_at: later(0),
    )
  sessions.put(record) |> should.equal(Ok(Nil))
  let assert Ok(Some(found)) = sessions.get(id)
  should.equal(found.id, id)
  should.equal(found.metadata, record.metadata)

  // Puts replace the stored session.
  sessions.put(persistence.SessionRecord(..record, metadata: None))
  |> should.equal(Ok(Nil))
  let assert Ok(Some(found)) = sessions.get(id)
  should.equal(found.metadata, None)

  let uri = "file:///" <> unique("resource")
  sessions.set_subscription(id, uri, True) |> should.equal(Ok(Nil))
  sessions.set_subscription(id, uri, True) |> should.equal(Ok(Nil))
  sessions.subscribers(uri) |> should.equal(Ok([id]))
  sessions.subscriptions(id) |> should.equal(Ok([uri]))
  sessions.set_subscription(id, uri, False) |> should.equal(Ok(Nil))
  sessions.subscribers(uri) |> should.equal(Ok([]))

  sessions.set_subscription(id, uri, True) |> should.equal(Ok(Nil))
  sessions.delete(id) |> should.equal(Ok(Nil))
  sessions.get(id) |> should.equal(Ok(None))
  sessions.subscribers(uri) |> should.equal(Ok([]))
}

pub fn expired_sessions_are_returned_once_test() {
  use stores <- with_stores
  let sessions = stores.sessions
  let old = unique("old")
  let current = unique("current")
  let assert Ok(Nil) =
    sessions.put(persistence.SessionRecord(old, None, later(-10), later(-20)))
  let assert Ok(Nil) =
    sessions.put(persistence.SessionRecord(current, None, later(3600), later(0)))
  let assert Ok(expired) = sessions.delete_expired(later(0))
  should.be_true(list_contains(expired, old))
  should.be_false(list_contains(expired, current))
  let assert Ok(again) = sessions.delete_expired(later(0))
  should.be_false(list_contains(again, old))
  let assert Ok(Some(_)) = sessions.get(current)
  Nil
}

fn task_record(id: String, scope) -> persistence.TaskRecord {
  persistence.TaskRecord(
    task: actions.Task(
      task_id: id,
      status: actions.Working,
      status_message: None,
      created_at: "2026-10-20T10:00:00Z",
      last_updated_at: "2026-10-20T10:00:00Z",
      ttl_ms: Some(60_000),
      poll_interval_ms: Some(1000),
    ),
    scope: scope,
    outcome: None,
    inputs: dict.new(),
    cancellation_status_message: None,
    cancellation_meta: None,
    expires_at: Some(later(60)),
    owner: Some("replica"),
    version: 0,
  )
}

pub fn tasks_use_optimistic_concurrency_test() {
  use stores <- with_stores
  let tasks = stores.tasks
  let id = unique("task")
  let record = task_record(id, Some("principal:alice"))
  tasks.insert(record) |> should.equal(Ok(Nil))
  tasks.get(id) |> should.equal(Ok(Some(record)))

  let completed =
    persistence.TaskRecord(
      ..record,
      outcome: Some(Ok(actions.TaskResultModern(jsonrpc.VBool(True)))),
      version: 1,
    )
  tasks.replace(completed) |> should.equal(Ok(True))
  // A writer that read the old version loses.
  tasks.replace(completed) |> should.equal(Ok(False))
  tasks.get(id) |> should.equal(Ok(Some(completed)))
  tasks.delete(id) |> should.equal(Ok(Nil))
  tasks.get(id) |> should.equal(Ok(None))
}

pub fn tasks_are_listed_and_removed_by_scope_test() {
  use stores <- with_stores
  let tasks = stores.tasks
  let scope = Some(unique("session:"))
  let owned = task_record(unique("owned"), scope)
  let unscoped = task_record(unique("unscoped"), None)
  let assert Ok(Nil) = tasks.insert(owned)
  let assert Ok(Nil) = tasks.insert(unscoped)
  tasks.list(persistence.Scope(scope)) |> should.equal(Ok([owned]))
  let assert Ok(without_scope) = tasks.list(persistence.Scope(None))
  should.be_true(list_contains(without_scope, unscoped))
  tasks.delete_scope(scope) |> should.equal(Ok([owned.task.task_id]))
  tasks.list(persistence.Scope(scope)) |> should.equal(Ok([]))

  let expired =
    persistence.TaskRecord(
      ..task_record(unique("expired"), None),
      expires_at: Some(later(-1)),
    )
  let assert Ok(Nil) = tasks.insert(expired)
  let assert Ok(removed) = tasks.delete_expired(later(0))
  should.be_true(list_contains(removed, expired.task.task_id))
  should.be_false(list_contains(removed, unscoped.task.task_id))
  tasks.delete(unscoped.task.task_id) |> should.equal(Ok(Nil))
}

pub fn records_survive_reopening_the_database_test() {
  let path = database_path()
  let id = unique("durable")
  let first = open(path)
  let assert Ok(Nil) =
    first.sessions.put(persistence.SessionRecord(id, None, later(60), later(0)))
  let second = open(path)
  let assert Ok(Some(_)) = second.sessions.get(id)
  Nil
}

pub fn a_stopped_database_becomes_store_errors_test() {
  let stores = gleam_mcp_sqlite.stores(process.new_name("never_started"))
  stores.sessions.get("anything") |> should.be_error
}

fn list_contains(items: List(a), item: a) -> Bool {
  case items {
    [] -> False
    [first, ..rest] -> first == item || list_contains(rest, item)
  }
}

pub fn servers_sharing_the_database_share_sessions_test() {
  use stores <- with_stores
  let implementation =
    actions.Implementation("sqlite-test", "1.0.0", None, None, None, [])
  let replica = fn() {
    server.new(implementation)
    |> server.with_session_store(stores.sessions)
    |> server.with_task_store(stores.tasks)
  }
  let first = replica()
  let second = replica()
  let session = server.ensure_streamable_http_session(first, None)
  server.bind_session(first, session, Some("alice")) |> should.be_true
  server.bind_session(second, session, Some("bob")) |> should.be_false
  let assert Some(metadata) = server.session_metadata(second, session)
  should.equal(metadata.principal, Some("alice"))
  server.close_session(second, session)
  server.has_streamable_http_session(first, session) |> should.be_false
}
