import gleam_mcp/jsonrpc
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn request_id_to_value_test() {
  jsonrpc.request_id_to_value(jsonrpc.IntId(42))
  |> should.equal(jsonrpc.VInt(42))

  jsonrpc.request_id_to_value(jsonrpc.StringId("abc"))
  |> should.equal(jsonrpc.VString("abc"))
}

pub fn user_rejected_error_test() {
  let jsonrpc.RpcError(code, message, data) = jsonrpc.user_rejected_error()
  should.equal(code, jsonrpc.user_rejected_error_code)
  should.equal(message, "User rejected sampling request")
  data |> should.be_none
}

pub fn invalid_params_error_test() {
  let jsonrpc.RpcError(code, message, data) =
    jsonrpc.invalid_params_error("Bad input")
  should.equal(code, jsonrpc.invalid_params_error_code)
  should.equal(message, "Bad input")
  data |> should.be_none
}

pub fn method_not_found_error_test() {
  let jsonrpc.RpcError(code, message, data) =
    jsonrpc.method_not_found_error("missing/method")
  should.equal(code, jsonrpc.method_not_found_error_code)
  should.equal(message, "missing/method")
  data |> should.be_none
}
