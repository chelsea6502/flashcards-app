// ============================================================
// main.gleam — Application Entry Point
// ============================================================
//
// This is where the server starts. In Gleam/Erlang (the BEAM virtual machine),
// a program's entry point is the `main` function in your top-level module.
//
// THE BEAM: Gleam compiles to run on the Erlang BEAM virtual machine. The BEAM
// is famous for building massively concurrent, fault-tolerant systems (it powers
// WhatsApp, Discord, etc.). Rather than threads, the BEAM uses lightweight
// "processes" — not OS processes, but tiny isolated units of computation that
// can number in the millions. Each process has its own memory and communicates
// only by sending messages (the Actor Model).
//
// IMPORTS: In Gleam, every module you use must be explicitly imported. The name
// after the last "/" is the module name you'll use in code (e.g., `process`,
// `io`, `wisp`). You can also import specific types or values with curly braces.

import envoy
// `envoy` is a library for reading environment variables (like ANTHROPIC_API_KEY).

import gleam/erlang/process
// `process` gives us tools to work with BEAM processes. We use `process.sleep_forever()`
// at the end to keep the main process alive — without it, the program would exit
// immediately after starting, killing the server.

import gleam/io
// `io` provides `io.println` for printing to the console (stdout).

import mist
// `mist` is a Gleam HTTP server library — it handles the low-level TCP connections.

import server/context.{Context}
// We import the `Context` type directly into scope with curly braces, so we can
// write `Context(...)` instead of `context.Context(...)`.

import server/router
import server/services/dictionary
import wisp
// `wisp` is a higher-level web framework that sits on top of `mist`. It handles
// things like request logging, crash recovery, static file serving, etc.

import wisp/wisp_mist
// `wisp_mist` bridges wisp's request handler type with mist's server type.

pub fn main() {
  // `pub fn` declares a public function. Functions without `pub` are private to
  // their module. `main` takes no arguments and returns Nil (nothing).

  // Set up Gleam's logger so we get nicely formatted log output.
  wisp.configure_logger()

  // Generate a random secret key used by wisp to sign cookies and sessions.
  // `wisp.random_string(64)` returns a 64-character random alphanumeric string.
  let secret_key_base = wisp.random_string(64)

  // ----------------------------------------------------------
  // READING ENVIRONMENT VARIABLES
  // ----------------------------------------------------------
  // `envoy.get("VAR_NAME")` returns `Result(String, Nil)`:
  //   - `Ok(value)` if the variable is set
  //   - `Error(Nil)` if it's missing
  //
  // RESULT TYPES: `Result(OkType, ErrType)` is Gleam's way of handling
  // operations that can fail — there are no exceptions. You always have to
  // explicitly handle both the Ok and Error cases.
  //
  // PIPE OPERATOR |>: The `|>` operator takes the value on the left and passes
  // it as the FIRST argument to the function on the right. So:
  //   `envoy.get("KEY") |> unwrap_env("KEY")`
  // is equivalent to:
  //   `unwrap_env(envoy.get("KEY"), "KEY")`
  // Pipes let you write data transformations in a natural left-to-right reading
  // order instead of nesting function calls.

  let claude_api_key =
    envoy.get("ANTHROPIC_API_KEY") |> unwrap_env("ANTHROPIC_API_KEY")
  // `unwrap_env` panics if the variable is missing — Claude is required.

  let openai_api_key = envoy.get("OPENAI_API_KEY") |> ok_or("")
  // `ok_or` returns a default value if missing — OpenAI is optional (falls back
  // to empty string, which disables image generation gracefully).

  let tts_url = envoy.get("TTS_URL") |> ok_or("http://localhost:8766")
  // TTS is optional; if not set, we assume a local TTS server.

  // ----------------------------------------------------------
  // STARTING THE DICTIONARY ACTOR
  // ----------------------------------------------------------
  // CEDICT is a large open-source Chinese-English dictionary file.
  // `priv_directory()` returns the path to this project's `priv/` folder,
  // which is where Erlang/Gleam conventionally stores static data files.
  let cedict_path = priv_directory() <> "/cedict/cedict_ts.u8"
  // `<>` is Gleam's string concatenation operator.

  // `dictionary.start(cedict_path)` reads and parses the CEDICT file, then
  // spawns an OTP actor (a long-lived BEAM process) that holds the parsed data
  // in memory and responds to lookup requests. It returns Result(Subject(Msg), String).
  //
  // CASE EXPRESSION: Gleam's primary way to branch on a value. Here we branch
  // on whether starting the dictionary succeeded or failed.
  //
  // PATTERN MATCHING: The patterns `Ok(actor)` and `Error(err)` destructure the
  // Result — `actor` and `err` are new variable bindings that capture the
  // inner values.
  let dict_actor = case dictionary.start(cedict_path) {
    Ok(actor) -> {
      io.println("Dictionary loaded successfully")
      actor
      // The last expression in a block is its value — so this whole `case`
      // expression evaluates to `actor` on success.
    }
    Error(err) -> {
      io.println("FATAL: " <> err)
      // `panic as "message"` immediately crashes the current process with a
      // message. On the BEAM, you'd normally let a supervisor restart it, but
      // here we truly cannot continue without the dictionary.
      panic as "Cannot start without dictionary"
    }
  }

  // ----------------------------------------------------------
  // BUILDING THE CONTEXT
  // ----------------------------------------------------------
  // `Context` is a plain record (struct) defined in context.gleam that bundles
  // all the shared state the server needs. It gets passed into every request
  // handler so handlers can access the dictionary, API keys, etc.
  //
  // LABELED ARGUMENTS / FIELD PUNNING: In Gleam, when a variable name matches
  // the field name you're setting, you can write `dict_actor:` instead of
  // `dict_actor: dict_actor`. This is called "field punning" or "shorthand".
  let ctx =
    Context(
      static_directory: static_directory(),
      dict_actor:,
      // shorthand for `dict_actor: dict_actor`
      claude_api_key:,
      // shorthand for `claude_api_key: claude_api_key`
      tts_url:,
      openai_api_key:,
    )

  // ----------------------------------------------------------
  // CREATING THE REQUEST HANDLER
  // ----------------------------------------------------------
  // `router.handle_request` has type `fn(Request, Context) -> Response`, but
  // wisp/mist expect a handler of type `fn(Request) -> Response` (one argument).
  //
  // `router.handle_request(_, ctx)` uses `_` as a placeholder for the first
  // argument — this creates a PARTIAL APPLICATION (closure) that already has
  // `ctx` baked in, and is just waiting for the `Request` to be supplied later.
  // This is Gleam's way of doing partial function application without a special
  // syntax — you just pass an anonymous function or use `_` in a call expression.
  let handler = router.handle_request(_, ctx)

  // ----------------------------------------------------------
  // STARTING THE HTTP SERVER
  // ----------------------------------------------------------
  // LET ASSERT: `let assert Ok(_) = ...` is like `let Ok(_) = ...` but it will
  // panic if the right-hand side is an Error. Use it when you're certain the
  // operation won't fail (or when failure is truly unrecoverable, like here —
  // if we can't bind port 8000, there's no point continuing).
  //
  // This is a PIPELINE that builds and starts the server step by step:
  //   1. `wisp_mist.handler(handler, secret_key_base)` wraps our wisp handler
  //      for mist to understand.
  //   2. `mist.new(...)` creates a new mist server configuration.
  //   3. `mist.port(8000)` sets which port to listen on.
  //   4. `mist.start(...)` actually starts the server (spawns BEAM processes
  //      to accept TCP connections).
  // Each step returns a value that gets piped into the next.
  let assert Ok(_) =
    handler
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  wisp.log_info("Server started on http://localhost:8000")

  // SLEEP FOREVER: The main function on the BEAM would exit after this line,
  // which would cause the VM to shut down (since there's nothing left to do in
  // the main process). `process.sleep_forever()` blocks this process indefinitely,
  // keeping the VM — and thus all the spawned server processes — alive.
  // The actual HTTP serving happens in separate BEAM processes managed by mist.
  process.sleep_forever()
}

// ----------------------------------------------------------
// HELPER FUNCTIONS
// ----------------------------------------------------------

// Returns the path to this OTP application's `priv/` directory.
// `priv/` is a standard Erlang convention for "private" static data
// (configuration files, data files, templates, etc.) shipped with the app.
//
// `let assert Ok(priv) = ...` will panic if the priv directory can't be found,
// which would mean the app is misconfigured — a reasonable crash-early approach.
fn priv_directory() -> String {
  let assert Ok(priv) = wisp.priv_directory("server")
  priv
}

// Returns the path to the static files directory (CSS, JS, etc.) that the
// HTTP server will serve to browsers.
fn static_directory() -> String {
  priv_directory() <> "/static"
}

// Unwraps a Result(String, Nil), panicking with a helpful message if it's Error.
// Used for REQUIRED environment variables — we can't run without them.
//
// NOTE: `name` is the second parameter, but when called via the pipe operator
// (`envoy.get("KEY") |> unwrap_env("KEY")`), the piped value becomes the FIRST
// argument (`result`), and "KEY" is the second. This is why the order matters.
fn unwrap_env(result: Result(String, Nil), name: String) -> String {
  case result {
    Ok(val) -> val
    Error(Nil) ->
      // `panic as { expr }` evaluates `expr` (a String here) and uses it as
      // the panic message. The braces `{}` form a block expression.
      panic as { "Missing required env var: " <> name }
  }
}

// Unwraps a Result(String, Nil), returning `default` if it's Error.
// Used for OPTIONAL environment variables that have sensible defaults.
fn ok_or(result: Result(String, Nil), default: String) -> String {
  case result {
    Ok(val) -> val
    Error(Nil) -> default
  }
}
