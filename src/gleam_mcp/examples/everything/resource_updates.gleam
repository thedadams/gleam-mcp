import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server

pub opaque type Simulation {
  Simulation(subject: process.Subject(Message), label_sessions: Bool)
}

type Message {
  Toggle(id: String, reply: process.Subject(Bool))
  Tick(id: String, generation: Int)
  Close(id: String, reply: process.Subject(Nil))
  Stop(reply: process.Subject(Nil))
}

type Interval {
  Interval(generation: Int, timer: process.Timer)
}

pub fn new(app: server.Server) -> Simulation {
  new_with_interval(app, 5000)
}

pub fn new_with_interval(app: server.Server, interval_ms: Int) -> Simulation {
  new_with_config(app, interval_ms, True)
}

pub fn new_without_session_labels(app: server.Server) -> Simulation {
  new_with_config(app, 5000, False)
}

fn new_with_config(
  app: server.Server,
  interval_ms: Int,
  label_sessions: Bool,
) -> Simulation {
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(app, subject, int.max(interval_ms, 1), dict.new(), 0)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Simulation(subject, label_sessions)
}

pub fn register(app: server.Server, simulation: Simulation) -> server.Server {
  server.register_context_tool_descriptor(
    app,
    helpers.descriptor(
      "toggle-subscriber-updates",
      "Toggle Subscriber Updates",
      "Toggles simulated resource subscription updates on or off.",
      helpers.empty_schema(),
      None,
      helpers.interactive_annotations(False),
    ),
    fn(_, context, _) { toggle_tool(simulation, context) },
  )
}

pub fn toggle_tool(
  simulation: Simulation,
  context: server.RequestContext,
) -> Result(actions.CallToolResult, jsonrpc.RpcError) {
  case server.session_id(context) {
    None ->
      Error(jsonrpc.invalid_params_error(
        "toggle-subscriber-updates requires a session-based transport",
      ))
    Some(id) -> {
      let reply = process.new_subject()
      process.send(simulation.subject, Toggle(id, reply))
      let assert Ok(enabled) = process.receive(reply, 1000)
      let display_id = case simulation.label_sessions {
        True -> id
        False -> "undefined"
      }
      Ok(
        helpers.text_result(case enabled {
          True ->
            "Started simulated resource updated notifications for session "
            <> display_id
            <> " at a 5 second pace. Client will receive updates for any resources the it is subscribed to."
          False ->
            "Stopped simulated resource updates for session " <> display_id
        }),
      )
    }
  }
}

pub fn close_session(simulation: Simulation, id: String) -> Nil {
  let reply = process.new_subject()
  process.send(simulation.subject, Close(id, reply))
  let _ = process.receive(reply, 1000)
  Nil
}

pub fn stop(simulation: Simulation) -> Nil {
  let reply = process.new_subject()
  process.send(simulation.subject, Stop(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

fn loop(
  app: server.Server,
  subject: process.Subject(Message),
  interval_ms: Int,
  intervals: dict.Dict(String, Interval),
  generation: Int,
) -> Nil {
  case process.receive_forever(subject) {
    Toggle(id, reply) -> {
      let next = case dict.get(intervals, id) {
        Ok(interval) -> {
          cancel(interval)
          dict.delete(intervals, id)
        }
        Error(_) -> {
          emit(app, id)
          dict.insert(
            intervals,
            id,
            Interval(
              generation,
              process.send_after(subject, interval_ms, Tick(id, generation)),
            ),
          )
        }
      }
      process.send(reply, dict.has_key(next, id))
      loop(app, subject, interval_ms, next, generation + 1)
    }
    Tick(id, token) -> {
      let next = case dict.get(intervals, id) {
        Ok(Interval(current, _)) if current == token -> {
          case server.has_streamable_http_session(app, id) {
            True -> {
              emit(app, id)
              dict.insert(
                intervals,
                id,
                Interval(
                  token,
                  process.send_after(subject, interval_ms, Tick(id, token)),
                ),
              )
            }
            False -> dict.delete(intervals, id)
          }
        }
        _ -> intervals
      }
      loop(app, subject, interval_ms, next, generation)
    }
    Close(id, reply) -> {
      case dict.get(intervals, id) {
        Ok(interval) -> cancel(interval)
        _ -> Nil
      }
      process.send(reply, Nil)
      loop(app, subject, interval_ms, dict.delete(intervals, id), generation)
    }
    Stop(reply) -> {
      list.each(dict.values(intervals), cancel)
      process.send(reply, Nil)
    }
  }
}

fn emit(app: server.Server, id: String) -> Nil {
  server.resource_subscriptions(app, id)
  |> list.each(fn(uri) {
    let _ =
      server.send_notification(
        app,
        server.RequestContext(Some(id), None),
        jsonrpc.Notification(
          mcp.method_notify_resource_updated,
          Some(
            actions.NotifyResourceUpdated(
              actions.ResourceUpdatedNotificationParams(uri, None),
            ),
          ),
        ),
      )
    Nil
  })
}

fn cancel(interval: Interval) -> Nil {
  let _ = process.cancel_timer(interval.timer)
  Nil
}
