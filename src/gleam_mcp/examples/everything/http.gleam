import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_mcp/server
import gleam_mcp/server/streamable_http
import mist

pub fn handler(
  app: server.Server,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  let next = streamable_http.handler(app)
  cors(fn(req: request.Request(mist.Connection)) {
    case req.path {
      "/mcp" -> {
        let result = next(req)
        case req.method == http.Delete && result.status == 204 {
          True -> response.Response(..result, status: 200)
          False -> result
        }
      }
      _ ->
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
    }
  })
}

/// Match the reference example's permissive Inspector CORS configuration.
/// This wrapper is specific to the demonstration transports.
pub fn cors(
  next: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  cors_config(
    next,
    "GET,POST,DELETE",
    Some("mcp-session-id,last-event-id,mcp-protocol-version"),
  )
}

pub fn deprecated_cors(
  next: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  cors_config(next, "GET,POST", None)
}

fn cors_config(
  next: fn(request.Request(mist.Connection)) ->
    response.Response(mist.ResponseData),
  methods: String,
  exposed: Option(String),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(req: request.Request(mist.Connection)) {
    let result = case req.method {
      http.Options ->
        response.new(204) |> response.set_body(mist.Bytes(bytes_tree.new()))
      _ ->
        next(
          request.Request(
            ..req,
            headers: list.filter(req.headers, fn(header) {
              header.0 != "origin"
            }),
          ),
        )
    }
    let result =
      result
      |> response.set_header("access-control-allow-origin", "*")
      |> response.set_header("access-control-allow-methods", methods)
    let result = case exposed {
      Some(headers) ->
        response.set_header(result, "access-control-expose-headers", headers)
      None -> result
    }
    case request.get_header(req, "access-control-request-headers") {
      Ok(headers) ->
        response.set_header(result, "access-control-allow-headers", headers)
      Error(_) -> result
    }
  }
}
