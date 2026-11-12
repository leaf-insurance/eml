//// Resolving MIME parameter values, including RFC 2231 extended values and
//// continuations (assumptions.md §H.4).
////
//// A value is resolved in this order:
////
//// 1. The extended form: `name*=charset'lang'%XX..`, or the continuations
////    `name*0`, `name*1*`, ... Sections are assembled as bytes and decoded
////    with the charset once.
//// 2. The plain `name=value`. RFC 2047 encoded-words in it are decoded, a
////    common nonstandard form (`filename="=?UTF-8?B?...?="`).
////
//// An extended form that is ambiguous (a gap, a duplicated section, or both
//// a single and a continued form), malformed (a bad `%` escape or missing
//// quotes), or in an unsupported charset falls back to the plain form, and
//// is reported.

import eml/charset
import eml/diagnostic.{type Kind}
import eml/encoded_word
import eml/internal/utf8
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Value {
  Resolved(String)
  Ambiguous
  Malformed
  Unsupported
  Absent
}

/// Resolves the parameter `name` (lowercase) from parsed parameters.
pub fn resolve(
  parameters: List(#(String, BitArray)),
  name: String,
  options: charset.Options,
) -> #(Value, List(Kind)) {
  let #(extended, extended_kinds) = extended(parameters, name, options)
  case extended {
    Resolved(_) -> #(extended, extended_kinds)
    _ -> {
      // An unsupported charset is reported by the charset decoder.
      let problem = case extended {
        Ambiguous -> [diagnostic.AmbiguousParameter(name)]
        Malformed -> [diagnostic.MalformedParameter(name)]
        _ -> []
      }
      let problem = list.append(problem, extended_kinds)
      case list.key_find(parameters, name) {
        Ok(value) -> {
          let #(text, kinds) = plain(value, options)
          #(Resolved(text), list.append(problem, kinds))
        }
        Error(_) -> #(extended, problem)
      }
    }
  }
}

fn plain(value: BitArray, options: charset.Options) -> #(String, List(Kind)) {
  case utf8.to_string(value) {
    Ok(text) ->
      case string.contains(text, "=?") {
        True -> encoded_word.decode(value, options)
        False -> #(text, [])
      }
    Error(_) -> encoded_word.raw_text(value)
  }
}

type Section {
  Section(index: Int, encoded: Bool, value: BitArray)
}

fn extended(
  parameters: List(#(String, BitArray)),
  name: String,
  options: charset.Options,
) -> #(Value, List(Kind)) {
  let prefix = name <> "*"
  let single = list.key_find(parameters, prefix)
  let singles = list.count(parameters, fn(parameter) { parameter.0 == prefix })
  let sections =
    list.filter_map(parameters, fn(parameter) {
      case string.starts_with(parameter.0, prefix) {
        False -> Error(Nil)
        True ->
          section(
            string.drop_start(parameter.0, string.length(prefix)),
            parameter.1,
          )
      }
    })
  let invalid_index =
    list.any(parameters, fn(parameter) {
      string.starts_with(parameter.0, prefix)
      && parameter.0 != prefix
      && result.is_error(section(
        string.drop_start(parameter.0, string.length(prefix)),
        parameter.1,
      ))
    })
  case single, sections, invalid_index || singles > 1 {
    _, _, True -> #(Ambiguous, [])
    Error(_), [], False -> #(Absent, [])
    Ok(value), [], False ->
      case split_charset(value) {
        Ok(#(label, encoded)) ->
          case percent_decode(encoded, []) {
            Ok(bytes) -> decode_charset(bytes, label, options)
            Error(_) -> #(Malformed, [])
          }
        Error(_) -> #(Malformed, [])
      }
    Ok(_), _, False -> #(Ambiguous, [])
    Error(_), sections, False -> continuation(sections, options)
  }
}

/// Parses the part of a parameter name after `name*`: `N` or `N*`, where N
/// has no leading zeros and at most 3 digits.
fn section(suffix: String, value: BitArray) -> Result(Section, Nil) {
  let #(digits, encoded) = case string.ends_with(suffix, "*") {
    True -> #(string.drop_end(suffix, 1), True)
    False -> #(suffix, False)
  }
  let leading_zero = digits != "0" && string.starts_with(digits, "0")
  let signed = string.contains(digits, "+") || string.contains(digits, "-")
  case int.parse(digits), leading_zero || signed {
    Ok(index), False if index >= 0 && index < 1000 ->
      Ok(Section(index, encoded, value))
    _, _ -> Error(Nil)
  }
}

fn continuation(
  sections: List(Section),
  options: charset.Options,
) -> #(Value, List(Kind)) {
  let sorted = list.sort(sections, fn(a, b) { int.compare(a.index, b.index) })
  let contiguous =
    list.index_map(sorted, fn(section, i) { section.index == i })
    |> list.all(fn(ok) { ok })
  case contiguous, sorted {
    False, _ -> #(Ambiguous, [])
    True, [] -> #(Absent, [])
    True, [first, ..rest] -> {
      let start = case first.encoded {
        True ->
          case split_charset(first.value) {
            Ok(#(label, encoded)) ->
              percent_decode(encoded, [])
              |> result.map(fn(bytes) { #(label, bytes) })
            Error(_) -> Error(Nil)
          }
        False -> Ok(#(None, first.value))
      }
      let rest =
        list.try_map(rest, fn(section) {
          case section.encoded {
            True -> percent_decode(section.value, [])
            False -> Ok(section.value)
          }
        })
      case start, rest {
        Ok(#(label, first)), Ok(rest) ->
          decode_charset(bit_array.concat([first, ..rest]), label, options)
        _, _ -> #(Malformed, [])
      }
    }
  }
}

/// Splits `charset'language'rest`. An empty charset is `None`.
fn split_charset(value: BitArray) -> Result(#(Option(String), BitArray), Nil) {
  case utf8.to_string(value) {
    Ok(text) ->
      case string.split_once(text, "'") {
        Ok(#(label, rest)) ->
          case string.split_once(rest, "'") {
            Ok(#(_language, encoded)) -> {
              let label = case label {
                "" -> None
                _ -> Some(label)
              }
              Ok(#(label, bit_array.from_string(encoded)))
            }
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn percent_decode(
  value: BitArray,
  acc: List(BitArray),
) -> Result(BitArray, Nil) {
  case value {
    <<"%", h, l, rest:bytes>> ->
      case hex(h), hex(l) {
        Ok(h), Ok(l) -> percent_decode(rest, [<<{ h * 16 + l }>>, ..acc])
        _, _ -> Error(Nil)
      }
    <<"%", _:bytes>> -> Error(Nil)
    <<c, rest:bytes>> -> percent_decode(rest, [<<c>>, ..acc])
    _ -> Ok(acc |> list.reverse |> bit_array.concat)
  }
}

fn decode_charset(
  bytes: BitArray,
  label: Option(String),
  options: charset.Options,
) -> #(Value, List(Kind)) {
  case charset.decode(bytes, label, options) {
    #(Ok(text), kinds) -> #(Resolved(text), kinds)
    #(Error(_), kinds) -> #(Unsupported, kinds)
  }
}

fn hex(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 48 && c <= 57 -> Ok(c - 48)
    _ if c >= 65 && c <= 70 -> Ok(c - 55)
    _ if c >= 97 && c <= 102 -> Ok(c - 87)
    _ -> Error(Nil)
  }
}
