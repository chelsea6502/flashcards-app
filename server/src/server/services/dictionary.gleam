// ============================================================
// services/dictionary.gleam — Dictionary Actor
// ============================================================
//
// This module implements the dictionary lookup service as an OTP Actor.
//
// OTP ACTORS ON THE BEAM:
// OTP (Open Telecom Platform) is a set of design principles and libraries for
// building concurrent, fault-tolerant BEAM applications. An "actor" is a
// long-lived BEAM process that:
//   1. Holds some private state (here: the parsed CEDICT dictionary in memory)
//   2. Receives messages in a loop
//   3. Handles each message, possibly updating state and/or sending replies
//   4. Runs concurrently with everything else — no locks needed!
//
// WHY AN ACTOR FOR THE DICTIONARY?
// The CEDICT file is ~60MB and takes a moment to parse. We parse it ONCE at
// startup into a hash map, store it in an actor's state, and then every request
// can query it instantly by sending the actor a message. All requests are handled
// concurrently without any locking because each message is processed sequentially
// by the actor — the actor is its own serialization point.
//
// This is the fundamental OTP pattern: isolate mutable state inside a process.

import gleam/dict.{type Dict}
// `Dict` is Gleam's hash map type. `Dict(String, DictEntry)` maps String keys
// to DictEntry values.

import gleam/erlang/process.{type Subject}
// `Subject(Msg)` is a typed reference to a BEAM process's mailbox.

import gleam/list
import gleam/otp/actor
// The `actor` module provides Gleam's idiomatic OTP GenServer wrapper.
// It abstracts the raw Erlang gen_server behaviour into a type-safe API.

import server/util/cedict_parser
import shared/types.{type DictEntry}
// `DictEntry` is a shared type (used by both client and server) that holds
// the parsed data for one dictionary entry: traditional, simplified, pinyin, definitions.

import simplifile
// `simplifile` is a cross-platform file I/O library for Gleam.

// ----------------------------------------------------------
// MESSAGE TYPE
// ----------------------------------------------------------
// Every actor defines a `Msg` type that enumerates ALL the messages it can
// receive. This is Gleam's equivalent of defining the "API" of the actor.
//
// `pub type Msg` makes the type available to other modules (the context and
// handlers need to reference it).
pub type Msg {
  // `Lookup` is the only message this actor understands.
  // It carries two pieces of data:
  //   - `word`: the Chinese word to look up (String)
  //   - `reply`: a Subject to send the result back to
  //
  // THE REPLY SUBJECT PATTERN: This is how request-response works in the actor
  // model. The sender creates a temporary `Subject` (a one-shot mailbox), puts
  // it in the message, and then waits for a reply on that subject. The actor
  // sends the result to that reply subject. This is similar to a "callback" or
  // "promise" but expressed as a typed mailbox.
  //
  // LABELED FIELDS: `word:` and `reply:` are field labels. When constructing:
  //   `Lookup(word: "你好", reply: my_subject)`
  // and when destructuring in a case expression:
  //   `Lookup(word, reply)` — binds to local variables `word` and `reply`
  Lookup(word: String, reply: Subject(Result(DictEntry, Nil)))
}

// ----------------------------------------------------------
// STATE TYPE
// ----------------------------------------------------------
// The actor's private state — what it "remembers" between messages.
// Here it's just a wrapper around the dictionary map.
//
// We define it as a record (struct) rather than using `Dict` directly because:
// 1. It's more self-documenting
// 2. Easy to add more state fields later without changing the message handling code
pub type DictState {
  DictState(entries: Dict(String, DictEntry))
}

// ----------------------------------------------------------
// START FUNCTION
// ----------------------------------------------------------
// `start` is the public API to launch the dictionary actor. It:
//   1. Reads the CEDICT file from disk
//   2. Parses it into a list of DictEntry values
//   3. Builds a hash map for O(1) lookups
//   4. Spawns an OTP actor process with that map as its initial state
//   5. Returns a `Subject(Msg)` that callers use to send messages to the actor
//
// Return type: `Result(Subject(Msg), String)`
//   - `Ok(subject)` if everything worked — the subject is the actor's "address"
//   - `Error(message)` if the file couldn't be read or the actor failed to start
pub fn start(cedict_path: String) -> Result(Subject(Msg), String) {
  case simplifile.read(cedict_path) {
    Ok(contents) -> {
      // Parse the raw file contents into a List(DictEntry).
      let entries = cedict_parser.parse(contents)

      // Build a Dict(String, DictEntry) for fast lookups by word.
      let lookup_map = build_lookup(entries)

      // Wrap the map in our state type.
      let state = DictState(entries: lookup_map)

      // ACTOR CREATION (builder pattern):
      // `actor.new(state)` creates an actor builder with the initial state.
      // `|> actor.on_message(handle_message)` registers the message handler function.
      // `|> actor.start` actually spawns the BEAM process and starts the message loop.
      //
      // This is a PIPELINE of builder calls — each returns a modified builder,
      // and `actor.start` consumes the builder and produces the running actor.
      case actor.new(state) |> actor.on_message(handle_message) |> actor.start {
        Ok(started) ->
          // `started` is an `actor.Started` record. `.data` is the `Subject(Msg)` —
          // the typed mailbox address we'll use to send messages to this actor.
          Ok(started.data)
        Error(_) -> Error("Failed to start dictionary actor")
      }
    }
    Error(_) -> Error("Failed to read CEDICT file: " <> cedict_path)
  }
}

// ----------------------------------------------------------
// BUILD LOOKUP MAP
// ----------------------------------------------------------
// Converts a list of dictionary entries into a Dict keyed by both the
// simplified AND traditional forms of each word.
//
// Why index both? Chinese users might search by either form. By inserting each
// entry under two keys, a single Dict.get() call handles both cases.
fn build_lookup(entries: List(DictEntry)) -> Dict(String, DictEntry) {
  // `list.fold` is like `reduce` in JavaScript or `foldl` in Haskell.
  // It iterates over `entries`, carrying an accumulator (`acc`) through each step.
  // We start with an empty dict and insert each entry twice (simplified + traditional).
  //
  // ANONYMOUS FUNCTION: `fn(acc, entry) { ... }` is a lambda/closure.
  // Gleam closures capture variables from the surrounding scope by value.
  entries
  |> list.fold(dict.new(), fn(acc, entry) {
    acc
    // Insert this entry under the simplified Chinese characters.
    |> dict.insert(entry.simplified, entry)
    // Insert the SAME entry under the traditional Chinese characters too.
    // If simplified == traditional (for many characters), this just overwrites
    // the same key with the same value — harmless.
    |> dict.insert(entry.traditional, entry)
  })
}

// ----------------------------------------------------------
// MESSAGE HANDLER
// ----------------------------------------------------------
// This function is called by the actor runtime for EVERY message the actor receives.
// It runs in the actor's own BEAM process — completely isolated from request handler
// processes. No shared memory, no race conditions.
//
// Parameters:
//   - `state`: the actor's current state (our dictionary map)
//   - `msg`: the message that was sent to this actor
//
// Return type: `actor.Next(DictState, Msg)`
//   This tells the actor runtime what to do next:
//   - `actor.continue(new_state)` — keep running with this (possibly updated) state
//   - `actor.stop(reason)` — shut down the actor
fn handle_message(
  state: DictState,
  msg: Msg,
) -> actor.Next(DictState, Msg) {
  // Pattern match on the message type. Since `Msg` only has one variant
  // (`Lookup`), there's only one case. If we added more message types later,
  // the compiler would warn us to handle them here.
  case msg {
    Lookup(word, reply) -> {
      // Look up the word in our dictionary map.
      // `dict.get` returns `Result(DictEntry, Nil)`:
      //   - `Ok(entry)` if the word was found
      //   - `Error(Nil)` if not (Gleam uses `Nil` as the error for "not found")
      let result = dict.get(state.entries, word)

      // Send the result back to the caller via the reply Subject they provided.
      // `process.send(subject, value)` delivers `value` to the mailbox of the
      // process waiting on `subject`. This is non-blocking — the actor doesn't
      // wait for the caller to receive it.
      process.send(reply, result)

      // `actor.continue(state)` tells the runtime: "keep this actor running,
      // the state hasn't changed". Since dictionary lookups are read-only, we
      // always return the same state. If we were updating state (e.g., a counter),
      // we'd pass the new state here instead.
      actor.continue(state)
    }
  }
}

// ----------------------------------------------------------
// PUBLIC LOOKUP API
// ----------------------------------------------------------
// This is the convenient public function that OTHER modules use to query the
// dictionary. It hides the actor message-passing details behind a clean API.
//
// `actor.call` is a synchronous "send and wait" operation:
//   1. It creates a temporary reply Subject
//   2. Calls the provided function to build the message (including the reply Subject)
//   3. Sends the message to `dict_actor`
//   4. Blocks the CALLING process until a reply arrives (or timeout)
//   5. Returns whatever was sent to the reply Subject
//
// `waiting: 5000` — timeout in milliseconds. If no reply arrives in 5 seconds,
//   `actor.call` will crash the calling process (this is the BEAM's approach:
//   fail fast rather than hang forever).
//
// `sending: fn(reply) { Lookup(word, reply) }` — a function that takes the
//   auto-generated reply Subject and wraps it in our `Lookup` message.
//   `actor.call` calls this function internally with the reply Subject.
//
// This pattern (call with a function that builds the message) is how gleam/otp
// handles typed request-response while keeping the `Lookup` constructor private
// to this module if desired.
pub fn lookup(
  dict_actor: Subject(Msg),
  word: String,
) -> Result(DictEntry, Nil) {
  actor.call(dict_actor, waiting: 5000, sending: fn(reply) {
    Lookup(word, reply)
  })
}
