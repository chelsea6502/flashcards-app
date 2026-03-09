// ============================================================
// services/tts.gleam — Text-to-Speech Client
// ============================================================
//
// This module is an HTTP client for the Python TTS microservice
// (tts_server/server.py). It sends Chinese text and receives
// base64-encoded audio data.
//
// The TTS service is OPTIONAL — if it's down or returns an error,
// the generate handler will still produce a card, just without audio.

import gleam/dynamic/decode
// For safely parsing the JSON response from the TTS server.

import gleam/http
// Provides `http.Post` for specifying the HTTP method.

import gleam/http/request
// For building HTTP request records.

import gleam/httpc
// Gleam's HTTP client — sends the request synchronously.

import gleam/json
// For building the JSON request body.

import gleam/result
// Helper functions for working with `Result` values.

// ----------------------------------------------------------
// PUBLIC API
// ----------------------------------------------------------
// Send text to the TTS server and get back base64-encoded audio.
//
// Parameters:
//   - `tts_url`: Base URL of the TTS server (e.g., "http://localhost:8766")
//   - `text`: Chinese text to synthesize
//
// Returns:
//   - `Ok(base64_string)` — the audio data encoded as base64
//   - `Error(message)` — a human-readable error description
pub fn synthesize(tts_url: String, text: String) -> Result(String, String) {
  // If no TTS URL is configured, skip silently with a warning message.
  case tts_url {
    "" -> Error("TTS not configured (no TTS_URL set)")
    _ -> do_synthesize(tts_url, text)
  }
}

// ----------------------------------------------------------
// INTERNAL: Perform the actual HTTP request
// ----------------------------------------------------------
fn do_synthesize(tts_url: String, text: String) -> Result(String, String) {
  // Build the JSON request body: { "text": "..." }
  let body =
    json.object([#("text", json.string(text))])
    |> json.to_string

  // Parse the URL and build the request.
  // The TTS endpoint is at POST /tts on the TTS server.
  let req_result =
    request.to(tts_url <> "/tts")
    |> result.map_error(fn(_) { "Invalid TTS URL: " <> tts_url })

  case req_result {
    Error(err) -> Error(err)
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_body(body)
        |> request.prepend_header("content-type", "application/json")

      // Send the request. The TTS server may take a few seconds to synthesize.
      case httpc.send(req) {
        Ok(resp) ->
          case resp.status {
            200 -> parse_tts_response(resp.body)
            status ->
              Error(
                "TTS server returned status "
                <> json.to_string(json.int(status))
                <> ": "
                <> resp.body,
              )
          }
        Error(_) ->
          Error(
            "Failed to connect to TTS server at " <> tts_url,
          )
      }
    }
  }
}

// ----------------------------------------------------------
// PARSE TTS RESPONSE
// ----------------------------------------------------------
// The TTS server returns: { "audio_base64": "..." }
// We extract the audio_base64 field.
fn parse_tts_response(body: String) -> Result(String, String) {
  let decoder = {
    use audio <- decode.field("audio_base64", decode.string)
    decode.success(audio)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(_) { "Failed to parse TTS response" })
}
