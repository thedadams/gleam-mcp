import gleam/int
import gleam/option.{None}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/jsonrpc

pub fn implementation() -> actions.Implementation {
  actions.Implementation("gleam-mcp-conformance", "0.1.0", None, None, None, [])
}

pub fn bootstrap(
  config: transport.HttpConfig,
  protocol_version: String,
  caps: capabilities.Config,
) -> Result(client.Client, String) {
  let app = client.new(transport.Http(config), caps)
  let connected = case protocol_version {
    "2025-11-25" ->
      client.initialize(app, implementation())
      |> result.map(fn(pair) { pair.0 })
    "2026-07-28" ->
      client.connect(app, implementation())
      |> result.map(fn(pair) { pair.0 })
    _ -> {
      let _ = client.close(app)
      Error(
        client.Transport(transport.UnexpectedResponse(
          "Unsupported conformance protocol version: " <> protocol_version,
        )),
      )
    }
  }
  case connected {
    Ok(app) if app.protocol_version == protocol_version -> Ok(app)
    Ok(app) -> {
      let _ = client.close(app)
      Error("Client negotiated a different conformance protocol version")
    }
    Error(error) -> {
      let _ = client.close(app)
      Error(client_error(error))
    }
  }
}

/// Carry the SDK's updated client through both successful and failed steps.
pub fn step(
  outcome: #(client.Client, Result(a, client.ClientError)),
) -> #(client.Client, Result(a, String)) {
  let #(app, outcome) = outcome
  #(app, result.map_error(outcome, client_error))
}

pub fn then(
  outcome: #(client.Client, Result(a, String)),
  next: fn(client.Client, a) -> #(client.Client, Result(b, String)),
) -> #(client.Client, Result(b, String)) {
  let #(app, outcome) = outcome
  case outcome {
    Ok(value) -> next(app, value)
    Error(error) -> #(app, Error(error))
  }
}

pub fn finish(
  outcome: #(client.Client, Result(a, String)),
) -> #(client.Client, Result(Nil, String)) {
  let #(app, outcome) = outcome
  #(app, result.map(outcome, fn(_) { Nil }))
}

pub fn close(
  app: client.Client,
  outcome: Result(Nil, String),
) -> Result(Nil, String) {
  let #(_, closed) = client.close(app)
  case outcome {
    Error(error) -> Error(error)
    Ok(_) -> result.map_error(closed, client_error)
  }
}

pub fn client_error(error: client.ClientError) -> String {
  case error {
    client.Rpc(jsonrpc.RpcError(code, message, _)) ->
      "JSON-RPC " <> int.to_string(code) <> ": " <> message
    client.Transport(error) ->
      case error {
        transport.AuthorizationRequired(status, _) ->
          "Authorization required: HTTP " <> int.to_string(status)
        transport.ProcessError(message)
        | transport.HttpError(message)
        | transport.UnexpectedResponse(message) -> message
        transport.ProtocolHttpError(status, _)
        | transport.VersionedProtocolHttpError(status, _, _) ->
          "HTTP " <> int.to_string(status)
        transport.TimeoutError -> "MCP operation timed out"
        transport.SessionExpired -> "MCP session expired"
      }
  }
}
