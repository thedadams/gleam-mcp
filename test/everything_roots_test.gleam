import everything_feature_test_support as support
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/roots
import gleam_mcp/jsonrpc
import gleam_mcp/server
import gleam_mcp/server/streamable_http_store as store
import gleeunit/should

pub fn roots_change_during_pending_refresh_is_not_lost_test() {
  let app = support.app()
  let cache = roots.new(app)
  let session =
    support.ready_session(
      app,
      actions.ClientCapabilities(
        ..support.empty_capabilities(),
        roots: Some(actions.ClientRootsCapabilities(Some(True))),
      ),
    )
  let context = support.context(session)
  let listener = support.listen(app, session)
  let original = [actions.Root("file:///original", Some("Original"), None)]
  let stale = [actions.Root("file:///stale", Some("Stale"), None)]
  let latest = [actions.Root("file:///latest", Some("Latest"), None)]

  roots.sync(cache, context, False)
  let initial = receive_request(listener)
  support.respond(
    app,
    session,
    initial,
    actions.ServerResultListRoots(actions.ListRootsResult(original, None)),
  )
  should.equal(roots.fetch(cache, context), Ok(original))

  roots.sync(cache, context, True)
  let pending = receive_request(listener)
  // Two changes while this request is pending must coalesce into a refresh.
  roots.sync(cache, context, True)
  roots.sync(cache, context, True)
  // This cached read also fences the actor's preceding change messages.
  should.equal(roots.fetch(cache, context), Ok(original))
  assert_no_requests(listener)
  support.respond(
    app,
    session,
    pending,
    actions.ServerResultListRoots(actions.ListRootsResult(stale, None)),
  )

  let refresh = receive_request(listener)
  should.equal(
    support.action(refresh),
    Some(actions.ServerRequestListRoots(None)),
  )
  should.not_equal(refresh, pending)
  // Cached reads remain available while the queued refresh is outstanding.
  should.equal(roots.fetch(cache, context), Ok(stale))
  support.respond(
    app,
    session,
    refresh,
    actions.ServerResultListRoots(actions.ListRootsResult(latest, None)),
  )
  await_latest(cache, session, latest, 30)
  assert_no_requests(listener)

  roots.close_session(cache, session)
  roots.stop(cache)
  server.close_session(app, session)
}

fn receive_request(
  listener: process.Subject(store.ListenerMessage),
) -> jsonrpc.Request(actions.ServerActionRequest) {
  case process.receive(listener, 1000) {
    Ok(store.DeliverRequest(request)) -> request
    Ok(store.DeliverNotification(_)) -> receive_request(listener)
    _ -> panic as "Expected client roots request"
  }
}

fn assert_no_requests(listener: process.Subject(store.ListenerMessage)) -> Nil {
  case process.receive(listener, 0) {
    Ok(store.DeliverNotification(_)) -> assert_no_requests(listener)
    Error(_) -> Nil
    _ -> panic as "Roots changes started redundant concurrent requests"
  }
}

fn await_latest(
  cache: roots.Store,
  session: String,
  expected: List(actions.Root),
  remaining: Int,
) -> Nil {
  let current = roots.fetch(cache, support.context(session)) |> should.be_ok
  case current == expected, remaining {
    True, _ -> Nil
    False, 0 -> panic as "Roots change during pending refresh was lost"
    False, _ -> {
      process.sleep(5)
      await_latest(cache, session, expected, remaining - 1)
    }
  }
}
