import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/uri
import gleam_mcp/actions
import gleam_mcp/codec_decode
import gleam_mcp/examples/everything/interaction_results
import gleam_mcp/examples/everything/tool_helpers as helpers
import gleam_mcp/jsonrpc.{type Value, VArray, VBool, VObject, VString}
import gleam_mcp/server
import youid/uuid

pub opaque type Store {
  Store(subject: process.Subject(Message))
}

type Message {
  Take(key: #(String, String, String), reply: process.Subject(Bool))
  Clear(session_id: String)
  Stop
}

type Arguments {
  Arguments(
    url: String,
    message: String,
    elicitation_id: Option(String),
    error_path: Bool,
  )
}

pub fn new() -> Store {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(fn(state, message) {
      case message {
        Take(key, reply) -> {
          let already_issued = dict.has_key(state, key)
          process.send(reply, !already_issued)
          actor.continue(case already_issued {
            True -> dict.delete(state, key)
            False -> dict.insert(state, key, Nil)
          })
        }
        Clear(session_id) ->
          state
          |> dict.filter(fn(key, _) { key.0 != session_id })
          |> actor.continue
        Stop -> actor.stop()
      }
    })
    |> actor.start
  Store(started.data)
}

pub fn clear_session(store: Store, session_id: String) -> Nil {
  process.send(store.subject, Clear(session_id))
}

pub fn close(store: Store) -> Nil {
  process.send(store.subject, Stop)
}

pub fn register(app: server.Server, store: Store) -> server.Server {
  server.register_context_tool_descriptor(
    app,
    descriptor(),
    fn(app, context, arguments) {
      prepare(store, context, arguments)
      |> result.try(fn(params) {
        let assert actions.ElicitRequestUrlParams(_, id, url, _, _) = params
        server.elicit(
          server.with_request_timeout(app, 600_000),
          context,
          actions.ElicitRequestUrl(params),
        )
        |> result.map(fn(value) {
          interaction_results.url_tool_result(value, id, url)
        })
      })
      |> helpers.tool_result
    },
  )
}

pub fn descriptor() -> actions.Tool {
  helpers.descriptor(
    "trigger-url-elicitation",
    "Trigger URL Elicitation Tool",
    "Trigger a URL elicitation so the client can direct the user to a browser flow. "
      <> "Supports two mechanisms: the request path (elicitation/create, default) which awaits the user's "
      <> "response, and the error path (UrlElicitationRequiredError, -32042) which signals the client "
      <> "to handle URL elicitation via the error response. Set errorPath=true to use the error path.",
    helpers.object_schema(
      [
        #(
          "url",
          helpers.string_schema("The URL the user should open")
            |> helpers.with_property("format", VString("uri")),
        ),
        #(
          "message",
          helpers.string_schema(
            "Message shown to the user before opening the URL",
          )
            |> helpers.with_property(
              "default",
              VString("Please open the link to complete this action."),
            ),
        ),
        #(
          "elicitationId",
          helpers.string_schema(
            "Optional explicit elicitation ID. Defaults to a random UUID.",
          ),
        ),
        #(
          "errorPath",
          VObject([
            #("type", VString("boolean")),
            #("default", VBool(False)),
            #(
              "description",
              VString(
                "Controls which elicitation mechanism is used. "
                <> "When false (default), sends an elicitation/create request (request path). "
                <> "When true, throws a UrlElicitationRequiredError (MCP error code -32042) so the client handles "
                <> "the URL elicitation via the error path rather than waiting for a response. "
                <> "To clear the error, satisfy the prerequisite and retry this call with the same arguments; the "
                <> "retry ignores errorPath and proceeds, so the client does not loop on the same error.",
              ),
            ),
          ]),
        ),
      ],
      ["url"],
    ),
    None,
    helpers.interactive_annotations(True),
  )
}

/// The error-path marker uses the original caller arguments, so a retry without
/// an explicit ID matches even though each request generates a fresh UUID.
pub fn prepare(
  store: Store,
  context: server.RequestContext,
  arguments: Option(dict.Dict(String, Value)),
) -> Result(actions.ElicitRequestUrlParams, jsonrpc.RpcError) {
  let fields = case arguments {
    Some(fields) -> dict.to_list(fields)
    None -> []
  }
  use arguments <- result.try(
    codec_decode.decode_value(VObject(fields), arguments_decoder())
    |> result.map_error(jsonrpc.invalid_params_error),
  )
  use _ <- result.try(validate_url(arguments.url))
  let id = arguments.elicitation_id |> option_default(uuid.v4_string())
  let key = #(
    server.session_id(context) |> option_default("default"),
    arguments.url,
    arguments.elicitation_id |> option_default(""),
  )
  case
    arguments.error_path
    && actor.call(store.subject, 1000, fn(reply) { Take(key, reply) })
  {
    True -> Error(prerequisite_error())
    False ->
      Ok(actions.ElicitRequestUrlParams(
        arguments.message,
        id,
        arguments.url,
        None,
        None,
      ))
  }
}

fn prerequisite_error() -> jsonrpc.RpcError {
  jsonrpc.RpcError(
    -32_042,
    "MCP error -32042: This request requires browser-based authorization.",
    Some(
      VObject([
        #(
          "elicitations",
          VArray([
            VObject([
              #("mode", VString("url")),
              #("url", VString("https://modelcontextprotocol.io")),
              #(
                "message",
                VString(
                  "Open this link to satisfy the prerequisite, then retry the request.",
                ),
              ),
              #("elicitationId", VString(uuid.v4_string())),
            ]),
          ]),
        ),
      ]),
    ),
  )
}

fn arguments_decoder() -> decode.Decoder(Arguments) {
  use url <- decode.field("url", decode.string)
  use message <- decode.optional_field(
    "message",
    "Please open the link to complete this action.",
    decode.string,
  )
  use id <- decode.optional_field(
    "elicitationId",
    None,
    decode.map(decode.string, Some),
  )
  use error_path <- decode.optional_field("errorPath", False, decode.bool)
  decode.success(Arguments(url, message, id, error_path))
}

fn validate_url(value: String) -> Result(Nil, jsonrpc.RpcError) {
  case uri.parse(value) {
    Ok(uri) ->
      case uri.scheme, uri.host {
        None, _ ->
          Error(jsonrpc.invalid_params_error("url must be an absolute URL"))
        Some("http"), None
        | Some("https"), None
        | Some("http"), Some("")
        | Some("https"), Some("")
        -> Error(jsonrpc.invalid_params_error("url must have a host"))
        _, _ -> Ok(Nil)
      }
    Error(_) -> Error(jsonrpc.invalid_params_error("url must be a valid URL"))
  }
}

fn option_default(value: Option(a), default: a) -> a {
  case value {
    Some(value) -> value
    None -> default
  }
}
