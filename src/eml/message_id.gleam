//// Message IDs: the Message-ID, In-Reply-To and References fields (RFC 5322
//// §3.6.4, assumptions.md §H.2).
////
//// An ID is returned without its angle brackets, and is never lowercased.
//// As in the obsolete syntax of RFC 5322 §4.5.4, whitespace and comments
//// inside the brackets are removed (quoted strings are kept as they are),
//// and phrases between IDs are skipped. These recoveries are reported as
//// `InvalidMessageId`:
////
//// - an ID without brackets, `a@b`, is kept when the field has no ID in
////   brackets (otherwise it is a word of a phrase);
//// - an unclosed `<a@b` is closed at the next whitespace or the end;
//// - an ID without `@`, or with nothing on one side of it, is kept;
//// - an empty `<>` is dropped;
//// - an unclosed quoted string between IDs is skipped to the end;
//// - a field with no ID at all is reported.
////
//// Quoted strings, comments and domain literals are read as such, so a `<`,
//// `>` or `(` inside them is not structure. A `[` without a `]` before the
//// next `[` is an ordinary character.

import eml/diagnostic.{type Kind}
import eml/encoded_word
import eml/internal/structured
import gleam/bit_array
import gleam/list

/// Parses an unfolded field value into its message IDs.
pub fn parse(value: BitArray) -> #(List(String), List(Kind)) {
  let #(ids, bare, kinds) = loop(value, [], [], [])
  case ids, bare {
    [], [] -> #([], [diagnostic.InvalidMessageId])
    [], _ -> #(bare, list.append(kinds, [diagnostic.InvalidMessageId]))
    _, _ -> #(ids, kinds)
  }
}

/// Returns the IDs in brackets, the IDs without, and the diagnostics.
fn loop(
  rest: BitArray,
  ids: List(String),
  bare: List(String),
  kinds: List(Kind),
) -> #(List(String), List(String), List(Kind)) {
  case structured.skip_cfws(rest) {
    <<>> -> #(list.reverse(ids), list.reverse(bare), list.reverse(kinds))
    <<"<", rest:bytes>> -> {
      let #(id, closed, rest) = inside(rest, [], closes(rest))
      case id, closed {
        <<>>, _ -> loop(rest, ids, bare, [diagnostic.InvalidMessageId, ..kinds])
        _, True -> loop(rest, [text(id), ..ids], bare, check(id, kinds))
        _, False ->
          loop(rest, [text(id), ..ids], bare, [
            diagnostic.InvalidMessageId,
            ..kinds
          ])
      }
    }
    <<"\"", rest:bytes>> ->
      case quoted(rest, []) {
        #(_, True, rest) -> loop(rest, ids, bare, kinds)
        #(_, False, rest) ->
          loop(rest, ids, bare, [diagnostic.InvalidMessageId, ..kinds])
      }
    <<c, rest:bytes>> if c == 0x2C || c == 0x3E -> loop(rest, ids, bare, kinds)
    rest -> {
      let #(word, rest) = word(rest, [])
      case well_formed(word) {
        True -> loop(rest, ids, [text(word), ..bare], kinds)
        // A word of a phrase (obsolete syntax).
        False -> loop(rest, ids, bare, kinds)
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
      let #(quoted, _, rest) = quoted(rest, [<<"\"">>])
      inside(rest, [quoted, ..acc], closed)
    }
    <<"[", rest:bytes>> ->
      case literal(rest, [<<"[">>]) {
        Ok(#(literal, rest)) -> inside(rest, [literal, ..acc], closed)
        Error(_) -> inside(rest, [<<"[">>, ..acc], closed)
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

/// Whether a `>` follows before the next `<`, reading as `inside` does.
fn closes(rest: BitArray) -> Bool {
  case rest {
    <<">", _:bytes>> -> True
    <<"<", _:bytes>> -> False
    <<"\"", rest:bytes>> -> closes(quoted(rest, []).2)
    <<"[", rest:bytes>> ->
      case literal(rest, []) {
        Ok(#(_, rest)) -> closes(rest)
        Error(_) -> closes(rest)
      }
    <<"(", _:bytes>> -> closes(structured.skip_cfws(rest))
    <<_, rest:bytes>> -> closes(rest)
    _ -> False
  }
}

/// A quoted string, after its opening quote, up to and including its closing
/// quote. Returns the string after `acc`, whether it was closed, and the
/// rest.
fn quoted(rest: BitArray, acc: List(BitArray)) -> #(BitArray, Bool, BitArray) {
  case rest {
    <<"\"", rest:bytes>> -> #(
      bit_array.concat(list.reverse([<<"\"">>, ..acc])),
      True,
      rest,
    )
    <<"\\", c, rest:bytes>> -> quoted(rest, [<<c>>, <<"\\">>, ..acc])
    <<c, rest:bytes>> -> quoted(rest, [<<c>>, ..acc])
    _ -> #(bit_array.concat(list.reverse(acc)), False, <<>>)
  }
}

/// A domain literal, after its `[`, up to and including its `]`. Error when
/// another `[`, or the end, comes first.
fn literal(
  rest: BitArray,
  acc: List(BitArray),
) -> Result(#(BitArray, BitArray), Nil) {
  case rest {
    <<"]", rest:bytes>> ->
      Ok(#(bit_array.concat(list.reverse([<<"]">>, ..acc])), rest))
    <<"[", _:bytes>> -> Error(Nil)
    <<c, rest:bytes>> -> literal(rest, [<<c>>, ..acc])
    _ -> Error(Nil)
  }
}

/// A word outside brackets: up to whitespace, `<`, `>`, `(`, `"` or `,`.
fn word(rest: BitArray, acc: List(BitArray)) -> #(BitArray, BitArray) {
  case rest {
    <<c, _:bytes>>
      if c == 0x20
      || c == 0x09
      || c == 0x0D
      || c == 0x0A
      || c == 0x3C
      || c == 0x3E
      || c == 0x28
      || c == 0x22
      || c == 0x2C
    -> #(bit_array.concat(list.reverse(acc)), rest)
    <<c, rest:bytes>> -> word(rest, [<<c>>, ..acc])
    _ -> #(bit_array.concat(list.reverse(acc)), <<>>)
  }
}

fn check(id: BitArray, kinds: List(Kind)) -> List(Kind) {
  case well_formed(id) {
    True -> kinds
    False -> [diagnostic.InvalidMessageId, ..kinds]
  }
}

/// Whether the bytes have an `@` with something on both sides.
fn well_formed(bytes: BitArray) -> Bool {
  case bytes {
    <<"@", _:bytes>> -> False
    _ -> at_before_end(bytes)
  }
}

fn at_before_end(bytes: BitArray) -> Bool {
  case bytes {
    <<"@", _, _:bytes>> -> True
    <<_, rest:bytes>> -> at_before_end(rest)
    _ -> False
  }
}

fn text(id: BitArray) -> String {
  encoded_word.raw_text(id).0
}
