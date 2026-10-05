import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam_mcp/actions.{
  type ActionNotification, type ClientActionRequest, type ClientActionResult,
  type Implementation,
}
import gleam_mcp/client/capabilities
import gleam_mcp/client/codec as client_codec
import gleam_mcp/client/http_stream
import gleam_mcp/client/runtime
import gleam_mcp/client/stdio_manager
import gleam_mcp/client/subscriptions
import gleam_mcp/client/transport
import gleam_mcp/codec_common
import gleam_mcp/http_headers
import gleam_mcp/jsonrpc.{type Request, type Response, type RpcError, Request}
import gleam_mcp/mcp
import gleam_mcp/server/codec as server_codec
import gleam_mcp/wire
import youid/uuid

const maximum_tool_discovery_pages = 100

pub type VersionNegotiation {
  Auto
  Pin(String)
}

pub type ConnectionInfo {
  Modern(actions.DiscoverResult)
  Legacy(actions.InitializeResult)
}

pub type Client {
  Client(
    transport_config: transport.Config,
    runners: transport.Runners,
    capabilities: capabilities.Config,
    protocol_version: String,
    session_id: Option(String),
    peer_capabilities: Option(actions.ServerCapabilities),
    client_info: Option(Implementation),
    cached_tools: Dict(String, actions.Tool),
    stdio_manager: Option(stdio_manager.Manager),
    closed: Bool,
    lifecycle: runtime.Control,
    generation: Int,
    version_negotiation: VersionNegotiation,
    log_level: Option(actions.LoggingLevel),
    maximum_input_rounds: Int,
    connection_info: Option(ConnectionInfo),
    last_cache_hint: Option(actions.CacheHint),
    discovery_timeout_ms: Int,
    extensions: Dict(String, jsonrpc.Value),
    peer_protocol_version: Option(String),
  )
}

pub type ClientError {
  Rpc(RpcError)
  Transport(transport.TransportError)
}

pub fn new(
  transport_config: transport.Config,
  capabilities: capabilities.Config,
) -> Client {
  let manager = stdio_manager.start()
  let client =
    new_with_runners(
      transport_config,
      transport.default_runners_with_manager(manager),
      capabilities,
    )
  Client(..client, stdio_manager: Some(manager))
}

pub fn new_with_runners(
  transport_config: transport.Config,
  runners: transport.Runners,
  capabilities: capabilities.Config,
) -> Client {
  Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capabilities,
    protocol_version: jsonrpc.latest_protocol_version,
    session_id: None,
    peer_capabilities: None,
    client_info: None,
    cached_tools: dict.new(),
    stdio_manager: None,
    closed: False,
    lifecycle: runtime.new(),
    generation: 0,
    version_negotiation: Auto,
    log_level: None,
    maximum_input_rounds: 16,
    connection_info: None,
    last_cache_hint: None,
    discovery_timeout_ms: 5000,
    extensions: dict.new(),
    peer_protocol_version: None,
  )
}

pub fn initialize(
  client: Client,
  client_info: Implementation,
) -> Result(#(Client, actions.InitializeResult), ClientError) {
  let client = case is_closed(client) {
    True ->
      Client(
        ..client,
        session_id: None,
        peer_capabilities: None,
        cached_tools: dict.new(),
      )
    False -> client
  }
  let generation = runtime.open(client.lifecycle)
  initialize_current(
    Client(
      ..client,
      generation: generation,
      protocol_version: jsonrpc.legacy_protocol_version,
      peer_protocol_version: None,
    ),
    client_info,
  )
}

/// Pin negotiation to a supported version, or retain automatic legacy fallback.
pub fn with_version_negotiation(
  client: Client,
  negotiation: VersionNegotiation,
) -> Client {
  Client(..client, version_negotiation: negotiation)
}

pub fn with_protocol_version(client: Client, version: String) -> Client {
  Client(..client, protocol_version: version, version_negotiation: Pin(version))
}

pub fn with_log_level(
  client: Client,
  level: Option(actions.LoggingLevel),
) -> Client {
  Client(..client, log_level: level)
}

pub fn with_maximum_input_rounds(client: Client, rounds: Int) -> Client {
  Client(..client, maximum_input_rounds: case rounds < 1 {
    True -> 1
    False -> rounds
  })
}

pub fn with_discovery_timeout(client: Client, timeout_ms: Int) -> Client {
  Client(..client, discovery_timeout_ms: case timeout_ms < 1 {
    True -> 1
    False -> timeout_ms
  })
}

pub fn last_cache_hint(client: Client) -> Option(actions.CacheHint) {
  client.last_cache_hint
}

pub fn with_extensions(
  client: Client,
  extensions: Dict(String, jsonrpc.Value),
) -> Client {
  Client(..client, extensions: extensions)
}

pub fn with_tasks_extension(client: Client) -> Client {
  with_extensions(
    client,
    dict.insert(
      client.extensions,
      "io.modelcontextprotocol/tasks",
      jsonrpc.VObject([]),
    ),
  )
}

/// Discover modern servers and fall back only when the peer demonstrates legacy
/// behavior. Authentication failures and recognized modern errors never trigger
/// a speculative legacy handshake.
pub fn connect(
  client: Client,
  info: Implementation,
) -> Result(#(Client, ConnectionInfo), ClientError) {
  let generation = runtime.open(client.lifecycle)
  let fresh =
    Client(
      ..client,
      generation: generation,
      closed: False,
      session_id: None,
      peer_capabilities: None,
      cached_tools: dict.new(),
      client_info: Some(info),
      connection_info: None,
      peer_protocol_version: None,
    )
  case client.version_negotiation {
    Pin(version) if version == jsonrpc.legacy_protocol_version ->
      connect_legacy(fresh, info)
    Pin(version) if version != jsonrpc.latest_protocol_version ->
      Error(
        Transport(transport.UnexpectedResponse(
          "Unsupported pinned MCP protocol version: " <> version,
        )),
      )
    _ ->
      connect_modern(
        Client(..fresh, protocol_version: jsonrpc.latest_protocol_version),
        info,
      )
  }
}

fn connect_modern(
  client: Client,
  info: Implementation,
) -> Result(#(Client, ConnectionInfo), ClientError) {
  let timeout = case transport_timeout(client) < client.discovery_timeout_ms {
    True -> transport_timeout(client)
    False -> client.discovery_timeout_ms
  }
  connect_modern_attempt(client, info, True, clock_ms() + timeout)
}

fn clock_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn connect_modern_attempt(
  client: Client,
  info: Implementation,
  retry_version: Bool,
  deadline: Int,
) -> Result(#(Client, ConnectionInfo), ClientError) {
  let timeout = deadline - clock_ms()
  use _ <- result.try(case timeout > 0 {
    True -> Ok(Nil)
    False -> Error(Transport(transport.TimeoutError))
  })
  let #(probed, response) =
    send_request(
      with_request_timeout(client, timeout),
      "server/discover",
      Some(actions.ClientRequestDiscover(None)),
    )
  let probed = Client(..probed, transport_config: client.transport_config)
  case response {
    Ok(jsonrpc.ResultResponse(_, actions.ClientResultDiscover(discovered))) -> {
      case
        list.contains(
          discovered.supported_versions,
          jsonrpc.latest_protocol_version,
        )
      {
        False ->
          Error(
            Transport(transport.UnexpectedResponse(
              "Discovery omitted the requested protocol version",
            )),
          )
        True -> {
          use caps <- result.try(
            client_codec.decode_server_capabilities(
              jsonrpc.VObject(dict.to_list(discovered.capabilities)),
            )
            |> result.map_error(fn(message) {
              Transport(transport.UnexpectedResponse(message))
            }),
          )
          let connected =
            Client(
              ..probed,
              peer_capabilities: Some(caps),
              connection_info: Some(Modern(discovered)),
            )
          Ok(#(connected, Modern(discovered)))
        }
      }
    }
    Ok(jsonrpc.ErrorResponse(_, error)) if error.code == -32_022 ->
      case
        retry_version
        && list.contains(
          supported_versions(error.data),
          jsonrpc.latest_protocol_version,
        )
      {
        True -> connect_modern_attempt(probed, info, False, deadline)
        False -> {
          case client.version_negotiation, supported_versions(error.data) {
            Auto, versions ->
              case list.contains(versions, jsonrpc.legacy_protocol_version) {
                True -> connect_legacy(close_probe(probed), info)
                False -> Error(Rpc(error))
              }
            _, _ -> Error(Rpc(error))
          }
        }
      }
    Ok(jsonrpc.ErrorResponse(_, error)) ->
      case client.version_negotiation, client.transport_config {
        Auto, transport.Http(_)
          if error.code == -32_601
          && probed.peer_protocol_version
          != Some(jsonrpc.latest_protocol_version)
        -> connect_legacy(close_probe(probed), info)
        Auto, transport.Stdio(_)
          if error.code != -32_020 && error.code != -32_021
        -> connect_legacy(close_probe(probed), info)
        _, _ -> Error(Rpc(error))
      }
    Error(error) ->
      case client.version_negotiation, client.transport_config, error {
        Auto, transport.Http(_), Transport(transport.ProtocolHttpError(400, _))
        -> connect_legacy(close_probe(probed), info)
        Auto, transport.Stdio(_), _ -> connect_legacy(close_probe(probed), info)
        _, _, _ -> Error(error)
      }
    _ -> Error(unexpected_response_error("server/discover"))
  }
}

fn close_probe(client: Client) -> Client {
  case client.stdio_manager {
    Some(manager) -> {
      let _ = stdio_manager.close(manager, client.session_id)
      Nil
    }
    None -> Nil
  }
  Client(
    ..client,
    session_id: None,
    peer_capabilities: None,
    cached_tools: dict.new(),
  )
}

fn connect_legacy(
  client: Client,
  info: Implementation,
) -> Result(#(Client, ConnectionInfo), ClientError) {
  use #(client, initialized) <- result.try(initialize_current(
    Client(..client, protocol_version: jsonrpc.legacy_protocol_version),
    info,
  ))
  let connected = Client(..client, connection_info: Some(Legacy(initialized)))
  Ok(#(connected, Legacy(initialized)))
}

fn supported_versions(data: Option(jsonrpc.Value)) -> List(String) {
  case data {
    Some(jsonrpc.VObject(fields)) ->
      case list.key_find(fields, "supported") {
        Ok(jsonrpc.VArray(versions)) ->
          list.filter_map(versions, fn(version) {
            case version {
              jsonrpc.VString(value) -> Ok(value)
              _ -> Error(Nil)
            }
          })
        _ -> []
      }
    _ -> []
  }
}

fn transport_timeout(client: Client) -> Int {
  let timeout = case client.transport_config {
    transport.Http(config) -> config.timeout_ms
    transport.Stdio(config) -> config.timeout_ms
  }
  timeout |> option.unwrap(30_000)
}

fn modern_meta(
  client: Client,
  existing: Option(actions.RequestMeta),
) -> actions.RequestMeta {
  let existing = existing |> option.unwrap(actions.RequestMeta(None, None))
  let extras =
    existing.extra
    |> option.map(fn(meta) { meta.fields })
    |> option.unwrap(dict.new())
  let caps = case capabilities.modern_capabilities(client.capabilities) {
    jsonrpc.VObject(fields) ->
      jsonrpc.VObject([
        #("extensions", jsonrpc.VObject(dict.to_list(client.extensions))),
        ..fields
      ])
    value -> value
  }
  let extras =
    extras
    |> dict.insert(
      "io.modelcontextprotocol/protocolVersion",
      jsonrpc.VString(client.protocol_version),
    )
    |> dict.insert("io.modelcontextprotocol/clientCapabilities", caps)
  let extras = case client.client_info {
    Some(info) -> {
      let assert Ok(value) =
        codec_common.encode_implementation(info)
        |> json.to_string
        |> json.parse(client_codec.value_decoder())
      dict.insert(extras, "io.modelcontextprotocol/clientInfo", value)
    }
    None -> dict.delete(extras, "io.modelcontextprotocol/clientInfo")
  }
  let extras = case client.log_level {
    Some(level) ->
      dict.insert(
        extras,
        "io.modelcontextprotocol/logLevel",
        jsonrpc.VString(logging_level_name(level)),
      )
    None -> dict.delete(extras, "io.modelcontextprotocol/logLevel")
  }
  actions.RequestMeta(..existing, extra: Some(actions.Meta(extras)))
}

fn logging_level_name(level: actions.LoggingLevel) -> String {
  case level {
    actions.Debug -> "debug"
    actions.Info -> "info"
    actions.Notice -> "notice"
    actions.Warning -> "warning"
    actions.Error -> "error"
    actions.Critical -> "critical"
    actions.Alert -> "alert"
    actions.Emergency -> "emergency"
  }
}

fn attach_metadata(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> Request(ClientActionRequest) {
  case incoming {
    Request(id, method, params) -> {
      let action = params |> option.unwrap(actions.ClientRequestPing(None))
      Request(
        id,
        method,
        Some(actions.with_request_meta(
          action,
          Some(modern_meta(client, actions.request_meta(action))),
        )),
      )
    }
    _ -> incoming
  }
}

fn initialize_current(
  client: Client,
  client_info: Implementation,
) -> Result(#(Client, actions.InitializeResult), ClientError) {
  let client = Client(..client, client_info: Some(client_info), closed: False)
  let Client(capabilities: config, protocol_version: protocol_version, ..) =
    client

  let params =
    actions.InitializeRequestParams(
      protocol_version,
      capabilities.to_initialize_capabilities(config),
      client_info,
      None,
    )

  let #(next_client, response) =
    send_request(
      client,
      mcp.method_initialize,
      Some(actions.ClientRequestInitialize(params)),
    )

  case response {
    Ok(jsonrpc.ResultResponse(_, actions.ClientResultInitialize(result))) -> {
      use _ <- result.try(validate_initialize_result(result))
      let next_client =
        Client(
          ..next_client,
          protocol_version: result.protocol_version,
          peer_capabilities: Some(result.capabilities),
          cached_tools: dict.new(),
        )
      case is_closed(next_client) {
        True -> {
          let _ = close(next_client)
          Error(Transport(transport.UnexpectedResponse("MCP client is closed")))
        }
        False -> {
          let #(ready_client, r) = initialized(next_client)
          case r, is_closed(ready_client) {
            Ok(_), False -> Ok(#(ready_client, result))
            _, True -> {
              let _ = close(ready_client)
              Error(
                Transport(transport.UnexpectedResponse("MCP client is closed")),
              )
            }
            Error(error), False -> Error(error)
          }
        }
      }
    }
    Ok(jsonrpc.ResultResponse(_, _)) ->
      Error(
        Transport(transport.UnexpectedResponse(
          "Unexpected response to initialize request",
        )),
      )
    Ok(jsonrpc.ErrorResponse(_, error)) -> Error(Rpc(error))
    Error(error) -> Error(error)
  }
}

pub fn peer_capabilities(client: Client) -> Option(actions.ServerCapabilities) {
  client.peer_capabilities
}

fn validate_initialize_result(
  value: actions.InitializeResult,
) -> Result(Nil, ClientError) {
  case value.protocol_version == jsonrpc.legacy_protocol_version {
    False ->
      Error(
        Transport(transport.UnexpectedResponse(
          "Unsupported negotiated MCP protocol version: "
          <> value.protocol_version,
        )),
      )
    True ->
      case value.capabilities.tasks {
        Some(actions.ServerTasksCapabilities(
          requests: Some(actions.ServerTaskRequestCapabilities(tools_call: Some(
            _,
          ))),
          ..,
        ))
          if value.capabilities.tools == None
        ->
          Error(
            Transport(transport.UnexpectedResponse(
              "Server declared tool tasks without tools capability",
            )),
          )
        _ -> Ok(Nil)
      }
  }
}

/// Close resources owned by the default client. Custom runner implementations
/// own their subprocess resources and must close them themselves.
pub fn close(client: Client) -> #(Client, Result(Nil, ClientError)) {
  runtime.close(client.lifecycle, client.generation)
  let outcome = case client.transport_config {
    transport.Http(_)
      if client.protocol_version == jsonrpc.latest_protocol_version
    -> Ok(Nil)
    transport.Http(config) ->
      case client.session_id {
        None -> Ok(Nil)
        Some(_) ->
          transport.close_http(
            config,
            client.session_id,
            client.protocol_version,
          )
          |> result.map_error(Transport)
      }
    transport.Stdio(_) ->
      case client.stdio_manager {
        Some(manager) ->
          stdio_manager.close(manager, client.session_id)
          |> result.map_error(fn(error) {
            Transport(transport.ProcessError(error))
          })
        None -> Ok(Nil)
      }
  }
  case outcome {
    Ok(Nil) | Error(Transport(transport.SessionExpired)) -> #(
      Client(
        ..client,
        session_id: None,
        peer_capabilities: None,
        cached_tools: dict.new(),
        closed: True,
      ),
      Ok(Nil),
    )
    Error(error) -> #(Client(..client, closed: True), Error(error))
  }
}

/// Override the timeout for subsequent requests from this client value.
pub fn with_request_timeout(client: Client, timeout_ms: Int) -> Client {
  let timeout_ms = case timeout_ms < 1 {
    True -> 1
    False -> timeout_ms
  }
  let config = case client.transport_config {
    transport.Http(config) ->
      transport.Http(
        transport.HttpConfig(..config, timeout_ms: Some(timeout_ms)),
      )
    transport.Stdio(config) ->
      transport.Stdio(
        transport.StdioConfig(..config, timeout_ms: Some(timeout_ms)),
      )
  }
  Client(..client, transport_config: config)
}

pub fn ping(client: Client) -> #(Client, Result(Nil, ClientError)) {
  let #(next_client, response) = send_request(client, mcp.method_ping, None)
  case response {
    Ok(jsonrpc.ResultResponse(_, _)) -> #(next_client, Ok(Nil))
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(next_client, Error(Rpc(error)))
    Error(error) -> #(next_client, Error(error))
  }
}

pub fn initialized(client: Client) -> #(Client, Result(Nil, ClientError)) {
  case client.protocol_version == jsonrpc.latest_protocol_version {
    True -> #(client, Ok(Nil))
    False -> send_notification(client, mcp.method_initialized, None)
  }
}

pub fn listen(client: Client) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(
      client,
      Error(Transport(transport.UnexpectedResponse("MCP client is closed"))),
    )
    False ->
      case client.protocol_version == jsonrpc.latest_protocol_version {
        True ->
          listen_with_notifications(
            client,
            Some(capabilities.notification_filter(client.capabilities)),
          )
        False -> listen_forever(client)
      }
  }
}

/// Listen to the explicitly selected modern notification types. Resource
/// updates require URI entries in notifications.resourceSubscriptions.
pub fn listen_with_notifications(
  client: Client,
  notifications: Option(jsonrpc.Value),
) -> #(Client, Result(Nil, ClientError)) {
  case
    is_closed(client)
    || client.protocol_version != jsonrpc.latest_protocol_version
  {
    True -> #(
      client,
      Error(
        Transport(transport.UnexpectedResponse(
          "Modern subscriptions require an open modern client",
        )),
      ),
    )
    False -> {
      let id = jsonrpc.StringId(uuid.v4_string())
      let incoming =
        attach_metadata(
          client,
          Request(
            id,
            "subscriptions/listen",
            Some(
              actions.ClientRequestSubscriptionsListen(
                actions.SubscriptionsListenParams(notifications, None),
              ),
            ),
          ),
        )
      let validator = subscriptions.new(incoming, notifications)
      let stop = process.new_subject()
      runtime.watch_request(client.lifecycle, client.generation, id, stop)
      let #(next, result) = case client.transport_config {
        transport.Http(config) -> {
          let finished = process.new_subject()
          let encoded = wire.encode_request(incoming, client.protocol_version)
          let timeout = case transport_timeout(client) < 3_600_000 {
            True -> 3_600_000
            False -> transport_timeout(client)
          }
          let streamed =
            http_stream.request_modern(
              config.base_url,
              transport.modern_headers(
                config,
                client.protocol_version,
                encoded,
                [],
              ),
              encoded,
              timeout,
              Some(stop),
              fn(payload, _) {
                use event <- result.try(
                  subscriptions.event(validator, payload)
                  |> result.map_error(http_stream.InvalidResponse),
                )
                case event {
                  subscriptions.Acknowledged(filter) ->
                    capabilities.acknowledged(client.capabilities, filter)
                    |> result.map(fn(_) { False })
                    |> result.map_error(fn(error) {
                      http_stream.InvalidResponse(error.message)
                    })
                  subscriptions.Notification(notification) ->
                    capabilities.handle_notification(
                      client.capabilities,
                      notification,
                    )
                    |> result.map(fn(_) { False })
                    |> result.map_error(fn(error) {
                      http_stream.InvalidResponse(error.message)
                    })
                  subscriptions.Finished(outcome) -> {
                    process.send(finished, outcome |> result.map_error(Rpc))
                    Ok(True)
                  }
                }
              },
            )
          let outcome = case streamed {
            Ok(_) ->
              process.receive(finished, 0)
              |> result.unwrap(
                Error(
                  Transport(transport.UnexpectedResponse(
                    "Subscription stream ended without completion",
                  )),
                ),
              )
            Error(error) ->
              case is_closed(client), error {
                True, _ -> Ok(Nil)
                False, http_stream.Closed -> Ok(Nil)
                _, _ ->
                  Error(Transport(transport.map_stream_error(error, None)))
              }
          }
          #(client, outcome)
        }
        transport.Stdio(config) ->
          case client.stdio_manager {
            None -> #(
              client,
              Error(
                Transport(transport.UnexpectedResponse(
                  "Modern stdio listening requires the managed transport",
                )),
              ),
            )
            Some(manager) -> {
              let events = process.new_subject()
              let manager_config =
                stdio_manager.Config(
                  config.command,
                  config.args,
                  config.env,
                  config.cwd,
                  config.timeout_ms,
                )
              case
                stdio_manager.subscribe(
                  manager,
                  manager_config,
                  client.session_id,
                  wire.encode_request(incoming, client.protocol_version),
                  events,
                )
              {
                Error(message) -> #(
                  client,
                  Error(Transport(transport.ProcessError(message))),
                )
                Ok(session) -> {
                  let next = set_runtime(client, session)
                  let outcome =
                    listen_stdio_subscription(next, validator, events, stop, id)
                  #(next, outcome)
                }
              }
            }
          }
      }
      subscriptions.stop(validator)
      runtime.unwatch(client.lifecycle, stop)
      #(next, result)
    }
  }
}

type SubscriptionEvent {
  SubscriptionPayload(Result(String, String))
  SubscriptionStop
}

fn listen_stdio_subscription(
  client: Client,
  validator: subscriptions.Validator,
  events: process.Subject(Result(String, String)),
  stop: process.Subject(Nil),
  id: jsonrpc.RequestId,
) -> Result(Nil, ClientError) {
  let selector =
    process.new_selector()
    |> process.select_map(events, SubscriptionPayload)
    |> process.select_map(stop, fn(_) { SubscriptionStop })
  case process.selector_receive_forever(selector) {
    SubscriptionStop -> {
      case is_closed(client) {
        True -> Nil
        False -> {
          let _ =
            perform_notification(
              client,
              mcp.method_notify_cancelled,
              Some(
                actions.NotifyCancelled(actions.CancelledNotificationParams(
                  Some(id),
                  None,
                  None,
                )),
              ),
            )
          Nil
        }
      }
      Ok(Nil)
    }
    SubscriptionPayload(Error(message)) ->
      case is_closed(client) {
        True -> Ok(Nil)
        False -> Error(Transport(transport.ProcessError(message)))
      }
    SubscriptionPayload(Ok(payload)) -> {
      use event <- result.try(
        subscriptions.event(validator, payload)
        |> result.map_error(fn(message) {
          Transport(transport.UnexpectedResponse(message))
        }),
      )
      case event {
        subscriptions.Acknowledged(filter) -> {
          use _ <- result.try(run_subscription_callback(
            fn() { capabilities.acknowledged(client.capabilities, filter) },
            stop,
            client.capabilities.request_timeout_ms,
          ))
          listen_stdio_subscription(client, validator, events, stop, id)
        }
        subscriptions.Notification(notification) -> {
          use _ <- result.try(run_subscription_callback(
            fn() {
              capabilities.handle_notification(
                client.capabilities,
                notification,
              )
            },
            stop,
            client.capabilities.request_timeout_ms,
          ))
          listen_stdio_subscription(client, validator, events, stop, id)
        }
        subscriptions.Finished(outcome) -> outcome |> result.map_error(Rpc)
      }
    }
  }
}

type CallbackEvent {
  CallbackReply(Result(Nil, RpcError))
  CallbackStop
}

fn run_subscription_callback(
  work: fn() -> Result(Nil, RpcError),
  stop: process.Subject(Nil),
  timeout: Int,
) -> Result(Nil, ClientError) {
  let reply = process.new_subject()
  let worker = process.spawn_unlinked(fn() { process.send(reply, work()) })
  let selector =
    process.new_selector()
    |> process.select_map(reply, CallbackReply)
    |> process.select_map(stop, fn(_) { CallbackStop })
  let outcome = case process.selector_receive(selector, timeout) {
    Ok(CallbackReply(result)) -> result |> result.map_error(Rpc)
    Ok(CallbackStop) -> {
      process.send(stop, Nil)
      Ok(Nil)
    }
    Error(_) -> Error(Transport(transport.TimeoutError))
  }
  process.kill(worker)
  outcome
}

fn listen_forever(client: Client) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(Client(..client, closed: True), Ok(Nil))
    False -> listen_once(client)
  }
}

fn listen_once(client: Client) -> #(Client, Result(Nil, ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  case transport_config {
    transport.Http(http_config) -> {
      let stop = process.new_subject()
      runtime.watch(client.lifecycle, client.generation, stop)
      let outcome =
        transport.streamable_http_listen_until_closed(
          http_config,
          session_id,
          protocol_version,
          capability_config,
          stop,
        )
      runtime.unwatch(client.lifecycle, stop)
      case outcome {
        Ok(next_session_id) ->
          listen_forever(set_runtime(client, next_session_id))
        Error(error) ->
          case is_closed(client), should_retry_http_listen(error) {
            True, _ -> #(Client(..client, closed: True), Ok(Nil))
            False, True -> {
              process.sleep(100)
              listen_forever(client)
            }
            False, False ->
              case error {
                transport.SessionExpired -> #(
                  recover_expired_session(
                    client,
                    jsonrpc.Request(
                      jsonrpc.StringId("expired-listen"),
                      "listen",
                      None,
                    ),
                  ),
                  Error(Transport(error)),
                )
                _ -> #(client, Error(Transport(error)))
              }
          }
      }
    }
    transport.Stdio(stdio_config) -> {
      let transport.Runners(stdio_listen: stdio_listen, ..) = runners
      case stdio_listen(stdio_config, session_id, capability_config) {
        Ok(response) -> {
          let next_session_id = response.session_id
          let client = set_runtime(client, next_session_id)
          runtime.await_closed(client.lifecycle, client.generation)
          #(Client(..client, closed: True), Ok(Nil))
        }
        Error(error) -> #(client, Error(Transport(error)))
      }
    }
  }
}

fn should_retry_http_listen(error: transport.TransportError) -> Bool {
  case error {
    transport.TimeoutError -> True
    transport.HttpError(_) -> True
    _ -> False
  }
}

pub fn list_resources(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourcesResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_resources,
    params,
    actions.ClientRequestListResources,
    fn(result) {
      case result {
        actions.ClientResultListResources(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn list_resource_templates(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListResourceTemplatesResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_resource_templates,
    params,
    actions.ClientRequestListResourceTemplates,
    fn(result) {
      case result {
        actions.ClientResultListResourceTemplates(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn read_resource(
  client: Client,
  params: actions.ReadResourceRequestParams,
) -> #(Client, Result(actions.ReadResourceResult, ClientError)) {
  request_action(
    client,
    mcp.method_read_resource,
    actions.ClientRequestReadResource(params),
    fn(result) {
      case result {
        actions.ClientResultReadResource(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn subscribe_resource(
  client: Client,
  params: actions.SubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_subscribe_resource,
    actions.ClientRequestSubscribeResource(params),
  )
}

pub fn unsubscribe_resource(
  client: Client,
  params: actions.UnsubscribeRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_unsubscribe_resource,
    actions.ClientRequestUnsubscribeResource(params),
  )
}

pub fn list_prompts(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListPromptsResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_prompts,
    params,
    actions.ClientRequestListPrompts,
    fn(result) {
      case result {
        actions.ClientResultListPrompts(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn get_prompt(
  client: Client,
  params: actions.GetPromptRequestParams,
) -> #(Client, Result(actions.GetPromptResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_prompt,
    actions.ClientRequestGetPrompt(params),
    fn(result) {
      case result {
        actions.ClientResultGetPrompt(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn list_tools(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListToolsResult, ClientError)) {
  let #(next_client, outcome) =
    request_paginated(
      client,
      mcp.method_list_tools,
      params,
      actions.ClientRequestListTools,
      fn(result) {
        case result {
          actions.ClientResultListTools(value) -> Some(value)
          _ -> None
        }
      },
    )
  case outcome {
    Ok(page) -> {
      let filter_headers = case
        next_client.protocol_version,
        next_client.transport_config
      {
        "2026-07-28", transport.Http(_) -> True
        _, _ -> False
      }
      let cursor = params |> option.then(fn(params) { params.cursor })
      let #(next_client, page) =
        cache_tool_page(next_client, page, cursor, filter_headers)
      #(next_client, Ok(page))
    }
    Error(error) -> #(next_client, Error(error))
  }
}

fn cache_tool_page(
  client: Client,
  page: actions.ListToolsResult,
  cursor: Option(actions.Cursor),
  filter_headers: Bool,
) -> #(Client, actions.ListToolsResult) {
  let tools = case filter_headers {
    True ->
      list.filter(page.tools, fn(tool) {
        http_headers.definitions(tool.input_schema) |> result.is_ok
      })
    False -> page.tools
  }
  let cached =
    list.fold(
      tools,
      case cursor {
        None -> dict.new()
        Some(_) -> client.cached_tools
      },
      fn(cache, tool) { dict.insert(cache, tool.name, tool) },
    )
  #(
    Client(..client, cached_tools: cached),
    actions.ListToolsResult(..page, tools: tools),
  )
}

pub fn call_tool(
  client: Client,
  params: actions.CallToolRequestParams,
) -> #(Client, Result(actions.CallToolResponse, ClientError)) {
  let #(client, descriptor) = ensure_tool_descriptor(client, params.name)
  case descriptor {
    Error(error) -> #(client, Error(error))
    Ok(_) ->
      request_action(
        client,
        mcp.method_call_tool,
        actions.ClientRequestCallTool(params),
        fn(result) {
          case result {
            actions.ClientResultCallTool(res) -> Some(actions.CallTool(res))
            actions.ClientResultCreateTask(res) ->
              Some(actions.CallToolTask(res))
            actions.ClientResultTaskModern(value) ->
              Some(actions.CallToolTaskModern(value))
            _ -> None
          }
        },
      )
  }
}

pub fn complete(
  client: Client,
  params: actions.CompleteRequestParams,
) -> #(Client, Result(actions.CompleteResult, ClientError)) {
  request_action(
    client,
    mcp.method_complete,
    actions.ClientRequestComplete(params),
    fn(result) {
      case result {
        actions.ClientResultComplete(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn set_logging_level(
  client: Client,
  params: actions.SetLevelRequestParams,
) -> #(Client, Result(Nil, ClientError)) {
  request_empty(
    client,
    mcp.method_set_logging_level,
    actions.ClientRequestSetLoggingLevel(params),
  )
}

pub fn list_tasks(
  client: Client,
  params: Option(actions.PaginatedRequestParams),
) -> #(Client, Result(actions.ListTasksResult, ClientError)) {
  request_paginated(
    client,
    mcp.method_list_tasks,
    params,
    actions.ClientRequestListTasks,
    fn(result) {
      case result {
        actions.ClientResultListTasks(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn get_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.GetTaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_task,
    actions.ClientRequestGetTask(params),
    fn(result) {
      case result {
        actions.ClientResultGetTask(value) -> Some(value)
        _ -> None
      }
    },
  )
}

/// Read the current July 2026 polling-extension task representation.
pub fn get_task_modern(
  client: Client,
  task_id: String,
) -> #(Client, Result(jsonrpc.Value, ClientError)) {
  modern_task_request(
    client,
    "tasks/get",
    actions.ClientRequestGetTask(actions.TaskIdParams(task_id)),
  )
}

pub fn update_task(
  client: Client,
  task_id: String,
  input_responses: Dict(String, jsonrpc.Value),
) -> #(Client, Result(jsonrpc.Value, ClientError)) {
  modern_task_request(
    client,
    "tasks/update",
    actions.ClientRequestUpdateTask(actions.TaskUpdateParams(
      task_id,
      Some(jsonrpc.VObject(dict.to_list(input_responses))),
      None,
    )),
  )
}

pub fn cancel_task_modern(
  client: Client,
  task_id: String,
) -> #(Client, Result(jsonrpc.Value, ClientError)) {
  modern_task_request(
    client,
    "tasks/cancel",
    actions.ClientRequestCancelTask(actions.TaskIdParams(task_id)),
  )
}

fn modern_task_request(
  client: Client,
  method: String,
  params: ClientActionRequest,
) -> #(Client, Result(jsonrpc.Value, ClientError)) {
  case client.protocol_version == jsonrpc.latest_protocol_version {
    False -> #(
      client,
      Error(
        Transport(transport.UnexpectedResponse(
          "Modern task API requires the July 2026 protocol",
        )),
      ),
    )
    True ->
      request_action(client, method, params, fn(result) {
        case result {
          actions.ClientResultTaskModern(value) -> Some(value)
          _ -> None
        }
      })
  }
}

pub fn get_task_result(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.TaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_get_task_result,
    actions.ClientRequestGetTaskResult(params),
    fn(result) {
      case result {
        actions.ClientResultTaskResult(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn cancel_task(
  client: Client,
  params: actions.TaskIdParams,
) -> #(Client, Result(actions.CancelTaskResult, ClientError)) {
  request_action(
    client,
    mcp.method_cancel_task,
    actions.ClientRequestCancelTask(params),
    fn(result) {
      case result {
        actions.ClientResultCancelTask(value) -> Some(value)
        _ -> None
      }
    },
  )
}

pub fn cancelled(
  client: Client,
  params: actions.CancelledNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  case
    client.protocol_version == jsonrpc.latest_protocol_version,
    params.request_id
  {
    True, Some(id) ->
      runtime.cancel_request(client.lifecycle, client.generation, id)
    _, _ -> Nil
  }
  case client.protocol_version, client.transport_config {
    "2026-07-28", transport.Http(_) -> {
      case params.request_id {
        Some(id) ->
          runtime.cancel_request(client.lifecycle, client.generation, id)
        None -> Nil
      }
      #(client, Ok(Nil))
    }
    _, _ ->
      notify_action(
        client,
        mcp.method_notify_cancelled,
        actions.NotifyCancelled(params),
      )
  }
}

pub fn progress(
  client: Client,
  params: actions.ProgressNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_progress,
    actions.NotifyProgress(params),
  )
}

pub fn resource_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_resource_list_changed,
    actions.NotifyResourceListChanged(None),
  )
}

pub fn resource_updated(
  client: Client,
  params: actions.ResourceUpdatedNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_resource_updated,
    actions.NotifyResourceUpdated(params),
  )
}

pub fn prompt_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_prompts_list_changed,
    actions.NotifyPromptListChanged(None),
  )
}

pub fn tool_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_tools_list_changed,
    actions.NotifyToolListChanged(None),
  )
}

pub fn logging_message(
  client: Client,
  params: actions.LoggingMessageNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_logging_message,
    actions.NotifyLoggingMessage(params),
  )
}

pub fn roots_list_changed(
  client: Client,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_roots_list_changed,
    actions.NotifyRootsListChanged(None),
  )
}

pub fn elicitation_complete(
  client: Client,
  params: actions.ElicitationCompleteNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_elicitation_complete,
    actions.NotifyElicitationComplete(params),
  )
}

pub fn task_status(
  client: Client,
  params: actions.TaskStatusNotificationParams,
) -> #(Client, Result(Nil, ClientError)) {
  notify_action(
    client,
    mcp.method_notify_task_status,
    actions.NotifyTaskStatus(params),
  )
}

fn request_paginated(
  client: Client,
  method: String,
  params: Option(actions.PaginatedRequestParams),
  wrap: fn(actions.PaginatedRequestParams) -> actions.ClientActionRequest,
  extract: fn(actions.ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  request_action(
    client,
    method,
    wrap(default_paginated_params(params)),
    extract,
  )
}

fn request_action(
  client: Client,
  method: String,
  action: actions.ClientActionRequest,
  extract: fn(actions.ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  send_request(client, method, Some(action))
  |> expect_result(method, extract)
}

fn request_empty(
  client: Client,
  method: String,
  action: actions.ClientActionRequest,
) -> #(Client, Result(Nil, ClientError)) {
  send_request(client, method, Some(action))
  |> expect_empty_result
}

fn notify_action(
  client: Client,
  method: String,
  action: ActionNotification,
) -> #(Client, Result(Nil, ClientError)) {
  send_notification(client, method, Some(action))
}

fn default_paginated_params(
  params: Option(actions.PaginatedRequestParams),
) -> actions.PaginatedRequestParams {
  case params {
    Some(value) -> value
    None -> actions.PaginatedRequestParams(None, None)
  }
}

fn expect_empty_result(
  response: #(Client, Result(Response(ClientActionResult), ClientError)),
) -> #(Client, Result(Nil, ClientError)) {
  let #(client, result) = response

  case result {
    Ok(jsonrpc.ResultResponse(_, _)) -> #(client, Ok(Nil))
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
  }
}

fn expect_result(
  response: #(Client, Result(Response(ClientActionResult), ClientError)),
  method: String,
  extract: fn(ClientActionResult) -> Option(result),
) -> #(Client, Result(result, ClientError)) {
  let #(client, pending) = response

  case pending {
    Ok(jsonrpc.ResultResponse(_, result)) -> {
      case extract(result) {
        Some(value) -> #(client, Ok(value))
        None -> #(client, Error(unexpected_response_error(method)))
      }
    }
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
  }
}

fn unexpected_response_error(method: String) -> ClientError {
  Transport(transport.UnexpectedResponse(
    "Unexpected response to " <> method <> " request",
  ))
}

fn ensure_tool_descriptor(
  client: Client,
  name: String,
) -> #(Client, Result(Nil, ClientError)) {
  case
    client.peer_capabilities == None
    && client.protocol_version != jsonrpc.latest_protocol_version
  {
    True -> #(client, Ok(Nil))
    False ->
      case dict.get(client.cached_tools, name) {
        Ok(_) -> #(client, Ok(Nil))
        Error(Nil) ->
          discover_tool(client, name, None, [], maximum_tool_discovery_pages)
      }
  }
}

fn discover_tool(
  client: Client,
  name: String,
  cursor: Option(actions.Cursor),
  visited: List(actions.Cursor),
  remaining_pages: Int,
) -> #(Client, Result(Nil, ClientError)) {
  find_tool_pages(
    client,
    name,
    cursor,
    visited,
    remaining_pages,
    fn(client, cursor) {
      list_tools(client, Some(actions.PaginatedRequestParams(cursor, None)))
    },
    "Tool discovery exceeded 100 pages; list and cache tools explicitly",
    "Server repeated a tools/list pagination cursor",
  )
}

fn find_tool_pages(
  client: Client,
  name: String,
  cursor: Option(actions.Cursor),
  visited: List(actions.Cursor),
  remaining_pages: Int,
  fetch: fn(Client, Option(actions.Cursor)) ->
    #(Client, Result(actions.ListToolsResult, ClientError)),
  page_limit_error: String,
  cursor_error: String,
) -> #(Client, Result(Nil, ClientError)) {
  case remaining_pages <= 0 {
    True -> #(
      client,
      Error(Transport(transport.UnexpectedResponse(page_limit_error))),
    )
    False -> {
      let #(client, response) = fetch(client, cursor)
      case response {
        Error(error) -> #(client, Error(error))
        Ok(page) ->
          case dict.get(client.cached_tools, name) {
            Ok(_) -> #(client, Ok(Nil))
            Error(Nil) ->
              case page.page.next_cursor {
                Some(next) ->
                  case list.contains(visited, next) {
                    True -> #(
                      client,
                      Error(
                        Transport(transport.UnexpectedResponse(cursor_error)),
                      ),
                    )
                    False ->
                      find_tool_pages(
                        client,
                        name,
                        Some(next),
                        [next, ..visited],
                        remaining_pages - 1,
                        fetch,
                        page_limit_error,
                        cursor_error,
                      )
                  }
                None -> #(
                  client,
                  Error(
                    Rpc(jsonrpc.invalid_params_error("Unknown tool: " <> name)),
                  ),
                )
              }
          }
      }
    }
  }
}

fn validate_request_capability(
  client: Client,
  params: Option(ClientActionRequest),
  method: String,
) -> Result(Nil, ClientError) {
  case is_closed(client), params {
    True, Some(actions.ClientRequestInitialize(_)) -> Ok(Nil)
    True, _ ->
      Error(Transport(transport.UnexpectedResponse("MCP client is closed")))
    False, _ ->
      case client.peer_capabilities, params {
        None, _ -> Ok(Nil)
        Some(caps), Some(action) -> {
          let action = actions.request_without_input(action)
          let allowed = case action {
            actions.ClientRequestDiscover(_)
            | actions.ClientRequestSubscriptionsListen(_)
            | actions.ClientRequestInitialize(_)
            | actions.ClientRequestPing(_) -> True
            actions.ClientRequestListResources(_)
            | actions.ClientRequestListResourceTemplates(_)
            | actions.ClientRequestReadResource(_) -> caps.resources != None
            actions.ClientRequestSubscribeResource(_)
            | actions.ClientRequestUnsubscribeResource(_) ->
              case caps.resources {
                Some(cap) -> cap.subscribe == Some(True)
                None -> False
              }
            actions.ClientRequestListPrompts(_)
            | actions.ClientRequestGetPrompt(_) -> caps.prompts != None
            actions.ClientRequestListTools(_)
            | actions.ClientRequestCallTool(_) -> caps.tools != None
            actions.ClientRequestComplete(_) -> caps.completions != None
            actions.ClientRequestSetLoggingLevel(_) -> caps.logging != None
            actions.ClientRequestListTasks(_) ->
              case caps.tasks {
                Some(tasks) -> tasks.list != None
                None ->
                  client.protocol_version == jsonrpc.latest_protocol_version
              }
            actions.ClientRequestCancelTask(_) ->
              case caps.tasks {
                Some(tasks) -> tasks.cancel != None
                None ->
                  client.protocol_version == jsonrpc.latest_protocol_version
              }
            actions.ClientRequestGetTask(_)
            | actions.ClientRequestGetTaskResult(_)
            | actions.ClientRequestUpdateTask(_) ->
              client.protocol_version == jsonrpc.latest_protocol_version
              || caps.tasks != None
            actions.ClientRequestWithInput(_, _, _) -> False
          }
          case allowed {
            False ->
              Error(
                Rpc(jsonrpc.method_not_found_error(
                  "Peer did not declare capability for " <> method,
                )),
              )
            True ->
              case action {
                actions.ClientRequestCallTool(params) ->
                  validate_tool_task(client, caps, params)
                _ -> Ok(Nil)
              }
          }
        }
        _, None -> Ok(Nil)
      }
  }
}

fn validate_tool_task(
  client: Client,
  caps: actions.ServerCapabilities,
  params: actions.CallToolRequestParams,
) -> Result(Nil, ClientError) {
  case client.protocol_version == jsonrpc.latest_protocol_version {
    True ->
      case params.task {
        None -> Ok(Nil)
        Some(_) ->
          Error(
            Rpc(jsonrpc.invalid_params_error(
              "Modern tool tasks use the declared task extension",
            )),
          )
      }
    False -> validate_legacy_tool_task(client, caps, params)
  }
}

fn validate_legacy_tool_task(
  client: Client,
  caps: actions.ServerCapabilities,
  params: actions.CallToolRequestParams,
) -> Result(Nil, ClientError) {
  let support = case dict.get(client.cached_tools, params.name) {
    Ok(tool) ->
      case tool.execution {
        Some(execution) -> execution.task_support
        None -> None
      }
    Error(Nil) -> None
  }
  let task_calls = case caps.tasks {
    Some(actions.ServerTasksCapabilities(requests: Some(requests), ..)) ->
      requests.tools_call != None
    _ -> False
  }
  case params.task, support {
    Some(_), _ if !task_calls ->
      Error(
        Rpc(jsonrpc.method_not_found_error(
          "Peer does not support task-augmented tools/call",
        )),
      )
    Some(_), Some(actions.TaskForbidden) | Some(_), None ->
      Error(
        Rpc(jsonrpc.method_not_found_error(
          "Tool does not support task augmentation",
        )),
      )
    None, Some(actions.TaskRequired) ->
      Error(
        Rpc(jsonrpc.method_not_found_error("Tool requires task augmentation")),
      )
    _, _ -> Ok(Nil)
  }
}

fn recover_expired_session(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> Client {
  let fresh =
    Client(
      ..client,
      session_id: None,
      peer_capabilities: None,
      cached_tools: dict.new(),
    )
  let initialize_request = case incoming {
    Request(_, method, _) -> method == mcp.method_initialize
    jsonrpc.Notification(_, _) -> False
  }
  case is_closed(client), initialize_request, client.client_info {
    False, False, Some(info) ->
      case initialize_current(fresh, info) {
        Ok(#(recovered, _)) -> recovered
        Error(_) -> fresh
      }
    True, _, _ -> Client(..fresh, closed: True)
    _, _, _ -> fresh
  }
}

fn validate_response_mode(
  client: Client,
  incoming: Request(ClientActionRequest),
  response: Response(ClientActionResult),
) -> Result(Response(ClientActionResult), ClientError) {
  case client.protocol_version == jsonrpc.latest_protocol_version {
    True -> Ok(response)
    False -> validate_legacy_response_mode(client, incoming, response)
  }
}

fn validate_legacy_response_mode(
  client: Client,
  incoming: Request(ClientActionRequest),
  response: Response(ClientActionResult),
) -> Result(Response(ClientActionResult), ClientError) {
  case client.peer_capabilities, incoming, response {
    Some(_),
      Request(_, _, Some(actions.ClientRequestCallTool(params))),
      jsonrpc.ResultResponse(_, result)
    -> {
      case params.task, result {
        Some(_), actions.ClientResultCreateTask(_)
        | None, actions.ClientResultCallTool(_)
        -> Ok(response)
        _, _ ->
          Error(
            Transport(transport.UnexpectedResponse(
              "tools/call response did not match task augmentation mode",
            )),
          )
      }
    }
    _, _, _ -> Ok(response)
  }
}

fn send_request(
  client: Client,
  method: String,
  params: Option(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  request(client, Request(jsonrpc.StringId(uuid.v4_string()), method, params))
}

/// Issue a request with a caller-selected ID. Use the same ID with `cancelled`
/// for ordinary requests; task execution must be cancelled with `cancel_task`.
/// Request metadata can include a progress token handled by the configured
/// progress callback.
pub fn request(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  case incoming {
    jsonrpc.Notification(_, _) -> #(
      client,
      Error(Rpc(jsonrpc.invalid_params_error("Expected a request"))),
    )
    Request(_, method, params) -> {
      let #(client, prepared) = case
        option.map(params, actions.request_without_input)
      {
        Some(actions.ClientRequestCallTool(params)) ->
          ensure_tool_descriptor(client, params.name)
        _ -> #(client, Ok(Nil))
      }
      case prepared {
        Error(error) -> #(client, Error(error))
        Ok(Nil) ->
          case validate_request_capability(client, params, method) {
            Error(error) -> #(client, Error(error))
            Ok(Nil) ->
              case client.protocol_version == jsonrpc.latest_protocol_version {
                True -> execute_modern(client, incoming)
                False -> perform_request(client, incoming)
              }
          }
      }
    }
  }
}

type InputEvent {
  InputReply(Result(Response(actions.ServerActionResult), RpcError))
  InputStopped
}

fn execute_modern(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let assert Request(id, _, _) = incoming
  let stop = process.new_subject()
  let expired = process.new_subject()
  runtime.watch_request(client.lifecycle, client.generation, id, stop)
  let timer =
    process.spawn_unlinked(fn() {
      process.sleep(transport_timeout(client))
      process.send(expired, Nil)
      process.send(stop, Nil)
    })
  let #(client, outcome) =
    modern_round(
      client,
      incoming,
      incoming,
      stop,
      client.maximum_input_rounds,
      False,
    )
  process.kill(timer)
  runtime.unwatch(client.lifecycle, stop)
  let outcome = case process.receive(expired, 0) {
    Ok(_) -> Error(Transport(transport.TimeoutError))
    Error(_) -> outcome
  }
  #(client, outcome)
}

fn modern_round(
  client: Client,
  original: Request(ClientActionRequest),
  current: Request(ClientActionRequest),
  stop: process.Subject(Nil),
  remaining: Int,
  refreshed_headers: Bool,
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  case process.receive(stop, 0) {
    Ok(_) -> #(
      client,
      Error(Transport(transport.UnexpectedResponse("MCP request cancelled"))),
    )
    Error(_) -> {
      let current = attach_metadata(client, current)
      let assert Request(id, _, _) = current
      runtime.watch_request(client.lifecycle, client.generation, id, stop)
      let #(client, response) =
        perform_request_options(client, current, Some(stop))
      let #(client, response) = retain_cache_hint(client, response)
      case response {
        Ok(jsonrpc.ResultResponse(
          _,
          actions.ClientResultInputRequired(required),
        )) -> {
          let state_size =
            option.map(required.request_state, string.byte_size)
            |> option.unwrap(0)
          case
            remaining <= 0
            || required.input_requests == None
            && required.request_state == None
            || state_size > 1_048_576
          {
            True -> #(
              client,
              Error(
                Transport(transport.UnexpectedResponse(
                  "Invalid or excessive MRTR continuation",
                )),
              ),
            )
            False -> {
              case
                collect_inputs(
                  client.capabilities,
                  required.input_requests,
                  stop,
                )
              {
                Error(error) -> #(client, Error(error))
                Ok(inputs) -> {
                  let assert Request(_, method, Some(action)) =
                    attach_metadata(client, original)
                  let next =
                    Request(
                      jsonrpc.StringId(uuid.v4_string()),
                      method,
                      Some(actions.ClientRequestWithInput(
                        actions.request_without_input(action),
                        required.request_state,
                        inputs,
                      )),
                    )
                  modern_round(
                    client,
                    original,
                    next,
                    stop,
                    remaining - 1,
                    refreshed_headers,
                  )
                }
              }
            }
          }
        }
        Ok(jsonrpc.ErrorResponse(_, error))
          if error.code == -32_020 && !refreshed_headers
        ->
          case original {
            Request(_, method, Some(actions.ClientRequestCallTool(params))) -> {
              let #(client, refreshed) =
                refresh_tool_headers(
                  client,
                  params.name,
                  None,
                  [],
                  stop,
                  maximum_tool_discovery_pages,
                )
              case refreshed {
                Error(error) -> #(client, Error(error))
                Ok(_) -> {
                  let Request(_, _, params) = current
                  modern_round(
                    client,
                    original,
                    Request(jsonrpc.StringId(uuid.v4_string()), method, params),
                    stop,
                    remaining,
                    True,
                  )
                }
              }
            }
            _ -> #(client, response)
          }
        _ -> #(client, response)
      }
    }
  }
}

fn retain_cache_hint(
  client: Client,
  response: Result(Response(ClientActionResult), ClientError),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  case response {
    Ok(jsonrpc.ResultResponse(id, actions.ClientResultWithCache(value, hint))) -> #(
      Client(..client, last_cache_hint: Some(hint)),
      Ok(jsonrpc.ResultResponse(id, value)),
    )
    _ -> #(client, response)
  }
}

fn collect_inputs(
  config: capabilities.Config,
  requests: Option(Dict(String, jsonrpc.Value)),
  stop: process.Subject(Nil),
) -> Result(Option(Dict(String, jsonrpc.Value)), ClientError) {
  case requests {
    None -> Ok(None)
    Some(requests) -> {
      case dict.size(requests) > 32 {
        True ->
          Error(
            Transport(transport.UnexpectedResponse(
              "MRTR response exceeded 32 input requests",
            )),
          )
        False ->
          list.try_fold(dict.to_list(requests), dict.new(), fn(inputs, entry) {
            let #(key, input) = entry
            use response <- result.try(collect_input(config, input, stop))
            Ok(dict.insert(inputs, key, response))
          })
          |> result.map(Some)
      }
    }
  }
}

fn collect_input(
  config: capabilities.Config,
  input: jsonrpc.Value,
  stop: process.Subject(Nil),
) -> Result(jsonrpc.Value, ClientError) {
  use fields <- result.try(case input {
    jsonrpc.VObject(fields) -> Ok(fields)
    _ ->
      Error(
        Transport(transport.UnexpectedResponse(
          "MRTR input must be a request object",
        )),
      )
  })
  let id = jsonrpc.StringId(uuid.v4_string())
  let request =
    jsonrpc.VObject([
      #("jsonrpc", jsonrpc.VString("2.0")),
      #("id", jsonrpc.request_id_to_value(id)),
      ..list.filter(fields, fn(field) {
        field.0 != "jsonrpc" && field.0 != "id"
      })
    ])
    |> codec_common.encode_value
    |> json.to_string
  use incoming <- result.try(case client_codec.decode_server_message(request) {
    Ok(client_codec.ServerActionRequest(Request(_, _, Some(action)) as request)) ->
      case action {
        actions.ServerRequestListRoots(_) -> Ok(request)
        actions.ServerRequestCreateMessage(params) if params.task == None ->
          Ok(request)
        actions.ServerRequestElicit(actions.ElicitRequestForm(params))
          if params.task == None
        -> Ok(request)
        actions.ServerRequestElicit(actions.ElicitRequestUrl(params)) ->
          case actions.elicit_url_task(params) {
            None -> Ok(request)
            _ ->
              Error(
                Transport(transport.UnexpectedResponse(
                  "Task-augmented MRTR input is unsupported",
                )),
              )
          }
        _ ->
          Error(
            Transport(transport.UnexpectedResponse(
              "Unsupported MRTR input request",
            )),
          )
      }
    _ ->
      Error(
        Transport(transport.UnexpectedResponse("Malformed MRTR input request")),
      )
  })
  let reply = process.new_subject()
  capabilities.start_request(config, incoming, reply)
  let selector =
    process.new_selector()
    |> process.select_map(reply, InputReply)
    |> process.select_map(stop, fn(_) { InputStopped })
  case process.selector_receive_forever(selector) {
    InputStopped -> {
      capabilities.cancel_input(config, id)
      Error(
        Transport(transport.UnexpectedResponse(
          "MCP request cancelled while collecting input",
        )),
      )
    }
    InputReply(Error(error))
    | InputReply(Ok(jsonrpc.ErrorResponse(_, error))) -> Error(Rpc(error))
    InputReply(Ok(response)) ->
      server_codec.encode_server_response(response)
      |> json.parse(decode.at(["result"], client_codec.value_decoder()))
      |> result.map_error(fn(_) {
        Transport(transport.UnexpectedResponse("Invalid MRTR input result"))
      })
  }
}

fn refresh_tool_headers(
  client: Client,
  name: String,
  cursor: Option(actions.Cursor),
  visited: List(actions.Cursor),
  stop: process.Subject(Nil),
  pages: Int,
) -> #(Client, Result(Nil, ClientError)) {
  find_tool_pages(
    client,
    name,
    cursor,
    visited,
    pages,
    fn(client, cursor) { fetch_tool_headers(client, cursor, stop) },
    "Tool header refresh exceeded page limit",
    "Repeated tool header refresh cursor",
  )
}

fn fetch_tool_headers(
  client: Client,
  cursor: Option(actions.Cursor),
  stop: process.Subject(Nil),
) -> #(Client, Result(actions.ListToolsResult, ClientError)) {
  let incoming =
    Request(
      jsonrpc.StringId(uuid.v4_string()),
      mcp.method_list_tools,
      Some(
        actions.ClientRequestListTools(actions.PaginatedRequestParams(
          cursor,
          None,
        )),
      ),
    )
    |> attach_metadata(client, _)
  let #(client, response) =
    perform_request_options(client, incoming, Some(stop))
  let #(client, response) = retain_cache_hint(client, response)
  case response {
    Ok(jsonrpc.ResultResponse(_, actions.ClientResultListTools(page))) -> {
      let #(client, page) = cache_tool_page(client, page, cursor, True)
      #(client, Ok(page))
    }
    Ok(jsonrpc.ErrorResponse(_, error)) -> #(client, Error(Rpc(error)))
    Error(error) -> #(client, Error(error))
    _ -> #(client, Error(unexpected_response_error(mcp.method_list_tools)))
  }
}

/// Set a timeout for one request while retaining the client's default timeout.
pub fn request_with_timeout(
  client: Client,
  incoming: Request(ClientActionRequest),
  timeout_ms: Int,
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let #(next_client, outcome) =
    request(with_request_timeout(client, timeout_ms), incoming)
  #(Client(..next_client, transport_config: client.transport_config), outcome)
}

fn perform_request(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  perform_request_options(client, incoming, None)
}

fn perform_request_options(
  client: Client,
  incoming: Request(ClientActionRequest),
  stop: Option(process.Subject(Nil)),
) -> #(Client, Result(Response(ClientActionResult), ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  let transport.Runners(
    stdio_request: stdio_request,
    streamable_request: streamable_request,
    ..,
  ) = runners

  let response = case wire.validate_request(incoming, protocol_version) {
    Error(message) -> Error(Transport(transport.UnexpectedResponse(message)))
    Ok(_) ->
      case transport_config, client.stdio_manager, protocol_version {
        transport.Http(http_config), Some(_), "2026-07-28" -> {
          use mirrored <- result.try(mirrored_headers(client, incoming))
          transport.streamable_http_request_options(
            http_config,
            None,
            protocol_version,
            capability_config,
            incoming,
            fn(request) { wire.encode_request(request, protocol_version) },
            fn(body, request) {
              wire.decode_response(body, request, protocol_version)
            },
            mirrored,
            stop,
          )
          |> result.map_error(Transport)
        }
        transport.Stdio(config), Some(manager), "2026-07-28" ->
          case stop {
            Some(stop) ->
              transport.stdio_request_until_stopped(
                manager,
                config,
                session_id,
                capability_config,
                incoming,
                stop,
              )
              |> result.map_error(Transport)
            None ->
              send_message(
                transport_config,
                session_id,
                protocol_version,
                capability_config,
                incoming,
                stdio_request,
                streamable_request,
              )
          }
        _, _, _ ->
          send_message(
            transport_config,
            session_id,
            protocol_version,
            capability_config,
            incoming,
            stdio_request,
            streamable_request,
          )
      }
  }
  case response {
    Ok(response) -> {
      let peer_protocol_version = case response {
        transport.VersionedTransportResponse(protocol_version:, ..) ->
          Some(protocol_version)
        _ -> client.peer_protocol_version
      }
      #(
        set_runtime(
          Client(..client, peer_protocol_version: peer_protocol_version),
          response.session_id,
        ),
        validate_response_mode(client, incoming, response.response),
      )
    }
    Error(Transport(transport.SessionExpired)) -> #(
      recover_expired_session(client, incoming),
      Error(Transport(transport.SessionExpired)),
    )
    Error(error) -> #(client, Error(error))
  }
}

fn mirrored_headers(
  client: Client,
  incoming: Request(ClientActionRequest),
) -> Result(List(#(String, String)), ClientError) {
  let params = case incoming {
    Request(_, _, params) | jsonrpc.Notification(_, params) -> params
  }
  case params |> option.map(actions.request_without_input) {
    Some(actions.ClientRequestCallTool(params)) -> {
      use tool <- result.try(
        dict.get(client.cached_tools, params.name)
        |> result.map_error(fn(_) {
          Rpc(jsonrpc.invalid_params_error("Unknown tool: " <> params.name))
        }),
      )
      http_headers.parameters(
        tool.input_schema,
        jsonrpc.VObject(
          params.arguments |> option.map(dict.to_list) |> option.unwrap([]),
        ),
      )
      |> result.map_error(fn(message) {
        Rpc(jsonrpc.invalid_params_error(message))
      })
    }
    _ -> Ok([])
  }
}

fn send_notification(
  client: Client,
  method: String,
  params: Option(ActionNotification),
) -> #(Client, Result(Nil, ClientError)) {
  let allowed = case client.protocol_version, client.transport_config {
    "2026-07-28", transport.Http(_) -> False
    "2026-07-28", transport.Stdio(_) -> method == mcp.method_notify_cancelled
    _, _ -> True
  }
  case allowed {
    False -> #(
      client,
      Error(
        Rpc(jsonrpc.method_not_found_error(
          "Notification is unavailable in this protocol version: " <> method,
        )),
      ),
    )
    True -> send_allowed_notification(client, method, params)
  }
}

fn send_allowed_notification(
  client: Client,
  method: String,
  params: Option(ActionNotification),
) -> #(Client, Result(Nil, ClientError)) {
  case is_closed(client) {
    True -> #(
      client,
      Error(Transport(transport.UnexpectedResponse("MCP client is closed"))),
    )
    False -> perform_notification(client, method, params)
  }
}

fn perform_notification(
  client: Client,
  method: String,
  params: Option(ActionNotification),
) -> #(Client, Result(Nil, ClientError)) {
  let Client(
    transport_config: transport_config,
    runners: runners,
    capabilities: capability_config,
    protocol_version: protocol_version,
    session_id: session_id,
    ..,
  ) = client

  let transport.Runners(
    stdio_notification: stdio_request,
    streamable_notification: streamable_request,
    ..,
  ) = runners

  let notification = jsonrpc.Notification(method, params)

  case
    send_message(
      transport_config,
      session_id,
      protocol_version,
      capability_config,
      notification,
      stdio_request,
      streamable_request,
    )
  {
    Ok(response) -> #(set_runtime(client, response.session_id), Ok(Nil))
    Error(Transport(transport.SessionExpired)) -> {
      let client = case method == mcp.method_initialized {
        True ->
          Client(
            ..client,
            session_id: None,
            peer_capabilities: None,
            cached_tools: dict.new(),
          )
        False ->
          recover_expired_session(
            client,
            jsonrpc.Request(
              jsonrpc.StringId("expired-notification"),
              method,
              None,
            ),
          )
      }
      #(client, Error(Transport(transport.SessionExpired)))
    }
    Error(error) -> #(client, Error(error))
  }
}

fn send_message(
  transport_config: transport.Config,
  session_id: Option(String),
  protocol_version: String,
  capability_config: capabilities.Config,
  request: Request(action),
  stdio_request: fn(
    transport.StdioConfig,
    Option(String),
    capabilities.Config,
    Request(action),
  ) -> Result(transport.TransportResponse(result), transport.TransportError),
  streamable_request: fn(
    transport.HttpConfig,
    Option(String),
    String,
    capabilities.Config,
    Request(action),
  ) -> Result(transport.TransportResponse(result), transport.TransportError),
) -> Result(transport.TransportResponse(result), ClientError) {
  transport.send_request(
    transport_config,
    session_id,
    protocol_version,
    capability_config,
    request,
    stdio_request,
    streamable_request,
  )
  |> result.map_error(Transport)
}

fn set_runtime(client: Client, session_id: Option(String)) -> Client {
  let next_session_id = case
    client.transport_config,
    client.protocol_version,
    session_id
  {
    transport.Http(_), "2026-07-28", _ -> None
    _, _, Some(_) -> session_id
    _, _, None -> client.session_id
  }

  Client(..client, session_id: next_session_id)
}

fn is_closed(client: Client) -> Bool {
  client.closed || !runtime.is_open(client.lifecycle, client.generation)
}
