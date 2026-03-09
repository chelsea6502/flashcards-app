// ============================================================
// shared/types.gleam
//
// This module defines the core data types (also called "models")
// shared between the client and the server. Because both sides
// import this same file, they always agree on the shape of the
// data they send back and forth.
//
// KEY GLEAM CONCEPT — Custom types
// ---------------------------------
// In Gleam you define your own types with the `type` keyword.
// Each type lists one or more *constructors*. A constructor is a
// function that builds a value of that type.
//
//   pub type Color {
//     Red         // constructor with no fields
//     Rgb(r: Int, g: Int, b: Int)  // constructor with fields
//   }
//
// When a type has *exactly one constructor* (like most types here)
// the constructor is usually given the same name as the type —
// that is just a convention, not a rule.
//
// All types in this file are `pub` (public), meaning other modules
// can import and use them.
// ============================================================

// ------------------------------------------------------------
// DictEntry
//
// Represents one entry from a Chinese dictionary. A word can be
// written in two scripts (traditional / simplified) and has a
// pronunciation written in numbered pinyin (e.g. "ni3 hao3") as
// well as a list of English definitions.
//
// Notice that `definitions` is `List(String)` — a word can have
// several meanings, so we store them all in a list.
// ------------------------------------------------------------
pub type DictEntry {
  DictEntry(
    traditional: String,
    simplified: String,
    pinyin_numbered: String,
    definitions: List(String),
  )
}

// ------------------------------------------------------------
// CardDraft
//
// A fully-assembled flashcard that is ready to be reviewed before
// being pushed to Anki. It holds everything the card needs:
// the sentence it came from, the target vocabulary word, audio
// and image data encoded as base64 strings, free-text notes, and
// a list of warnings produced during generation (e.g. "audio was
// unavailable so silence was used").
//
// KEY GLEAM CONCEPT — Labeled fields
// -----------------------------------
// Gleam constructors can have *labeled* fields (field_name: Type).
// You can then access them with dot-notation:
//   card.sentence
//   card.warnings
// and you can pattern-match on specific fields by name without
// needing to match every single field.
// ------------------------------------------------------------
pub type CardDraft {
  CardDraft(
    sentence: String,
    target_word: String,
    target_pinyin: String,
    target_meaning: String,
    sentence_pinyin: String,
    sentence_meaning: String,
    word_audio_base64: String,
    sentence_audio_base64: String,
    image_base64: String,
    notes: String,
    warnings: List(String),
  )
}

// ------------------------------------------------------------
// GenerateRequest
//
// The HTTP request body the client sends when it wants the server
// to generate a flashcard draft for a given word.
//
// This type has only one field (`word: String`), but wrapping it
// in a custom type instead of using a bare String is intentional:
// it makes the code self-documenting and prevents accidentally
// passing a plain string where a request is expected.
// ------------------------------------------------------------
pub type GenerateRequest {
  GenerateRequest(word: String)
}

// ------------------------------------------------------------
// PushRequest
//
// The HTTP request body the client sends when it wants to push
// a finished card to Anki. It bundles together:
//   - `deck`: the name of the Anki deck to add the card to
//   - `card`: the fully-populated CardDraft to add
// ------------------------------------------------------------
pub type PushRequest {
  PushRequest(deck: String, card: CardDraft)
}

// ------------------------------------------------------------
// PushResponse
//
// The HTTP response body the server sends back after successfully
// adding a card to Anki. Anki returns a numeric note ID for each
// newly created note, which the client can use to open or verify
// the card.
// ------------------------------------------------------------
pub type PushResponse {
  PushResponse(note_id: Int)
}

// ------------------------------------------------------------
// AppError
//
// KEY GLEAM CONCEPT — Sum types (multiple constructors)
// ------------------------------------------------------
// Unlike all the types above, `AppError` has *several*
// constructors. Each constructor represents a different kind of
// failure that can happen in the application. This is sometimes
// called a "sum type" or "tagged union" in other languages.
//
// In Rust you would write this as an `enum`; in TypeScript you
// would use a discriminated union. In Gleam it is just a regular
// custom type with multiple constructors.
//
// Each constructor carries a payload that gives context about the
// failure:
//
//   DictNotFound(word: String)
//     — the requested word was not found in the dictionary;
//       `word` is the word that was looked up.
//
//   LlmError(detail: String)
//     — something went wrong when calling the LLM (language
//       model) API.
//
//   TtsError(detail: String)
//     — something went wrong with text-to-speech audio generation.
//
//   ImageError(detail: String)
//     — something went wrong when fetching or processing images.
//
//   AnkiError(detail: String)
//     — something went wrong when communicating with Anki.
//
//   JsonError(detail: String)
//     — JSON serialization or deserialization failed.
//
// KEY GLEAM CONCEPT — Pattern matching on sum types
// --------------------------------------------------
// To handle an AppError you use a `case` expression and match on
// each constructor:
//
//   case err {
//     DictNotFound(word) -> "No entry found for: " <> word
//     LlmError(detail)   -> "LLM failed: " <> detail
//     TtsError(detail)   -> "TTS failed: " <> detail
//     ImageError(detail) -> "Image failed: " <> detail
//     AnkiError(detail)  -> "Anki failed: " <> detail
//     JsonError(detail)  -> "JSON error: " <> detail
//   }
//
// Gleam's compiler is *exhaustive* — it will refuse to compile if
// you forget to handle one of the constructors. That means you can
// never silently ignore an error case.
// ------------------------------------------------------------
pub type AppError {
  DictNotFound(word: String)
  LlmError(detail: String)
  TtsError(detail: String)
  ImageError(detail: String)
  AnkiError(detail: String)
  JsonError(detail: String)
}
