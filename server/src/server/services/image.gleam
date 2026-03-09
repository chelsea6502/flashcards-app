// ============================================================
// services/image.gleam — Image Generation (DALL-E 3)
// ============================================================
//
// This module generates illustrative images for flashcards using
// OpenAI's DALL-E 3 API. The image helps create a visual memory
// association for the vocabulary word.
//
// Image generation is OPTIONAL — if it fails or the API key is
// not configured, the card is still created without an image.

import gleam/dynamic/decode
// For safely parsing the JSON response from OpenAI's API.

import gleam/http
// Provides `http.Post` for specifying the HTTP method.

import gleam/http/request
// For building HTTP request records.

import gleam/httpc
// Gleam's HTTP client — sends the request synchronously.

import gleam/json
// For building the JSON request body and parsing responses.

import gleam/result
// Helper functions for working with `Result` values.

// ----------------------------------------------------------
// PUBLIC API
// ----------------------------------------------------------
// Generate an image for a vocabulary word's definition.
//
// Parameters:
//   - `api_key`: OpenAI API key (starts with "sk-")
//   - `definition`: The English definition to illustrate
//
// Returns:
//   - `Ok(base64_string)` — the image data encoded as base64
//   - `Error(message)` — a human-readable error description
pub fn generate(
  api_key: String,
  word: String,
  definition: String,
  sentence: String,
  sentence_meaning: String,
) -> Result(String, String) {
  case api_key {
    "" -> Error("Image generation not configured (no OPENAI_API_KEY set)")
    _ -> do_generate(api_key, word, definition, sentence, sentence_meaning)
  }
}

// ----------------------------------------------------------
// INTERNAL: Perform the DALL-E API request
// ----------------------------------------------------------
fn do_generate(
  api_key: String,
  word: String,
  definition: String,
  sentence: String,
  sentence_meaning: String,
) -> Result(String, String) {
  let prompt =
    "I'm building a Chinese vocabulary flashcard app. Each card shows a Chinese word, "
    <> "an example sentence using that word, and an image to create a visual memory aid. "
    <> "Generate an image for this card. "
    <> "The sentence is: \""
    <> sentence
    <> "\" which means: \""
    <> sentence_meaning
    <> "\". The vocabulary word is \""
    <> word
    <> "\" ("
    <> definition
    <> "). "
    <> "Depict the scene described by the sentence so the image helps the learner remember the word in context. "
    <> "Simple, clean illustration style. No text or letters in the image."

  // Build the JSON request body for DALL-E 3.
  // We request:
  //   - model: dall-e-3 (highest quality)
  //   - size: 1024x1024 (square, good for flashcards)
  //   - quality: standard (faster and cheaper than "hd")
  //   - response_format: b64_json (base64-encoded image data, avoids needing
  //     to download from a URL)
  //   - n: 1 (one image)
  let body =
    json.object([
      #("model", json.string("dall-e-3")),
      #("prompt", json.string(prompt)),
      #("n", json.int(1)),
      #("size", json.string("1024x1024")),
      #("quality", json.string("standard")),
      #("response_format", json.string("b64_json")),
    ])
    |> json.to_string

  // Build the HTTP request to OpenAI's image generation endpoint.
  let assert Ok(req) =
    request.to("https://api.openai.com/v1/images/generations")

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.prepend_header("content-type", "application/json")
    |> request.prepend_header("authorization", "Bearer " <> api_key)

  // Send the request. DALL-E can take 10-20 seconds to generate an image.
  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 -> parse_dalle_response(resp.body)
        status ->
          Error(
            "DALL-E API returned status "
            <> json.to_string(json.int(status))
            <> ": "
            <> resp.body,
          )
      }
    Error(_) -> Error("Failed to connect to OpenAI API")
  }
}

// ----------------------------------------------------------
// PARSE DALL-E RESPONSE
// ----------------------------------------------------------
// OpenAI's response format:
// {
//   "data": [
//     { "b64_json": "..." }
//   ]
// }
// We extract data[0].b64_json.
fn parse_dalle_response(body: String) -> Result(String, String) {
  let decoder = {
    use b64 <- decode.field(
      "data",
      decode.at([0], {
        use img <- decode.field("b64_json", decode.string)
        decode.success(img)
      }),
    )
    decode.success(b64)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(_) { "Failed to parse DALL-E response" })
}
