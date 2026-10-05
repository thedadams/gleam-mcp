/// Shared wire decoders. Keep nullable and missing-field behavior in one place.
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_mcp/actions
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc

pub fn decode_value(
  value: jsonrpc.Value,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  value
  |> codec_value.to_dynamic
  |> decode.run(decoder)
  |> result.map_error(fn(errors) {
    json_error_message(json.UnableToDecode(errors))
  })
}

pub fn request_meta_decoder() -> decode.Decoder(actions.RequestMeta) {
  {
    use fields <- decode.then(value_dict_decoder())
    use progress_token <- decode.optional_field(
      "progressToken",
      None,
      decode.map(request_id_decoder(), Some),
    )
    let fields = dict.delete(fields, "progressToken")
    let extra = case dict.size(fields) {
      0 -> None
      _ -> Some(actions.Meta(fields))
    }
    decode.success(actions.RequestMeta(progress_token, extra))
  }
}

pub fn request_meta_only_decoder() -> decode.Decoder(
  Option(actions.RequestMeta),
) {
  use meta <- decode.optional_field(
    "_meta",
    None,
    decode.map(request_meta_decoder(), Some),
  )
  decode.success(meta)
}

pub fn notification_meta_only_decoder() -> decode.Decoder(
  Option(actions.NotificationMeta),
) {
  {
    use meta <- decode.optional_field(
      "_meta",
      None,
      decode.optional(notification_meta_decoder()),
    )
    decode.success(meta)
  }
}

pub fn notification_meta_decoder() -> decode.Decoder(actions.NotificationMeta) {
  decode.map(value_dict_decoder(), fn(fields) {
    let extra = case dict.size(fields) {
      0 -> None
      _ -> Some(actions.Meta(fields))
    }
    actions.NotificationMeta(extra)
  })
}

pub fn task_metadata_decoder() -> decode.Decoder(actions.TaskMetadata) {
  {
    use ttl_ms <- decode.optional_field(
      "ttl",
      None,
      decode.optional(decode.int),
    )
    decode.success(actions.TaskMetadata(ttl_ms))
  }
}

pub fn task_id_params_decoder() -> decode.Decoder(actions.TaskIdParams) {
  {
    use task_id <- decode.field("taskId", decode.string)
    use meta <- decode.then(request_meta_only_decoder())
    decode.success(case meta {
      None -> actions.TaskIdParams(task_id)
      Some(_) -> actions.TaskIdParamsWithMeta(task_id, meta)
    })
  }
}

pub fn implementation_decoder() -> decode.Decoder(actions.Implementation) {
  {
    use name <- decode.field("name", decode.string)
    use version <- decode.field("version", decode.string)
    use title <- decode.optional_field(
      "title",
      None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      None,
      decode.optional(decode.string),
    )
    use website_url <- decode.optional_field(
      "websiteUrl",
      None,
      decode.optional(decode.string),
    )
    use icons <- decode.optional_field(
      "icons",
      [],
      decode.list(of: icon_decoder()),
    )
    decode.success(actions.Implementation(
      name: name,
      version: version,
      title: title,
      description: description,
      website_url: website_url,
      icons: icons,
    ))
  }
}

pub fn icon_decoder() -> decode.Decoder(actions.Icon) {
  {
    use src <- decode.field("src", decode.string)
    use mime_type <- decode.optional_field(
      "mimeType",
      None,
      decode.optional(decode.string),
    )
    use sizes <- decode.optional_field(
      "sizes",
      [],
      decode.list(of: decode.string),
    )
    use theme <- decode.optional_field(
      "theme",
      None,
      decode.optional(icon_theme_decoder()),
    )
    decode.success(actions.Icon(src, mime_type, sizes, theme))
  }
}

pub fn icon_theme_decoder() -> decode.Decoder(actions.IconTheme) {
  decode.then(decode.string, fn(value) {
    case value {
      "light" -> decode.success(actions.LightTheme)
      "dark" -> decode.success(actions.DarkTheme)
      _ -> decode.failure(actions.LightTheme, expected: "IconTheme")
    }
  })
}

pub fn logging_level_decoder() -> decode.Decoder(actions.LoggingLevel) {
  decode.then(decode.string, fn(value) {
    case value {
      "debug" -> decode.success(actions.Debug)
      "info" -> decode.success(actions.Info)
      "notice" -> decode.success(actions.Notice)
      "warning" -> decode.success(actions.Warning)
      "error" -> decode.success(actions.Error)
      "critical" -> decode.success(actions.Critical)
      "alert" -> decode.success(actions.Alert)
      "emergency" -> decode.success(actions.Emergency)
      _ -> decode.failure(actions.Info, expected: "LoggingLevel")
    }
  })
}

pub fn value_dict_decoder() -> decode.Decoder(dict.Dict(String, jsonrpc.Value)) {
  decode.dict(decode.string, value_decoder())
}

pub fn request_id_decoder() -> decode.Decoder(jsonrpc.RequestId) {
  decode.one_of(decode.map(decode.string, jsonrpc.StringId), or: [
    decode.map(decode.int, jsonrpc.IntId),
  ])
}

pub fn value_decoder() -> decode.Decoder(jsonrpc.Value) {
  use <- decode.recursive
  decode.one_of(decode.map(decode.string, jsonrpc.VString), or: [
    decode.map(decode.int, jsonrpc.VInt),
    decode.map(number_decoder(), jsonrpc.VFloat),
    decode.map(decode.bool, jsonrpc.VBool),
    decode.map(decode.list(of: value_decoder()), jsonrpc.VArray),
    decode.map(decode.dict(decode.string, value_decoder()), fn(fields) {
      jsonrpc.VObject(dict.to_list(fields))
    }),
    null_value_decoder(),
  ])
}

pub fn null_value_decoder() -> decode.Decoder(jsonrpc.Value) {
  decode.map(decode.optional(decode.dynamic), fn(_) { jsonrpc.VNull })
  |> decode.collapse_errors("Null")
}

pub fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
}

pub fn json_error_message(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of JSON input"
    json.UnexpectedByte(byte) -> "Unexpected JSON byte: " <> byte
    json.UnexpectedSequence(sequence) ->
      "Unexpected JSON sequence: " <> sequence
    json.UnableToDecode(errors) ->
      case errors {
        [] -> "Unable to decode JSON value"
        [decode.DecodeError(expected, found, path), ..] ->
          "Expected "
          <> expected
          <> ", found "
          <> found
          <> decode_path_suffix(path)
      }
  }
}

pub fn decode_path_suffix(path: List(String)) -> String {
  case path {
    [] -> ""
    _ -> " at " <> string.join(path, ".")
  }
}

pub fn error_decoder() -> decode.Decoder(jsonrpc.RpcError) {
  {
    use code <- decode.field("code", decode.int)
    use message <- decode.field("message", decode.string)
    use data <- decode.optional_field(
      "data",
      None,
      decode.optional(value_decoder()),
    )
    decode.success(jsonrpc.RpcError(code:, message:, data: data))
  }
}
