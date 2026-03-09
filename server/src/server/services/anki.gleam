// ============================================================
// services/anki.gleam — AnkiConnect Integration
// ============================================================
//
// This module communicates with Anki via the AnkiConnect plugin.
// AnkiConnect exposes a JSON-RPC-like API on localhost:8765 that
// lets external programs create notes, store media files, etc.
//
// The push flow is:
//   1. Store audio file via `storeMediaFile` (if audio exists)
//   2. Store image file via `storeMediaFile` (if image exists)
//   3. Create the note via `addNote` with all 9 TSC v2 fields
//   4. Return the note ID from Anki
//
// AnkiConnect API format:
//   POST http://localhost:8765
//   { "action": "actionName", "version": 6, "params": { ... } }
//
// Response format:
//   { "result": <value>, "error": <null or string> }

import gleam/dynamic/decode
// For safely parsing AnkiConnect's JSON responses.

import gleam/http

import gleam/option
// Gleam's Option type: `option.Some(value)` or `option.None`.
// Provides `http.Post` for specifying the HTTP method.

import gleam/http/request
// For building HTTP request records.

import gleam/httpc
// Gleam's HTTP client — sends requests synchronously.

import gleam/json
// For building JSON request bodies and parsing responses.

import gleam/result
// Helper functions for working with `Result` values.

import gleam/string
// String utilities.

import shared/types.{type CardDraft}
// The CardDraft type contains all the flashcard data to push.

// ----------------------------------------------------------
// ANKI CONNECT URL
// ----------------------------------------------------------
// AnkiConnect always runs on localhost:8765.
const anki_url = "http://localhost:8765"

// ----------------------------------------------------------
// PUBLIC API
// ----------------------------------------------------------
// Push a complete flashcard to Anki.
//
// Parameters:
//   - `deck`: Name of the Anki deck (e.g., "Chinese::Sentences")
//   - `card`: The CardDraft with all field data
//
// Returns:
//   - `Ok(note_id)` — the integer ID of the created Anki note
//   - `Error(message)` — a human-readable error description
pub fn push_card(deck: String, card: CardDraft) -> Result(Int, String) {
  // Step 1: Store word audio file if we have audio data
  let word_audio_filename = case card.word_audio_base64 {
    "" -> ""
    _ -> {
      let filename = "flashcard_word_" <> card.target_word <> ".mp3"
      case store_media_file(filename, card.word_audio_base64) {
        Ok(_) -> filename
        Error(_) -> ""
      }
    }
  }

  // Step 2: Store sentence audio file if we have audio data
  let sentence_audio_filename = case card.sentence_audio_base64 {
    "" -> ""
    _ -> {
      let filename = "flashcard_sentence_" <> card.target_word <> ".mp3"
      case store_media_file(filename, card.sentence_audio_base64) {
        Ok(_) -> filename
        Error(_) -> ""
      }
    }
  }

  // Step 3: Store image file if we have image data
  let image_filename = case card.image_base64 {
    "" -> ""
    _ -> {
      let filename = "flashcard_" <> card.target_word <> ".png"
      case store_media_file(filename, card.image_base64) {
        Ok(_) -> filename
        Error(_) -> ""
      }
    }
  }

  // Step 4: Build the audio and image field values for Anki.
  // Anki uses special syntax for referencing media files:
  //   Audio: [sound:filename.mp3]
  //   Image: <img src="filename.png">
  let word_audio_field = case word_audio_filename {
    "" -> ""
    f -> "[sound:" <> f <> "]"
  }

  let sentence_audio_field = case sentence_audio_filename {
    "" -> ""
    f -> "[sound:" <> f <> "]"
  }

  let audio_field = word_audio_field <> sentence_audio_field

  let image_field = case image_filename {
    "" -> ""
    f -> "<img src=\"" <> f <> "\">"
  }

  // Step 5: Create the note with all fields.
  add_note(deck, card, audio_field, image_field)
}

// ----------------------------------------------------------
// STORE MEDIA FILE
// ----------------------------------------------------------
// Upload a base64-encoded file to Anki's media collection.
//
// AnkiConnect's `storeMediaFile` action takes:
//   - filename: the name to save the file as
//   - data: base64-encoded file contents
fn store_media_file(
  filename: String,
  data_base64: String,
) -> Result(Nil, String) {
  let body =
    json.object([
      #("action", json.string("storeMediaFile")),
      #("version", json.int(6)),
      #(
        "params",
        json.object([
          #("filename", json.string(filename)),
          #("data", json.string(data_base64)),
        ]),
      ),
    ])
    |> json.to_string

  case send_anki_request(body) {
    Ok(_) -> Ok(Nil)
    Error(err) -> Error("Failed to store media file: " <> err)
  }
}

// ----------------------------------------------------------
// ADD NOTE
// ----------------------------------------------------------
// Create a new Anki note with the TSC v2 model fields.
//
// The model name "Mandarin TSC v2" must match exactly what exists
// in the user's Anki collection.
fn add_note(
  deck: String,
  card: CardDraft,
  audio_field: String,
  image_field: String,
) -> Result(Int, String) {
  let body =
    json.object([
      #("action", json.string("addNote")),
      #("version", json.int(6)),
      #(
        "params",
        json.object([
          #(
            "note",
            json.object([
              #("deckName", json.string(deck)),
              #("modelName", json.string("Mandarin TSC v2")),
              #(
                "fields",
                json.object([
                  #("Sentence", json.string(card.sentence)),
                  #("TargetWord", json.string(card.target_word)),
                  #("TargetPinyin", json.string(card.target_pinyin)),
                  #("TargetMeaning", json.string(card.target_meaning)),
                  #("SentencePinyin", json.string(card.sentence_pinyin)),
                  #("SentenceMeaning", json.string(card.sentence_meaning)),
                  #("Audio", json.string(audio_field)),
                  #("Image", json.string(image_field)),
                  #("Notes", json.string(card.notes)),
                ]),
              ),
              #(
                "options",
                json.object([
                  #("allowDuplicate", json.bool(False)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string

  case send_anki_request(body) {
    Ok(resp_body) -> parse_add_note_response(resp_body)
    Error(err) -> Error("Failed to add note to Anki: " <> err)
  }
}

// ----------------------------------------------------------
// SEND ANKI REQUEST
// ----------------------------------------------------------
// Low-level function to send a JSON-RPC request to AnkiConnect
// and return the raw response body.
fn send_anki_request(body: String) -> Result(String, String) {
  let assert Ok(req) = request.to(anki_url)

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.prepend_header("content-type", "application/json")

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 -> {
          // Check if AnkiConnect returned an error in its response body.
          case check_anki_error(resp.body) {
            Ok(Nil) -> Ok(resp.body)
            Error(err) -> Error(err)
          }
        }
        status ->
          Error(
            "AnkiConnect returned status "
            <> string.inspect(status),
          )
      }
    Error(_) ->
      Error(
        "Failed to connect to AnkiConnect at "
        <> anki_url
        <> " — is Anki running with AnkiConnect installed?",
      )
  }
}

// ----------------------------------------------------------
// CHECK ANKI ERROR
// ----------------------------------------------------------
// AnkiConnect always returns { "result": ..., "error": ... }.
// If "error" is not null, something went wrong.
fn check_anki_error(body: String) -> Result(Nil, String) {
  let decoder = {
    use error <- decode.field("error", decode.optional(decode.string))
    decode.success(error)
  }

  case json.parse(body, decoder) {
    Ok(option) ->
      case option {
        option.Some(err) -> Error("AnkiConnect error: " <> err)
        option.None -> Ok(Nil)
      }
    Error(_) -> Ok(Nil)
  }
}

// ----------------------------------------------------------
// PARSE ADD NOTE RESPONSE
// ----------------------------------------------------------
// Extract the note ID from AnkiConnect's addNote response:
//   { "result": 1234567890, "error": null }
fn parse_add_note_response(body: String) -> Result(Int, String) {
  let decoder = {
    use note_id <- decode.field("result", decode.int)
    decode.success(note_id)
  }

  json.parse(body, decoder)
  |> result.map_error(fn(_) { "Failed to parse AnkiConnect addNote response" })
}
