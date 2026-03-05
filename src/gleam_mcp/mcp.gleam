import gleam/dict.{type Dict}
import gleam/option.{type Option}
import gleam_mcp/jsonrpc.{type RequestId, type Value}

pub const method_initialize = "initialize"

pub const method_initialized = "notifications/initialized"

pub const method_ping = "ping"

pub const method_list_prompts = "prompts/list"

pub const method_get_prompt = "prompts/get"

pub const method_list_resources = "resources/list"

pub const method_list_resource_templates = "resources/templates/list"

pub const method_notify_resource_list_changed = "notifications/resources/list_changed"

pub const method_read_resource = "resources/read"

pub const method_notify_resource_updated = "notifications/resources/updated"

pub const method_subscribe_resource = "resources/subscribe"

pub const method_unsubscribe_resource = "resources/unsubscribe"

pub const method_list_tools = "tools/list"

pub const method_notify_tools_list_changed = "notifications/tools/list_changed"

pub const method_call_tool = "tools/call"

pub const method_complete = "completion/complete"

pub const method_create_message = "sampling/createMessage"

pub const method_list_roots = "roots/list"

pub const method_notify_roots_list_changed = "notifications/roots/list_changed"

pub const method_elicit = "elicitation/create"

pub const method_notify_elicitation_complete = "notifications/elicitation/complete"

pub const method_set_logging_level = "logging/setLevel"

pub const method_notify_logging_message = "notifications/message"

pub const method_notify_prompts_list_changed = "notifications/prompts/list_changed"

pub const method_list_tasks = "tasks/list"

pub const method_get_task = "tasks/get"

pub const method_get_task_result = "tasks/result"

pub const method_cancel_task = "tasks/cancel"

pub const method_notify_task_status = "notifications/tasks/status"

pub const method_notify_cancelled = "notifications/cancelled"

pub const method_notify_progress = "notifications/progress"

pub type Message {
  Request(id: RequestId, method: String, params: Option(Dict(String, Value)))
  Notification(method: String, params: Option(Dict(String, Value)))
  Response(id: RequestId, result: MCPResult)
  ErrorResponse(id: Option(RequestId), error: String)
}

pub type MCPResult {
  ResultWithMeta(result: Dict(String, Value), meta: Dict(String, Value))
  Result(result: Dict(String, Value))
}

pub type Error {
  Error(code: Int, message: String, data: Option(Dict(String, Value)))
}
