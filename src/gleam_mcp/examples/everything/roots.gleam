import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

type Message {
  Fetch(context: server.RequestContext, force: Bool, reply: Option(Reply))
  Fetched(
    id: String,
    generation: Int,
    result: Result(List(actions.Root), jsonrpc.RpcError),
  )
  WorkerDown(process.Down)
  Close(id: String, reply: process.Subject(Nil))
  Stop(reply: process.Subject(Nil))
}

type Reply =
  process.Subject(Result(List(actions.Root), jsonrpc.RpcError))

type Entry {
  Cached(roots: List(actions.Root))
  Loading(
    generation: Int,
    pid: process.Pid,
    monitor: process.Monitor,
    waiters: List(Reply),
    previous: Option(List(actions.Root)),
    refresh: Option(server.RequestContext),
  )
}

pub fn new(app: server.Server) -> Store {
  new_store(app, None)
}

pub fn new_with_logger(
  app: server.Server,
  logger: http_logging.Logger,
) -> Store {
  new_store(app, Some(logger))
}

fn new_store(app: server.Server, logger: Option(http_logging.Logger)) -> Store {
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      loop(app, logger, subject, dict.new(), 0)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Store(subject)
}

pub fn register(app: server.Server, store: Store) -> server.Server {
  server.register_context_tool_descriptor(
    app,
    helpers.descriptor(
      "get-roots-list",
      "Get Roots List Tool",
      "Lists the current MCP roots provided by the client. Demonstrates the roots protocol capability even though this server doesn't access files.",
      helpers.empty_schema(),
      None,
      helpers.read_only_annotations(),
    ),
    fn(_, context, _) {
      fetch(store, context)
      |> result.map(fn(roots) { helpers.text_result(format_roots(roots)) })
    },
  )
}

pub fn sync(store: Store, context: server.RequestContext, force: Bool) -> Nil {
  process.send(store.subject, Fetch(context, force, None))
}

pub fn fetch(
  store: Store,
  context: server.RequestContext,
) -> Result(List(actions.Root), jsonrpc.RpcError) {
  let reply = process.new_subject()
  process.send(store.subject, Fetch(context, False, Some(reply)))
  case process.receive(reply, 3_600_000) {
    Ok(value) -> value
    Error(_) -> Error(internal_error("Timed out waiting for client roots"))
  }
}

pub fn close_session(store: Store, id: String) -> Nil {
  let reply = process.new_subject()
  process.send(store.subject, Close(id, reply))
  let _ = process.receive(reply, 1000)
  Nil
}

pub fn stop(store: Store) -> Nil {
  let reply = process.new_subject()
  process.send(store.subject, Stop(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

fn loop(
  app: server.Server,
  logger: Option(http_logging.Logger),
  subject: process.Subject(Message),
  entries: dict.Dict(String, Entry),
  generation: Int,
) -> Nil {
  let message =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(WorkerDown)
    |> process.selector_receive_forever
  case message {
    Fetch(context, force, reply) -> {
      case server.session_id(context) {
        None -> {
          reply_to(
            reply,
            Error(jsonrpc.invalid_params_error(
              "Roots require a session-based transport",
            )),
          )
          loop(app, logger, subject, entries, generation)
        }
        Some(id) -> {
          case supports_roots(app, id) {
            False -> {
              reply_to(
                reply,
                Error(jsonrpc.invalid_params_error(
                  "Client does not support roots",
                )),
              )
              loop(app, logger, subject, entries, generation)
            }
            True ->
              case dict.get(entries, id), force {
                Ok(Cached(roots)), False -> {
                  reply_to(reply, Ok(roots))
                  loop(app, logger, subject, entries, generation)
                }
                Ok(Loading(token, pid, monitor, waiters, previous, refresh)), _
                -> {
                  let waiters = case previous, reply {
                    Some(roots), _ -> {
                      reply_to(reply, Ok(roots))
                      waiters
                    }
                    None, Some(reply) -> [reply, ..waiters]
                    None, None -> waiters
                  }
                  // A roots change can arrive before the current reply reflects it.
                  // Coalesce changes into one follow-up without cancelling that RPC.
                  let refresh = case force {
                    True -> Some(context)
                    False -> refresh
                  }
                  loop(
                    app,
                    logger,
                    subject,
                    dict.insert(
                      entries,
                      id,
                      Loading(token, pid, monitor, waiters, previous, refresh),
                    ),
                    generation,
                  )
                }
                previous, _ -> {
                  let previous = case previous {
                    Ok(Cached(roots)) -> Some(roots)
                    _ -> None
                  }
                  let waiters = case reply {
                    Some(reply) -> [reply]
                    None -> []
                  }
                  loop(
                    app,
                    logger,
                    subject,
                    dict.insert(
                      entries,
                      id,
                      start_loading(
                        app,
                        subject,
                        id,
                        context,
                        generation,
                        waiters,
                        previous,
                      ),
                    ),
                    generation + 1,
                  )
                }
              }
          }
        }
      }
    }
    Fetched(id, token, fetched) -> {
      case dict.get(entries, id) {
        Ok(Loading(current, _, monitor, waiters, previous, refresh))
          if current == token
        -> {
          process.demonitor_process(monitor)
          list.each(waiters, fn(reply) { process.send(reply, fetched) })
          let retained = case fetched {
            Ok(roots) -> {
              log_roots(app, logger, id, list.length(roots))
              Some(roots)
            }
            Error(_) -> previous
          }
          let #(next, generation) =
            finish_loading(
              app,
              subject,
              entries,
              id,
              retained,
              refresh,
              generation,
            )
          loop(app, logger, subject, next, generation)
        }
        _ -> loop(app, logger, subject, entries, generation)
      }
    }
    WorkerDown(down) -> {
      let #(next, generation) =
        list.fold(dict.to_list(entries), #(entries, generation), fn(acc, entry) {
          case entry.1 {
            Loading(_, _, monitor, waiters, previous, refresh)
              if monitor == down.monitor
            -> {
              list.each(waiters, fn(reply) {
                process.send(
                  reply,
                  Error(internal_error("Client roots request failed")),
                )
              })
              finish_loading(
                app,
                subject,
                acc.0,
                entry.0,
                previous,
                refresh,
                acc.1,
              )
            }
            _ -> acc
          }
        })
      loop(app, logger, subject, next, generation)
    }
    Close(id, reply) -> {
      case dict.get(entries, id) {
        Ok(entry) -> cleanup(entry)
        _ -> Nil
      }
      process.send(reply, Nil)
      loop(app, logger, subject, dict.delete(entries, id), generation)
    }
    Stop(reply) -> {
      list.each(dict.values(entries), cleanup)
      process.send(reply, Nil)
    }
  }
}

fn start_loading(
  app: server.Server,
  subject: process.Subject(Message),
  id: String,
  context: server.RequestContext,
  generation: Int,
  waiters: List(Reply),
  previous: Option(List(actions.Root)),
) -> Entry {
  let pid =
    process.spawn_unlinked(fn() {
      process.send(
        subject,
        Fetched(id, generation, request_roots(app, context)),
      )
    })
  Loading(generation, pid, process.monitor(pid), waiters, previous, None)
}

fn finish_loading(
  app: server.Server,
  subject: process.Subject(Message),
  entries: dict.Dict(String, Entry),
  id: String,
  retained: Option(List(actions.Root)),
  refresh: Option(server.RequestContext),
  generation: Int,
) -> #(dict.Dict(String, Entry), Int) {
  case refresh {
    Some(context) -> #(
      dict.insert(
        entries,
        id,
        start_loading(app, subject, id, context, generation, [], retained),
      ),
      generation + 1,
    )
    None -> #(
      case retained {
        Some(roots) -> dict.insert(entries, id, Cached(roots))
        None -> dict.delete(entries, id)
      },
      generation,
    )
  }
}

fn cleanup(entry: Entry) -> Nil {
  case entry {
    Cached(_) -> Nil
    Loading(_, pid, monitor, waiters, _, _) -> {
      process.demonitor_process(monitor)
      process.kill(pid)
      list.each(waiters, fn(reply) {
        process.send(reply, Error(internal_error("Client session closed")))
      })
    }
  }
}

fn reply_to(
  reply: Option(Reply),
  value: Result(List(actions.Root), jsonrpc.RpcError),
) -> Nil {
  case reply {
    Some(reply) -> process.send(reply, value)
    None -> Nil
  }
}

fn supports_roots(app: server.Server, id: String) -> Bool {
  case server.session_metadata(app, id) {
    Some(meta) ->
      case meta.client_capabilities.roots {
        Some(_) -> True
        None -> False
      }
    None -> False
  }
}

fn request_roots(
  app: server.Server,
  context: server.RequestContext,
) -> Result(List(actions.Root), jsonrpc.RpcError) {
  case
    server.send_request(
      app,
      context,
      jsonrpc.Request(
        jsonrpc.StringId(uuid.v4_string()),
        mcp.method_list_roots,
        Some(actions.ServerRequestListRoots(None)),
      ),
    )
  {
    Ok(jsonrpc.ResultResponse(_, actions.ServerResultListRoots(result))) ->
      Ok(result.roots)
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(error)
    Error(error) -> Error(error)
    _ ->
      Error(jsonrpc.invalid_params_error(
        "Client returned an unexpected roots result",
      ))
  }
}

fn log_roots(
  app: server.Server,
  logger: Option(http_logging.Logger),
  id: String,
  count: Int,
) -> Nil {
  let params =
    actions.LoggingMessageNotificationParams(
      actions.Info,
      Some("everything-server"),
      jsonrpc.VString(
        "Roots updated: "
        <> int.to_string(count)
        <> " root(s) received from client",
      ),
      None,
    )
  case logger {
    Some(logger) -> http_logging.send(logger, id, params)
    None -> {
      let _ =
        server.send_notification(
          app,
          server.RequestContext(Some(id), None),
          jsonrpc.Notification(
            mcp.method_notify_logging_message,
            Some(actions.NotifyLoggingMessage(params)),
          ),
        )
      Nil
    }
  }
}

pub fn format_roots(roots: List(actions.Root)) -> String {
  case roots {
    [] ->
      "The client supports roots but no roots are currently configured.\n\nThis could mean:\n1. The client hasn't provided any roots yet\n2. The client provided an empty roots list\n3. The roots configuration is still being loaded"
    _ ->
      "Current MCP Roots ("
      <> int.to_string(list.length(roots))
      <> " total):\n\n"
      <> string.join(
        list.index_map(roots, fn(root, index) {
          int.to_string(index + 1)
          <> ". "
          <> case root.name {
            Some(name) if name != "" -> name
            _ -> "Unnamed Root"
          }
          <> "\n   URI: "
          <> root.uri
        }),
        "\n\n",
      )
      <> "\n\nNote: This server demonstrates the roots protocol capability but doesn't actually access files. The roots are provided by the MCP client and can be used by servers that need file system access."
  }
}

fn internal_error(message: String) -> jsonrpc.RpcError {
  jsonrpc.RpcError(-32_603, message, None)
}
