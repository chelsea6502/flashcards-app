// This file is the heart of the Lustre frontend application.
//
// Lustre follows the Elm Architecture, a pattern made famous by the Elm language.
// Every Lustre app is built around three core concepts:
//
//   1. Model   — the single source of truth for all application state
//   2. Update  — a pure function that takes the current model + a message
//               and returns the next model (plus any side effects to run)
//   3. View    — a pure function that takes the current model and returns
//               an HTML element tree to render
//
// Data flows in one direction:
//   user interaction → Msg → update() → new Model → view() → HTML
//
// This makes the app easy to reason about: the UI is always a deterministic
// function of the model.

// --- Imports ---

// `import gleam/int` brings in Gleam's standard library module for integer
// utilities. We use `int.to_string` later to convert a note ID to text.
import gleam/int

// `import gleam/json` gives us tools to build JSON values (json.object,
// json.string, etc.) that we send in HTTP request bodies.
import gleam/json

// `import gleam/list` gives us list utilities. We use `list.map` to turn a
// list of warning strings into a list of HTML <li> elements.
import gleam/list

// `import lustre` is the core Lustre package. We use `lustre.application` to
// wire together init/update/view, and `lustre.start` to mount it into the DOM.
import lustre

// `import lustre/attribute as attr` imports the attribute module and gives it
// the shorter alias `attr`. The `as` keyword lets you rename any import.
// So instead of writing `attribute.class(...)` everywhere we write `attr.class(...)`.
import lustre/attribute as attr

// `effect.{type Effect}` imports the module AND brings the `Effect` type into
// scope directly. The curly-brace syntax lets you pull specific names out of a
// module so you can use them unqualified. `type Effect` means we're importing
// only the type (not a value), which is useful for type annotations.
import lustre/effect.{type Effect}

// Same pattern: import `element` module and also pull the `Element` type into
// scope so type signatures can say `Element(Msg)` instead of `element.Element(Msg)`.
import lustre/element.{type Element}

// `lustre/element/html` contains functions for every HTML tag: html.div,
// html.h1, html.button, html.input, html.textarea, etc.
// Each function takes a list of attributes and a list of child elements.
import lustre/element/html

// `lustre/event` has helpers for DOM events: event.on_click, event.on_input, etc.
// These return Lustre attributes that, when triggered, dispatch a Msg.
import lustre/event

// `rsvp` is a Gleam HTTP client library designed for Lustre. It builds
// Effect values that perform HTTP requests and then dispatch a Msg with the
// result. Think of it as "fetch, but wired into Lustre's update loop".
import rsvp

// `shared/codec` is our own module (in the `shared` package) that holds JSON
// encoders and decoders shared between the client and server.
import shared/codec

// `shared/types.{type CardDraft}` imports the `types` module and also pulls
// the `CardDraft` type into scope directly. We reference the module as
// `types.CardDraft(...)` when constructing values, and just `CardDraft` in
// type annotations.
import shared/types.{type CardDraft}

// --- Model ---
//
// The Model is the complete state of the application at any point in time.
// Lustre holds exactly one Model value. Whenever `update` returns a new Model,
// Lustre re-runs `view` and patches the DOM to match.

// `UiState` is a custom type (Gleam's version of a discriminated union / enum).
// Each variant represents a distinct phase of the app's lifecycle.
// Variants can be plain (Idle) or carry data (Success carries an Int, ErrorState carries a String).
pub type UiState {
  // Nothing is happening; the input form is visible.
  Idle
  // Waiting for the AI generation API to respond.
  Generating
  // The card draft arrived and is being shown for user review.
  Preview
  // Waiting for the Anki push API to respond.
  Pushing
  // The card was pushed successfully. We remember the note_id so we can show it.
  // Named fields on variants are written like record fields: `Success(note_id: Int)`.
  Success(note_id: Int)
  // Something went wrong. We store a human-readable message.
  ErrorState(message: String)
}

// `Model` is a record type — Gleam's equivalent of a struct.
// All fields are listed in the single constructor also named `Model`.
// The type annotation after each field name describes what it holds.
//
//   word  — the Chinese word the user typed
//   deck  — the Anki deck name the user typed
//   state — which phase we're in (see UiState above)
//   card  — either Ok(CardDraft) when we have card data, or Error(Nil) when we don't.
//           `Result(CardDraft, Nil)` is Gleam's built-in Result type:
//             Ok(value)   means success / present
//             Error(Nil)  means absent (we use Nil as a placeholder error because
//                         there's nothing meaningful to say — the card just doesn't exist yet)
pub type Model {
  Model(word: String, deck: String, state: UiState, card: Result(CardDraft, Nil))
}

// `init` is called once when the app starts. It returns the initial Model and
// any Effect to run immediately (we run none here).
//
// The `_flags` parameter (note the leading underscore — Gleam's convention for
// unused variables) is data that can be passed from JavaScript into Gleam at
// startup. We don't use it here, so its type is `Nil` (Gleam's "nothing" type).
//
// The return type `#(Model, Effect(Msg))` is a 2-tuple. Gleam tuples are written
// with `#(...)`. `update` and `init` both return this same shape so Lustre knows
// what to do next: apply the new model and schedule any effects.
fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(
    // Start with an empty word, a sensible default deck name, the Idle state,
    // and no card data yet.
    Model(word: "", deck: "Mandarin::Vocab", state: Idle, card: Error(Nil)),
    // `effect.none()` means "no side effects on startup".
    effect.none(),
  )
}

// --- Messages ---
//
// `Msg` is the set of all events the update function can receive. In the Elm
// Architecture, *everything* that can change the model must go through a Msg.
// This keeps state mutations centralised and easy to trace.
//
// Naming convention: messages are usually named after who sent them and what
// they did — e.g. `UserClickedGenerate` (the user), `GotCardDraft` (the app
// received data from the network).

pub type Msg {
  // The user typed in the word input field. Carries the new full value.
  UserUpdatedWord(String)
  // The user typed in the deck input field.
  UserUpdatedDeck(String)
  // The user clicked the "Generate" button.
  UserClickedGenerate
  // The HTTP request to /api/generate completed.
  // `Result(CardDraft, rsvp.Error)` means it either succeeded with a CardDraft
  // or failed with an rsvp.Error (network error, non-2xx status, decode failure, etc.).
  GotCardDraft(Result(CardDraft, rsvp.Error))
  // The user clicked "Push to Anki".
  UserClickedPush
  // The HTTP request to /api/push completed.
  GotPushResult(Result(types.PushResponse, rsvp.Error))
  // The user clicked "Start Over" / "Add Another".
  UserClickedReset
  // The user edited the sentence field on the preview card.
  UserEditedSentence(String)
  // The user edited the meaning field.
  UserEditedMeaning(String)
  // The user edited the notes field.
  UserEditedNotes(String)
}

// --- Update ---
//
// `update` is a pure function — it takes the current model and a message, and
// returns the *next* model along with any side effects to perform.
//
// "Pure" means it has no side effects itself: no HTTP calls, no random numbers,
// no console logs. All of that is expressed as Effect values returned in the
// tuple. Lustre runs those effects after calling update.

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  // `case` is Gleam's pattern-matching expression. It matches `msg` against
  // every variant of the Msg type. The compiler enforces exhaustiveness —
  // you *must* handle every case, or the code won't compile.
  case msg {
    // --- Record update syntax: `Model(..model, field: new_value)` ---
    //
    // `..model` means "copy all fields from the existing model record".
    // Then `word: word` overrides just that one field with the new value.
    // This is how you do immutable record updates in Gleam.
    // The model itself is never mutated; a brand-new record is returned.
    UserUpdatedWord(word) -> #(Model(..model, word: word), effect.none())

    UserUpdatedDeck(deck) -> #(Model(..model, deck: deck), effect.none())

    // When the user clicks Generate, we transition to the Generating state
    // AND kick off an HTTP request by returning the Effect from `generate_card`.
    // Lustre will run that effect, and when it completes it will dispatch a
    // GotCardDraft message back into the update loop.
    UserClickedGenerate -> #(
      Model(..model, state: Generating),
      generate_card(model.word),
    )

    // Pattern matching can destructure the inner value of a variant.
    // `GotCardDraft(Ok(card))` only matches when the result is Ok, and binds
    // the inner CardDraft to the name `card`.
    GotCardDraft(Ok(card)) -> #(
      Model(..model, state: Preview, card: Ok(card)),
      effect.none(),
    )

    // `GotCardDraft(Error(_))` matches any Error variant. The `_` means we
    // don't care about the specific error value — we just know something failed.
    GotCardDraft(Error(_)) -> #(
      Model(..model, state: ErrorState("Failed to generate card")),
      effect.none(),
    )

    // For UserClickedPush we need to check whether we actually have card data.
    // We pattern match on `model.card` (a Result) inside the outer case.
    // This is a nested case — totally normal in Gleam.
    UserClickedPush ->
      case model.card {
        Ok(card) -> #(
          Model(..model, state: Pushing),
          // Pass both the deck name and the card draft to the push effect.
          push_card(model.deck, card),
        )
        // If there's no card (shouldn't normally happen), do nothing.
        Error(Nil) -> #(model, effect.none())
      }

    // `resp.note_id` accesses the `note_id` field of the PushResponse record.
    // We store it in the Success variant so the view can display it.
    GotPushResult(Ok(resp)) -> #(
      Model(..model, state: Success(resp.note_id)),
      effect.none(),
    )

    GotPushResult(Error(_)) -> #(
      Model(..model, state: ErrorState("Failed to push to Anki")),
      effect.none(),
    )

    // Reset clears the word and card but preserves the deck name — convenient
    // so the user doesn't have to retype it when adding the next card.
    UserClickedReset -> #(
      Model(word: "", deck: model.deck, state: Idle, card: Error(Nil)),
      effect.none(),
    )

    // For the three editable fields, we need to update a *nested* record.
    // The pattern is:
    //   1. Check that model.card is Ok (we need a card to edit).
    //   2. Build a new CardDraft using record update syntax on `card`.
    //   3. Wrap it back in Ok(...) and store it in the model.
    //
    // `types.CardDraft(..card, sentence: s)` creates a new CardDraft with all
    // fields from `card` except `sentence`, which gets the new value `s`.
    UserEditedSentence(s) ->
      case model.card {
        Ok(card) -> #(
          Model(..model, card: Ok(types.CardDraft(..card, sentence: s))),
          effect.none(),
        )
        Error(Nil) -> #(model, effect.none())
      }

    UserEditedMeaning(m) ->
      case model.card {
        Ok(card) -> #(
          Model(..model, card: Ok(types.CardDraft(..card, target_meaning: m))),
          effect.none(),
        )
        Error(Nil) -> #(model, effect.none())
      }

    UserEditedNotes(n) ->
      case model.card {
        Ok(card) -> #(
          Model(..model, card: Ok(types.CardDraft(..card, notes: n))),
          effect.none(),
        )
        Error(Nil) -> #(model, effect.none())
      }
  }
}

// --- Effects ---
//
// Effects are values that *describe* a side effect without executing it.
// Lustre executes them after `update` returns. When the async work finishes,
// the Effect dispatches a Msg back into the update loop.
//
// This keeps `update` pure: it never does I/O directly, only returns
// descriptions of I/O as Effect values.

// `generate_card` builds an HTTP POST request to /api/generate.
// It returns an `Effect(Msg)`, not a response — the actual request happens
// asynchronously after this function returns.
fn generate_card(word: String) -> Effect(Msg) {
  // Build a JSON object body: `{"word": "<word>"}`.
  // `json.object` takes a list of key-value pairs (#(key, json_value) tuples).
  // `json.string` wraps a Gleam String into a JSON string value.
  let body = json.object([#("word", json.string(word))])

  // `rsvp.post` creates an Effect that will:
  //   1. Send a POST request to "/api/generate" with `body` as the JSON body.
  //   2. When the response arrives, decode the JSON using `codec.card_draft_decoder()`.
  //   3. Wrap the decoded value (or error) in a `GotCardDraft(...)` message.
  //   4. Dispatch that message into the Lustre update loop.
  //
  // `rsvp.expect_json(decoder, msg_constructor)` wires together the decoder
  // and the message constructor. `GotCardDraft` is a function
  // `Result(CardDraft, rsvp.Error) -> Msg`, which is exactly what rsvp needs.
  rsvp.post(
    "/api/generate",
    body,
    rsvp.expect_json(codec.card_draft_decoder(), GotCardDraft),
  )
}

// `push_card` builds an HTTP POST to /api/push.
// It takes the deck name and the full CardDraft record.
fn push_card(deck: String, card: CardDraft) -> Effect(Msg) {
  // Build the request body: `{"deck": "...", "card": {...}}`.
  // `codec.encode_card_draft(card)` converts the CardDraft record into a JSON
  // value using our shared encoder.
  let body =
    json.object([
      #("deck", json.string(deck)),
      #("card", codec.encode_card_draft(card)),
    ])
  rsvp.post(
    "/api/push",
    body,
    // When the response arrives, decode it as a PushResponse and dispatch
    // GotPushResult with the result.
    rsvp.expect_json(codec.push_response_decoder(), GotPushResult),
  )
}

// --- View ---
//
// The view is a pure function from Model to an Element tree. Lustre calls it
// every time the model changes and efficiently patches the real DOM.
//
// Lustre elements are *values* — ordinary Gleam data. They describe what the
// DOM should look like, but don't create or mutate actual DOM nodes themselves.
// Lustre diffs the old and new element trees and applies minimal DOM patches.

// `view` is the root view function. It always renders the page title and then
// delegates the main content to sub-views based on `model.state`.
fn view(model: Model) -> Element(Msg) {
  // `html.div` renders a <div>. The first argument is a list of attributes
  // (here just the CSS class), the second is a list of child elements.
  html.div([attr.class("container")], [
    // `html.h1([], [...])` — the first `[]` is an empty attribute list,
    // the second contains child elements. `element.text("...")` creates a
    // text node (no surrounding tag).
    html.h1([], [element.text("Mandarin Flashcard Generator")]),
    // Here we branch on `model.state` to decide which sub-view to render.
    // Each arm of the case expression returns an `Element(Msg)`, so they're
    // all valid children of the outer div.
    case model.state {
      Idle -> view_input_form(model)
      Generating -> view_loading("Generating flashcard...")
      Preview -> view_preview(model)
      Pushing -> view_loading("Pushing to Anki...")
      // Pattern matching can extract the data carried by a variant.
      // `Success(note_id)` binds the Int to `note_id` and passes it along.
      Success(note_id) -> view_success(note_id)
      // Same here: extract the message string from ErrorState.
      ErrorState(message) -> view_error(message)
    },
  ])
}

// `view_input_form` renders the initial word/deck input form.
// It receives the whole model so it can read `model.word` and `model.deck`
// to pre-populate the inputs.
fn view_input_form(model: Model) -> Element(Msg) {
  html.div([attr.class("input-form")], [
    html.div([attr.class("field")], [
      html.label([], [element.text("Chinese Word")]),
      // `html.input` is a void element in HTML (no children), but in Lustre
      // it still takes two lists: attributes and children (children will be empty).
      html.input([
        // `attr.type_("text")` — note the trailing underscore. In Gleam,
        // `type` is a reserved keyword, so the library adds `_` to avoid
        // the collision. This is a common Gleam convention.
        attr.type_("text"),
        // `attr.value` sets the input's value attribute, keeping it in sync
        // with the model (controlled input pattern).
        attr.value(model.word),
        attr.placeholder("e.g. 了解"),
        // `event.on_input` fires whenever the user types. It dispatches
        // `UserUpdatedWord(newValue)` into the update loop on every keystroke.
        event.on_input(UserUpdatedWord),
        attr.class("word-input"),
      ]),
    ]),
    html.div([attr.class("field")], [
      html.label([], [element.text("Deck")]),
      html.input([
        attr.type_("text"),
        attr.value(model.deck),
        event.on_input(UserUpdatedDeck),
      ]),
    ]),
    // `event.on_click(UserClickedGenerate)` dispatches the `UserClickedGenerate`
    // message (no payload) when the button is clicked.
    html.button(
      [event.on_click(UserClickedGenerate), attr.class("btn primary")],
      [element.text("Generate")],
    ),
  ])
}

// `view_loading` is a simple spinner + message component reused for both
// the Generating and Pushing states.
fn view_loading(message: String) -> Element(Msg) {
  html.div([attr.class("loading")], [
    // An empty div styled as a CSS spinner — no Gleam children needed.
    html.div([attr.class("spinner")], []),
    html.p([], [element.text(message)]),
  ])
}

// `view_preview` shows the generated card and lets the user edit some fields
// before pushing to Anki.
fn view_preview(model: Model) -> Element(Msg) {
  // We need to unwrap `model.card` because it's a `Result`. In the Preview
  // state it should always be `Ok`, but Gleam's type system requires us to
  // handle both branches explicitly — there's no way to skip the Error case.
  case model.card {
    Ok(card) ->
      html.div([attr.class("card-preview")], [
        // `card_field` is a helper defined below that renders a read-only label+value pair.
        card_field("Target Word", element.text(card.target_word)),
        // Pinyin fields contain HTML (tone-colored <span> tags), so we use
        // `innerHTML` via a Lustre attribute to render them as actual HTML
        // rather than escaped text.
        html_field("Pinyin", card.target_pinyin),
        // `editable_field` renders a label + text input. We pass the message
        // constructor `UserEditedMeaning` as a callback — it's a first-class
        // function value in Gleam, just like any other value.
        editable_field("Meaning", card.target_meaning, UserEditedMeaning),
        editable_textarea("Sentence", card.sentence, UserEditedSentence),
        html_field("Sentence Pinyin", card.sentence_pinyin),
        card_field("Sentence Meaning", element.text(card.sentence_meaning)),
        editable_textarea("Notes", card.notes, UserEditedNotes),
        view_audio("Word Audio", card.word_audio_base64),
        view_audio("Sentence Audio", card.sentence_audio_base64),
        // Image preview — only shown if image data exists
        view_image(card.image_base64),
        // Show any AI-generated warnings (e.g. "unusual usage") or nothing.
        view_warnings(card.warnings),
        html.div([attr.class("actions")], [
          html.button(
            [event.on_click(UserClickedPush), attr.class("btn primary")],
            [element.text("Push to Anki")],
          ),
          html.button(
            [event.on_click(UserClickedReset), attr.class("btn secondary")],
            [element.text("Start Over")],
          ),
        ]),
      ])
    // This branch should never be reached in normal usage, but Gleam's
    // exhaustive pattern matching requires us to handle it.
    Error(Nil) -> html.div([], [element.text("No card data")])
  }
}

// `card_field` is a small helper that renders a read-only label/value pair.
// It accepts `content` as an already-built `Element(Msg)` rather than a raw
// string, which makes it flexible — callers can pass `element.text(...)` or
// any other element as the value.
fn card_field(label: String, content: Element(Msg)) -> Element(Msg) {
  html.div([attr.class("card-field")], [
    html.label([], [element.text(label)]),
    html.div([attr.class("value")], [content]),
  ])
}

// `html_field` renders a label + raw HTML content. This is used for pinyin
// fields that contain <span> tags with tone color classes.
// `element.unsafe_raw_html` tells Lustre to set innerHTML directly rather
// than escaping the content as text.
fn html_field(label: String, html_content: String) -> Element(Msg) {
  html.div([attr.class("card-field")], [
    html.label([], [element.text(label)]),
    html.div([attr.class("value")], [
      element.unsafe_raw_html("", "span", [], html_content),
    ]),
  ])
}

fn view_audio(label: String, audio_base64: String) -> Element(Msg) {
  case audio_base64 {
    "" -> html.div([attr.class("card-field")], [
      html.label([], [element.text(label)]),
      html.div([attr.class("value muted")], [element.text("No audio available")]),
    ])
    data ->
      html.div([attr.class("card-field")], [
        html.label([], [element.text(label)]),
        html.div([attr.class("value")], [
          html.audio([attr.attribute("controls", ""), attr.attribute("src", "data:audio/mp3;base64," <> data)], []),
        ]),
      ])
  }
}

// `view_image` renders an image preview if image data exists.
fn view_image(image_base64: String) -> Element(Msg) {
  case image_base64 {
    "" -> html.div([attr.class("card-field")], [
      html.label([], [element.text("Image")]),
      html.div([attr.class("value muted")], [element.text("No image available")]),
    ])
    data ->
      html.div([attr.class("card-field")], [
        html.label([], [element.text("Image")]),
        html.div([attr.class("value image-preview")], [
          html.img([attr.src("data:image/png;base64," <> data), attr.alt("Generated illustration")]),
        ]),
      ])
  }
}

// `editable_field` renders a label + single-line text input.
//
// `on_input: fn(String) -> Msg` is a *function type* annotation. This parameter
// accepts any function that takes a String and returns a Msg. In practice we
// pass variant constructors like `UserEditedMeaning`, which Gleam treats as
// functions automatically — `UserEditedMeaning` has type `fn(String) -> Msg`.
fn editable_field(
  label: String,
  value: String,
  on_input: fn(String) -> Msg,
) -> Element(Msg) {
  html.div([attr.class("card-field editable")], [
    html.label([], [element.text(label)]),
    html.input([
      attr.type_("text"),
      attr.value(value),
      // We pass `on_input` (the function we received) directly to event.on_input.
      // event.on_input will call it with the new string value each time the user types.
      event.on_input(on_input),
    ]),
  ])
}

// `editable_textarea` is the multi-line version of `editable_field`.
// `html.textarea` takes attributes and a String content (unlike most elements
// which take a list of child elements).
fn editable_textarea(
  label: String,
  value: String,
  on_input: fn(String) -> Msg,
) -> Element(Msg) {
  html.div([attr.class("card-field editable")], [
    html.label([], [element.text(label)]),
    html.textarea([event.on_input(on_input)], value),
  ])
}

// `view_warnings` renders a warning list, or nothing if there are no warnings.
// `List(String)` is Gleam's generic list type — a linked list of strings here.
fn view_warnings(warnings: List(String)) -> Element(Msg) {
  case warnings {
    // `[]` is the pattern for an empty list. If there are no warnings we
    // return `element.none()`, which renders nothing at all in the DOM.
    [] -> element.none()
    // `_` matches any non-empty list (we don't need to destructure it).
    _ ->
      html.div([attr.class("warnings")], [
        html.ul(
          [],
          // `list.map` transforms every element of a list using a function.
          // Here we turn each warning String into an <li> element.
          // The anonymous function syntax is `fn(arg) { body }`.
          list.map(warnings, fn(w) { html.li([], [element.text(w)]) }),
        ),
      ])
  }
}

// `view_success` is shown after a card is pushed successfully.
fn view_success(note_id: Int) -> Element(Msg) {
  html.div([attr.class("success")], [
    html.h2([], [element.text("Card Added!")]),
    // `<>` is Gleam's string concatenation operator.
    // `int.to_string` converts an Int to its String representation.
    html.p([], [element.text("Note ID: " <> int.to_string(note_id))]),
    html.button(
      [event.on_click(UserClickedReset), attr.class("btn primary")],
      [element.text("Add Another")],
    ),
  ])
}

// `view_error` is shown when something goes wrong (generation or push failure).
fn view_error(message: String) -> Element(Msg) {
  html.div([attr.class("error-state")], [
    html.p([], [element.text(message)]),
    html.button(
      [event.on_click(UserClickedReset), attr.class("btn secondary")],
      [element.text("Start Over")],
    ),
  ])
}

// --- Entry Point ---

// `main` is called by the Gleam/JavaScript runtime when the page loads.
// `pub` makes it visible to the outside world (other modules or the JS harness).
pub fn main() {
  // `lustre.application` wires together the three pillars of the Elm Architecture.
  // It returns an opaque App value that Lustre knows how to run.
  let app = lustre.application(init, update, view)

  // `lustre.start` mounts the app into the DOM node matching the CSS selector "#app".
  // The third argument (Nil) is the flags value passed to `init`.
  //
  // `let assert Ok(_)` is a pattern match that *crashes* if the result is Error.
  // This is intentional: if mounting fails (e.g. #app doesn't exist) there's
  // nothing useful the app can do, so panicking is the right call.
  // In production code you might handle this more gracefully.
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
