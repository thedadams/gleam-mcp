import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/resources
import gleam_mcp/jsonrpc
import gleam_mcp/server

pub fn register_prompts(app_server: server.Server) -> server.Server {
  app_server
  |> server.add_prompt(
    "simple-prompt",
    "A simple Everything prompt",
    [],
    simple_prompt,
  )
  |> server.add_prompt(
    "args-prompt",
    "A prompt with required and optional arguments",
    [
      actions.PromptArgument(
        name: "city",
        title: None,
        description: Some("City to ask about"),
        required: Some(True),
      ),
      actions.PromptArgument(
        name: "state",
        title: None,
        description: Some("Optional state or region"),
        required: Some(False),
      ),
    ],
    args_prompt,
  )
  |> server.add_prompt(
    "resource-prompt",
    "A prompt that embeds a dynamic resource",
    [
      actions.PromptArgument(
        name: "resourceType",
        title: None,
        description: Some("Text or Blob"),
        required: Some(True),
      ),
      actions.PromptArgument(
        name: "resourceId",
        title: None,
        description: Some("A positive integer resource id"),
        required: Some(True),
      ),
    ],
    resource_prompt,
  )
  |> server.add_prompt(
    "completable-prompt",
    "A prompt intended to exercise argument completions",
    [
      actions.PromptArgument(
        name: "department",
        title: None,
        description: Some("Engineering, Support, or Research"),
        required: Some(True),
      ),
      actions.PromptArgument(
        name: "name",
        title: None,
        description: Some("A suggested teammate name for the chosen department"),
        required: Some(True),
      ),
    ],
    completable_prompt,
  )
}

pub fn completion_handler(
  params: actions.CompleteRequestParams,
) -> Result(actions.CompleteResult, jsonrpc.RpcError) {
  let actions.CompleteRequestParams(ref, argument, context, _) = params
  let actions.CompleteArgument(name, value) = argument

  let values = case ref, name {
    actions.PromptRef("completable-prompt", _), "department" ->
      filter_matches(["Engineering", "Support", "Research"], value)
    actions.PromptRef("completable-prompt", _), "name" ->
      filter_matches(prompt_name_suggestions(context), value)
    actions.PromptRef("resource-prompt", _), "resourceType" ->
      filter_matches(["Text", "Blob"], value)
    actions.PromptRef("resource-prompt", _), "resourceId" ->
      filter_matches(["1", "2", "3", "4"], value)
    actions.ResourceTemplateRef(uri), _
      if uri == resources.dynamic_text_template
    -> filter_matches(["1", "2", "3", "4"], value)
    actions.ResourceTemplateRef(uri), _
      if uri == resources.dynamic_blob_template
    -> filter_matches(["1", "2", "3", "4"], value)
    _, _ -> []
  }

  Ok(actions.CompleteResult(
    completion: actions.CompletionValues(
      values,
      Some(list.length(values)),
      Some(False),
    ),
    meta: None,
  ))
}

fn simple_prompt(
  _arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  Ok(actions.GetPromptResult(
    description: Some("A basic prompt from the Gleam Everything server"),
    messages: [
      actions.PromptMessage(
        actions.User,
        actions.TextBlock(actions.TextContent(
          "Please describe what the Gleam Everything server demonstrates.",
          None,
          None,
        )),
      ),
    ],
    meta: None,
  ))
}

fn args_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case require_prompt_argument(arguments, "city") {
    Ok(city) -> {
      let location = case optional_prompt_argument(arguments, "state") {
        Some(state) -> city <> ", " <> state
        None -> city
      }

      Ok(actions.GetPromptResult(
        description: Some("A prompt assembled from supplied arguments"),
        messages: [
          actions.PromptMessage(
            actions.User,
            actions.TextBlock(actions.TextContent(
              "What should a visitor know about the tech scene in "
                <> location
                <> "?",
              None,
              None,
            )),
          ),
        ],
        meta: None,
      ))
    }
    Error(error) -> Error(error)
  }
}

fn resource_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case resource_choice(arguments) {
    Ok(#("Text", id)) ->
      Ok(actions.GetPromptResult(
        description: Some("A prompt that includes an embedded text resource"),
        messages: [
          actions.PromptMessage(
            actions.User,
            actions.TextBlock(actions.TextContent(
              "Review the embedded text resource and summarize its contents.",
              None,
              None,
            )),
          ),
          actions.PromptMessage(
            actions.Assistant,
            actions.EmbeddedResourceBlock(actions.EmbeddedResource(
              resources.text_resource_contents(id),
              None,
              None,
            )),
          ),
        ],
        meta: None,
      ))
    Ok(#("Blob", id)) ->
      Ok(actions.GetPromptResult(
        description: Some("A prompt that includes an embedded blob resource"),
        messages: [
          actions.PromptMessage(
            actions.User,
            actions.TextBlock(actions.TextContent(
              "Inspect the embedded blob resource metadata and describe what it represents.",
              None,
              None,
            )),
          ),
          actions.PromptMessage(
            actions.Assistant,
            actions.EmbeddedResourceBlock(actions.EmbeddedResource(
              resources.blob_resource_contents(id),
              None,
              None,
            )),
          ),
        ],
        meta: None,
      ))
    Ok(#(_, _)) ->
      Error(jsonrpc.invalid_params_error("resourceType must be Text or Blob"))
    Error(error) -> Error(error)
  }
}

fn completable_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case
    require_prompt_argument(arguments, "department"),
    require_prompt_argument(arguments, "name")
  {
    Ok(department), Ok(name) ->
      Ok(actions.GetPromptResult(
        description: Some(
          "A prompt that pairs a department with a suggested name",
        ),
        messages: [
          actions.PromptMessage(
            actions.User,
            actions.TextBlock(actions.TextContent(
              name
                <> " from "
                <> department
                <> " needs a concise onboarding note.",
              None,
              None,
            )),
          ),
        ],
        meta: None,
      ))
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}

fn require_prompt_argument(
  arguments: Option(dict.Dict(String, String)),
  key: String,
) -> Result(String, jsonrpc.RpcError) {
  case optional_prompt_argument(arguments, key) {
    Some(value) -> Ok(value)
    None -> Error(jsonrpc.invalid_params_error(key <> " is required"))
  }
}

fn optional_prompt_argument(
  arguments: Option(dict.Dict(String, String)),
  key: String,
) -> Option(String) {
  case arguments {
    Some(values) ->
      case dict.get(values, key) {
        Ok(value) -> Some(value)
        Error(Nil) -> None
      }
    None -> None
  }
}

fn resource_choice(
  arguments: Option(dict.Dict(String, String)),
) -> Result(#(String, Int), jsonrpc.RpcError) {
  case
    require_prompt_argument(arguments, "resourceType"),
    require_prompt_argument(arguments, "resourceId")
  {
    Ok(resource_type), Ok(id_text) ->
      case string.uppercase(resource_type), int.parse(id_text) {
        "TEXT", Ok(id) if id > 0 -> Ok(#("Text", id))
        "BLOB", Ok(id) if id > 0 -> Ok(#("Blob", id))
        _, Ok(_) ->
          Error(jsonrpc.invalid_params_error(
            "resourceId must be a positive integer",
          ))
        _, Error(_) ->
          Error(jsonrpc.invalid_params_error(
            "resourceId must be a positive integer",
          ))
      }
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}

fn prompt_name_suggestions(
  context: Option(actions.CompleteContext),
) -> List(String) {
  case context {
    Some(actions.CompleteContext(arguments: Some(arguments))) ->
      case dict.get(arguments, "department") {
        Ok("Engineering") -> ["Ada", "Linus", "Grace"]
        Ok("Support") -> ["Jordan", "Casey", "Mina"]
        Ok("Research") -> ["Noor", "Iris", "Theo"]
        _ -> ["Ada", "Jordan", "Noor"]
      }
    _ -> ["Ada", "Jordan", "Noor"]
  }
}

fn filter_matches(options: List(String), prefix: String) -> List(String) {
  let lowered_prefix = string.lowercase(prefix)
  options
  |> list.filter(fn(option) {
    string.starts_with(string.lowercase(option), lowered_prefix)
  })
}
