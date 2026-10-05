import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/examples/everything/resources
import gleam_mcp/jsonrpc
import gleam_mcp/server

pub fn register_prompts(app: server.Server) -> server.Server {
  app
  |> register(
    "simple-prompt",
    "Simple Prompt",
    "A prompt with no arguments",
    [],
    simple_prompt,
  )
  |> register(
    "args-prompt",
    "Arguments Prompt",
    "A prompt with two arguments, one required and one optional",
    [
      argument("city", "Name of the city", True),
      actions.PromptArgument("state", None, None, Some(False)),
    ],
    args_prompt,
  )
  |> register(
    "resource-prompt",
    "Resource Prompt",
    "A prompt that includes an embedded resource reference",
    [
      argument("resourceType", "Type of resource to fetch", True),
      argument("resourceId", "ID of the text resource to fetch", True),
    ],
    resource_prompt,
  )
  |> register(
    "completable-prompt",
    "Team Management",
    "First argument choice narrows values for second argument.",
    [
      argument("department", "Choose the department.", True),
      argument(
        "name",
        "Choose a team member to lead the selected department.",
        True,
      ),
    ],
    completable_prompt,
  )
}

fn register(
  app: server.Server,
  name: String,
  title: String,
  description: String,
  arguments: List(actions.PromptArgument),
  handler: server.PromptHandler,
) -> server.Server {
  server.register_prompt_descriptor(
    app,
    actions.Prompt(name, Some(title), Some(description), arguments, [], None),
    handler,
  )
}

fn argument(
  name: String,
  description: String,
  required: Bool,
) -> actions.PromptArgument {
  actions.PromptArgument(name, None, Some(description), Some(required))
}

pub fn completion_handler(
  params: actions.CompleteRequestParams,
) -> Result(actions.CompleteResult, jsonrpc.RpcError) {
  let actions.CompleteRequestParams(reference, argument, context, _) = params
  let actions.CompleteArgument(name, value) = argument
  let values = case reference, name {
    actions.PromptRef("completable-prompt", _), "department" ->
      filter_matches(["Engineering", "Sales", "Marketing", "Support"], value)
    actions.PromptRef("completable-prompt", _), "name" ->
      filter_matches(team_members(context), value)
    actions.PromptRef("resource-prompt", _), "resourceType" ->
      filter_matches(["Text", "Blob"], value)
    actions.PromptRef("resource-prompt", _), "resourceId" ->
      complete_resource_id(value)
    actions.ResourceTemplateRef(uri), "resourceId"
      if uri == resources.dynamic_text_template
      || uri == resources.dynamic_blob_template
    -> complete_resource_id(value)
    _, _ -> []
  }
  Ok(actions.CompleteResult(
    actions.CompletionValues(values, Some(list.length(values)), Some(False)),
    None,
  ))
}

fn complete_resource_id(value: String) -> List(String) {
  case resources.positive_resource_id(value) {
    Ok(_) -> [value]
    Error(_) -> []
  }
}

fn simple_prompt(
  _arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  Ok(
    prompt_result([text_message("This is a simple prompt without arguments.")]),
  )
}

fn args_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case required_argument(arguments, "city") {
    Error(error) -> Error(error)
    Ok(city) -> {
      let location = case optional_argument(arguments, "state") {
        Some(state) if state != "" -> city <> ", " <> state
        _ -> city
      }
      Ok(prompt_result([text_message("What's weather in " <> location <> "?")]))
    }
  }
}

fn resource_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case
    required_argument(arguments, "resourceType"),
    required_argument(arguments, "resourceId")
  {
    Error(error), _ | _, Error(error) -> Error(error)
    Ok(kind), Ok(value) -> {
      case
        kind == "Text" || kind == "Blob",
        resources.positive_resource_id(value)
      {
        False, _ ->
          Error(jsonrpc.invalid_params_error(
            "Invalid resourceType: " <> kind <> ". Must be Text or Blob.",
          ))
        _, Error(_) ->
          Error(jsonrpc.invalid_params_error(
            "Invalid resourceId: "
            <> value
            <> ". Must be a finite positive integer.",
          ))
        True, Ok(id) -> {
          let content = case kind {
            "Text" -> resources.text_resource_contents(id)
            _ -> resources.blob_resource_contents(id)
          }
          Ok(
            prompt_result([
              text_message(
                "This prompt includes the "
                <> kind
                <> " resource with id: "
                <> int.to_string(id)
                <> ". Please analyze the following resource:",
              ),
              actions.PromptMessage(
                actions.User,
                actions.EmbeddedResourceBlock(actions.EmbeddedResource(
                  content,
                  None,
                  None,
                )),
              ),
            ]),
          )
        }
      }
    }
  }
}

fn completable_prompt(
  arguments: Option(dict.Dict(String, String)),
) -> Result(actions.GetPromptResult, jsonrpc.RpcError) {
  case
    required_argument(arguments, "department"),
    required_argument(arguments, "name")
  {
    Ok(department), Ok(name) ->
      Ok(
        prompt_result([
          text_message(
            "Please promote "
            <> name
            <> " to the head of the "
            <> department
            <> " team.",
          ),
        ]),
      )
    Error(error), _ | _, Error(error) -> Error(error)
  }
}

fn required_argument(
  arguments: Option(dict.Dict(String, String)),
  name: String,
) -> Result(String, jsonrpc.RpcError) {
  optional_argument(arguments, name)
  |> option.to_result(jsonrpc.invalid_params_error(name <> " is required"))
}

fn optional_argument(
  arguments: Option(dict.Dict(String, String)),
  name: String,
) -> Option(String) {
  arguments
  |> option.then(fn(arguments) {
    dict.get(arguments, name) |> option.from_result
  })
}

fn team_members(context: Option(actions.CompleteContext)) -> List(String) {
  let department =
    context
    |> option.then(fn(context) { context.arguments })
    |> optional_argument("department")
  case department {
    Some("Engineering") -> ["Alice", "Bob", "Charlie"]
    Some("Sales") -> ["David", "Eve", "Frank"]
    Some("Marketing") -> ["Grace", "Henry", "Iris"]
    Some("Support") -> ["John", "Kim", "Lee"]
    _ -> []
  }
}

fn filter_matches(values: List(String), prefix: String) -> List(String) {
  list.filter(values, fn(value) { string.starts_with(value, prefix) })
}

fn prompt_result(
  messages: List(actions.PromptMessage),
) -> actions.GetPromptResult {
  actions.GetPromptResult(None, messages, None)
}

fn text_message(text: String) -> actions.PromptMessage {
  actions.PromptMessage(
    actions.User,
    actions.TextBlock(actions.TextContent(text, None, None)),
  )
}
