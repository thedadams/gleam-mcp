import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/jsonrpc

pub fn configuration(scenario: String) -> capabilities.Config {
  capabilities.none()
  |> capabilities.with_list_roots(fn(_) { Ok([]) })
  |> capabilities.with_create_message(fn(_) {
    Ok(
      capabilities.CreateMessage(actions.CreateMessageResult(
        actions.SamplingMessage(
          actions.Assistant,
          actions.SingleSamplingContent(
            actions.SamplingText(actions.TextContent(
              "Conformance sampling response",
              None,
              None,
            )),
          ),
          None,
        ),
        "conformance-model",
        None,
        None,
      )),
    )
  })
  |> capabilities.with_elicit_form(fn(params) {
    let content = case scenario {
      "sep-2322-client-request-state" ->
        dict.from_list([#("confirmed", actions.ElicitBool(True))])
      _ -> schema_defaults(params.requested_schema)
    }
    Ok(
      capabilities.Elicit(actions.ElicitResult(
        actions.ElicitAccept,
        Some(content),
        None,
      )),
    )
  })
}

fn schema_defaults(
  schema: jsonrpc.Value,
) -> dict.Dict(String, actions.ElicitValue) {
  let properties = case schema {
    jsonrpc.VObject(fields) ->
      case list.key_find(fields, "properties") {
        Ok(jsonrpc.VObject(properties)) -> properties
        _ -> []
      }
    _ -> []
  }
  properties
  |> list.filter_map(fn(property) {
    let #(name, schema) = property
    case schema {
      jsonrpc.VObject(fields) -> {
        use value <- result.try(list.key_find(fields, "default"))
        result.map(elicit_value(value), fn(value) { #(name, value) })
      }
      _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

fn elicit_value(value: jsonrpc.Value) -> Result(actions.ElicitValue, Nil) {
  case value {
    jsonrpc.VString(value) -> Ok(actions.ElicitString(value))
    jsonrpc.VInt(value) -> Ok(actions.ElicitInt(value))
    jsonrpc.VFloat(value) -> Ok(actions.ElicitFloat(value))
    jsonrpc.VBool(value) -> Ok(actions.ElicitBool(value))
    jsonrpc.VArray(values) ->
      values
      |> list.try_map(fn(value) {
        case value {
          jsonrpc.VString(value) -> Ok(value)
          _ -> Error(Nil)
        }
      })
      |> result.map(actions.ElicitStringArray)
    _ -> Error(Nil)
  }
}
