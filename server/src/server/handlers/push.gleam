// ============================================================
// handlers/push.gleam — Push to Anki Handler
// ============================================================
//
// This module handles the business logic for POST /api/push.
// It takes a PushRequest (deck name + CardDraft) and pushes
// the card to Anki via the AnkiConnect API.

import gleam/json
// For serializing the response to a JSON string.

import server/services/anki
// AnkiConnect integration — storeMediaFile + addNote.

import shared/codec
// Shared encoder functions for the wire format.

import shared/types.{type PushRequest, PushResponse}
// `PushRequest`: the decoded request body.
// `PushResponse`: the response type with the Anki note ID.

import wisp.{type Response}
// `Response` is wisp's HTTP response type.

// ----------------------------------------------------------
// MAIN HANDLER FUNCTION
// ----------------------------------------------------------
// Push a flashcard to Anki and return the note ID.
pub fn handle(req: PushRequest) -> Response {
  case anki.push_card(req.deck, req.card) {
    Ok(note_id) -> {
      let body =
        codec.encode_push_response(PushResponse(note_id:))
        |> json.to_string
      wisp.json_response(body, 200)
    }
    Error(err) -> {
      let body =
        codec.encode_error("Anki push failed: " <> err)
        |> json.to_string
      wisp.json_response(body, 500)
    }
  }
}
