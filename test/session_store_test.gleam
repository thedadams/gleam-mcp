import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/time/duration
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/persistence
import gleam_mcp/persistence/memory
import gleam_mcp/server
import gleeunit/should

fn implementation() -> actions.Implementation {
  actions.Implementation("session-store-test", "1.0.0", None, None, None, [])
}

fn shared_store() -> persistence.SessionStore {
  let assert Ok(actor.Started(data: store, ..)) =
    memory.start_sessions(process.new_name("session_store_test"))
  store
}

pub fn replicas_sharing_a_store_share_sessions_test() {
  let store = shared_store()
  let first = server.new(implementation()) |> server.with_session_store(store)
  let second = server.new(implementation()) |> server.with_session_store(store)

  let session = server.ensure_streamable_http_session(first, None)
  should.be_true(server.bind_session(first, session, Some("alice")))

  should.be_true(server.has_streamable_http_session(second, session))
  should.be_false(server.bind_session(second, session, Some("bob")))
  let metadata = server.session_metadata(second, session) |> should.be_some
  should.equal(metadata.principal, Some("alice"))

  server.close_session(second, session)
  should.be_false(server.has_streamable_http_session(first, session))
}

pub fn idle_sessions_expire_test() {
  let app =
    server.new(implementation())
    |> server.with_session_ttl(
      ttl: duration.milliseconds(50),
      refresh_every: duration.hours(1),
    )
  let session = server.ensure_streamable_http_session(app, None)
  should.be_true(server.has_streamable_http_session(app, session))
  process.sleep(80)
  should.be_false(server.has_streamable_http_session(app, session))
  server.session_metadata(app, session) |> should.be_none
}

pub fn requests_extend_a_session_test() {
  let app =
    server.new(implementation())
    |> server.with_session_ttl(
      ttl: duration.milliseconds(150),
      refresh_every: duration.milliseconds(0),
    )
  let session = server.ensure_streamable_http_session(app, None)
  keep_alive(app, session, 6)
  should.be_true(server.has_streamable_http_session(app, session))
}

fn keep_alive(app: server.Server, session: String, times: Int) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      process.sleep(50)
      should.be_true(server.has_streamable_http_session(app, session))
      keep_alive(app, session, times - 1)
    }
  }
}

pub fn refreshes_are_limited_to_the_refresh_interval_test() {
  let writes = process.new_subject()
  let store = shared_store()
  let counting =
    persistence.SessionStore(
      ..store,
      put: fn(record: persistence.SessionRecord) {
        process.send(writes, record.id)
        store.put(record)
      },
    )
  let app =
    server.new(implementation())
    |> server.with_session_store(counting)
    |> server.with_session_ttl(
      ttl: duration.hours(1),
      refresh_every: duration.hours(1),
    )
  let session = server.ensure_streamable_http_session(app, None)
  process.receive(writes, 100) |> should.equal(Ok(session))
  should.be_true(server.has_streamable_http_session(app, session))
  should.be_true(server.has_streamable_http_session(app, session))
  process.receive(writes, 50) |> should.equal(Error(Nil))
}

pub fn store_failures_are_not_reported_as_missing_sessions_test() {
  let failing =
    persistence.SessionStore(..shared_store(), get: fn(_) {
      Error(persistence.StoreError("down"))
    })
  let app = server.new(implementation()) |> server.with_session_store(failing)
  server.find_session(app, "anything")
  |> should.equal(Error(persistence.StoreError("down")))
}

pub fn memory_store_returns_each_expired_session_once_test() {
  let store = shared_store()
  let now = timestamp.system_time()
  let past = timestamp.add(now, duration.seconds(-1))
  let future = timestamp.add(now, duration.hours(1))
  let assert Ok(Nil) =
    store.put(persistence.SessionRecord("old", None, past, past))
  let assert Ok(Nil) =
    store.put(persistence.SessionRecord("new", None, future, now))
  let assert Ok(Nil) = store.set_subscription("old", "file:///a", True)

  store.delete_expired(now) |> should.equal(Ok(["old"]))
  store.delete_expired(now) |> should.equal(Ok([]))
  store.get("old") |> should.equal(Ok(None))
  store.subscribers("file:///a") |> should.equal(Ok([]))
  store.get("new") |> should.be_ok |> should.be_some
}
