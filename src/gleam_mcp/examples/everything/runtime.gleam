import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/resource_updates
import gleam_mcp/examples/everything/roots
import gleam_mcp/examples/everything/tasks
import gleam_mcp/server
import gleam_mcp/task_store

/// Session state shared by every projection of the Everything server.
pub opaque type Runtime {
  Runtime(
    logger: http_logging.Logger,
    roots: roots.Store,
    updates: resource_updates.Simulation,
  )
}

pub fn new(app: server.Server, logger: http_logging.Logger) -> Runtime {
  Runtime(logger, roots.new_with_logger(app, logger), resource_updates.new(app))
}

pub fn new_without_session_labels(
  app: server.Server,
  logger: http_logging.Logger,
) -> Runtime {
  Runtime(
    logger,
    roots.new_with_logger(app, logger),
    resource_updates.new_without_session_labels(app),
  )
}

pub fn register(app: server.Server, runtime: Runtime) -> server.Server {
  app
  |> roots.register(runtime.roots)
  |> resource_updates.register(runtime.updates)
  |> tasks.register
  |> server.with_tool_task_options(
    "simulate-research-query",
    Some(300_000),
    1000,
  )
  |> server.with_tool_task_lifecycle(
    "simulate-research-query",
    task_store.TaskLifecycle(
      Some("Gathering sources..."),
      Some("Client cancelled task execution."),
      Some(actions.Meta(dict.new())),
    ),
  )
}

pub fn notification_handler(runtime: Runtime) -> server.NotificationHandler {
  fn(_, context, notification) {
    case notification {
      actions.NotifyInitialized(_) -> roots.sync(runtime.roots, context, False)
      actions.NotifyRootsListChanged(_) ->
        roots.sync(runtime.roots, context, True)
      _ -> Nil
    }
    Ok(Nil)
  }
}

pub fn close_session(runtime: Runtime, id: String) -> Nil {
  roots.close_session(runtime.roots, id)
  resource_updates.close_session(runtime.updates, id)
  http_logging.cleanup_session(runtime.logger, id)
}

pub fn stop(runtime: Runtime) -> Nil {
  roots.stop(runtime.roots)
  resource_updates.stop(runtime.updates)
  http_logging.stop(runtime.logger)
}

/// Reverse RPC and session subscriptions are legacy features. The modern
/// progress tool works through its request-scoped notification stream.
pub fn tool_visible(
  name: String,
  capabilities: actions.ClientCapabilities,
  modern: Bool,
) -> Bool {
  case name {
    "get-roots-list" -> !modern && is_present(capabilities.roots)
    "trigger-sampling-request"
    | "trigger-elicitation-request"
    | "trigger-url-elicitation" -> !modern
    "trigger-sampling-request-async" ->
      !modern
      && is_present(capabilities.sampling)
      && supports_async_sampling(capabilities)
    "trigger-elicitation-request-async" ->
      !modern
      && is_present(capabilities.elicitation)
      && supports_async_elicitation(capabilities)
    "simulate-research-query"
    | "toggle-subscriber-updates"
    | "toggle-simulated-logging" -> !modern
    _ -> True
  }
}

fn supports_async_sampling(capabilities: actions.ClientCapabilities) -> Bool {
  case capabilities.tasks {
    Some(tasks) ->
      case tasks.requests {
        Some(requests) -> is_present(requests.sampling_create_message)
        None -> False
      }
    None -> False
  }
}

fn supports_async_elicitation(
  capabilities: actions.ClientCapabilities,
) -> Bool {
  case capabilities.tasks {
    Some(tasks) ->
      case tasks.requests {
        Some(requests) -> is_present(requests.elicitation_create)
        None -> False
      }
    None -> False
  }
}

fn is_present(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}
