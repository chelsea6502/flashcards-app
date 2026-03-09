// ============================================================
// util/pinyin.gleam — Pinyin Tone Conversion
// ============================================================
//
// Pinyin is the standard romanization system for Mandarin Chinese. Each syllable
// has a tone number (1-4, plus 5 for neutral/light tone). For example:
//   "ni3 hao3" = 你好 (nǐ hǎo, "hello")
//
// CEDICT stores pinyin with tone NUMBERS (e.g., "liao3 jie3").
// For display, we want tone MARKS — diacritical marks over vowels (e.g., "liǎo jiě").
// For color-coded HTML display, we want each syllable in a `<span class="toneN">` tag.
//
// This module implements the conversion algorithm. The key challenge is knowing
// WHICH vowel to put the tone mark on — there are specific rules (see below).
//
// TONE PLACEMENT RULES (official pinyin rules):
//   1. If there's an 'a' or 'e', it gets the mark (e.g., hao → hāo, bei → bēi)
//   2. If there's 'ou', the 'o' gets the mark (e.g., gou → gǒu)
//   3. Otherwise, the LAST vowel gets the mark (e.g., gui → guì, liu → liú)
//
// The functions are organized from public (high-level) to private (low-level).

import gleam/int
// `int.to_string` for converting tone numbers to strings (for HTML class names).

import gleam/list
// List processing: `list.map`, `list.fold`, `list.filter`, `list.index_map`,
// `list.contains`, `list.last`.

import gleam/string
// String utilities: `string.split`, `string.join`, `string.to_graphemes`,
// `string.trim`, `string.last`, `string.concat`, etc.

// ----------------------------------------------------------
// PUBLIC API
// ----------------------------------------------------------

/// Convert numbered pinyin like "liao3 jie3" to tone-marked "liǎo jiě"
///
/// Triple-slash comments (`///`) are Gleam doc comments. They appear in
/// generated documentation (like JSDoc or rustdoc). Regular `//` comments are
/// not included in generated docs.
///
/// This function handles space-separated syllables by splitting on spaces,
/// converting each syllable individually, then re-joining.
pub fn to_tone_marks(numbered: String) -> String {
  numbered
  |> string.split(" ")
  // Split "liao3 jie3" into ["liao3", "jie3"]
  |> list.map(syllable_to_marks)
  // Convert each syllable: "liao3" → "liǎo"
  |> string.join(" ")
  // Re-join with spaces: ["liǎo", "jiě"] → "liǎo jiě"
}

/// Convert numbered pinyin to HTML with tone-colored spans
/// e.g. "liao3 jie3" -> "<span class=\"tone3\">liǎo</span> <span class=\"tone3\">jiě</span>"
///
/// The CSS classes tone1–tone5 are defined in the frontend stylesheet to
/// color-code tones (tone1=red, tone2=orange, tone3=green, etc. — conventional).
///
/// Note: The input may contain `<b>` tags from the LLM (marking the target word).
/// `string.split(" ")` will put `<b>` as its own "syllable" and it will pass
/// through `syllable_to_html` essentially unchanged (it has no tone number).
pub fn to_tone_html(numbered: String) -> String {
  numbered
  |> string.split(" ")
  |> list.map(syllable_to_html)
  |> string.join(" ")
}

// ----------------------------------------------------------
// SYLLABLE CONVERSION
// ----------------------------------------------------------

// Wraps a single syllable in a tone-colored HTML span.
// e.g., "liao3" → `<span class="tone3">liǎo</span>`
fn syllable_to_html(syllable: String) -> String {
  let tone = get_tone_number(syllable)
  let marked = syllable_to_marks(syllable)
  // String concatenation with `<>` to build the HTML tag.
  "<span class=\"tone"
  <> int.to_string(tone)
  <> "\">"
  <> marked
  <> "</span>"
}

// Extract the tone number from a syllable by looking at its last character.
// Returns 1-4 for tones 1-4, and 5 for neutral/light tone (or unrecognized).
//
// `string.last(str)` returns `Result(String, Nil)` — the last grapheme, or
// Error if the string is empty. We use this because Gleam strings are UTF-8
// and `string.last` safely handles multi-byte characters.
fn get_tone_number(syllable: String) -> Int {
  let trimmed = string.trim(syllable)
  // Pattern match on the last character of the syllable.
  // `Ok("1")` means the last char IS the string "1", etc.
  // The `_` wildcard matches any other last character (or Error if empty).
  case string.last(trimmed) {
    Ok("1") -> 1
    Ok("2") -> 2
    Ok("3") -> 3
    Ok("4") -> 4
    Ok("5") -> 5
    // Neutral tone explicitly marked as 5 in some systems
    _ -> 5
    // Default to neutral tone for anything else (HTML tags, punctuation, etc.)
  }
}

// Convert a single syllable from numbered to tone-marked form.
// e.g., "liao3" → "liǎo",  "ma5" → "ma",  "Zhong1" → "Zhōng"
fn syllable_to_marks(syllable: String) -> String {
  let trimmed = string.trim(syllable)
  let tone = get_tone_number(trimmed)
  case tone {
    5 ->
      // Tone 5 (neutral) gets no mark — just strip the trailing number.
      strip_tone_number(trimmed)
    _ -> {
      // For tones 1-4: strip the number, then find and replace the right vowel.
      let base = strip_tone_number(trimmed)
      apply_tone_mark(base, tone)
    }
  }
}

// ----------------------------------------------------------
// TONE NUMBER STRIPPING
// ----------------------------------------------------------

// Remove the trailing tone digit (1-5) from a pinyin syllable.
// e.g., "liao3" → "liao",  "ma5" → "ma",  "zhong" → "zhong" (unchanged)
//
// `string.last(s)` returns `Result(String, Nil)`.
// The `|` in patterns is "or" — multiple patterns that map to the same branch.
// This is called "pattern alternatives" in Gleam.
fn strip_tone_number(s: String) -> String {
  let last = string.last(s)
  case last {
    // If the last character is a digit 1-5, remove it.
    // `string.drop_end(s, 1)` removes the last 1 character from s.
    Ok("1") | Ok("2") | Ok("3") | Ok("4") | Ok("5") -> string.drop_end(s, 1)
    // Otherwise (no tone number, or empty string), return unchanged.
    _ -> s
  }
}

// ----------------------------------------------------------
// TONE MARK APPLICATION
// ----------------------------------------------------------

// Apply a tone diacritic to the appropriate vowel in a base syllable.
// e.g., apply_tone_mark("liao", 3) → "liǎo"
fn apply_tone_mark(base: String, tone: Int) -> String {
  // `string.to_graphemes` splits the string into a list of Unicode grapheme
  // clusters. A "grapheme" is what a user perceives as a single character —
  // this matters for Unicode where some characters are multi-code-point.
  // For pinyin, most characters are simple ASCII, but "ü" needs special care.
  let graphemes = string.to_graphemes(base)

  // Find which index in the grapheme list should receive the tone mark.
  let vowel_idx = find_tone_vowel(graphemes)

  case vowel_idx {
    Ok(idx) ->
      // We found the vowel at position `idx` — replace it with the tone-marked version.
      replace_at(graphemes, idx, tone)
    Error(Nil) ->
      // No vowel found (shouldn't happen with valid pinyin, but handle gracefully).
      base
  }
}

// ----------------------------------------------------------
// TONE VOWEL FINDING (PLACEMENT RULES)
// ----------------------------------------------------------

// Find the index of the grapheme that should receive the tone mark,
// following official pinyin tone placement rules.
fn find_tone_vowel(graphemes: List(String)) -> Result(Int, Nil) {
  // RULE 1: If there's an 'a' or 'e', it ALWAYS gets the tone mark.
  // These are the "open" vowels and always take priority.
  // `find_index` returns `Result(Int, Nil)` — Ok(index) or Error(Nil) if not found.
  case find_index(graphemes, fn(g) { g == "a" || g == "A" }) {
    Ok(idx) -> Ok(idx)
    // 'a' not found — try 'e'
    Error(Nil) ->
      case find_index(graphemes, fn(g) { g == "e" || g == "E" }) {
        Ok(idx) -> Ok(idx)
        // 'e' not found — try 'o' (for the "ou" rule and others)
        Error(Nil) ->
          // RULE 2: If there's an 'o', it gets the mark.
          // This handles "ou" (o gets it, not u) and other o-syllables.
          // NOTE: The original CEDICT rules strictly say "ou" → o gets it,
          // but in practice this simpler rule (find 'o' first) works for
          // all common pinyin syllables containing 'o'.
          case find_index(graphemes, fn(g) { g == "o" || g == "O" }) {
            Ok(idx) -> Ok(idx)
            // RULE 3: No a, e, or o — the LAST vowel gets the mark.
            // This handles syllables like "gui" (last vowel = i),
            // "liu" (last vowel = u), "lü" (last vowel = ü), etc.
            Error(Nil) ->
              find_last_vowel(graphemes)
          }
      }
  }
}

// Find the index of the last vowel in a grapheme list.
// Returns Error(Nil) if there are no vowels (shouldn't happen with valid pinyin).
fn find_last_vowel(graphemes: List(String)) -> Result(Int, Nil) {
  // List of all vowel graphemes we recognize (including uppercase and ü).
  let vowels = ["a", "e", "i", "o", "u", "ü", "A", "E", "I", "O", "U", "Ü"]

  // `list.index_map(list, fn(elem, idx) {...})` maps over the list with both
  // the element AND its 0-based index available. Returns a new list of whatever
  // the function returns.
  //
  // We produce a list of `#(grapheme, index)` pairs, then filter to keep only
  // the vowel pairs, then take the last one.
  let last =
    graphemes
    |> list.index_map(fn(g, i) { #(g, i) })
    // `list.filter` keeps only elements where the predicate returns True.
    // `pair.0` accesses the first element of the tuple (the grapheme string).
    |> list.filter(fn(pair) { list.contains(vowels, pair.0) })
    // `list.last` returns the last element, or Error(Nil) if the list is empty.
    |> list.last

  // Destructure the result tuple to extract just the index.
  case last {
    Ok(#(_, idx)) -> Ok(idx)
    // `#(_, idx)` matches a 2-tuple, discarding the first element (grapheme)
    // and binding the second (index) to `idx`.
    Error(Nil) -> Error(Nil)
  }
}

// ----------------------------------------------------------
// INDEX FINDING
// ----------------------------------------------------------

// Find the index of the first element in a list satisfying `predicate`.
// Returns Ok(index) or Error(Nil) if no element matches.
//
// TYPE PARAMETER: `a` in `List(a)` and `fn(a) -> Bool` is a generic type
// parameter — this function works for lists of any type. Gleam infers the
// concrete type from the call site. This is lowercase by convention (unlike
// concrete types like String, Int which are capitalized).
fn find_index(
  items: List(a),
  predicate: fn(a) -> Bool,
) -> Result(Int, Nil) {
  // Delegate to the recursive helper, starting at index 0.
  find_index_helper(items, predicate, 0)
}

// Recursive helper for find_index.
// Gleam has no loops — iteration is done with recursion.
// The BEAM optimizes "tail-recursive" calls (where the recursive call is the
// very last thing in a branch) into a loop, so there's no stack overflow risk.
fn find_index_helper(
  items: List(a),
  predicate: fn(a) -> Bool,
  idx: Int,
) -> Result(Int, Nil) {
  // Pattern match on the list.
  // In Gleam, lists are singly-linked. `[first, ..rest]` is the "cons" pattern:
  // it matches a non-empty list, binding `first` to the head element and `rest`
  // to the tail (the rest of the list, which is itself a List).
  case items {
    // BASE CASE: empty list — we've checked everything, nothing matched.
    [] -> Error(Nil)
    // RECURSIVE CASE: at least one element.
    [first, ..rest] ->
      case predicate(first) {
        // The current element matches — return its index.
        True -> Ok(idx)
        // Doesn't match — recurse into the rest of the list with idx + 1.
        // This is a tail call (the recursive call is the last thing we do here),
        // so the BEAM will optimize it to not grow the call stack.
        False -> find_index_helper(rest, predicate, idx + 1)
      }
  }
}

// ----------------------------------------------------------
// REPLACEMENT
// ----------------------------------------------------------

// Replace the grapheme at position `idx` with its tone-marked version.
// All other graphemes are kept as-is.
fn replace_at(graphemes: List(String), idx: Int, tone: Int) -> String {
  graphemes
  // `list.index_map` gives us both the grapheme and its index.
  // We check if this is the target index — if so, apply the mark; otherwise keep as-is.
  |> list.index_map(fn(g, i) {
    case i == idx {
      True -> apply_mark_to_vowel(g, tone)
      // Replace this vowel with its tone-marked form.
      False -> g
      // Keep all other graphemes unchanged.
    }
  })
  // `string.concat` joins a List(String) into a single String (no separator).
  // e.g., ["l", "ǐ", "a", "o"] → "liǎo" (well, after the mark is applied, "liǎo")
  |> string.concat
}

// ----------------------------------------------------------
// VOWEL-TO-TONE-MARK LOOKUP TABLE
// ----------------------------------------------------------
// Map each (vowel, tone) combination to the Unicode character with that diacritic.
// This uses a MULTI-ARGUMENT CASE expression — Gleam can match on a tuple of
// values simultaneously: `case vowel, tone { "a", 1 -> "ā" ... }`.
// This is equivalent to nested case expressions but more concise.
//
// The `_, _` wildcard at the end catches any combination we don't handle
// (e.g., consonants that somehow got here, or tone 5 which should have been
// stripped already) and returns the vowel unchanged.
fn apply_mark_to_vowel(vowel: String, tone: Int) -> String {
  case vowel, tone {
    // Tone 1 (flat/high): macron ā ē ī ō ū ǖ
    "a", 1 -> "ā"
    "a", 2 -> "á"
    "a", 3 -> "ǎ"
    "a", 4 -> "à"
    "e", 1 -> "ē"
    "e", 2 -> "é"
    "e", 3 -> "ě"
    "e", 4 -> "è"
    "i", 1 -> "ī"
    "i", 2 -> "í"
    "i", 3 -> "ǐ"
    "i", 4 -> "ì"
    "o", 1 -> "ō"
    "o", 2 -> "ó"
    "o", 3 -> "ǒ"
    "o", 4 -> "ò"
    "u", 1 -> "ū"
    "u", 2 -> "ú"
    "u", 3 -> "ǔ"
    "u", 4 -> "ù"
    // ü (u-umlaut) appears in syllables like lü, nü, lüe, nüe.
    // CEDICT sometimes writes this as "u:" — that case is handled by the CEDICT
    // parser before reaching here. Here we handle the actual ü character.
    "ü", 1 -> "ǖ"
    "ü", 2 -> "ǘ"
    "ü", 3 -> "ǚ"
    "ü", 4 -> "ǜ"
    // Uppercase variants — for proper nouns (e.g., "Zhong1 guo2" for 中国)
    // Handle lu:3 style entries (CEDICT uses u: for ü)
    "A", 1 -> "Ā"
    "A", 2 -> "Á"
    "A", 3 -> "Ǎ"
    "A", 4 -> "À"
    "E", 1 -> "Ē"
    "E", 2 -> "É"
    "E", 3 -> "Ě"
    "E", 4 -> "È"
    "I", 1 -> "Ī"
    "I", 2 -> "Í"
    "I", 3 -> "Ǐ"
    "I", 4 -> "Ì"
    "O", 1 -> "Ō"
    "O", 2 -> "Ó"
    "O", 3 -> "Ǒ"
    "O", 4 -> "Ò"
    "U", 1 -> "Ū"
    "U", 2 -> "Ú"
    "U", 3 -> "Ǔ"
    "U", 4 -> "Ù"
    // Catch-all: unrecognized vowel or tone combination — return unchanged.
    // This handles any edge cases gracefully without crashing.
    _, _ -> vowel
  }
}
