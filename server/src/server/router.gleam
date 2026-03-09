// ============================================================
// router.gleam — HTTP Request Router
// ============================================================
//
// The router is the "front door" of the web server. Every HTTP request that
// arrives goes through `handle_request` first. The router's job is to:
//   1. Apply middleware (logging, crash protection, static files)
//   2. Inspect the URL path and dispatch to the right handler function
//
// This is a very common web framework pattern — Wisp encourages keeping routing
// logic separate from handler logic.

import gleam/dynamic/decode
// `decode` is Gleam's library for safely decoding untyped data (like JSON) into
// typed Gleam values. JSON arrives as unstructured `Dynamic` data; decoders
// validate and transform it into concrete types like `GenerateRequest`.

import gleam/http
// The `http` module defines types for HTTP methods (GET, POST, etc.) and other
// HTTP concepts.

import server/context.{type Context}
// We import the `Context` type alias so we can write `Context` in type annotations.
// `type Context` (without curly braces) imports the type; `{Context}` would import
// the constructor. Here `{type Context}` makes the *type name* available.

import server/handlers/generate
// The actual business logic for the /api/generate endpoint lives in this module.

import server/handlers/push
// The business logic for the /api/push endpoint (AnkiConnect integration).

import shared/codec
// `codec` contains shared encoder/decoder functions used by both client and server.
// Having these in a `shared` package ensures the client and server always agree
// on the wire format.

import wisp.{type Request, type Response}
// Import both the `wisp` module AND bring the `Request` and `Response` types
// directly into scope so we don't have to write `wisp.Request` everywhere.

// ----------------------------------------------------------
// MAIN REQUEST HANDLER
// ----------------------------------------------------------
// This function is the single entry point for ALL HTTP requests. Wisp calls it
// for every incoming request. It returns a `Response` that wisp sends back to
// the client.
//
// The `pub` keyword makes this function visible to other modules (main.gleam
// needs to reference it when setting up the server).
pub fn handle_request(req: Request, ctx: Context) -> Response {
  // ----------------------------------------------------------
  // THE `use` CALLBACK PATTERN / WISP MIDDLEWARE
  // ----------------------------------------------------------
  // The `use <- func` syntax is Gleam's "use expression". It's syntactic sugar
  // for passing the REST OF THE CURRENT FUNCTION as a callback argument.
  //
  // So `use <- wisp.log_request(req)` is equivalent to:
  //   wisp.log_request(req, fn() {
  //     // everything after this line...
  //   })
  //
  // This lets middleware functions "wrap" the handler: they can run code before
  // calling the callback (the rest of the function), inspect or modify the
  // result, or short-circuit and return early without calling the callback at all.
  //
  // It reads naturally top-to-bottom: "use this middleware, then continue".
  // This is the idiomatic Wisp way to layer middleware.

  // Log every incoming request (method, path, response status) to the console.
  use <- wisp.log_request(req)

  // Catch any runtime panics and return a 500 Internal Server Error response
  // instead of crashing the server. On the BEAM, a crash in one process doesn't
  // kill other processes — but we still want to return a proper HTTP error.
  use <- wisp.rescue_crashes

  // Serve files from `ctx.static_directory` when the URL starts with "/static".
  // If a file is found, this short-circuits and returns the file directly.
  // If not found, it calls the rest of the function to handle the request normally.
  //
  // LABELED ARGUMENTS: Gleam supports labeled arguments, which must be passed
  // by name. `under:` and `from:` are the labels here — they make the call site
  // self-documenting. You can pass labeled arguments in any order.
  use <- wisp.serve_static(req, under: "/static", from: ctx.static_directory)

  // ----------------------------------------------------------
  // URL ROUTING VIA PATTERN MATCHING
  // ----------------------------------------------------------
  // `wisp.path_segments(req)` splits the URL path into a list of strings.
  // e.g., "/api/generate" becomes `["api", "generate"]`
  //       "/"             becomes `[]`
  //       "/foo/bar/baz"  becomes `["foo", "bar", "baz"]`
  //
  // We then pattern match on that list to route to the right handler.
  // This is pure Gleam pattern matching — no regex, no special routing DSL.
  // Lists in Gleam are matched with literal syntax: `["segment1", "segment2"]`
  // matches exactly two segments with those exact values.
  case wisp.path_segments(req) {
    ["api", "generate"] -> handle_generate(req, ctx)
    // Matches exactly: POST /api/generate
    ["api", "push"] -> handle_push(req)
    // Matches exactly: POST /api/push
    [] -> serve_index()
    // Matches the root path "/"
    _ -> wisp.not_found()
    // The wildcard `_` matches anything else → 404 Not Found
  }
}

// ----------------------------------------------------------
// GENERATE HANDLER
// ----------------------------------------------------------
// Handles POST /api/generate — the main flashcard generation endpoint.
fn handle_generate(req: Request, ctx: Context) -> Response {
  // `use <- wisp.require_method(req, http.Post)` is more middleware magic:
  // if the request method is NOT POST, wisp returns a 405 Method Not Allowed
  // response and never calls the rest of this function.
  use <- wisp.require_method(req, http.Post)

  // `use json_body <- wisp.require_json(req)` reads the request body and parses
  // it as JSON. If the body is missing or invalid JSON, wisp returns 400 Bad Request.
  // If parsing succeeds, `json_body` is bound to the parsed `Dynamic` value
  // (an untyped representation of the JSON — we still need to decode it).
  use json_body <- wisp.require_json(req)

  // `decode.run(json_body, codec.generate_request_decoder())` applies a decoder
  // to the dynamic JSON data, returning `Result(GenerateRequest, DecodeErrors)`.
  //
  // DECODERS: A decoder describes the *expected shape* of the data. If the JSON
  // matches, you get `Ok(typed_value)`. If anything is wrong (wrong type, missing
  // field), you get `Error(errors)`. This is how Gleam achieves type-safe JSON
  // parsing — the type system ensures you always handle both possibilities.
  case decode.run(json_body, codec.generate_request_decoder()) {
    Ok(gen_req) ->
      // The JSON decoded successfully into a `GenerateRequest`. Pass all the
      // context fields the handler needs individually (rather than the whole ctx)
      // so the handler module doesn't need to import `context.gleam` — cleaner
      // dependency graph.
      generate.handle(
        gen_req,
        ctx.dict_actor,
        ctx.claude_api_key,
        ctx.tts_url,
        ctx.openai_api_key,
      )
    Error(_) -> wisp.unprocessable_content()
    // 422 Unprocessable Content — the JSON was valid but didn't have the
    // expected structure (wrong fields, wrong types, etc.)
  }
}

// ----------------------------------------------------------
// PUSH HANDLER
// ----------------------------------------------------------
// Handles POST /api/push — pushes a flashcard to Anki via AnkiConnect.
fn handle_push(req: Request) -> Response {
  use <- wisp.require_method(req, http.Post)
  use json_body <- wisp.require_json(req)
  case decode.run(json_body, codec.push_request_decoder()) {
    Ok(push_req) -> push.handle(push_req)
    Error(_) -> wisp.unprocessable_content()
  }
}

// ----------------------------------------------------------
// INDEX HTML
// ----------------------------------------------------------
// Serves the single-page application's HTML shell for the root URL "/".
// The actual app logic is loaded by the <script> tag — this is the SPA pattern.
fn serve_index() -> Response {
  wisp.html_response(
    // This is a multi-line string literal in Gleam (just a regular string with
    // embedded newlines). Gleam strings are UTF-8 and use double quotes.
    // Escaped quotes inside strings use the standard backslash: \".
    "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Mandarin Flashcard Generator</title>
  <link rel=\"stylesheet\" href=\"/static/styles.css\">
</head>
<body>
  <div id=\"app\"></div>
  <script type=\"module\" src=\"/static/app.mjs\"></script>
</body>
</html>",
    200,
    // Second argument is the HTTP status code.
  )
}
