// ============================================================
// services/llm.gleam — Claude LLM Integration
// ============================================================
//
// This module handles communication with the Anthropic Claude API to generate
// example sentences for Chinese vocabulary words.
//
// The flow is:
//   1. Build a prompt string describing what we want Claude to produce
//   2. Serialize it into a JSON HTTP request body
//   3. Send the request to api.anthropic.com
//   4. Parse Claude's JSON response to extract the generated text
//   5. Parse the LLM's own JSON output (Claude returns JSON inside its message)
//   6. Return a typed `LlmResult` or a descriptive `Error(String)`
//
// Everything returns `Result(T, String)` — no exceptions, no panics.
// The caller in generate.gleam decides what to do when something fails.

import gleam/dynamic/decode
// `decode` lets us safely parse untyped JSON (`Dynamic`) into Gleam types.
// Instead of crashing on unexpected JSON, decoders return Result values.

import gleam/http
// Defines `http.Post`, `http.Get`, etc. for specifying HTTP methods.

import gleam/http/request
// `request` provides functions for building HTTP request records:
// setting methods, headers, body, URL parsing, etc.

import gleam/httpc
// `httpc` is Gleam's HTTP client for sending requests.
// It runs synchronously in the current BEAM process.

import gleam/json
// `json` provides functions to build JSON structures (json.object, json.string,
// json.int, json.array) and serialize them to strings with `json.to_string`.

import gleam/result
// `result` provides helper functions for working with `Result` values:
// `result.map`, `result.map_error`, `result.try`, etc.

import gleam/string
// String manipulation utilities.

// ----------------------------------------------------------
// RESULT TYPE
// ----------------------------------------------------------
// A plain record (struct) representing the structured data we expect Claude to
// return. By parsing Claude's free-form text into this typed record, the rest of
// the application can work with it safely — no stringly-typed data.
pub type LlmResult {
  LlmResult(
    // The example sentence in Chinese, with the target word wrapped in <b> tags.
    sentence: String,
    // Full sentence pinyin with tone numbers (e.g., "wo3 <b>liao3 jie3</b> ni3")
    sentence_pinyin: String,
    // English translation of the example sentence.
    sentence_meaning: String,
    // Pedagogical notes: grammar points, measure words, mnemonics, etc.
    notes: String,
  )
}

// ----------------------------------------------------------
// MAIN PUBLIC FUNCTION
// ----------------------------------------------------------
// Calls the Claude API to generate an example sentence for a vocabulary word.
//
// Returns `Result(LlmResult, String)`:
//   - `Ok(result)` with the parsed LLM output on success
//   - `Error(message)` with a human-readable error description on failure
pub fn generate_sentence(
  api_key: String,
  word: String,
  definition: String,
  pinyin: String,
) -> Result(LlmResult, String) {
  // ----------------------------------------------------------
  // BUILD THE PROMPT
  // ----------------------------------------------------------
  // We construct the prompt using string concatenation (`<>` operator).
  // The prompt asks Claude to return ONLY JSON — no prose, no markdown wrapper.
  // We specify the exact JSON schema so we can reliably parse the response.
  //
  // Note: We embed `word` and `pinyin` into the example output format so Claude
  // uses the correct word in the right place. LLMs respond better to concrete
  // examples than abstract descriptions.
  let prompt =
    "You are a Mandarin Chinese teaching assistant. Generate a natural example sentence for the word \""
    <> word
    <> "\" (pinyin: "
    <> pinyin
    <> ", meaning: "
    <> definition
    <> ").

Return ONLY valid JSON with these exact fields:
{
  \"sentence\": \"The Chinese sentence with the target word wrapped in <b> tags, e.g. 我<b>"
    <> word
    <> "</b>这个问题\",
  \"sentence_pinyin\": \"Full sentence pinyin with tone numbers, e.g. wo3 <b>"
    <> pinyin
    <> "</b> zhe4 ge4 wen4 ti2\",
  \"sentence_meaning\": \"English translation of the sentence\",
  \"notes\": \"Useful notes: measure words, grammar points, common collocations, or mnemonics\"
}"

  // ----------------------------------------------------------
  // BUILD THE JSON REQUEST BODY
  // ----------------------------------------------------------
  // `json.object` takes a list of `#(key, value)` tuples and builds a JSON object.
  // `#(a, b)` is Gleam's tuple syntax — a fixed-size grouping of values.
  //
  // `json.preprocessed_array` takes a list of already-built `Json` values and
  // wraps them in a JSON array. This is slightly more efficient than `json.array`
  // when the items are already `Json` type.
  //
  // The final `|> json.to_string` serializes the entire JSON tree to a String.
  let body =
    json.object([
      #("model", json.string("claude-sonnet-4-20250514")),
      #("max_tokens", json.int(1024)),
      #(
        "messages",
        json.preprocessed_array([
          json.object([
            #("role", json.string("user")),
            #("content", json.string(prompt)),
          ]),
        ]),
      ),
    ])
    |> json.to_string

  // ----------------------------------------------------------
  // BUILD THE HTTP REQUEST
  // ----------------------------------------------------------
  // `request.to(url)` parses the URL and returns `Result(Request, Nil)`.
  //
  // LET ASSERT: `let assert Ok(req) = request.to(...)` unwraps the Ok value or
  // panics if it's Error. We use this here because the URL is a hard-coded
  // constant — if it fails to parse, that's a programmer error, not a runtime
  // error, and a panic is appropriate. Prefer `case` for user-supplied values.
  let assert Ok(req) = request.to("https://api.anthropic.com/v1/messages")

  // Build up the request by piping through setter functions.
  // Each function takes a request and returns a modified request.
  // This is immutable transformation — each step creates a new request record.
  //
  // SHADOWING: We reuse the name `req` for each step. In Gleam, variables are
  // immutable, but you can "shadow" a name with a new binding. The original `req`
  // isn't mutated — a new value is bound to the same name. This is idiomatic
  // when doing a series of transformations on one thing.
  let req =
    req
    |> request.set_method(http.Post)
    // Set the request body (the JSON string we built above).
    |> request.set_body(body)
    // Add required HTTP headers.
    |> request.prepend_header("content-type", "application/json")
    |> request.prepend_header("x-api-key", api_key)
    // Anthropic requires this header to specify the API version.
    |> request.prepend_header("anthropic-version", "2023-06-01")

  // ----------------------------------------------------------
  // SEND THE REQUEST
  // ----------------------------------------------------------
  // `httpc.send(req)` is synchronous — it blocks this BEAM process until the
  // response arrives. This is fine because each HTTP request to our server runs
  // in its own lightweight BEAM process (spawned by mist), so blocking one
  // doesn't affect others. The BEAM scheduler handles everything.
  //
  // Returns `Result(Response(String), Dynamic)` where the Dynamic error is a
  // low-level network error (connection refused, timeout, etc.)
  case httpc.send(req) {
    Ok(resp) ->
      // Pattern match on the HTTP status code.
      // In Gleam, you can match on integer literals directly in case expressions.
      case resp.status {
        200 -> parse_claude_response(resp.body)
        // Any non-200 status is an error. We include the status code and response
        // body in the error string to aid debugging.
        status ->
          Error(
            "Claude API returned status "
            <> string.inspect(status)
            // `string.inspect` converts any value to its debug string representation.
            <> ": "
            <> resp.body,
          )
      }
    Error(_) -> Error("Failed to connect to Claude API")
    // We discard the specific error value with `_` since it's a low-level
    // Erlang term that isn't particularly useful to surface to the user.
  }
}

// ----------------------------------------------------------
// PARSE CLAUDE'S RESPONSE ENVELOPE
// ----------------------------------------------------------
// Claude's API wraps the actual generated text in a response envelope like:
//   {
//     "content": [{"type": "text", "text": "...the JSON we want..."}],
//     "model": "...",
//     ...
//   }
//
// We need to dig into `content[0].text` to get the actual LLM output.
fn parse_claude_response(body: String) -> Result(LlmResult, String) {
  // ----------------------------------------------------------
  // BUILDING A DECODER
  // ----------------------------------------------------------
  // A decoder describes the shape of the data we expect and how to extract it.
  // Decoders compose — you build complex decoders from simple ones.
  //
  // `decode.field("content", inner_decoder)` says: "expect a field named 'content'
  // and apply `inner_decoder` to its value".
  //
  // `decode.at([0], inner)` says: "expect an array and apply `inner` to index 0".
  //
  // USE WITH DECODERS: The `use content <- decode.field(...)` pattern is the
  // same `use` callback pattern from the router, but here it's for building
  // decoders. Each `use` step says "extract this field and bind it to this name;
  // then continue building the decoder with it in scope". If any extraction fails,
  // the whole decoder returns Error without executing the rest.
  //
  // Think of it like a pipeline of "do this, then with the result do this, then..."
  // that short-circuits on the first failure.
  let text_decoder = {
    use content <- decode.field("content", decode.at([0], {
      use text <- decode.field("text", decode.string)
      // `decode.success(text)` says "we're done; the decoded value is `text`".
      decode.success(text)
    }))
    decode.success(content)
  }

  // `json.parse(body, decoder)` parses the JSON string and applies the decoder.
  // Returns `Result(String, json.DecodeError)`.
  case json.parse(body, text_decoder) {
    Ok(text) -> parse_llm_json(text)
    // If we couldn't extract the text, something unexpected happened with the
    // API response format.
    Error(_) -> Error("Failed to parse Claude response structure")
  }
}

// ----------------------------------------------------------
// PARSE THE LLM'S JSON OUTPUT
// ----------------------------------------------------------
// Claude was asked to return JSON. This function parses that JSON into an LlmResult.
// We need a separate parsing step because the JSON lives inside Claude's text field.
fn parse_llm_json(text: String) -> Result(LlmResult, String) {
  // The LLM might wrap JSON in markdown code blocks
  // (e.g., ```json\n{...}\n```). We strip those first.
  let cleaned = clean_json_text(text)

  // Build a decoder that expects the exact JSON schema we specified in the prompt.
  // Each `use field_name <- decode.field("field_name", decode.string)` line:
  //   1. Extracts the named field from the JSON object
  //   2. Decodes it as a String
  //   3. Binds the result to `field_name` for use in the next step
  // If ANY field is missing or has the wrong type, the whole decoder returns Error.
  let decoder = {
    use sentence <- decode.field("sentence", decode.string)
    use sentence_pinyin <- decode.field("sentence_pinyin", decode.string)
    use sentence_meaning <- decode.field("sentence_meaning", decode.string)
    use notes <- decode.field("notes", decode.string)
    // `decode.success(...)` marks the end of the decoder chain and produces the
    // final typed value. Field punning: `sentence:` means `sentence: sentence`, etc.
    decode.success(LlmResult(sentence:, sentence_pinyin:, sentence_meaning:, notes:))
  }

  // `result.map_error` transforms the Error case while leaving Ok unchanged.
  // If parsing fails, we attach the raw `cleaned` text to the error message
  // so we can see what the LLM actually returned (useful for debugging prompt issues).
  json.parse(cleaned, decoder)
  |> result.map_error(fn(_) { "Failed to parse LLM JSON output: " <> cleaned })
}

// ----------------------------------------------------------
// CLEAN MARKDOWN CODE FENCE FROM JSON
// ----------------------------------------------------------
// LLMs sometimes wrap their JSON output in markdown fences like:
//   ```json
//   { "sentence": "..." }
//   ```
// Even when explicitly told not to. This function strips those fences
// so we can parse the raw JSON.
fn clean_json_text(text: String) -> String {
  let trimmed = string.trim(text)
  case string.starts_with(trimmed, "```") {
    True -> {
      // Remove the opening ``` (3 chars) and any leading whitespace.
      let without_start =
        trimmed
        |> string.drop_start(3)
        |> string.trim_start

      // Remove the optional "json" language hint right after the backticks.
      // (```json vs just ``` — both are common)
      let without_lang = case string.starts_with(without_start, "json") {
        True -> string.drop_start(without_start, 4)
        // drop the 4 chars "json"
        False -> without_start
      }

      // Remove the closing ``` (3 chars) if present.
      case string.ends_with(without_lang, "```") {
        True -> string.drop_end(without_lang, 3) |> string.trim
        False -> without_lang |> string.trim
      }
    }
    // No code fence — return as-is (just trimmed of whitespace).
    False -> trimmed
  }
}
