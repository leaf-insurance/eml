//// RFC 2045 lexing for the structured fields the MIME tree depends on:
//// Content-Type and Content-Transfer-Encoding (assumptions.md §E.1, §E.2).

import eml/diagnostic.{type Kind}
import eml/mime.{type ContentType, type TransferEncoding, ContentType}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string

const max_comment_depth = 32

/// Removes the line breaks of folded continuation lines. Inside a field
/// value every CR and LF is part of a fold, so all of them are removed.
pub fn unfold(value: BitArray) -> BitArray {
  unfold_loop(value, value, 0, 0, [])
}

fn unfold_loop(
  value: BitArray,
  rest: BitArray,
  pos: Int,
  run_start: Int,
  chunks: List(BitArray),
) -> BitArray {
  case rest {
    <<c, rest:bytes>> if c == 13 || c == 10 -> {
      let chunks = [slice(value, run_start, pos), ..chunks]
      unfold_loop(value, rest, pos + 1, pos + 1, chunks)
    }
    <<_, rest:bytes>> -> unfold_loop(value, rest, pos + 1, run_start, chunks)
    _ ->
      case chunks {
        [] -> value
        _ ->
          [slice(value, run_start, pos), ..chunks]
          |> list.reverse
          |> bit_array.concat
      }
  }
}

/// Parses an unfolded Content-Type value. Returns `None` for the content
/// type when there is no `type/subtype` pair; parameter errors never
/// invalidate the type.
pub fn parse_content_type(
  value: BitArray,
) -> #(Option(ContentType), List(Kind)) {
  let rest = skip_cfws(value)
  case token(rest) {
    #(<<>>, _) -> #(None, [diagnostic.InvalidContentType])
    #(type_, rest) ->
      case skip_cfws(rest) {
        <<"/", rest:bytes>> ->
          case token(skip_cfws(rest)) {
            #(<<>>, _) -> #(None, [diagnostic.InvalidContentType])
            #(subtype, rest) -> {
              let #(parameters, kinds) = parameters(rest, [], set.new(), [])
              let content_type =
                ContentType(
                  type_: ascii_lowercase(type_),
                  subtype: ascii_lowercase(subtype),
                  parameters:,
                )
              #(Some(content_type), kinds)
            }
          }
        _ -> #(None, [diagnostic.InvalidContentType])
      }
  }
}

fn parameters(
  rest: BitArray,
  acc: List(#(String, BitArray)),
  seen: Set(String),
  kinds: List(Kind),
) -> #(List(#(String, BitArray)), List(Kind)) {
  case skip_cfws(rest) {
    <<>> -> #(list.reverse(acc), list.reverse(kinds))
    <<";", rest:bytes>> ->
      case skip_cfws(rest) {
        <<>> -> #(list.reverse(acc), list.reverse(kinds))
        <<";", _:bytes>> as rest -> parameters(rest, acc, seen, kinds)
        rest ->
          case parameter(rest) {
            Error(Nil) ->
              parameters(skip_to_semicolon(rest), acc, seen, [
                diagnostic.InvalidParameter,
                ..kinds
              ])
            Ok(#(name, value, rest, value_kinds)) -> {
              let kinds = list.append(value_kinds, kinds)
              case set.contains(seen, name) {
                True ->
                  parameters(rest, acc, seen, [
                    diagnostic.DuplicateParameter(name),
                    ..kinds
                  ])
                False ->
                  parameters(
                    rest,
                    [#(name, value), ..acc],
                    set.insert(seen, name),
                    kinds,
                  )
              }
            }
          }
      }
    // Garbage between parameters: skip to the next `;`.
    rest ->
      parameters(skip_to_semicolon(rest), acc, seen, [
        diagnostic.InvalidParameter,
        ..kinds
      ])
  }
}

/// Reads one `attribute = value` parameter.
fn parameter(
  rest: BitArray,
) -> Result(#(String, BitArray, BitArray, List(Kind)), Nil) {
  case token(rest) {
    #(<<>>, _) -> Error(Nil)
    #(name, after_name) ->
      case skip_cfws(after_name) {
        <<"=", after_equals:bytes>> ->
          case parameter_value(after_equals) {
            #(None, _, _) -> Error(Nil)
            #(Some(value), rest, kinds) ->
              Ok(#(ascii_lowercase(name), value, rest, kinds))
          }
        _ -> Error(Nil)
      }
  }
}

fn parameter_value(
  rest: BitArray,
) -> #(Option(BitArray), BitArray, List(Kind)) {
  case skip_cfws(rest) {
    <<"\"", rest:bytes>> -> {
      let #(value, rest, terminated) = quoted_string(rest, [])
      case terminated {
        True -> #(Some(value), rest, [])
        False -> #(Some(value), rest, [diagnostic.UnterminatedQuotedString])
      }
    }
    rest -> {
      let #(value, rest) = unquoted_value(rest, rest, 0)
      case value {
        <<>> -> #(None, rest, [])
        _ -> #(Some(value), rest, [])
      }
    }
  }
}

/// Reads the body of a quoted string after its opening quote, resolving
/// quoted-pairs. Returns the value, the rest, and whether the closing quote
/// was found.
fn quoted_string(
  rest: BitArray,
  acc: List(BitArray),
) -> #(BitArray, BitArray, Bool) {
  case rest {
    <<"\"", rest:bytes>> -> #(finish(acc), rest, True)
    <<"\\", c, rest:bytes>> -> quoted_string(rest, [<<c>>, ..acc])
    <<c, rest:bytes>> -> quoted_string(rest, [<<c>>, ..acc])
    _ -> #(finish(acc), <<>>, False)
  }
}

fn finish(acc: List(BitArray)) -> BitArray {
  acc |> list.reverse |> bit_array.concat
}

/// An unquoted value runs to the next `;` or `(` (which starts a comment),
/// with trailing whitespace trimmed. This tolerates unquoted values
/// containing tspecials or spaces.
fn unquoted_value(
  start: BitArray,
  rest: BitArray,
  length: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<";", _:bytes>> | <<"(", _:bytes>> | <<>> -> #(
      trim_trailing_whitespace(slice(start, 0, length)),
      rest,
    )
    <<_, rest:bytes>> -> unquoted_value(start, rest, length + 1)
    _ -> #(trim_trailing_whitespace(slice(start, 0, length)), rest)
  }
}

fn trim_trailing_whitespace(value: BitArray) -> BitArray {
  let size = bit_array.byte_size(value)
  case size > 0 {
    False -> value
    True ->
      case slice(value, size - 1, size) {
        <<c>> if c == 32 || c == 9 ->
          trim_trailing_whitespace(slice(value, 0, size - 1))
        _ -> value
      }
  }
}

/// Skips to the next top-level `;`, stepping over quoted strings and
/// comments so that a `;` inside them is not mistaken for a separator.
fn skip_to_semicolon(rest: BitArray) -> BitArray {
  case rest {
    <<";", _:bytes>> | <<>> -> rest
    <<"\"", rest:bytes>> -> {
      let #(_, rest, _) = quoted_string(rest, [])
      skip_to_semicolon(rest)
    }
    <<"(", _:bytes>> -> skip_to_semicolon(skip_cfws(rest))
    <<_, rest:bytes>> -> skip_to_semicolon(rest)
    _ -> <<>>
  }
}

/// Skips whitespace and comments. Comments nest; an unterminated comment, or
/// one nested deeper than `max_comment_depth`, extends to the end.
pub fn skip_cfws(rest: BitArray) -> BitArray {
  case rest {
    <<c, rest:bytes>> if c == 32 || c == 9 || c == 13 || c == 10 ->
      skip_cfws(rest)
    <<"(", rest:bytes>> -> skip_cfws(skip_comment(rest, 1))
    _ -> rest
  }
}

fn skip_comment(rest: BitArray, depth: Int) -> BitArray {
  case rest {
    _ if depth > max_comment_depth -> <<>>
    <<")", rest:bytes>> ->
      case depth {
        1 -> rest
        _ -> skip_comment(rest, depth - 1)
      }
    <<"(", rest:bytes>> -> skip_comment(rest, depth + 1)
    <<"\\", _, rest:bytes>> -> skip_comment(rest, depth)
    <<_, rest:bytes>> -> skip_comment(rest, depth)
    _ -> <<>>
  }
}

/// Reads an RFC 2045 token: printable ASCII except SPACE and tspecials.
fn token(rest: BitArray) -> #(BitArray, BitArray) {
  token_loop(rest, rest, 0)
}

fn token_loop(
  start: BitArray,
  rest: BitArray,
  length: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<c, rest:bytes>> ->
      case is_token_char(c) {
        True -> token_loop(start, rest, length + 1)
        False -> #(slice(start, 0, length), slice(start, length, -1))
      }
    _ -> #(start, <<>>)
  }
}

fn is_token_char(c: Int) -> Bool {
  c > 32
  && c < 127
  && case c {
    // ( ) < > @ , ; : \ " / [ ] ? =
    40 | 41 | 60 | 62 | 64 | 44 | 59 | 58 | 92 | 34 | 47 | 91 | 93 | 63 | 61 ->
      False
    _ -> True
  }
}

/// Parses an unfolded Content-Transfer-Encoding value (§E.2).
pub fn parse_transfer_encoding(
  value: BitArray,
) -> #(TransferEncoding, List(Kind)) {
  let #(label, rest, quoted) = case skip_cfws(value) {
    <<"\"", rest:bytes>> -> {
      let #(label, rest, _) = quoted_string(rest, [])
      #(label, rest, True)
    }
    rest -> {
      let #(label, rest) = token(rest)
      #(label, rest, False)
    }
  }
  let label = ascii_lowercase(label)
  let trailing = case skip_cfws(rest) {
    <<>> -> False
    _ -> True
  }
  let #(encoding, nonstandard) = case label {
    "" | "7bit" -> #(mime.SevenBit, False)
    "8bit" -> #(mime.EightBit, False)
    "binary" -> #(mime.Binary, False)
    "base64" -> #(mime.Base64, False)
    "quoted-printable" -> #(mime.QuotedPrintable, False)
    "7-bit" | "none" -> #(mime.SevenBit, True)
    "8-bit" | "8bits" -> #(mime.EightBit, True)
    _ -> #(mime.Unknown(label), False)
  }
  case nonstandard || quoted || trailing {
    True -> #(encoding, [diagnostic.NonstandardTransferEncoding(label)])
    False -> #(encoding, [])
  }
}

pub type BoundaryStatus {
  ValidBoundary
  NonstandardBoundary
  UnusableBoundary
}

/// Classifies a boundary parameter (§E.1). Boundaries are never normalised.
pub fn boundary_status(boundary: BitArray) -> BoundaryStatus {
  let size = bit_array.byte_size(boundary)
  case size == 0 || contains_forbidden(boundary) {
    True -> UnusableBoundary
    False ->
      case size <= 70 && all_bchars(boundary) && !ends_with_space(boundary) {
        True -> ValidBoundary
        False -> NonstandardBoundary
      }
  }
}

fn contains_forbidden(bits: BitArray) -> Bool {
  case bits {
    <<c, _:bytes>> if c == 13 || c == 10 || c == 0 -> True
    <<_, rest:bytes>> -> contains_forbidden(rest)
    _ -> False
  }
}

fn all_bchars(bits: BitArray) -> Bool {
  case bits {
    <<c, rest:bytes>> ->
      case is_bchar(c) {
        True -> all_bchars(rest)
        False -> False
      }
    _ -> True
  }
}

fn is_bchar(c: Int) -> Bool {
  { c >= 48 && c <= 57 }
  || { c >= 65 && c <= 90 }
  || { c >= 97 && c <= 122 }
  || case c {
    // ' ( ) + _ , - . / : = ? SPACE
    39 | 40 | 41 | 43 | 95 | 44 | 45 | 46 | 47 | 58 | 61 | 63 | 32 -> True
    _ -> False
  }
}

fn ends_with_space(bits: BitArray) -> Bool {
  let size = bit_array.byte_size(bits)
  slice(bits, size - 1, size) == <<32>>
}

/// Lowercases ASCII letters. The input is a token, so it is ASCII.
pub fn ascii_lowercase(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(string) -> string.lowercase(string)
    Error(_) -> ""
  }
}

/// `slice(bits, from, to)` returns the bytes in `[from, to)`. A negative `to`
/// means the end of `bits`.
pub fn slice(bits: BitArray, from: Int, to: Int) -> BitArray {
  let size = bit_array.byte_size(bits)
  let to = case to < 0 || to > size {
    True -> size
    False -> to
  }
  case bit_array.slice(bits, from, to - from) {
    Ok(bits) -> bits
    Error(_) -> <<>>
  }
}
