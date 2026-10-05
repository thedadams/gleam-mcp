//// Own each streaming request in a separate process so DNS, connection setup,
//// and TLS cannot block the MCP operation deadline. Hackney monitors that
//// owner and closes its request and socket when the owner exits.

import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{type Option, None, Some}
import httpp/hackney

pub type Event {
  Started(status: Int, headers: List(http.Header))
  Chunk(BitArray)
  Ended
  Failed(String)
}

pub opaque type Handle {
  Handle(process.Pid)
}

type Message {
  Incoming(hackney.ClientRef, hackney.HttppMessage)
}

// httpp exposes the streaming and cancellation API, but its public Options
// omits timeout controls. Reuse its existing send function with Gleam option
// constructors matching Hackney's documented timeout options.
type Options {
  Async
  FollowRedirect(Bool)
  Pool(Bool)
  RecvTimeout(Int)
  ConnectTimeout(Int)
}

@external(erlang, "httpp_ffi", "send")
fn send(
  method: http.Method,
  url: String,
  headers: List(http.Header),
  body: bytes_tree.BytesTree,
  options: List(Options),
) -> Result(hackney.HackneyResponse, hackney.Error)

pub fn start(
  method: http.Method,
  url: String,
  headers: List(http.Header),
  body: String,
  timeout_ms: Int,
  events: process.Subject(event),
  map_event: fn(Event) -> event,
) -> Handle {
  let owner = process.self()
  Handle(
    process.spawn_unlinked(fn() {
      let worker = process.self()
      let _ = process.spawn_unlinked(fn() { guard_owner(owner, worker) })
      let publish = fn(event) { process.send(events, map_event(event)) }
      case
        send(method, url, headers, bytes_tree.from_string(body), [
          Async,
          FollowRedirect(False),
          Pool(False),
          RecvTimeout(timeout_ms + 1000),
          ConnectTimeout(timeout_ms + 1000),
        ])
      {
        Ok(hackney.AsyncResponse(ref)) -> {
          receive_stream(ref, None, publish)
          hackney.close(ref)
        }
        Error(error) -> publish(Failed(error_message(error)))
        _ -> publish(Failed("Unexpected HTTP stream startup response"))
      }
    }),
  )
}

// A separate monitor remains responsive while the request worker is blocked
// inside DNS, TCP, or TLS setup. Monitoring the worker also bounds the
// guardian's lifetime after completion, explicit stop, or startup failure.
fn guard_owner(owner: process.Pid, worker: process.Pid) -> Nil {
  let owner_monitor = process.monitor(owner)
  let worker_monitor = process.monitor(worker)
  let down =
    process.new_selector()
    |> process.select_monitors(fn(down) { down })
    |> process.selector_receive_forever
  case down {
    process.ProcessDown(_, pid, _) if pid == owner -> process.kill(worker)
    _ -> Nil
  }
  process.demonitor_process(owner_monitor)
  process.demonitor_process(worker_monitor)
}

/// Killing the request owner also cancels an in-progress connection setup.
/// Hackney's owner monitor tears down the async receiver and its socket.
pub fn stop(handle: Handle) -> Nil {
  let Handle(owner) = handle
  process.kill(owner)
}

fn receive_stream(
  ref: hackney.ClientRef,
  status: Option(Int),
  publish: fn(Event) -> Nil,
) -> Nil {
  let selector =
    process.new_selector()
    |> hackney.selecting_http_message(Incoming)
  case process.selector_receive_forever(selector) {
    Incoming(incoming_ref, _) if incoming_ref != ref ->
      receive_stream(ref, status, publish)
    Incoming(_, message) ->
      case message {
        hackney.Status(code) -> receive_stream(ref, Some(code), publish)
        hackney.Headers(headers) ->
          case status {
            Some(code) -> {
              publish(Started(code, headers))
              receive_stream(ref, status, publish)
            }
            None -> publish(Failed("HTTP stream headers preceded status"))
          }
        hackney.Binary(chunk) -> {
          publish(Chunk(chunk))
          receive_stream(ref, status, publish)
        }
        hackney.DoneStreaming -> publish(Ended)
        hackney.Redirect(..) | hackney.SeeOther(..) ->
          publish(Failed("HTTP redirects are disabled"))
        hackney.NotDecoded(value) -> publish(Failed(dynamic_error(value)))
      }
  }
}

fn error_message(error: hackney.Error) -> String {
  case error {
    hackney.TimedOut -> "HTTP stream timeout"
    hackney.Other(value) -> dynamic_error(value)
    _ -> "HTTP stream request failed"
  }
}

fn dynamic_error(value: Dynamic) -> String {
  let timeout =
    list.any([[], [0], [1], [1, 1]], fn(path) {
      case decode.run(value, decode.at(path, atom.decoder())) {
        Ok(value) -> atom.to_string(value) == "timeout"
        Error(_) -> False
      }
    })
  case timeout {
    True -> "HTTP stream timeout"
    False -> "HTTP stream request failed"
  }
}
