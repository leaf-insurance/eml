//// Message IDs: the Message-ID, In-Reply-To and References fields (RFC 5322
//// §3.6.4, assumptions.md §H.2).
////
//// An ID is returned without its angle brackets, and is never lowercased.
//// As in the obsolete syntax of RFC 5322 §4.5.4, whitespace and comments
//// inside the brackets are removed (quoted strings are kept as they are),
//// and phrases between IDs are skipped. These recoveries are reported as
//// `InvalidMessageId`:
////
//// - an ID without brackets, `a@b`, is kept when it contains `@`;
//// - an unclosed `<a@b` is closed at the next whitespace or the end;
//// - an ID without `@` is kept;
//// - an empty `<>` is dropped;
//// - a field with no ID at all is reported.

import eml/diagnostic.{type Kind}
import eml/encoded_word
import eml/internal/structured
import gleam/bit_array
import gleam/list

/// Parses an unfolded field value into its message IDs.
pub fn parse(value: BitArray) -> #(List(String), List(Kind)) {
  let #(ids, kinds) = loop(value, [], [])
  case ids, structured.trim(value) {
    [], <<_, _:bytes>> -> #([], [diagnostic.InvalidMessageId])
    _, _ -> #(ids, kinds)
  }
}

fn loop(
  rest: BitArray,
  ids: List(String),
  kinds: List(Kind),
) -> #(List(String), List(Kind)) {
  case structured.skip_cfws(rest) {
    <<>> -> #(list.reverse(ids), list.reverse(kinds))
    <<"<", rest:bytes>> -> {
      let #(id, closed, rest) = inside(rest, [], closes(rest))
      case id, closed {
        <<>>, _ -> loop(rest, ids, [diagnostic.InvalidMessageId, ..kinds])
        _, True -> loop(rest, [text(id), ..ids], check(id, kinds))
        _, False ->
          loop(rest, [text(id), ..ids], [diagnostic.InvalidMessageId, ..kinds])
      }
    }
    <<"\"", rest:bytes>> -> loop(quoted(rest, []).1, ids, kinds)
    <<c, rest:bytes>> if c == 0x2C || c == 0x3E -> loop(rest, ids, kinds)
    rest -> {
      let #(word, rest) = bare(rest, [])
      case contains_at(word) {
        True ->
          loop(rest, [text(word), ..ids], [diagnostic.InvalidMessageId, ..kinds])
        // A word of a phrase (obsolete syntax).
        False -> loop(rest, ids, kinds)
      }
    }
  }
}

/// The ID up to `>`, when `closed` says one follows. Returns the ID,
/// whether it was closed, and the rest. An unclosed ID ends at whitespace.
/// Another `<` starts the ID again.
fn inside(
  rest: BitArray,
  acc: List(BitArray),
  closed: Bool,
) -> #(BitArray, Bool, BitArray) {
  let id = fn() { bit_array.concat(list.reverse(acc)) }
  case rest {
    <<">", rest:bytes>> -> #(id(), True, rest)
    <<"<", rest:bytes>> -> inside(rest, [], closes(rest))
    <<"\"", rest:bytes>> -> {
      let #(quoted, rest) = quoted(rest, [<<"\"">>])
      inside(rest, [quoted, ..acc], closed)
    }
    <<c, _:bytes>>
      if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c == 0x28
    ->
      case closed, acc {
        False, [_, ..] -> #(id(), False, rest)
        _, _ -> inside(structured.skip_cfws(rest), acc, closed)
      }
    <<c, rest:bytes>> -> inside(rest, [<<c>>, ..acc], closed)
    _ -> #(id(), False, <<>>)
  }
}

/// Whether a `>` follows before the next `<`.
fn closes(rest: BitArray) -> Bool {
  case rest {
    <<">", _:bytes>> -> True
    <<"<", _:bytes>> -> False
    <<_, rest:bytes>> -> closes(rest)
    _ -> False
  }
}

/// A quoted string, after its opening quote, up to and including its closing
/// quote. Returns the string with `prefix`, and the rest.
fn quoted(rest: BitArray, acc: List(BitArray)) -> #(BitArray, BitArray) {
  case rest {
    <<"\"", rest:bytes>> -> #(
      bit_array.concat(list.reverse([<<"\"">>, ..acc])),
      rest,
    )
    <<"\\", c, rest:bytes>> -> quoted(rest, [<<c>>, <<"\\">>, ..acc])
    <<c, rest:bytes>> -> quoted(rest, [<<c>>, ..acc])
    _ -> #(bit_array.concat(list.reverse(acc)), <<>>)
  }
}

/// A word outside brackets: up to whitespace, `<`, `(`, `"` or `,`.
fn bare(rest: BitArray, acc: List(BitArray)) -> #(BitArray, BitArray) {
  case rest {
    <<c, _:bytes>>
      if c == 0x20
      || c == 0x09
      || c == 0x0D
      || c == 0x0A
      || c == 0x3C
      || c == 0x28
      || c == 0x22
      || c == 0x2C
    -> #(bit_array.concat(list.reverse(acc)), rest)
    <<c, rest:bytes>> -> bare(rest, [<<c>>, ..acc])
    _ -> #(bit_array.concat(list.reverse(acc)), <<>>)
  }
}

fn check(id: BitArray, kinds: List(Kind)) -> List(Kind) {
  case contains_at(id) {
    True -> kinds
    False -> [diagnostic.InvalidMessageId, ..kinds]
  }
}

fn contains_at(bytes: BitArray) -> Bool {
  case bytes {
    <<"@", _:bytes>> -> True
    <<_, rest:bytes>> -> contains_at(rest)
    _ -> False
  }
}

fn text(id: BitArray) -> String {
  encoded_word.raw_text(id).0
}
