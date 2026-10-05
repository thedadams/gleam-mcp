import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client/codec
import gleam_mcp/codec_common
import gleam_mcp/jsonrpc
import gleam_mcp/wire

pub type Event {
  Acknowledged(jsonrpc.Value)
  Notification(jsonrpc.Request(actions.ActionNotification))
  Finished(Result(Nil, jsonrpc.RpcError))
}

pub opaque type Validator {
  Validator(process.Subject(Message))
}

type Message {
  Frame(String, process.Subject(Result(Event, String)))
  Stop
  OwnerDown(process.Down)
}

pub fn new(
  request: jsonrpc.Request(actions.ClientActionRequest),
  requested: Option(jsonrpc.Value),
) -> Validator {
  let ready = process.new_subject()
  let owner = process.self()
  let _ =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      let monitor = process.monitor(owner)
      process.send(ready, subject)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_specific_monitor(monitor, OwnerDown)
      loop(selector, request, requested, None)
    })
  Validator(process.receive_forever(ready))
}

pub fn stop(validator: Validator) -> Nil {
  let Validator(subject) = validator
  process.send(subject, Stop)
}

pub fn event(validator: Validator, payload: String) -> Result(Event, String) {
  let Validator(subject) = validator
  let reply = process.new_subject()
  process.send(subject, Frame(payload, reply))
  process.receive(reply, 1000)
  |> result.unwrap(Error("Subscription validation failed"))
}

fn loop(
  selector: process.Selector(Message),
  request: jsonrpc.Request(actions.ClientActionRequest),
  requested: Option(jsonrpc.Value),
  acknowledged: Option(jsonrpc.Value),
) -> Nil {
  case process.selector_receive_forever(selector) {
    Stop | OwnerDown(_) -> Nil
    Frame(payload, reply) -> {
      let response = validate(payload, request, requested, acknowledged)
      process.send(reply, result.map(response, fn(pair) { pair.0 }))
      let acknowledged = case response {
        Ok(#(_, next)) -> next
        Error(_) -> acknowledged
      }
      loop(selector, request, requested, acknowledged)
    }
  }
}

fn validate(
  payload: String,
  request: jsonrpc.Request(actions.ClientActionRequest),
  requested: Option(jsonrpc.Value),
  acknowledged: Option(jsonrpc.Value),
) -> Result(#(Event, Option(jsonrpc.Value)), String) {
  let assert jsonrpc.Request(id, _, _) = request
  case wire.decode_response(payload, request, jsonrpc.latest_protocol_version) {
    Ok(jsonrpc.ErrorResponse(_, error)) ->
      Ok(#(Finished(Error(error)), acknowledged))
    Ok(jsonrpc.ResultResponse(_, _)) -> {
      use _ <- result.try(check_id(
        payload,
        ["result", "_meta", "io.modelcontextprotocol/subscriptionId"],
        id,
      ))
      case acknowledged {
        None -> Error("Subscription completed before acknowledgment")
        Some(_) -> Ok(#(Finished(Ok(Nil)), acknowledged))
      }
    }
    Error(_) -> {
      use _ <- result.try(check_id(
        payload,
        ["params", "_meta", "io.modelcontextprotocol/subscriptionId"],
        id,
      ))
      use method <- result.try(
        json.parse(payload, decode.at(["method"], decode.string))
        |> result.map_error(fn(_) { "Invalid subscription notification" }),
      )
      case method, acknowledged {
        "notifications/subscriptions/acknowledged", None -> {
          use filter <- result.try(
            json.parse(
              payload,
              decode.at(["params", "notifications"], codec.value_decoder()),
            )
            |> result.map_error(fn(_) {
              "Subscription acknowledgment requires a notifications object"
            }),
          )
          use _ <- result.try(check_subset(
            filter,
            requested |> option.unwrap(jsonrpc.VObject([])),
          ))
          Ok(#(Acknowledged(filter), Some(filter)))
        }
        "notifications/subscriptions/acknowledged", Some(_) ->
          Error("Duplicate subscription acknowledgment")
        _, None -> Error("Subscription notification preceded acknowledgment")
        _, Some(filter) -> {
          use _ <- result.try(check_notification(method, payload, filter))
          case
            wire.decode_server_message(payload, jsonrpc.latest_protocol_version)
          {
            Ok(codec.ActionNotification(notification)) ->
              Ok(#(Notification(notification), acknowledged))
            _ -> Error("Unsupported subscription notification")
          }
        }
      }
    }
  }
}

fn check_id(
  payload: String,
  path: List(String),
  expected: jsonrpc.RequestId,
) -> Result(Nil, String) {
  case json.parse(payload, decode.at(path, codec_common.request_id_decoder())) {
    Ok(id) if id == expected -> Ok(Nil)
    _ -> Error("Subscription ID does not match its listen request")
  }
}

fn check_subset(
  accepted: jsonrpc.Value,
  requested: jsonrpc.Value,
) -> Result(Nil, String) {
  case accepted, requested {
    jsonrpc.VObject(accepted), jsonrpc.VObject(requested) ->
      list.try_each(accepted, fn(entry) {
        let #(key, value) = entry
        let requested =
          list.key_find(requested, key) |> result.unwrap(jsonrpc.VNull)
        case key, value, requested {
          "toolsListChanged", jsonrpc.VBool(False), _
          | "promptsListChanged", jsonrpc.VBool(False), _
          | "resourcesListChanged", jsonrpc.VBool(False), _
          -> Ok(Nil)
          "toolsListChanged", jsonrpc.VBool(True), jsonrpc.VBool(True)
          | "promptsListChanged", jsonrpc.VBool(True), jsonrpc.VBool(True)
          | "resourcesListChanged", jsonrpc.VBool(True), jsonrpc.VBool(True)
          -> Ok(Nil)
          "resourceSubscriptions",
            jsonrpc.VArray(uris),
            jsonrpc.VArray(requested)
          | "taskIds", jsonrpc.VArray(uris), jsonrpc.VArray(requested)
          ->
            case
              list.all(uris, fn(uri) {
                case uri {
                  jsonrpc.VString(_) -> list.contains(requested, uri)
                  _ -> False
                }
              })
            {
              True -> Ok(Nil)
              False ->
                Error("Server acknowledged unrequested resource subscriptions")
            }
          _, _, _ ->
            Error(
              "Server acknowledged an invalid or unrequested notification filter",
            )
        }
      })
    _, _ -> Error("Notification filter must be an object")
  }
}

fn check_notification(
  method: String,
  payload: String,
  filter: jsonrpc.Value,
) -> Result(Nil, String) {
  let fields = case filter {
    jsonrpc.VObject(fields) -> dict.from_list(fields)
    _ -> dict.new()
  }
  let allowed = case method {
    "notifications/tools/list_changed" ->
      dict.get(fields, "toolsListChanged") == Ok(jsonrpc.VBool(True))
    "notifications/prompts/list_changed" ->
      dict.get(fields, "promptsListChanged") == Ok(jsonrpc.VBool(True))
    "notifications/resources/list_changed" ->
      dict.get(fields, "resourcesListChanged") == Ok(jsonrpc.VBool(True))
    "notifications/resources/updated" ->
      case
        dict.get(fields, "resourceSubscriptions"),
        json.parse(payload, decode.at(["params", "uri"], decode.string))
      {
        Ok(jsonrpc.VArray(uris)), Ok(uri) ->
          list.contains(uris, jsonrpc.VString(uri))
        _, _ -> False
      }
    "notifications/tasks" ->
      case
        dict.get(fields, "taskIds"),
        json.parse(payload, decode.at(["params", "taskId"], decode.string))
      {
        Ok(jsonrpc.VArray(ids)), Ok(id) ->
          list.contains(ids, jsonrpc.VString(id))
        _, _ -> False
      }
    _ -> False
  }
  case allowed {
    True -> Ok(Nil)
    False ->
      Error(
        "Server sent a notification outside the acknowledged subscription filter",
      )
  }
}
