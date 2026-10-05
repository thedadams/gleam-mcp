//// Bounded byte fetching for the Everything gzip tool.

import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import gleam_mcp/client/http_stream_driver as driver

pub type Limits {
  Limits(max_bytes: Int, timeout_ms: Int, allowed_domains: List(String))
}

pub fn limits_from_environment() -> Limits {
  Limits(
    environment_int("GZIP_MAX_FETCH_SIZE", 10 * 1024 * 1024),
    environment_int("GZIP_MAX_FETCH_TIME_MILLIS", 30_000),
    envoy.get("GZIP_ALLOWED_DOMAINS")
      |> result.unwrap("")
      |> string.split(",")
      |> list.map(fn(value) { string.lowercase(string.trim(value)) })
      |> list.filter(fn(value) { value != "" }),
  )
}

fn environment_int(name: String, fallback: Int) -> Int {
  case envoy.get(name) |> result.try(int.parse) {
    Ok(value) if value > 0 -> value
    _ -> fallback
  }
}

pub fn get(url: String, limits: Limits) -> Result(BitArray, String) {
  use parsed <- result.try(validate_url(url, limits))
  case parsed.scheme {
    Some("data") -> {
      let data =
        parsed.path
        <> case parsed.query {
          None -> ""
          Some(query) -> "?" <> query
        }
      data_uri(data, limits.max_bytes)
    }
    _ -> http_get(url, limits, now_ms() + limits.timeout_ms, 20)
  }
}

pub fn validate_url(url: String, limits: Limits) -> Result(uri.Uri, String) {
  use parsed <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "Invalid data URL" }),
  )
  let parsed =
    uri.Uri(..parsed, scheme: option.map(parsed.scheme, string.lowercase))
  case parsed.scheme, parsed.host {
    Some("data"), _ -> Ok(parsed)
    Some("http"), Some(host) | Some("https"), Some(host) if host != "" -> {
      let host = string.lowercase(host)
      case
        limits.allowed_domains == []
        || list.any(limits.allowed_domains, fn(domain) {
          host == domain || string.ends_with(host, "." <> domain)
        })
      {
        True -> Ok(parsed)
        False ->
          Error("Domain " <> host <> " is not in the allowed domains list.")
      }
    }
    _, _ -> Error("Only http, https, and data URLs are supported.")
  }
}

fn data_uri(path: String, maximum: Int) -> Result(BitArray, String) {
  use #(metadata, data) <- result.try(
    string.split_once(path, ",")
    |> result.map_error(fn(_) { "Invalid data URL" }),
  )
  let decoded = percent_decode_bytes(<<data:utf8>>, <<>>)
  let decoded = case string.ends_with(string.lowercase(metadata), ";base64") {
    True ->
      decoded
      |> bit_array.to_string
      |> result.map_error(fn(_) { "Invalid data URL base64" })
      |> result.try(fn(decoded) {
        decoded
        |> string.replace(" ", "")
        |> string.replace("\t", "")
        |> string.replace("\r", "")
        |> string.replace("\n", "")
        |> bit_array.base64_decode
        |> result.map_error(fn(_) { "Invalid data URL base64" })
      })
    False -> Ok(decoded)
  }
  use decoded <- result.try(decoded)
  case bit_array.byte_size(decoded) > maximum {
    True -> Error("Response exceeds " <> int.to_string(maximum) <> " bytes")
    False -> Ok(decoded)
  }
}

// Data URL percent escapes represent bytes, including bytes outside UTF-8.
// Malformed escapes remain literal, as in the Fetch data URL processor.
fn percent_decode_bytes(input: BitArray, output: BitArray) -> BitArray {
  case input {
    <<37, first, second, rest:bits>> if first != 43 && first != 45 ->
      case
        bit_array.to_string(<<first, second>>)
        |> result.try(int.base_parse(_, 16))
      {
        Ok(byte) -> percent_decode_bytes(rest, <<output:bits, byte>>)
        Error(_) ->
          percent_decode_bytes(<<first, second, rest:bits>>, <<output:bits, 37>>)
      }
    <<byte, rest:bits>> -> percent_decode_bytes(rest, <<output:bits, byte>>)
    <<>> -> output
    _ -> output
  }
}

fn http_get(
  url: String,
  limits: Limits,
  deadline: Int,
  redirects: Int,
) -> Result(BitArray, String) {
  use _ <- result.try(validate_url(url, limits))
  let remaining = deadline - now_ms()
  case remaining <= 0 || redirects < 0 {
    True -> Error("Fetch deadline or redirect limit exceeded")
    False -> {
      let events = process.new_subject()
      let handle =
        driver.start(
          http.Get,
          url,
          [#("accept-encoding", "identity")],
          "",
          remaining,
          events,
          fn(event) { event },
        )
      let outcome =
        receive_body(events, limits.max_bytes, deadline, None, [], 0)
      driver.stop(handle)
      case outcome {
        Ok(Body(bits)) -> Ok(bits)
        Ok(Redirect(location)) -> {
          use base <- result.try(
            uri.parse(url)
            |> result.map_error(fn(_) { "Invalid redirect base" }),
          )
          use relative <- result.try(
            uri.parse(location)
            |> result.map_error(fn(_) { "Invalid redirect URL" }),
          )
          use next <- result.try(
            uri.merge(base, relative)
            |> result.map_error(fn(_) { "Invalid redirect URL" }),
          )
          http_get(uri.to_string(next), limits, deadline, redirects - 1)
        }
        Error(error) -> Error(error)
      }
    }
  }
}

type Fetched {
  Body(BitArray)
  Redirect(String)
}

fn receive_body(
  events: process.Subject(driver.Event),
  maximum: Int,
  deadline: Int,
  status: Option(Int),
  chunks: List(BitArray),
  size: Int,
) -> Result(Fetched, String) {
  case process.receive(events, int.max(deadline - now_ms(), 0)) {
    Error(_) -> Error("Fetch timed out")
    Ok(driver.Failed(error)) -> Error(error)
    Ok(driver.Started(status, headers)) -> {
      case
        status == 301
        || status == 302
        || status == 303
        || status == 307
        || status == 308
      {
        True -> header(headers, "location") |> result.map(Redirect)
        False -> {
          let oversized = case
            header(headers, "content-length")
            |> result.try(fn(value) {
              int.parse(value)
              |> result.map_error(fn(_) { "Invalid Content-Length" })
            })
          {
            Ok(length) -> length > maximum
            _ -> False
          }
          case oversized || status == 204 || status == 304 {
            True ->
              Error(
                "Missing response body or Content-Length exceeds fetch limit",
              )
            False ->
              receive_body(
                events,
                maximum,
                deadline,
                Some(status),
                chunks,
                size,
              )
          }
        }
      }
    }
    Ok(driver.Chunk(chunk)) -> {
      let size = size + bit_array.byte_size(chunk)
      case size > maximum {
        True -> Error("Response exceeds " <> int.to_string(maximum) <> " bytes")
        False ->
          receive_body(
            events,
            maximum,
            deadline,
            status,
            [chunk, ..chunks],
            size,
          )
      }
    }
    Ok(driver.Ended) ->
      case status {
        None -> Error("No HTTP response body")
        Some(_) -> Ok(Body(bit_array.concat(list.reverse(chunks))))
      }
  }
}

fn header(headers: List(http.Header), name: String) -> Result(String, String) {
  headers
  |> list.find(fn(header) { string.lowercase(header.0) == name })
  |> result.map(fn(header) { header.1 })
  |> result.map_error(fn(_) { "Missing " <> name <> " header" })
}

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}
