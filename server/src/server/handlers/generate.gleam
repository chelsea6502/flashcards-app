// ============================================================
// handlers/generate.gleam — Flashcard Generation Handler
// ============================================================
//
// This module handles the business logic for POST /api/generate.
// It orchestrates several services in sequence to build a complete flashcard:
//
//   1. Dictionary lookup (CEDICT) — get definition and pinyin
//   2. Pinyin conversion — convert numbered pinyin to HTML tone marks
//   3. Claude LLM — generate an example sentence
//   4. Pinyin conversion — convert the sentence's pinyin to HTML too
//   5. TTS synthesis — generate audio for the example sentence
//   6. Image generation — generate a DALL-E image for the definition
//   7. Assemble — pack everything into a CardDraft and return as JSON
//
// Failures in optional steps (TTS, image) are collected as "warnings" rather
// than fatal errors — the card is still returned, just without audio/image.
// This is a key design choice: partial success > total failure.

import gleam/erlang/process.{type Subject}
// `Subject(DictMsg)` is the typed mailbox reference to the dictionary actor.

import gleam/json
// For serializing the final response to a JSON string.

import gleam/list
// List utilities — we use `list.reverse` to correct accumulator order.

import gleam/string
// String utilities — we use `string.trim` to clean up the input word.

import server/services/dictionary.{type Msg as DictMsg}
// We import both the module (for `dictionary.lookup`) and the `Msg` type alias
// (needed for the `Subject(DictMsg)` type annotation).

import server/services/image
// Image generation service (DALL-E via OpenAI API).

import server/services/llm
// LLM sentence generation service (Claude API).

import server/services/tts
// Text-to-speech synthesis service.

import server/util/pinyin
// Pinyin conversion utilities (numbered → tone marks/HTML).

import shared/codec
// Shared encoder/decoder functions for the wire format.

import shared/types.{type GenerateRequest, CardDraft}
// `GenerateRequest`: the decoded request body (contains the word to look up).
// `CardDraft`: the response type — all the data for a new flashcard.

import wisp.{type Response}
// `Response` is wisp's HTTP response type.

// ----------------------------------------------------------
// MAIN HANDLER FUNCTION
// ----------------------------------------------------------
// This function is called by the router once the request body has been decoded
// into a `GenerateRequest`. It performs all the service calls and returns a
// complete HTTP response.
//
// Notice this function takes individual values (dict_actor, claude_api_key, etc.)
// rather than a whole `Context`. This is a deliberate decoupling choice:
// the handler doesn't need to know about the Context type at all, making it
// easier to test and reuse.
pub fn handle(
  req: GenerateRequest,
  dict_actor: Subject(DictMsg),
  claude_api_key: String,
  tts_url: String,
  openai_api_key: String,
) -> Response {
  // Clean whitespace from the user-provided word (handles copy-paste artifacts).
  let word = string.trim(req.word)

  // Start with an empty warnings list. Warnings accumulate as optional steps fail.
  // We use a List as a stack (prepend is O(1) in Gleam's linked lists), then
  // reverse it at the end so warnings appear in chronological order.
  let warnings = []

  // ----------------------------------------------------------
  // STEP 1: DICTIONARY LOOKUP
  // ----------------------------------------------------------
  // Send a message to the dictionary actor and wait for a reply.
  // `dictionary.lookup` returns `Result(DictEntry, Nil)`.
  let dict_result = dictionary.lookup(dict_actor, word)

  // Destructure the result into the two values we care about.
  // `#(definition, pinyin_numbered)` is a 2-tuple — we unpack both fields in
  // one step. If the lookup succeeded, we join the definitions with "; ".
  // If it failed, we use empty strings as sentinels (checked below).
  let #(definition, pinyin_numbered) = case dict_result {
    Ok(entry) -> #(
      // `string.join(list, separator)` concatenates a list of strings with a separator.
      string.join(entry.definitions, "; "),
      entry.pinyin_numbered,
    )
    Error(Nil) -> #("", "")
    // `Error(Nil)` — word not found. `Nil` is the unit type (like `void`),
    // used here as the error payload because there's no useful information
    // to carry — it's simply "not found".
  }

  // Handle the "word not found" case by falling back to LLM-only mode and adding
  // a warning. We re-bind `definition`, `pinyin_numbered`, and `warnings` all at
  // once using a destructured tuple assignment.
  //
  // VARIABLE SHADOWING: Gleam allows re-binding the same name with `let`.
  // The old bindings are gone after this point — only the new values exist.
  // This is safe because Gleam values are immutable; there's no aliasing.
  let #(definition, pinyin_numbered, warnings) = case definition {
    "" -> #(
      "(unknown)",
      "(unknown)",
      // Prepend to warnings list: `[new_item, ..existing_list]` is the spread syntax.
      // This is O(1) — prepending to a linked list.
      ["Word not found in CEDICT — using LLM fallback", ..warnings],
    )
    // Wildcard: definition is non-empty, word was found — keep everything as-is.
    _ -> #(definition, pinyin_numbered, warnings)
  }

  // ----------------------------------------------------------
  // STEP 2: PINYIN CONVERSION (TARGET WORD)
  // ----------------------------------------------------------
  // Convert the numbered pinyin (e.g., "liao3 jie3") to HTML with tone color
  // spans (e.g., `<span class="tone3">liǎo</span> <span class="tone3">jiě</span>`).
  // These HTML spans are used by the frontend to color-code tones.
  let target_pinyin_html = case pinyin_numbered {
    // If the word wasn't in the dictionary, we don't have pinyin to convert.
    "(unknown)" -> "(unknown)"
    // `p` captures the actual pinyin string — feed it to the converter.
    p -> pinyin.to_tone_html(p)
  }

  // ----------------------------------------------------------
  // STEP 3: LLM SENTENCE GENERATION
  // ----------------------------------------------------------
  // Call Claude to generate an example sentence, its pinyin, English translation,
  // and usage notes. This is the slowest step — a network request to Anthropic's API.
  //
  // Returns `Result(LlmResult, String)`. We branch immediately to handle failure:
  // if Claude fails, the entire request fails (we can't make a card without a sentence).
  let llm_result =
    llm.generate_sentence(claude_api_key, word, definition, pinyin_numbered)

  case llm_result {
    Error(err) -> {
      // LLM failed — return a 500 error response. No card can be generated.
      // We still provide a structured JSON error body for the client to display.
      let body =
        codec.encode_error("LLM error: " <> err)
        |> json.to_string
      wisp.json_response(body, 500)
    }
    Ok(llm) -> {
      // `llm` is now bound to the `LlmResult` record with all the generated content.

      // ----------------------------------------------------------
      // STEP 4: PINYIN CONVERSION (SENTENCE)
      // ----------------------------------------------------------
      // Convert the sentence's numbered pinyin to HTML tone spans, same as above.
      // The sentence pinyin may contain `<b>` tags from the LLM — the converter
      // treats those as non-pinyin text and passes them through unchanged.
      let sentence_pinyin_html = pinyin.to_tone_html(llm.sentence_pinyin)

      // ----------------------------------------------------------
      // STEP 5: TTS (TEXT-TO-SPEECH)
      // ----------------------------------------------------------
      // Generate audio for both the isolated word and the full sentence.
      // TTS is OPTIONAL — failures add warnings but don't block card creation.
      let #(word_audio_base64, warnings) = case tts.synthesize(tts_url, word) {
        Ok(audio) -> #(audio, warnings)
        Error(err) -> #("", ["Word audio: " <> err, ..warnings])
      }

      let #(sentence_audio_base64, warnings) = case tts.synthesize(tts_url, llm.sentence) {
        Ok(audio) -> #(audio, warnings)
        Error(err) -> #("", ["Sentence audio: " <> err, ..warnings])
      }

      // ----------------------------------------------------------
      // STEP 6: IMAGE GENERATION
      // ----------------------------------------------------------
      // Request a DALL-E image illustrating the word's definition.
      // Also optional — failure adds a warning and uses an empty string.
      let #(image_base64, warnings) = case
        image.generate(openai_api_key, word, definition, llm.sentence, llm.sentence_meaning)
      {
        Ok(img) -> #(img, warnings)
        Error(err) -> #("", [err, ..warnings])
      }

      // ----------------------------------------------------------
      // STEP 7: ASSEMBLE THE CARD DRAFT
      // ----------------------------------------------------------
      // Pack all the collected data into a `CardDraft` record.
      // This is the response payload sent back to the client.
      //
      // FIELD PUNNING: `audio_base64:` is shorthand for `audio_base64: audio_base64`,
      // `image_base64:` is shorthand for `image_base64: image_base64`.
      // Fields where the variable name matches the field name can be written
      // with just the field name followed by a colon.
      let card =
        CardDraft(
          sentence: llm.sentence,
          target_word: word,
          target_pinyin: target_pinyin_html,
          target_meaning: definition,
          sentence_pinyin: sentence_pinyin_html,
          sentence_meaning: llm.sentence_meaning,
          word_audio_base64:,
          sentence_audio_base64:,
          image_base64:,
          // shorthand for `image_base64: image_base64`
          notes: llm.notes,
          // Reverse the warnings list so they appear in chronological order.
          // Remember: we prepended to a list (stack order), so the FIRST warning
          // we added is currently LAST. `list.reverse` fixes that.
          warnings: list.reverse(warnings),
        )

      // Encode the card to JSON and build a 200 OK HTTP response.
      // `codec.encode_card_draft` returns a `Json` value (a tree structure).
      // `json.to_string` serializes it to a JSON string.
      // `wisp.json_response` wraps it in an HTTP response with the right headers.
      let body =
        codec.encode_card_draft(card)
        |> json.to_string
      wisp.json_response(body, 200)
    }
  }
}
