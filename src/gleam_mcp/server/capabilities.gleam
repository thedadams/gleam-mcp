import gleam/option.{type Option, None, Some}
import gleam_mcp/actions
import gleam_mcp/jsonrpc

pub fn infer(
  has_tools has_tools: Bool,
  has_resources has_resources: Bool,
  has_prompts has_prompts: Bool,
  has_completion has_completion: Bool,
  has_logging has_logging: Bool,
) -> actions.ServerCapabilities {
  actions.ServerCapabilities(
    experimental: None,
    logging: bool_to_capability(has_logging),
    completions: bool_to_capability(has_completion),
    prompts: case has_prompts {
      True -> Some(actions.ServerPromptsCapabilities(list_changed: None))
      False -> None
    },
    resources: case has_resources {
      True ->
        Some(actions.ServerResourcesCapabilities(
          subscribe: None,
          list_changed: None,
        ))
      False -> None
    },
    tools: case has_tools {
      True -> Some(actions.ServerToolsCapabilities(list_changed: None))
      False -> None
    },
    tasks: None,
  )
}

fn bool_to_capability(enabled: Bool) -> Option(jsonrpc.Value) {
  case enabled {
    True -> Some(jsonrpc.VObject([]))
    False -> None
  }
}
