//// A suggested safe file name for an attachment (assumptions.md §I.1).
////
//// Attachment names are untrusted. `safe` turns one into a name that is a
//// single path component on Unix and Windows. It is a suggestion only:
//// it does not make names unique, and callers should create files with
//// their own identifiers and safe file creation APIs. Names such as
//// `.htaccess` or `-rf` are kept; they are valid single components.

import gleam/list
import gleam/string

const max_bytes = 255

const fallback = "attachment"

/// Windows reserved device names, compared with the part before the first
/// dot, with trailing spaces removed, in uppercase.
const reserved = [
  "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "COM0", "COM1", "COM2",
  "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
  "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
  "LPT¹", "LPT²", "LPT³",
]

/// Returns a safe file name. Working on code points, not grapheme clusters,
/// so that combining or prepended characters cannot hide anything:
///
/// - only the last path component (after `/` or `\`) is kept;
/// - control, bidirectional formatting and invisible characters (zero-width
///   characters, line and paragraph separators, U+FEFF) are removed;
/// - characters invalid on Windows (`: * ? " < > |`) become `_`, which also
///   removes drive letters and NTFS alternate data streams;
/// - the name is shortened to at most 255 bytes, keeping a short extension;
/// - then leading spaces, and trailing spaces and dots, are removed;
/// - a Windows reserved device name gets a leading `_`;
/// - an empty result becomes `attachment`.
pub fn safe(name: String) -> String {
  let codepoints =
    name
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
    |> basename([])
    |> list.filter_map(clean)
    // One byte is kept for a possible `_` prefix.
    |> truncate(max_bytes - 1)
    |> trim
  let name = from_codepoints(codepoints)
  let stem = case list.split_while(codepoints, fn(c) { c != 0x2E }) {
    #(stem, _) -> stem |> list.reverse |> drop_while(is_space) |> list.reverse
  }
  case name, list.contains(reserved, string.uppercase(from_codepoints(stem))) {
    "", _ -> fallback
    _, True -> "_" <> name
    _, False -> name
  }
}

/// The code points after the last `/` or `\`. `acc` is reversed.
fn basename(codepoints: List(Int), acc: List(Int)) -> List(Int) {
  case codepoints {
    [] -> list.reverse(acc)
    [c, ..rest] if c == 0x2F || c == 0x5C -> basename(rest, [])
    [c, ..rest] -> basename(rest, [c, ..acc])
  }
}

fn clean(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c < 0x20 || c == 0x7F || { c >= 0x80 && c <= 0x9F } -> Error(Nil)
    // Bidirectional formatting characters.
    0x061C | 0x200E | 0x200F -> Error(Nil)
    _ if { c >= 0x202A && c <= 0x202E } || { c >= 0x2066 && c <= 0x2069 } ->
      Error(Nil)
    // Zero-width characters, line and paragraph separators, and U+FEFF.
    0x200B | 0x200C | 0x200D | 0x2028 | 0x2029 | 0xFEFF -> Error(Nil)
    // : * ? " < > |
    0x3A | 0x2A | 0x3F | 0x22 | 0x3C | 0x3E | 0x7C -> Ok(0x5F)
    _ -> Ok(c)
  }
}

fn is_space(c: Int) -> Bool {
  c == 0x20
}

/// Removes leading spaces, and trailing spaces and dots.
fn trim(codepoints: List(Int)) -> List(Int) {
  codepoints
  |> drop_while(is_space)
  |> list.reverse
  |> drop_while(fn(c) { c == 0x20 || c == 0x2E })
  |> list.reverse
}

fn drop_while(codepoints: List(Int), predicate: fn(Int) -> Bool) -> List(Int) {
  case codepoints {
    [c, ..rest] ->
      case predicate(c) {
        True -> drop_while(rest, predicate)
        False -> codepoints
      }
    [] -> []
  }
}

fn utf8_size(c: Int) -> Int {
  case c {
    _ if c < 0x80 -> 1
    _ if c < 0x800 -> 2
    _ if c < 0x10000 -> 3
    _ -> 4
  }
}

fn size(codepoints: List(Int)) -> Int {
  list.fold(codepoints, 0, fn(total, c) { total + utf8_size(c) })
}

/// Shortens a name to at most `budget` bytes, keeping an extension of up to
/// 16 bytes.
fn truncate(codepoints: List(Int), budget: Int) -> List(Int) {
  case size(codepoints) <= budget {
    True -> codepoints
    False -> {
      let reversed = list.reverse(codepoints)
      let extension = case list.split_while(reversed, fn(c) { c != 0x2E }) {
        #(after_dot, [_dot, ..]) -> {
          let extension = [0x2E, ..list.reverse(after_dot)]
          case size(extension) <= 16 {
            True -> extension
            False -> []
          }
        }
        _ -> []
      }
      let stem = list.reverse(list.drop(reversed, list.length(extension)))
      list.append(take_bytes(stem, budget - size(extension), []), extension)
    }
  }
}

fn take_bytes(codepoints: List(Int), budget: Int, acc: List(Int)) -> List(Int) {
  case codepoints {
    [c, ..rest] ->
      case utf8_size(c) <= budget {
        True -> take_bytes(rest, budget - utf8_size(c), [c, ..acc])
        False -> list.reverse(acc)
      }
    [] -> list.reverse(acc)
  }
}

fn from_codepoints(codepoints: List(Int)) -> String {
  codepoints
  |> list.filter_map(string.utf_codepoint)
  |> string.from_utf_codepoints
}
