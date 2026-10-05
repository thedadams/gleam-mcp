//// Generated resources are isolated by legacy session, stdio connection,
//// or authenticated principal. Anonymous HTTP links contain random capability
//// tokens and are never included in another callers resource listing.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/uri
import gleam_mcp/actions
import gleam_mcp/jsonrpc
import gleam_mcp/server
import youid/uuid

pub type TransportMode {
  Stdio
  StreamableHttp
}

pub opaque type Store {
  Store(mode: TransportMode, subject: process.Subject(Command))
}

type Owner {
  Session(String)
  Principal(String)
  Direct
  Capability
}

type Entry {
  Entry(
    owner: Owner,
    resource: actions.Resource,
    content: actions.ResourceContents,
  )
}

type Command {
  Put(Entry, process.Subject(Nil))
  Entries(Owner, process.Subject(List(Entry)))
  ReadCapability(String, process.Subject(Option(actions.ResourceContents)))
  CloseSession(String)
  Stop(process.Subject(Nil))
}

pub fn new(mode: TransportMode) -> Store {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let commands = process.new_subject()
      process.send(ready, commands)
      loop(commands, dict.new())
    })
  Store(mode, process.receive_forever(ready))
}

pub fn put_blob(
  store: Store,
  context: server.RequestContext,
  name: String,
  blob: String,
) -> actions.Resource {
  let owner = owner(store.mode, context)
  let resource_uri = case owner {
    Capability ->
      "demo://resource/session/"
      <> uuid.v4_string()
      <> "/"
      <> uri.percent_encode(name)
    Principal(_) -> "demo://resource/session/" <> uri.percent_encode(name)
    Session(_) | Direct -> "demo://resource/session/" <> name
  }
  let resource =
    actions.Resource(
      resource_uri,
      name,
      None,
      None,
      Some("application/gzip"),
      None,
      None,
      [],
      None,
    )
  let content =
    actions.BlobResourceContents(
      resource_uri,
      Some("application/gzip"),
      blob,
      None,
    )
  let reply = process.new_subject()
  process.send(store.subject, Put(Entry(owner, resource, content), reply))
  process.receive_forever(reply)
  resource
}

pub fn projection(
  store: Store,
) -> fn(server.Server, server.RequestContext) -> server.Server {
  fn(app, context) {
    let owner = owner(store.mode, context)
    let reply = process.new_subject()
    process.send(store.subject, Entries(owner, reply))
    let entries = process.receive_forever(reply)
    let app =
      list.fold(entries, app, fn(app, entry) {
        server.register_resource_descriptor(app, entry.resource, fn() {
          Ok([entry.content])
        })
      })
    case owner {
      Capability ->
        server.add_resource_template(
          app,
          "demo://resource/session/{token}/{name}",
          "Session Resource",
          "Generated resources accessible only through their opaque resource links",
          Some("application/gzip"),
          fn(uri) {
            let reply = process.new_subject()
            process.send(store.subject, ReadCapability(uri, reply))
            case process.receive_forever(reply) {
              Some(content) -> Ok([content])
              None ->
                Error(jsonrpc.invalid_params_error("Unknown session resource"))
            }
          },
        )
      _ -> app
    }
  }
}

pub fn close_session(store: Store, session_id: String) -> Nil {
  process.send(store.subject, CloseSession(session_id))
}

pub fn stop(store: Store) -> Nil {
  let reply = process.new_subject()
  process.send(store.subject, Stop(reply))
  process.receive_forever(reply)
}

fn owner(mode: TransportMode, context: server.RequestContext) -> Owner {
  case context {
    server.ModernRequestContext(
      transport_scope: scope,
      principal: principal,
      ..,
    ) ->
      case mode {
        Stdio -> Session(scope)
        StreamableHttp ->
          case principal {
            Some(principal) -> Principal(principal)
            None -> Capability
          }
      }
    _ ->
      case server.session_id(context) {
        Some(id) -> Session(id)
        None -> Direct
      }
  }
}

fn loop(
  subject: process.Subject(Command),
  entries: dict.Dict(#(Owner, String), Entry),
) -> Nil {
  case process.receive_forever(subject) {
    Put(entry, reply) -> {
      process.send(reply, Nil)
      loop(
        subject,
        dict.insert(entries, #(entry.owner, entry.resource.uri), entry),
      )
    }
    Entries(owner, reply) -> {
      let visible = case owner {
        Capability -> []
        _ ->
          dict.values(entries)
          |> list.filter(fn(entry) { entry.owner == owner })
      }
      process.send(reply, visible)
      loop(subject, entries)
    }
    ReadCapability(uri, reply) -> {
      let content =
        dict.get(entries, #(Capability, uri))
        |> option.from_result
        |> option.map(fn(entry) { entry.content })
      process.send(reply, content)
      loop(subject, entries)
    }
    CloseSession(id) ->
      loop(
        subject,
        dict.filter(entries, fn(_, entry) { entry.owner != Session(id) }),
      )
    Stop(reply) -> process.send(reply, Nil)
  }
}
