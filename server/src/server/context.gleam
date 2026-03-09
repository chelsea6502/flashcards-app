// ============================================================
// context.gleam — Shared Request Context
// ============================================================
//
// This module defines the `Context` type — a plain record (Gleam's equivalent
// of a struct) that holds all the shared, request-independent state the server
// needs. It's created once at startup and passed into every request handler.
//
// WHY A CONTEXT RECORD?
// In Gleam, functions are pure by default and there's no global mutable state.
// Instead of global variables, we pass shared dependencies explicitly as
// function arguments. Bundling them into a single `Context` record is cleaner
// than having 5+ parameters on every handler function.
//
// This pattern is sometimes called "dependency injection" — the dependencies
// (API keys, actor references, paths) are "injected" from outside rather than
// being hard-coded or globally accessed.

import gleam/erlang/process.{type Subject}
// `Subject` is Gleam's typed mailbox handle for a BEAM process.
// A `Subject(Msg)` lets you send messages of type `Msg` to a specific process.
// Importing `{type Subject}` brings the type name into scope without needing to
// write `process.Subject` everywhere.

import server/services/dictionary.{type Msg as DictMsg}
// We import the `Msg` type from the dictionary service module, but rename it
// to `DictMsg` using the `as` keyword. This avoids ambiguity — we might import
// `Msg` types from multiple actor modules, and giving each a distinct alias
// makes code easier to read and avoids name collisions.

// ----------------------------------------------------------
// THE CONTEXT TYPE
// ----------------------------------------------------------
// In Gleam, `pub type Foo { Foo(...) }` defines a custom type with a single
// variant (constructor). This is essentially a struct. The type and the
// constructor share the same name (`Context`).
//
// All fields are immutable — once a Context is created, its values never change.
// This is perfectly fine for server-wide config that's set at startup.
pub type Context {
  Context(
    // Path to the directory containing static files (CSS, JS, images).
    // Used by wisp's static file serving middleware in the router.
    static_directory: String,
    // A `Subject(DictMsg)` is a typed mailbox reference to the dictionary actor
    // process. Holding this reference is how we communicate with the actor —
    // we send it a `DictMsg` message and it replies with the result.
    //
    // SUBJECT vs PID: On raw Erlang/Elixir you'd use a PID (process identifier)
    // to send messages, but PIDs are untyped. Gleam's `Subject(msg)` is a
    // typed wrapper that the compiler checks — you can only send messages of
    // type `msg` to this subject, preventing a whole class of bugs.
    dict_actor: Subject(DictMsg),
    // API key for the Anthropic Claude API (used for sentence generation).
    // Loaded from the ANTHROPIC_API_KEY environment variable at startup.
    claude_api_key: String,
    // Base URL for the Text-to-Speech service (e.g., "http://localhost:8766").
    // Loaded from TTS_URL environment variable, or defaults to localhost.
    tts_url: String,
    // API key for the OpenAI API (used for DALL-E image generation).
    // Optional — empty string disables image generation.
    openai_api_key: String,
  )
}
