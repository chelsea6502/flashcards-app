// ============================================================
// util/cedict_parser.gleam — CEDICT File Parser
// ============================================================
//
// CEDICT is the CC-CEDICT Chinese-English dictionary — a free, community-
// maintained dictionary with ~120,000 entries. It's distributed as a plain-text
// file with one entry per line.
//
// CEDICT LINE FORMAT:
//   Traditional Simplified [pinyin] /definition1/definition2/.../
//
// Examples:
//   了解 了解 [liao3 jie3] /to understand/to know/to find out/
//   中文 中文 [Zhong1 wen2] /Chinese language/
//   你好 你好 [ni3 hao3] /Hello!/Hi!/How are you?/
//
// Lines starting with "#" are comments. Empty lines are skipped.
//
// This module has one public function: `parse`, which takes the entire file as
// a String and returns a List(DictEntry). It uses Gleam's functional list
// processing and pattern matching on strings to do the parsing.

import gleam/list
// List processing functions: `list.filter_map` is the key one here.

import gleam/string
// String functions: `string.split`, `string.split_once`, `string.starts_with`,
// `string.trim`, `string.is_empty`, `string.drop_end`.

import shared/types.{type DictEntry, DictEntry}
// `type DictEntry` imports the type alias for annotations.
// `DictEntry` (without `type`) imports the constructor so we can write
// `DictEntry(traditional: ..., simplified: ..., ...)`.

// ----------------------------------------------------------
// PUBLIC API
// ----------------------------------------------------------
// Parse the entire CEDICT file contents into a list of DictEntry values.
// Comment lines and empty lines are automatically skipped.
//
// The function is intentionally simple at the top level — it delegates the
// hard work to helper functions. This is idiomatic Gleam: keep each function
// focused on one thing.
pub fn parse(contents: String) -> List(DictEntry) {
  contents
  // Split the file into individual lines.
  // `string.split(str, delimiter)` returns a `List(String)`.
  |> string.split("\n")
  // `list.filter_map` is like `map` + `filter` in one pass:
  //   - Apply `parse_line` to each element
  //   - If it returns `Ok(value)`, include `value` in the result
  //   - If it returns `Error(Nil)`, skip that element
  // This elegantly handles the fact that some lines (comments, blanks) don't
  // produce entries, without needing a separate filter step.
  |> list.filter_map(parse_line)
}

// ----------------------------------------------------------
// LINE FILTER
// ----------------------------------------------------------
// Decide whether a line should be parsed or skipped.
// Returns `Error(Nil)` for lines that should be skipped — this works with
// `list.filter_map` above to automatically exclude them from the result.
//
// In Gleam, `Nil` is the unit type (there's only one value of type Nil: `Nil`).
// `Error(Nil)` is the conventional way to say "this operation produced no result"
// when there's no meaningful error information to carry.
fn parse_line(line: String) -> Result(DictEntry, Nil) {
  // `||` is the boolean OR operator. The condition is:
  //   - Line starts with "#" (a CEDICT comment), OR
  //   - The line is empty/whitespace-only
  // If either is true, we skip this line.
  case string.starts_with(line, "#") || string.is_empty(string.trim(line)) {
    True -> Error(Nil)
    // Return Error to tell filter_map to skip this line.
    False -> parse_entry(line)
    // Actually parse it.
  }
}

// ----------------------------------------------------------
// ENTRY PARSER
// ----------------------------------------------------------
// Parse a single CEDICT entry line into a DictEntry.
//
// This uses NESTED PATTERN MATCHING with `string.split_once` to progressively
// destructure the line. `string.split_once(str, delimiter)` finds the FIRST
// occurrence of `delimiter` and returns:
//   - `Ok(#(before, after))` if found — a tuple of the two parts
//   - `Error(Nil)` if not found
//
// We nest three levels of split_once to parse:
//   1. "Traditional Simplified [pinyin] /defs/" → split on " " → traditional + rest
//   2. "Simplified [pinyin] /defs/" → split on " [" → simplified + rest2
//   3. "pinyin] /defs/" → split on "] /" → pinyin + defs_str
//
// If ANY split fails (malformed line), we return Error(Nil) to skip it.
fn parse_entry(line: String) -> Result(DictEntry, Nil) {
  // Format: Traditional Simplified [pinyin] /def1/def2/.../
  //
  // NESTED CASE EXPRESSIONS: Each case expression branches on the result of a
  // string operation. The nesting naturally represents the sequential steps:
  // first extract traditional, then simplified, then pinyin, then definitions.
  // If any step fails, the Error(Nil) propagates out through the nesting.
  case string.split_once(line, " ") {
    // Split "Traditional Simplified [...]" into "Traditional" and "Simplified [...]"
    Ok(#(traditional, rest)) ->
      case string.split_once(rest, " [") {
        // Split "Simplified [pinyin] /..." into "Simplified" and "pinyin] /..."
        Ok(#(simplified, rest2)) ->
          case string.split_once(rest2, "] /") {
            // Split "pinyin] /def1/def2/..." into "pinyin" and "def1/def2/..."
            Ok(#(pinyin, defs_str)) -> {
              // Parse the definitions string "/def1/def2/def3/"
              // The raw string looks like: "def1/def2/def3/"
              // (The opening "/" was consumed by the split above, but there's
              // still a trailing "/" at the end.)
              let definitions =
                defs_str
                // Remove the trailing "/" (last character)
                |> string.drop_end(1)
                // Split on "/" to get individual definitions
                |> string.split("/")
                // Filter out any empty strings that result from edge cases
                // (e.g., double slashes, or trailing slashes after drop_end)
                |> list.filter(fn(s) { !string.is_empty(s) })

              // Construct and return the DictEntry record.
              // All fields are labeled and the field punning shorthand is used for
              // `traditional:` and `simplified:` (variable name matches field name).
              Ok(DictEntry(
                traditional:,
                // shorthand for `traditional: traditional`
                simplified:,
                // shorthand for `simplified: simplified`
                pinyin_numbered: pinyin,
                // The pinyin field from CEDICT uses tone numbers (e.g., "liao3 jie3")
                definitions:,
                // shorthand for `definitions: definitions`
              ))
            }
            // The "] /" separator wasn't found — malformed line, skip it.
            Error(Nil) -> Error(Nil)
          }
        // The " [" separator wasn't found — malformed line, skip it.
        Error(Nil) -> Error(Nil)
      }
    // The first " " separator wasn't found — malformed line, skip it.
    Error(Nil) -> Error(Nil)
  }
}
