// ============================================================
// shared/codec.gleam
//
// "Codec" is short for coder/decoder. This module contains:
//
//   Encoders — functions that turn Gleam values INTO JSON.
//              Used by whichever side needs to send data over
//              the network (or write it to a response body).
//
//   Decoders — functions that turn JSON back INTO Gleam values.
//              Used by whichever side receives raw JSON and needs
//              to validate and parse it into typed data.
//
// Keeping encoding and decoding in one place means the two sides
// of every type stay in sync: when you add a new field you update
// the encoder and decoder right next to each other.
//
// KEY GLEAM CONCEPT — Imports
// ----------------------------
// `import gleam/dynamic/decode` — the standard library module for
//   building decoders. A `Decoder(t)` is a value that knows how to
//   parse dynamic (untyped) data into a specific type `t`.
//
// `import gleam/json.{type Json}` — the standard library module
//   for building JSON values. The `{type Json}` part imports the
//   *type alias* `Json` directly into scope so we can write `Json`
//   instead of `json.Json` in type annotations.
//
// The long `import shared/types.{...}` block imports both the
// *type names* (prefixed with `type`, used in annotations) and the
// *constructor functions* (without prefix, used to build values).
// For example:
//   `type CardDraft` lets us write `card: CardDraft` in signatures.
//   `CardDraft`      lets us write `CardDraft(sentence:, ...)` to
//                    construct a value.
// ============================================================
import gleam/dynamic/decode
import gleam/json.{type Json}
import shared/types.{
  type CardDraft, type GenerateRequest, type PushRequest, type PushResponse,
  CardDraft, GenerateRequest, PushRequest, PushResponse,
}

// ============================================================
// ENCODERS
// ============================================================
//
// KEY GLEAM CONCEPT — JSON encoding with gleam_json v3
// -----------------------------------------------------
// `json.object(fields)` builds a JSON object. It takes a list of
// *2-tuples* (pairs), where each pair is `#(key, value)`:
//   #("some_key", json.string("hello"))
//
// Common encoder primitives:
//   json.string(s)           — wraps a String as a JSON string
//   json.int(n)              — wraps an Int as a JSON number
//   json.bool(b)             — wraps a Bool as a JSON boolean
//   json.array(list, mapper) — encodes a List by applying `mapper`
//                              to every element
//   json.null()              — produces JSON null
//
// Every encoder returns `Json`, which is an opaque type. To turn a
// `Json` value into an actual string you call `json.to_string(j)`.
// ============================================================

// ------------------------------------------------------------
// encode_card_draft
//
// Converts a CardDraft into a JSON object. Every field on the
// Gleam record maps 1-to-1 to a JSON key.
//
// `card.sentence` uses dot-notation to access the labeled field
// `sentence` on the `card` value.
//
// `json.array(card.warnings, json.string)` encodes the list of
// warning strings as a JSON array. The second argument to
// `json.array` is a function that encodes each element — here we
// pass `json.string` directly (no parentheses) because we are
// passing the function itself as a value, not calling it yet.
// ------------------------------------------------------------
pub fn encode_card_draft(card: CardDraft) -> Json {
  json.object([
    #("sentence", json.string(card.sentence)),
    #("target_word", json.string(card.target_word)),
    #("target_pinyin", json.string(card.target_pinyin)),
    #("target_meaning", json.string(card.target_meaning)),
    #("sentence_pinyin", json.string(card.sentence_pinyin)),
    #("sentence_meaning", json.string(card.sentence_meaning)),
    #("word_audio_base64", json.string(card.word_audio_base64)),
    #("sentence_audio_base64", json.string(card.sentence_audio_base64)),
    #("image_base64", json.string(card.image_base64)),
    #("notes", json.string(card.notes)),
    #("warnings", json.array(card.warnings, json.string)),
  ])
}

// ------------------------------------------------------------
// encode_push_response
//
// Converts a PushResponse (which just wraps a single integer
// note_id) into a JSON object with one key.
// ------------------------------------------------------------
pub fn encode_push_response(resp: PushResponse) -> Json {
  json.object([#("note_id", json.int(resp.note_id))])
}

// ------------------------------------------------------------
// encode_error
//
// A generic error encoder. Instead of encoding an AppError
// directly, we convert the error to a human-readable string
// *before* calling this function (that happens at the HTTP
// handler layer). This keeps the wire format simple:
//   { "error": "No entry found for: 你好" }
// ------------------------------------------------------------
pub fn encode_error(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

// ============================================================
// DECODERS
// ============================================================
//
// KEY GLEAM CONCEPT — Decoders and the `use` keyword
// ----------------------------------------------------
// A `Decoder(t)` is a *description* of how to parse untyped
// (dynamic) data into a specific type `t`. Decoders are values —
// you build them up with combinators and then hand them to
// `json.decode` (or similar) to actually run them.
//
// `decode.field("key", inner_decoder)` produces a Decoder that:
//   1. Expects the input to be a JSON object.
//   2. Looks up `"key"` in that object.
//   3. Runs `inner_decoder` on whatever value is found there.
//   4. Returns the decoded value if everything succeeded, or a
//      decode error if the key is missing / the value is the
//      wrong type.
//
// `decode.success(value)` produces a Decoder that always succeeds
// and returns `value` without looking at the input at all. You
// use it at the end of a pipeline once you have gathered all the
// pieces and want to assemble them into your final Gleam type.
//
// THE `use` KEYWORD — callback sugar
// ------------------------------------
// `use` is syntactic sugar for chaining callbacks. Without it,
// decoding two fields would look like:
//
//   decode.field("word", decode.string, fn(word) {
//     decode.success(GenerateRequest(word:))
//   })
//
// With `use` the same code reads:
//
//   use word <- decode.field("word", decode.string)
//   decode.success(GenerateRequest(word:))
//
// Read `use word <- decode.field(...)` as:
//   "decode a field named 'word', bind the result to `word`,
//    then continue with the rest of the block."
//
// Each `use` line extracts one field and binds it to a name.
// The final `decode.success(...)` assembles all the bound values
// into the target Gleam type.
//
// KEY GLEAM CONCEPT — Field punning (shorthand syntax)
// ------------------------------------------------------
// When a variable has the *same name* as the field you are
// setting, Gleam lets you write just `field_name:` instead of
// `field_name: field_name`. For example:
//
//   CardDraft(sentence: sentence, target_word: target_word, ...)
//
// can be shortened to:
//
//   CardDraft(sentence:, target_word:, ...)
//
// You will see this shorthand used in all the `decode.success`
// calls below.
// ============================================================

// ------------------------------------------------------------
// generate_request_decoder
//
// Returns a decoder that parses JSON like:
//   { "word": "你好" }
// into a `GenerateRequest` value.
//
// This is the simplest decoder — it only needs one field.
// ------------------------------------------------------------
pub fn generate_request_decoder() -> decode.Decoder(GenerateRequest) {
  // Extract the "word" string field from the JSON object and bind
  // it to the variable `word`.
  use word <- decode.field("word", decode.string)
  // Now that we have `word`, construct a GenerateRequest.
  // `word:` is field-punning shorthand for `word: word`.
  decode.success(GenerateRequest(word:))
}

// ------------------------------------------------------------
// card_draft_decoder
//
// Returns a decoder that parses a JSON object with ten fields
// into a `CardDraft` value.
//
// Notice how each `use` line mirrors one entry in the
// `encode_card_draft` function above — the JSON keys must match
// exactly. If a key is missing or its value is not a string (or
// list of strings), the decoder returns an error instead of
// crashing.
// ------------------------------------------------------------
pub fn card_draft_decoder() -> decode.Decoder(CardDraft) {
  use sentence <- decode.field("sentence", decode.string)
  use target_word <- decode.field("target_word", decode.string)
  use target_pinyin <- decode.field("target_pinyin", decode.string)
  use target_meaning <- decode.field("target_meaning", decode.string)
  use sentence_pinyin <- decode.field("sentence_pinyin", decode.string)
  use sentence_meaning <- decode.field("sentence_meaning", decode.string)
  use word_audio_base64 <- decode.field("word_audio_base64", decode.string)
  use sentence_audio_base64 <- decode.field("sentence_audio_base64", decode.string)
  use image_base64 <- decode.field("image_base64", decode.string)
  use notes <- decode.field("notes", decode.string)
  // `decode.list(decode.string)` is a decoder combinator: it
  // expects a JSON array and decodes every element as a string.
  // If any element is not a string, the whole decoder fails.
  use warnings <- decode.field("warnings", decode.list(decode.string))
  // All ten variables are now in scope. Assemble the CardDraft.
  decode.success(CardDraft(
    sentence:,
    target_word:,
    target_pinyin:,
    target_meaning:,
    sentence_pinyin:,
    sentence_meaning:,
    word_audio_base64:,
    sentence_audio_base64:,
    image_base64:,
    notes:,
    warnings:,
  ))
}

// ------------------------------------------------------------
// push_request_decoder
//
// Returns a decoder that parses JSON like:
//   {
//     "deck": "Chinese::Sentences",
//     "card": { ... CardDraft fields ... }
//   }
// into a `PushRequest` value.
//
// Notice that the "card" field uses `card_draft_decoder()` as its
// inner decoder — this is *nested* decoding. The `decode.field`
// combinator recursively applies `card_draft_decoder()` to the
// value stored under the "card" key in the outer object.
// ------------------------------------------------------------
pub fn push_request_decoder() -> decode.Decoder(PushRequest) {
  use deck <- decode.field("deck", decode.string)
  // Reuse the card_draft_decoder we defined above — decoders are
  // just values, so they compose naturally.
  use card <- decode.field("card", card_draft_decoder())
  decode.success(PushRequest(deck:, card:))
}

// ------------------------------------------------------------
// push_response_decoder
//
// Returns a decoder that parses JSON like:
//   { "note_id": 1234567890 }
// into a `PushResponse` value.
//
// `decode.int` is the primitive decoder for JSON numbers that
// should be treated as integers.
// ------------------------------------------------------------
pub fn push_response_decoder() -> decode.Decoder(PushResponse) {
  use note_id <- decode.field("note_id", decode.int)
  decode.success(PushResponse(note_id:))
}
