import gleam/erlang/process
import gleam/list

/// Lifecycle state shared by immutable copies of a client.
pub opaque type Control {
  Control(process.Subject(Message))
}

type Message {
  Open(process.Subject(Int))
  Close(Int, process.Subject(Nil))
  IsOpen(Int, process.Subject(Bool))
  AwaitClosed(Int, process.Subject(Nil))
  Watch(Int, process.Subject(Nil), process.Subject(Nil))
  Unwatch(process.Subject(Nil), process.Subject(Nil))
}

pub fn new() -> Control {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(subject, 0, True, [])
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Control(subject)
}

pub fn open(control: Control) -> Int {
  let Control(subject) = control
  let reply = process.new_subject()
  process.send(subject, Open(reply))
  let assert Ok(generation) = process.receive(reply, 1000)
  generation
}

pub fn close(control: Control, generation: Int) -> Nil {
  let Control(subject) = control
  let reply = process.new_subject()
  process.send(subject, Close(generation, reply))
  let assert Ok(Nil) = process.receive(reply, 1000)
  Nil
}

pub fn is_open(control: Control, generation: Int) -> Bool {
  let Control(subject) = control
  let reply = process.new_subject()
  process.send(subject, IsOpen(generation, reply))
  let assert Ok(open) = process.receive(reply, 1000)
  open
}

pub fn await_closed(control: Control, generation: Int) -> Nil {
  let Control(subject) = control
  let reply = process.new_subject()
  process.send(subject, AwaitClosed(generation, reply))
  process.receive_forever(reply)
}

/// Notify a caller-owned subject when its client generation closes.
pub fn watch(
  control: Control,
  generation: Int,
  stop: process.Subject(Nil),
) -> Nil {
  let Control(subject) = control
  let registered = process.new_subject()
  process.send(subject, Watch(generation, stop, registered))
  let assert Ok(Nil) = process.receive(registered, 1000)
  Nil
}

pub fn unwatch(control: Control, stop: process.Subject(Nil)) -> Nil {
  let Control(subject) = control
  let removed = process.new_subject()
  process.send(subject, Unwatch(stop, removed))
  let assert Ok(Nil) = process.receive(removed, 1000)
  Nil
}

fn loop(
  subject: process.Subject(Message),
  generation: Int,
  open: Bool,
  waiters: List(process.Subject(Nil)),
) -> Nil {
  case process.receive_forever(subject) {
    Open(reply) -> {
      notify_closed(waiters)
      process.send(reply, generation + 1)
      loop(subject, generation + 1, True, [])
    }
    Close(requested, reply) -> {
      case requested == generation {
        True -> {
          notify_closed(waiters)
          process.send(reply, Nil)
          loop(subject, generation, False, [])
        }
        False -> {
          process.send(reply, Nil)
          loop(subject, generation, open, waiters)
        }
      }
    }
    IsOpen(requested, reply) -> {
      process.send(reply, open && requested == generation)
      loop(subject, generation, open, waiters)
    }
    AwaitClosed(requested, reply) -> {
      case open && requested == generation {
        True -> loop(subject, generation, open, [reply, ..waiters])
        False -> {
          process.send(reply, Nil)
          loop(subject, generation, open, waiters)
        }
      }
    }
    Watch(requested, stop, registered) -> {
      let next = case open && requested == generation {
        True -> [stop, ..waiters]
        False -> {
          process.send(stop, Nil)
          waiters
        }
      }
      process.send(registered, Nil)
      loop(subject, generation, open, next)
    }
    Unwatch(stop, removed) -> {
      let next = list.filter(waiters, fn(waiter) { waiter != stop })
      process.send(removed, Nil)
      loop(subject, generation, open, next)
    }
  }
}

fn notify_closed(waiters: List(process.Subject(Nil))) -> Nil {
  list.each(waiters, fn(waiter) { process.send(waiter, Nil) })
}
