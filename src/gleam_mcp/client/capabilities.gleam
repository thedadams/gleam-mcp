import gleam/option.{type Option, None, Some}
import gleam_mcp/actions.{
  type ClientCapabilities, ClientCapabilities, ClientElicitationCapabilities,
  ClientRootsCapabilities, ClientSamplingCapabilities,
}
import gleam_mcp/jsonrpc.{type RpcError, type Value, VObject}

pub type Root {
  Root(uri: String, name: Option(String), meta: Option(Value))
}

pub type Config {
  Config(
    list_roots: Option(fn() -> Result(List(Root), RpcError)),
    notify_roots_list_changed: Option(fn() -> Result(Nil, RpcError)),
    create_message: Option(fn(Value) -> Result(Value, RpcError)),
    sampling_tools: Option(fn(Value) -> Result(Nil, RpcError)),
    sampling_context: Option(fn(Value) -> Result(Nil, RpcError)),
    elicit_form: Option(fn(Value) -> Result(Value, RpcError)),
    elicit_url: Option(fn(Value) -> Result(Value, RpcError)),
  )
}

pub fn none() -> Config {
  Config(None, None, None, None, None, None, None)
}

pub fn to_initialize_capabilities(config: Config) -> ClientCapabilities {
  let Config(
    list_roots: list_roots,
    notify_roots_list_changed: notify_roots_list_changed,
    create_message: _create_message,
    sampling_tools: sampling_tools,
    sampling_context: sampling_context,
    elicit_form: elicit_form,
    elicit_url: elicit_url,
  ) = config

  let roots = case list_roots {
    None -> None
    Some(_) ->
      Some(
        ClientRootsCapabilities(
          list_changed: Some(has(notify_roots_list_changed)),
        ),
      )
  }

  let sampling = case sampling_tools, sampling_context {
    None, None -> None
    _, _ ->
      Some(
        ClientSamplingCapabilities(
          context: case sampling_context {
            Some(_) -> Some(VObject([]))
            None -> None
          },
          tools: case sampling_tools {
            Some(_) -> Some(VObject([]))
            None -> None
          },
        ),
      )
  }

  let elicitation = case elicit_form, elicit_url {
    None, None -> None
    _, _ ->
      Some(
        ClientElicitationCapabilities(
          form: case elicit_form {
            Some(_) -> Some(VObject([]))
            None -> None
          },
          url: case elicit_url {
            Some(_) -> Some(VObject([]))
            None -> None
          },
        ),
      )
  }

  ClientCapabilities(
    experimental: None,
    roots: roots,
    sampling: sampling,
    elicitation: elicitation,
    tasks: None,
  )
}

fn has(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}
