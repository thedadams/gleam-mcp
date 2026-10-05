import conformance/server_content
import gleam_mcp/jsonrpc.{type Value, VArray, VBool, VObject, VString}
import gleam_mcp/server

/// The official schema scenario checks that the SDK preserves this definition
/// when serializing tools/list. It does not exercise instance validation.
pub fn register(app: server.Server) -> server.Server {
  server.add_tool(
    app,
    "json_schema_2020_12_tool",
    "Conformance JSON Schema 2020-12 keyword preservation fixture",
    schema(),
    fn(_) { Ok(server_content.text_result("Schema preservation fixture")) },
  )
}

fn schema() -> Value {
  VObject([
    #("$schema", VString("https://json-schema.org/draft/2020-12/schema")),
    #("type", VString("object")),
    #(
      "$defs",
      VObject([
        #(
          "address",
          VObject([
            #("$anchor", VString("addressDef")),
            #("type", VString("object")),
            #(
              "properties",
              VObject([
                #("street", VObject([#("type", VString("string"))])),
                #("city", VObject([#("type", VString("string"))])),
              ]),
            ),
          ]),
        ),
      ]),
    ),
    #(
      "properties",
      VObject([
        #("name", VObject([#("type", VString("string"))])),
        #("address", VObject([#("$ref", VString("#/$defs/address"))])),
        #(
          "contactMethod",
          VObject([
            #("type", VString("string")),
            #("enum", VArray([VString("phone"), VString("email")])),
          ]),
        ),
        #("phone", VObject([#("type", VString("string"))])),
        #("email", VObject([#("type", VString("string"))])),
      ]),
    ),
    #(
      "allOf",
      VArray([
        VObject([
          #(
            "anyOf",
            VArray([
              VObject([#("required", VArray([VString("phone")]))]),
              VObject([#("required", VArray([VString("email")]))]),
            ]),
          ),
        ]),
      ]),
    ),
    #(
      "if",
      VObject([
        #(
          "properties",
          VObject([
            #("contactMethod", VObject([#("const", VString("phone"))])),
          ]),
        ),
        #("required", VArray([VString("contactMethod")])),
      ]),
    ),
    #("then", VObject([#("required", VArray([VString("phone")]))])),
    #("else", VObject([#("required", VArray([VString("email")]))])),
    #("additionalProperties", VBool(False)),
  ])
}
