import gleam/erlang/process
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server/runtime
import gleeunit/should

pub fn main() {
  crashed_request_workers_return_an_internal_error_immediately_test()
  finished_request_timers_cannot_cancel_reused_request_ids_test()
  cancellation_stops_only_the_matching_session_worker_test()
  session_close_releases_pending_requests_and_subscriptions_test()
  request_timeout_stops_worker_and_allows_a_new_request_test()
}

pub fn crashed_request_workers_return_an_internal_error_immediately_test() {
  let store = runtime.new()
  let id = jsonrpc.StringId("crashed")
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        runtime.run(store, None, id, 60_000, fn() {
          process.kill(process.self())
          Ok(actions.ClientResultEmpty(None))
        }),
      )
    })
  let error = process.receive(reply, 1000) |> should.be_ok |> should.be_error
  should.equal(error.code, -32_603)
  runtime.run(store, None, id, 1000, fn() {
    Ok(actions.ClientResultEmpty(None))
  })
  |> should.be_ok
}

pub fn finished_request_timers_cannot_cancel_reused_request_ids_test() {
  let store = runtime.new()
  let id = jsonrpc.StringId("reused")
  runtime.run(store, None, id, 20, fn() { Ok(actions.ClientResultEmpty(None)) })
  |> should.be_ok
  let ready = process.new_subject()
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        runtime.run(store, None, id, 1000, fn() {
          let continue = process.new_subject()
          process.send(ready, continue)
          process.receive_forever(continue)
          Ok(actions.ClientResultEmpty(None))
        }),
      )
    })
  let continue = process.receive(ready, 1000) |> should.be_ok
  let early = process.receive(reply, 50)
  process.send(continue, Nil)
  should.equal(early, Error(Nil))
  process.receive(reply, 1000) |> should.be_ok |> should.be_ok
}

pub fn cancellation_stops_only_the_matching_session_worker_test() {
  let store = runtime.new()
  let id = jsonrpc.StringId("same-id")
  let ready_a = process.new_subject()
  let ready_b = process.new_subject()
  let reply_a = process.new_subject()
  let reply_b = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply_a,
        runtime.run(store, Some("a"), id, 1000, fn() {
          let continue = process.new_subject()
          process.send(ready_a, #(process.self(), continue))
          process.receive_forever(continue)
          Ok(actions.ClientResultEmpty(None))
        }),
      )
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply_b,
        runtime.run(store, Some("b"), id, 1000, fn() {
          let continue = process.new_subject()
          process.send(ready_b, continue)
          process.receive_forever(continue)
          Ok(actions.ClientResultEmpty(None))
        }),
      )
    })
  let #(worker_a, _) = process.receive(ready_a, 1000) |> should.be_ok
  let continue_b = process.receive(ready_b, 1000) |> should.be_ok
  let monitor = process.monitor(worker_a)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  runtime.cancel(store, Some("a"), id)
  let error = process.receive(reply_a, 1000) |> should.be_ok |> should.be_error
  should.equal(error.code, -32_800)
  process.selector_receive(selector, 1000) |> should.be_ok
  let early_b = process.receive(reply_b, 10)
  process.send(continue_b, Nil)
  should.equal(early_b, Error(Nil))
  process.receive(reply_b, 1000) |> should.be_ok |> should.be_ok
}

pub fn session_close_releases_pending_requests_and_subscriptions_test() {
  let store = runtime.new()
  let ready = process.new_subject()
  let reply = process.new_subject()
  runtime.subscribe(store, "a", "file:///resource", True)
  runtime.subscribe(store, "b", "file:///resource", True)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        runtime.run(store, Some("a"), jsonrpc.StringId("close"), 1000, fn() {
          process.send(ready, Nil)
          process.sleep_forever()
          Ok(actions.ClientResultEmpty(None))
        }),
      )
    })
  process.receive(ready, 1000) |> should.be_ok
  runtime.close(store, "a")
  process.receive(reply, 1000) |> should.be_ok |> should.be_error
  should.equal(runtime.subscribers(store, "file:///resource"), ["b"])
}

pub fn request_timeout_stops_worker_and_allows_a_new_request_test() {
  let store = runtime.new()
  let id = jsonrpc.StringId("timeout")
  let error =
    runtime.run(store, None, id, 20, fn() {
      process.sleep_forever()
      Ok(actions.ClientResultEmpty(None))
    })
    |> should.be_error
  should.equal(error.code, -32_800)
  runtime.run(store, None, id, 1000, fn() {
    Ok(actions.ClientResultEmpty(None))
  })
  |> should.be_ok
}
