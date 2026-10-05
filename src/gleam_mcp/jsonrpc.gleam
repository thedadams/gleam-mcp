import gleam/option.{type Option, None}

pub const jsonrpc_version = "2.0"

pub const legacy_protocol_version = "2025-11-25"

pub const latest_protocol_version = "2026-07-28"

pub const supported_protocol_versions = [
  latest_protocol_version,
  legacy_protocol_version,
]

pub const header_mismatch_error_code = -32_020

pub const unsupported_protocol_version_error_code = -32_022

pub const missing_required_client_capability_error_code = -32_021

pub const user_rejected_error_code = -1

pub const invalid_params_error_code = -32_602

pub const method_not_found_error_code = -32_601

pub type Value {
  VNull
  VString(String)
  VInt(Int)
  VFloat(Float)
  VBool(Bool)
  VArray(List(Value))
  VObject(List(#(String, Value)))
}

pub type RequestId {
  IntId(Int)
  StringId(String)
}

pub type RpcError {
  RpcError(code: Int, message: String, data: Option(Value))
}

pub type Request(params) {
  Request(id: RequestId, method: String, params: Option(params))
  Notification(method: String, params: Option(params))
}

pub type Response(result) {
  ResultResponse(id: RequestId, result: result)
  ErrorResponse(id: Option(RequestId), error: RpcError)
}

pub fn request_id_to_value(id: RequestId) -> Value {
  case id {
    IntId(value) -> VInt(value)
    StringId(value) -> VString(value)
  }
}

pub fn user_rejected_error() -> RpcError {
  RpcError(
    code: user_rejected_error_code,
    message: "User rejected sampling request",
    data: None,
  )
}

pub fn invalid_params_error(message: String) -> RpcError {
  RpcError(code: invalid_params_error_code, message: message, data: None)
}

pub fn method_not_found_error(message: String) -> RpcError {
  RpcError(code: method_not_found_error_code, message: message, data: None)
}
