import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/codec_decode
import gleam_mcp/examples/everything/compression
import gleam_mcp/examples/everything/events
import gleam_mcp/examples/everything/http_logging
import gleam_mcp/examples/everything/prompts
import gleam_mcp/examples/everything/resources
import gleam_mcp/examples/everything/runtime
import gleam_mcp/examples/everything/session_resources
import gleam_mcp/examples/everything/tools
import gleam_mcp/examples/everything/url_elicitation
import gleam_mcp/jsonrpc
import gleam_mcp/mcp
import gleam_mcp/server
import gleam_mcp/server/codec

pub fn make_server() -> server.Server {
  let #(app, _, _) = build(session_resources.Stdio, None)
  app
}

pub fn make_server_with_http_logger(
  logger: Option(http_logging.Logger),
) -> server.Server {
  let #(app, _, _) = build(session_resources.StreamableHttp, logger)
  app
}

pub fn make_http_server() -> #(server.Server, http_logging.Logger) {
  let #(app, logger, _) = build(session_resources.StreamableHttp, None)
  #(app, logger)
}

/// The cleanup function stops all example-owned workers after the transport exits.
pub fn make_application(
  mode: session_resources.TransportMode,
) -> #(server.Server, fn() -> Nil) {
  let #(app, _, cleanup) = build(mode, None)
  #(app, cleanup)
}

fn build(
  mode: session_resources.TransportMode,
  supplied_logger: Option(http_logging.Logger),
) -> #(server.Server, http_logging.Logger, fn() -> Nil) {
  let history = events.new()
  let base =
    base_server() |> server.with_legacy_event_store(events.adapter(history))
  let logger = case supplied_logger {
    Some(logger) -> {
      http_logging.bind(logger, base)
      logger
    }
    None ->
      case mode {
        session_resources.Stdio -> http_logging.new_without_session_labels(base)
        session_resources.StreamableHttp -> http_logging.new_logger(base)
      }
  }
  let state = case mode {
    session_resources.Stdio -> runtime.new_without_session_labels(base, logger)
    session_resources.StreamableHttp -> runtime.new(base, logger)
  }
  let generated = session_resources.new(mode)
  let urls = url_elicitation.new()
  let app =
    base
    |> tools.register_tools_with_url_store(Some(logger), urls)
    |> runtime.register(state)
    |> compression.register_tools(generated)
    |> server.set_context_logging_handler(fn(context, level) {
      case context.session_id {
        Some(id) -> http_logging.set_level(logger, id, level)
        None -> Nil
      }
      Ok(Nil)
    })
    |> server.with_resource_subscription_handler(fn(context, uri, enabled) {
      case context.session_id {
        None -> Nil
        Some(id) -> {
          let message =
            case enabled {
              True -> "Received Subscribe Resource request for URI: "
              False -> "Received Unsubscribe Resource request: "
            }
            <> uri
            <> case mode {
              session_resources.Stdio -> " "
              session_resources.StreamableHttp -> " from session " <> id
            }
          http_logging.send(
            logger,
            id,
            actions.LoggingMessageNotificationParams(
              actions.Info,
              None,
              jsonrpc.VString(message),
              None,
            ),
          )
        }
      }
      Ok(Nil)
    })
    |> server.with_notification_handler(fn(app, context, notification) {
      use _ <- result.try(runtime.notification_handler(state)(
        app,
        context,
        notification,
      ))
      case notification {
        actions.NotifyInitialized(_) ->
          server.send_notification(
            app,
            context,
            jsonrpc.Notification(
              mcp.method_notify_tools_list_changed,
              Some(actions.NotifyToolListChanged(None)),
            ),
          )
        _ -> Ok(Nil)
      }
    })
    |> server.with_session_close_handler(fn(id) {
      runtime.close_session(state, id)
      session_resources.close_session(generated, id)
      url_elicitation.clear_session(urls, id)
      events.close_session(history, id)
    })
    |> server.with_server_projection(fn(app, context) {
      let #(capabilities, initialized) = client_capabilities(app, context)
      app
      |> server.filter_tools(fn(tool) {
        let conditional = case tool.name {
          "get-roots-list"
          | "trigger-sampling-request"
          | "trigger-elicitation-request"
          | "trigger-url-elicitation"
          | "simulate-research-query"
          | "trigger-sampling-request-async"
          | "trigger-elicitation-request-async" -> True
          _ -> False
        }
        { !conditional || initialized }
        && tools.is_available(tool.name, capabilities)
        && runtime.tool_visible(
          tool.name,
          capabilities,
          server.is_modern_context(context),
        )
      })
      |> session_resources.projection(generated)(context)
    })
  #(app, logger, fn() {
    runtime.stop(state)
    session_resources.stop(generated)
    url_elicitation.close(urls)
    events.stop(history)
  })
}

fn client_capabilities(
  app: server.Server,
  context: server.RequestContext,
) -> #(actions.ClientCapabilities, Bool) {
  let empty = actions.ClientCapabilities(None, None, None, None, None)
  case context {
    server.ModernRequestContext(..) -> {
      let capabilities =
        server.request_meta(context)
        |> option.then(fn(meta) { meta.extra })
        |> option.then(fn(meta) {
          dict.get(meta.fields, "io.modelcontextprotocol/clientCapabilities")
          |> option.from_result
        })
        |> option.then(fn(value) {
          codec_decode.decode_value(value, codec.client_capabilities_decoder())
          |> option.from_result
        })
        |> option.unwrap(empty)
      #(capabilities, True)
    }
    _ ->
      case context.session_id |> option.then(server.session_metadata(app, _)) {
        Some(metadata) -> #(metadata.client_capabilities, metadata.ready)
        None -> #(empty, False)
      }
  }
}

fn base_server() -> server.Server {
  server.new(implementation())
  |> server.with_instructions(resources.instructions())
  |> resources.register_resources
  |> prompts.register_prompts
  |> server.set_completion_handler(prompts.completion_handler)
  |> server.set_logging_handler(fn(_) { Ok(Nil) })
  |> server.with_capabilities(capabilities())
}

pub fn implementation() -> actions.Implementation {
  actions.Implementation(
    name: "mcp-servers/everything",
    version: "2.0.0",
    title: Some("Everything Reference Server"),
    description: None,
    website_url: None,
    icons: [],
  )
}

fn capabilities() -> actions.ServerCapabilities {
  let empty = Some(jsonrpc.VObject([]))
  actions.ServerCapabilities(
    experimental: None,
    logging: empty,
    completions: empty,
    prompts: Some(actions.ServerPromptsCapabilities(Some(True))),
    resources: Some(actions.ServerResourcesCapabilities(Some(True), Some(True))),
    tools: Some(actions.ServerToolsCapabilities(Some(True))),
    tasks: Some(actions.ServerTasksCapabilities(
      empty,
      empty,
      Some(actions.ServerTaskRequestCapabilities(empty)),
    )),
  )
}
