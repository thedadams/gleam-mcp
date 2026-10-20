//// JSON encodings of persisted records, for stores that keep them in a
//// database. Each record is one JSON document; stores also keep the fields
//// they query on, such as ids and expiry times, in their own columns.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import gleam_mcp/actions
import gleam_mcp/client/codec as client_codec
import gleam_mcp/codec_common
import gleam_mcp/codec_decode
import gleam_mcp/jsonrpc
import gleam_mcp/persistence.{
  type SessionMetadata, type SessionRecord, type TaskRecord, SessionMetadata,
  SessionRecord, TaskRecord,
}
import gleam_mcp/server/codec as server_codec

pub fn encode_session(record: SessionRecord) -> String {
  json.object([
    #("id", json.string(record.id)),
    #("metadata", json.nullable(record.metadata, session_metadata_json)),
    #("expires_at", json.int(to_milliseconds(record.expires_at))),
    #("refreshed_at", json.int(to_milliseconds(record.refreshed_at))),
  ])
  |> json.to_string
}

pub fn decode_session(raw: String) -> Result(SessionRecord, String) {
  json.parse(raw, {
    use id <- decode.field("id", decode.string)
    use metadata <- decode.field(
      "metadata",
      decode.optional(session_metadata_decoder()),
    )
    use expires_at <- decode.field("expires_at", decode.int)
    use refreshed_at <- decode.field("refreshed_at", decode.int)
    decode.success(SessionRecord(
      id,
      metadata,
      from_milliseconds(expires_at),
      from_milliseconds(refreshed_at),
    ))
  })
  |> result.map_error(codec_decode.json_error_message)
}

fn session_metadata_json(metadata: SessionMetadata) -> json.Json {
  json.object([
    #("protocol_version", json.string(metadata.protocol_version)),
    #(
      "client_capabilities",
      client_codec.encode_client_capabilities_value(
        metadata.client_capabilities,
      )
        |> codec_common.encode_value,
    ),
    #("initialized", json.bool(metadata.initialized)),
    #("ready", json.bool(metadata.ready)),
    #("principal", json.nullable(metadata.principal, json.string)),
  ])
}

fn session_metadata_decoder() -> decode.Decoder(SessionMetadata) {
  use protocol_version <- decode.field("protocol_version", decode.string)
  use capabilities <- decode.field(
    "client_capabilities",
    server_codec.client_capabilities_decoder(),
  )
  use initialized <- decode.field("initialized", decode.bool)
  use ready <- decode.field("ready", decode.bool)
  use principal <- decode.field("principal", decode.optional(decode.string))
  decode.success(SessionMetadata(
    protocol_version,
    capabilities,
    initialized,
    ready,
    principal,
  ))
}

pub fn encode_task(record: TaskRecord) -> String {
  json.object([
    #(
      "task",
      server_codec.encode_task(record.task) |> codec_common.encode_value,
    ),
    #("scope", json.nullable(record.scope, json.string)),
    #("outcome", json.nullable(record.outcome, outcome_json)),
    #(
      "inputs",
      codec_common.encode_value(jsonrpc.VObject(dict.to_list(record.inputs))),
    ),
    #(
      "cancellation_status_message",
      json.nullable(record.cancellation_status_message, json.string),
    ),
    #(
      "cancellation_meta",
      json.nullable(record.cancellation_meta, codec_common.encode_meta),
    ),
    #(
      "expires_at",
      json.nullable(option.map(record.expires_at, to_milliseconds), json.int),
    ),
    #("owner", json.nullable(record.owner, json.string)),
    #("version", json.int(record.version)),
  ])
  |> json.to_string
}

pub fn decode_task(raw: String) -> Result(TaskRecord, String) {
  json.parse(raw, {
    use task <- decode.field("task", client_codec.task_decoder())
    use scope <- decode.field("scope", decode.optional(decode.string))
    use outcome <- decode.field("outcome", decode.optional(outcome_decoder()))
    use inputs <- decode.field("inputs", codec_decode.value_dict_decoder())
    use cancellation_status_message <- decode.field(
      "cancellation_status_message",
      decode.optional(decode.string),
    )
    use cancellation_meta <- decode.field(
      "cancellation_meta",
      decode.optional(client_codec.meta_decoder()),
    )
    use expires_at <- decode.field("expires_at", decode.optional(decode.int))
    use owner <- decode.field("owner", decode.optional(decode.string))
    use version <- decode.field("version", decode.int)
    decode.success(TaskRecord(
      task: task,
      scope: scope,
      outcome: outcome,
      inputs: inputs,
      cancellation_status_message: cancellation_status_message,
      cancellation_meta: cancellation_meta,
      expires_at: option.map(expires_at, from_milliseconds),
      owner: owner,
      version: version,
    ))
  })
  |> result.map_error(codec_decode.json_error_message)
}

fn outcome_json(
  outcome: Result(actions.TaskResult, jsonrpc.RpcError),
) -> json.Json {
  case outcome {
    Ok(result) -> {
      let #(kind, value) = case result {
        actions.TaskResultModern(value) -> #("modern", value)
        actions.TaskCallTool(value) -> #(
          "call_tool",
          server_codec.encode_call_tool_result(value),
        )
        actions.TaskCreateMessage(value) -> #(
          "create_message",
          server_codec.encode_create_message_result(value),
        )
        actions.TaskElicit(value) -> #(
          "elicit",
          server_codec.encode_elicit_result(value),
        )
      }
      json.object([
        #("kind", json.string(kind)),
        #("result", codec_common.encode_value(value)),
      ])
    }
    Error(jsonrpc.RpcError(code, message, data)) ->
      json.object([
        #("kind", json.string("error")),
        #("code", json.int(code)),
        #("message", json.string(message)),
        #("data", json.nullable(data, codec_common.encode_value)),
      ])
  }
}

fn outcome_decoder() -> decode.Decoder(
  Result(actions.TaskResult, jsonrpc.RpcError),
) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "modern" -> {
      use value <- decode.field("result", codec_decode.value_decoder())
      decode.success(Ok(actions.TaskResultModern(value)))
    }
    "call_tool" -> {
      use value <- decode.field(
        "result",
        client_codec.call_tool_result_decoder(),
      )
      decode.success(Ok(actions.TaskCallTool(value)))
    }
    "create_message" -> {
      use value <- decode.field(
        "result",
        client_codec.create_message_result_decoder(),
      )
      decode.success(Ok(actions.TaskCreateMessage(value)))
    }
    "elicit" -> {
      use value <- decode.field("result", client_codec.elicit_result_decoder())
      decode.success(Ok(actions.TaskElicit(value)))
    }
    "error" -> {
      use code <- decode.field("code", decode.int)
      use message <- decode.field("message", decode.string)
      use data <- decode.field(
        "data",
        decode.optional(codec_decode.value_decoder()),
      )
      decode.success(Error(jsonrpc.RpcError(code, message, data)))
    }
    _ -> decode.failure(Error(jsonrpc.RpcError(0, "", None)), "TaskOutcome")
  }
}

/// Unix time in milliseconds, the resolution stores keep times at.
pub fn to_milliseconds(time: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(time)
  seconds * 1000 + nanoseconds / 1_000_000
}

pub fn from_milliseconds(milliseconds: Int) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    milliseconds / 1000,
    milliseconds % 1000 * 1_000_000,
  )
}
