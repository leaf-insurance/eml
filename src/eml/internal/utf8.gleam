//// UTF-8 conversion that behaves the same on both targets.
////
//// On JavaScript, gleam_stdlib's `bit_array.to_string` uses `TextDecoder`,
//// which removes a leading byte order mark; on Erlang it is kept. Here a
//// leading BOM is always kept as U+FEFF, and callers that want to remove
//// one do so explicitly.

import gleam/bit_array
import gleam/string

pub fn to_string(bits: BitArray) -> Result(String, Nil) {
  let #(count, rest) = leading_marks(bits, 0)
  case bit_array.to_string(rest) {
    Ok(text) -> Ok(string.repeat("\u{FEFF}", count) <> text)
    Error(_) -> Error(Nil)
  }
}

fn leading_marks(bits: BitArray, count: Int) -> #(Int, BitArray) {
  case bits {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> leading_marks(rest, count + 1)
    _ -> #(count, bits)
  }
}

/// Removes one leading UTF-8 byte order mark, as the WHATWG UTF-8 decoder
/// does.
pub fn strip_mark(bits: BitArray) -> BitArray {
  case bits {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> rest
    _ -> bits
  }
}
