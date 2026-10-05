import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam_mcp/server
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

type Event {
  Event(id: String, stream: String, payload: String)
}

type Message {
  Record(String, String, String, process.Subject(String))
  Replay(String, String, process.Subject(List(#(String, String))))
  Resume(String, String, process.Subject(Option(String)))
  Clear(String)
  Stop
}

pub fn new() -> Store {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(sessions, message) {
      case message {
        Record(session, stream, payload, reply) -> {
          let id = uuid.v4_string()
          let events = case dict.get(sessions, session) {
            Ok(events) -> events
            Error(_) -> []
          }
          process.send(reply, id)
          actor.continue(
            dict.insert(sessions, session, [
              Event(id, stream, payload),
              ..events
            ]),
          )
        }
        Replay(session, after, reply) -> {
          let events = case dict.get(sessions, session) {
            Ok(events) -> list.reverse(events)
            Error(_) -> []
          }
          let remaining =
            list.drop_while(events, fn(event) { event.id != after })
          let replay = case remaining {
            [origin, ..later] ->
              later
              |> list.filter(fn(event) { event.stream == origin.stream })
              |> list.map(fn(event) { #(event.id, event.payload) })
            [] -> []
          }
          process.send(reply, replay)
          actor.continue(sessions)
        }
        Resume(session, id, reply) -> {
          let stream = case dict.get(sessions, session) {
            Ok(events) ->
              case list.find(events, fn(event) { event.id == id }) {
                Ok(event) -> Some(event.stream)
                Error(_) -> None
              }
            Error(_) -> None
          }
          process.send(reply, stream)
          actor.continue(sessions)
        }
        Clear(session) -> actor.continue(dict.delete(sessions, session))
        Stop -> actor.stop()
      }
    })
    |> actor.start
  Store(started.data)
}

pub fn adapter(store: Store) -> server.LegacyEventStore {
  server.ResumableLegacyEventStore(
    record: fn(session, stream, payload) {
      let reply = process.new_subject()
      process.send(store.subject, Record(session, stream, payload, reply))
      let assert Ok(id) = process.receive(reply, 1000)
      id
    },
    replay: fn(session, after) {
      let reply = process.new_subject()
      process.send(store.subject, Replay(session, after, reply))
      let assert Ok(events) = process.receive(reply, 1000)
      events
    },
    resume: fn(session, id) {
      let reply = process.new_subject()
      process.send(store.subject, Resume(session, id, reply))
      let assert Ok(stream) = process.receive(reply, 1000)
      stream
    },
  )
}

pub fn close_session(store: Store, session: String) -> Nil {
  process.send(store.subject, Clear(session))
}

pub fn stop(store: Store) -> Nil {
  process.send(store.subject, Stop)
}
