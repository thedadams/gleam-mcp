//// Messages between replicas of one server, carried over a glyn PubSub.
////
//// Live state stays with the replica that owns it: SSE connections, request
//// workers and pending server requests never move. Replicas instead send each
//// other plain-data events, so that a request arriving at one replica can
//// reach a connection or worker held by another. Events cross nodes as a
//// versioned JSON envelope; one a replica cannot decode is dropped, which
//// keeps mixed versions running during a rolling deploy.
////
//// Replicas find each other through Erlang distribution: connect the nodes
//// (see `connect`) and give every replica the same cluster name.

import envoy
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/jsonrpc
import glyn/pubsub

const envelope_version = 1

/// One glyn scope serves every server on a node; cluster names keep their
/// groups apart.
const scope = "gleam_mcp"

pub opaque type Cluster {
  Cluster(
    pubsub: pubsub.PubSub(String),
    name: String,
    replica: String,
    shared: Bool,
  )
}

/// A cluster of one, which no other replica can join.
pub fn private(replica: String) -> Cluster {
  Cluster(new_pubsub(), "private/" <> replica, replica, False)
}

/// Join the cluster called `name`. Every replica of a server must use the
/// same name, and no other server may use it.
pub fn shared(name: String, replica: String) -> Cluster {
  Cluster(new_pubsub(), "shared/" <> name, replica, True)
}

fn new_pubsub() -> pubsub.PubSub(String) {
  pubsub.new(scope, decode.string, "")
}

/// Whether other replicas may share this cluster.
pub fn is_shared(cluster: Cluster) -> Bool {
  cluster.shared
}

/// The id of this replica.
pub fn replica(cluster: Cluster) -> String {
  cluster.replica
}

/// Whether the replica with the given id is still running.
pub fn alive(cluster: Cluster, replica: String) -> Bool {
  replica == cluster.replica
  || pubsub.subscriber_count(cluster.pubsub, group(cluster, Replica(replica)))
  > 0
}

pub type Topic {
  /// Every replica.
  Broadcast
  /// The replicas holding state for a 2025-11-25 session.
  Session(String)
  /// One replica, joined only to show that it is running.
  Replica(String)
}

pub type Event {
  /// A replica opened a session stream that should receive session messages.
  ListenerAttached(listener: String, attached_at: Int)
  ListenerDetached(listener: String)
  /// A replica joined the session; holders of session streams re-announce.
  ListenersRequested
  /// Write to a session stream held by the receiving replica.
  Write(
    listener: String,
    event_id: Option(String),
    payload: String,
    close: Bool,
  )
  /// A notification for whichever replica holds the session's newest stream.
  Notify(payload: String)
  /// The client's response to a server-sent request.
  ClientResponse(body: String)
  CancelRequest(id: jsonrpc.RequestId)
  CloseSession
  /// A notification for 2026-07-28 subscriptions on every replica.
  Notification(payload: String)
  TaskChanged(task: String)
  TaskInputs(
    task: String,
    scope: Option(String),
    inputs: Dict(String, jsonrpc.Value),
  )
}

pub type Envelope {
  Envelope(from: String, topic: Topic, event: Event)
}

/// Send an event to every replica in the topic other than this one.
pub fn publish(cluster: Cluster, topic: Topic, event: Event) -> Nil {
  let _ =
    pubsub.publish(
      cluster.pubsub,
      group(cluster, topic),
      encode(Envelope(cluster.replica, topic, event)),
    )
  Nil
}

fn group(cluster: Cluster, topic: Topic) -> String {
  cluster.name
  <> case topic {
    Broadcast -> "/broadcast"
    Session(id) -> "/session/" <> id
    Replica(id) -> "/replica/" <> id
  }
}

/// Connect this node to the named peers, such as `mcp@app-0.app.default`.
/// Returns the peers that could not be reached. Call it periodically, since a
/// restarted peer must be connected again.
pub fn connect(peers: List(String)) -> List(String) {
  let connected =
    node.visible()
    |> list.map(fn(peer) { atom.to_string(node.name(peer)) })
  let self = atom.to_string(node.name(node.self()))
  peers
  |> list.filter(fn(peer) { peer != self && !list.contains(connected, peer) })
  |> list.filter(fn(peer) { node.connect(atom.create(peer)) |> result.is_error })
}

/// Read peer node names from a comma-separated environment variable, such as
/// `MCP_CLUSTER_PEERS=mcp@app-0.app,mcp@app-1.app`.
pub fn peers_from_env(variable: String) -> List(String) {
  case envoy.get(variable) {
    Ok(value) ->
      value
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(peer) { peer != "" })
    Error(Nil) -> []
  }
}

pub opaque type ConnectorMessage {
  Reconnect
}

/// Keep this node connected to `peers`, retrying every `interval_ms` so that
/// restarted peers rejoin.
pub fn start_connector(
  peers: List(String),
  interval_ms: Int,
) -> actor.StartResult(process.Subject(ConnectorMessage)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.send(subject, Reconnect)
    actor.initialised(subject) |> actor.returning(subject) |> Ok
  })
  |> actor.on_message(fn(subject, message) {
    case message {
      Reconnect -> {
        let _ = connect(peers)
        process.send_after(subject, interval_ms, Reconnect)
        actor.continue(subject)
      }
    }
  })
  |> actor.start
}

pub fn supervised_connector(
  peers: List(String),
  interval_ms: Int,
) -> supervision.ChildSpecification(process.Subject(ConnectorMessage)) {
  supervision.worker(fn() { start_connector(peers, interval_ms) })
}

/// Handlers the relay calls for events from other replicas.
pub type Handlers {
  Handlers(
    listener_attached: fn(String, String, Int, String) -> Nil,
    listener_detached: fn(String, String) -> Nil,
    listeners_requested: fn(String) -> Nil,
    write: fn(String, String, Option(String), String, Bool) -> Nil,
    notify: fn(String, String) -> Nil,
    client_response: fn(String, String) -> Nil,
    cancel_request: fn(String, jsonrpc.RequestId) -> Nil,
    close_session: fn(String) -> Nil,
    notification: fn(String) -> Nil,
    task_changed: fn(String) -> Nil,
    task_inputs: fn(String, Option(String), Dict(String, jsonrpc.Value)) -> Nil,
    /// Sessions this replica already holds state for.
    sessions: fn() -> List(String),
  )
}

pub opaque type RelayMessage {
  Received(String)
  Join(String, process.Subject(Nil))
  Leave(String)
}

type Relay {
  Relay(
    cluster: Cluster,
    handlers: Handlers,
    subject: process.Subject(RelayMessage),
    selector: process.Selector(RelayMessage),
    sessions: Set(String),
  )
}

/// Join the topics this replica receives and dispatch their events.
pub fn start_relay(
  name: process.Name(RelayMessage),
  cluster: Cluster,
  handlers: Handlers,
) -> actor.StartResult(process.Subject(RelayMessage)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> subscribe(cluster, Broadcast)
      |> subscribe(cluster, Replica(cluster.replica))
    let relay =
      handlers.sessions()
      |> list.fold(
        Relay(cluster, handlers, subject, selector, set.new()),
        join_session,
      )
    actor.initialised(relay)
    |> actor.selecting(relay.selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle_relay_message)
  |> actor.start
}

pub fn supervised_relay(
  name: process.Name(RelayMessage),
  cluster: Cluster,
  handlers: Handlers,
) -> supervision.ChildSpecification(process.Subject(RelayMessage)) {
  supervision.worker(fn() { start_relay(name, cluster, handlers) })
}

/// Receive events for a session, returning once they will arrive. Does
/// nothing while the relay is not running.
pub fn join(relay: process.Name(RelayMessage), session: String) -> Nil {
  case process.named(relay) {
    Ok(_) -> process.call(process.named_subject(relay), 1000, Join(session, _))
    Error(Nil) -> Nil
  }
}

/// Stop receiving events for a session.
pub fn leave(relay: process.Name(RelayMessage), session: String) -> Nil {
  case process.named(relay) {
    Ok(_) -> process.send(process.named_subject(relay), Leave(session))
    Error(Nil) -> Nil
  }
}

fn subscribe(
  selector: process.Selector(RelayMessage),
  cluster: Cluster,
  topic: Topic,
) -> process.Selector(RelayMessage) {
  pubsub.subscribe(cluster.pubsub, group(cluster, topic))
  |> process.map_selector(Received)
  |> process.merge_selector(selector, _)
}

fn join_session(relay: Relay, session: String) -> Relay {
  case set.contains(relay.sessions, session) {
    True -> relay
    False ->
      Relay(
        ..relay,
        selector: subscribe(relay.selector, relay.cluster, Session(session)),
        sessions: set.insert(relay.sessions, session),
      )
  }
}

fn handle_relay_message(
  relay: Relay,
  message: RelayMessage,
) -> actor.Next(Relay, RelayMessage) {
  case message {
    Join(session, reply) -> {
      let joined = join_session(relay, session)
      process.send(reply, Nil)
      case joined.sessions == relay.sessions {
        True -> actor.continue(relay)
        False -> {
          // Learn about streams other replicas opened before this one joined.
          publish(relay.cluster, Session(session), ListenersRequested)
          actor.continue(joined) |> actor.with_selector(joined.selector)
        }
      }
    }
    Leave(session) -> {
      pubsub.unsubscribe(
        relay.cluster.pubsub,
        group(relay.cluster, Session(session)),
      )
      actor.continue(
        Relay(..relay, sessions: set.delete(relay.sessions, session)),
      )
    }
    Received(raw) -> {
      case decode_envelope(raw) {
        Ok(envelope) if envelope.from != relay.cluster.replica ->
          dispatch(relay.handlers, envelope)
        _ -> Nil
      }
      actor.continue(relay)
    }
  }
}

fn dispatch(handlers: Handlers, envelope: Envelope) -> Nil {
  case envelope.topic, envelope.event {
    Session(id), ListenerAttached(listener, attached_at) ->
      handlers.listener_attached(id, listener, attached_at, envelope.from)
    Session(id), ListenerDetached(listener) ->
      handlers.listener_detached(id, listener)
    Session(id), ListenersRequested -> handlers.listeners_requested(id)
    Session(id), Write(listener, event_id, payload, close) ->
      handlers.write(id, listener, event_id, payload, close)
    Session(id), Notify(payload) -> handlers.notify(id, payload)
    Session(id), ClientResponse(body) -> handlers.client_response(id, body)
    Session(id), CancelRequest(request) -> handlers.cancel_request(id, request)
    Session(id), CloseSession -> handlers.close_session(id)
    Broadcast, Notification(payload) -> handlers.notification(payload)
    Broadcast, TaskChanged(task) -> handlers.task_changed(task)
    Broadcast, TaskInputs(task, scope, inputs) ->
      handlers.task_inputs(task, scope, inputs)
    _, _ -> Nil
  }
}

pub fn encode(envelope: Envelope) -> String {
  let #(topic, topic_id) = case envelope.topic {
    Broadcast -> #("broadcast", "")
    Session(id) -> #("session", id)
    Replica(id) -> #("replica", id)
  }
  let #(kind, fields) = case envelope.event {
    ListenerAttached(listener, attached_at) -> #("listener_attached", [
      #("listener", json.string(listener)),
      #("attached_at", json.int(attached_at)),
    ])
    ListenerDetached(listener) -> #("listener_detached", [
      #("listener", json.string(listener)),
    ])
    ListenersRequested -> #("listeners_requested", [])
    Write(listener, event_id, payload, close) -> #("write", [
      #("listener", json.string(listener)),
      #("event_id", json.nullable(event_id, json.string)),
      #("payload", json.string(payload)),
      #("close", json.bool(close)),
    ])
    Notify(payload) -> #("notify", [#("payload", json.string(payload))])
    ClientResponse(body) -> #("client_response", [#("body", json.string(body))])
    CancelRequest(id) -> #("cancel_request", [
      #("id", codec_common.encode_value(jsonrpc.request_id_to_value(id))),
    ])
    CloseSession -> #("close_session", [])
    Notification(payload) -> #("notification", [
      #("payload", json.string(payload)),
    ])
    TaskChanged(task) -> #("task_changed", [#("task", json.string(task))])
    TaskInputs(task, scope, inputs) -> #("task_inputs", [
      #("task", json.string(task)),
      #("scope", json.nullable(scope, json.string)),
      #(
        "inputs",
        codec_common.encode_value(jsonrpc.VObject(dict.to_list(inputs))),
      ),
    ])
  }
  json.object([
    #("v", json.int(envelope_version)),
    #("from", json.string(envelope.from)),
    #("topic", json.string(topic)),
    #("topic_id", json.string(topic_id)),
    #("kind", json.string(kind)),
    ..fields
  ])
  |> json.to_string
}

pub fn decode_envelope(raw: String) -> Result(Envelope, Nil) {
  json.parse(raw, envelope_decoder()) |> result.replace_error(Nil)
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use version <- decode.field("v", decode.int)
  use from <- decode.field("from", decode.string)
  use topic <- decode.field("topic", decode.string)
  use topic_id <- decode.field("topic_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  let topic = case topic {
    "broadcast" -> Ok(Broadcast)
    "session" -> Ok(Session(topic_id))
    "replica" -> Ok(Replica(topic_id))
    _ -> Error(Nil)
  }
  case version == envelope_version, topic {
    True, Ok(topic) -> {
      use event <- decode.then(event_decoder(kind))
      decode.success(Envelope(from, topic, event))
    }
    _, _ -> decode.failure(Envelope(from, Broadcast, CloseSession), "Envelope")
  }
}

fn event_decoder(kind: String) -> decode.Decoder(Event) {
  case kind {
    "listener_attached" -> {
      use listener <- decode.field("listener", decode.string)
      use attached_at <- decode.field("attached_at", decode.int)
      decode.success(ListenerAttached(listener, attached_at))
    }
    "listener_detached" -> {
      use listener <- decode.field("listener", decode.string)
      decode.success(ListenerDetached(listener))
    }
    "listeners_requested" -> decode.success(ListenersRequested)
    "write" -> {
      use listener <- decode.field("listener", decode.string)
      use event_id <- decode.field("event_id", decode.optional(decode.string))
      use payload <- decode.field("payload", decode.string)
      use close <- decode.field("close", decode.bool)
      decode.success(Write(listener, event_id, payload, close))
    }
    "notify" -> {
      use payload <- decode.field("payload", decode.string)
      decode.success(Notify(payload))
    }
    "client_response" -> {
      use body <- decode.field("body", decode.string)
      decode.success(ClientResponse(body))
    }
    "cancel_request" -> {
      use id <- decode.field("id", codec_common.request_id_decoder())
      decode.success(CancelRequest(id))
    }
    "close_session" -> decode.success(CloseSession)
    "notification" -> {
      use payload <- decode.field("payload", decode.string)
      decode.success(Notification(payload))
    }
    "task_changed" -> {
      use task <- decode.field("task", decode.string)
      decode.success(TaskChanged(task))
    }
    "task_inputs" -> {
      use task <- decode.field("task", decode.string)
      use scope <- decode.field("scope", decode.optional(decode.string))
      use inputs <- decode.field("inputs", codec_decode.value_dict_decoder())
      decode.success(TaskInputs(task, scope, inputs))
    }
    _ -> decode.failure(CloseSession, "Event")
  }
}
