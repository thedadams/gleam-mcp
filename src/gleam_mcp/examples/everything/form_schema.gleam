/// Form fields from the official Everything server, including the enum variants.
/// Reference: modelcontextprotocol/servers at 5abed86c5317b833dd59907492d56c65981642aa.
import gleam_mcp/jsonrpc.{type Value, VArray, VFloat, VInt, VObject, VString}

pub fn requested_schema() -> Value {
  VObject([
    #("type", VString("object")),
    #(
      "properties",
      VObject([
        #(
          "name",
          VObject([
            #("title", VString("String")),
            #("type", VString("string")),
            #("description", VString("Your full, legal name")),
          ]),
        ),
        #(
          "check",
          VObject([
            #("title", VString("Boolean")),
            #("type", VString("boolean")),
            #("description", VString("Agree to the terms and conditions")),
          ]),
        ),
        #(
          "firstLine",
          VObject([
            #("title", VString("String with default")),
            #("type", VString("string")),
            #("description", VString("Favorite first line of a story")),
            #("default", VString("It was a dark and stormy night.")),
          ]),
        ),
        #(
          "email",
          VObject([
            #("title", VString("String with email format")),
            #("type", VString("string")),
            #("format", VString("email")),
            #(
              "description",
              VString(
                "Your email address (will be verified, and never shared with anyone else)",
              ),
            ),
          ]),
        ),
        #(
          "homepage",
          VObject([
            #("type", VString("string")),
            #("format", VString("uri")),
            #("title", VString("String with uri format")),
            #("description", VString("Portfolio / personal website")),
          ]),
        ),
        #(
          "birthdate",
          VObject([
            #("title", VString("String with date format")),
            #("type", VString("string")),
            #("format", VString("date")),
            #("description", VString("Your date of birth")),
          ]),
        ),
        #(
          "integer",
          VObject([
            #("title", VString("Integer")),
            #("type", VString("integer")),
            #(
              "description",
              VString(
                "Your favorite integer (do not give us your phone number, pin, or other sensitive info)",
              ),
            ),
            #("minimum", VInt(1)),
            #("maximum", VInt(100)),
            #("default", VInt(42)),
          ]),
        ),
        #(
          "number",
          VObject([
            #("title", VString("Number in range 1-1000")),
            #("type", VString("number")),
            #(
              "description",
              VString("Favorite number (there are no wrong answers)"),
            ),
            #("minimum", VInt(0)),
            #("maximum", VInt(1000)),
            #("default", VFloat(3.14)),
          ]),
        ),
        #(
          "untitledSingleSelectEnum",
          VObject([
            #("type", VString("string")),
            #("title", VString("Untitled Single Select Enum")),
            #("description", VString("Choose your favorite friend")),
            #(
              "enum",
              VArray([
                VString("Monica"),
                VString("Rachel"),
                VString("Joey"),
                VString("Chandler"),
                VString("Ross"),
                VString("Phoebe"),
              ]),
            ),
            #("default", VString("Monica")),
          ]),
        ),
        #(
          "untitledMultipleSelectEnum",
          VObject([
            #("type", VString("array")),
            #("title", VString("Untitled Multiple Select Enum")),
            #("description", VString("Choose your favorite instruments")),
            #("minItems", VInt(1)),
            #("maxItems", VInt(3)),
            #(
              "items",
              VObject([
                #("type", VString("string")),
                #(
                  "enum",
                  VArray([
                    VString("Guitar"),
                    VString("Piano"),
                    VString("Violin"),
                    VString("Drums"),
                    VString("Bass"),
                  ]),
                ),
              ]),
            ),
            #("default", VArray([VString("Guitar")])),
          ]),
        ),
        #(
          "titledSingleSelectEnum",
          VObject([
            #("type", VString("string")),
            #("title", VString("Titled Single Select Enum")),
            #("description", VString("Choose your favorite hero")),
            #(
              "oneOf",
              VArray([
                VObject([
                  #("const", VString("hero-1")),
                  #("title", VString("Superman")),
                ]),
                VObject([
                  #("const", VString("hero-2")),
                  #("title", VString("Green Lantern")),
                ]),
                VObject([
                  #("const", VString("hero-3")),
                  #("title", VString("Wonder Woman")),
                ]),
              ]),
            ),
            #("default", VString("hero-1")),
          ]),
        ),
        #(
          "titledMultipleSelectEnum",
          VObject([
            #("type", VString("array")),
            #("title", VString("Titled Multiple Select Enum")),
            #("description", VString("Choose your favorite types of fish")),
            #("minItems", VInt(1)),
            #("maxItems", VInt(3)),
            #(
              "items",
              VObject([
                #(
                  "anyOf",
                  VArray([
                    VObject([
                      #("const", VString("fish-1")),
                      #("title", VString("Tuna")),
                    ]),
                    VObject([
                      #("const", VString("fish-2")),
                      #("title", VString("Salmon")),
                    ]),
                    VObject([
                      #("const", VString("fish-3")),
                      #("title", VString("Trout")),
                    ]),
                  ]),
                ),
              ]),
            ),
            #("default", VArray([VString("fish-1")])),
          ]),
        ),
        #(
          "legacyTitledEnum",
          VObject([
            #("type", VString("string")),
            #("title", VString("Legacy Titled Single Select Enum")),
            #("description", VString("Choose your favorite type of pet")),
            #(
              "enum",
              VArray([
                VString("pet-1"),
                VString("pet-2"),
                VString("pet-3"),
                VString("pet-4"),
                VString("pet-5"),
              ]),
            ),
            #(
              "enumNames",
              VArray([
                VString("Cats"),
                VString("Dogs"),
                VString("Birds"),
                VString("Fish"),
                VString("Reptiles"),
              ]),
            ),
            #("default", VString("pet-1")),
          ]),
        ),
      ]),
    ),
    #("required", VArray([VString("name")])),
  ])
}
