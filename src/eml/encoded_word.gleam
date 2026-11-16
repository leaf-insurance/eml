//// Decoding of header text that may contain RFC 2047 encoded-words
//// (assumptions.md §H.3).
////
//// Encoded-words are recognised anywhere in the text, as in Python's
//// `email` package, not only between whitespace. Whitespace between
//// adjacent encoded-words is dropped. Each word is decoded independently;
//// only when that fails are adjacent words with the same charset joined, to
//// repair a multi-byte character split across them. A word that cannot be
//// decoded is kept literally.

import eml/charset
import eml/diagnostic.{type Kind}
import eml/internal/base64
import eml/internal/quoted_printable
import eml/internal/structured.{slice}
import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

type Token {
  Text(BitArray)
  Word(charset: String, encoding: Int, text: BitArray, raw: BitArray)
}

/// Decodes unstructured header text (an unfolded field value). Leading and
/// trailing whitespace is removed.
///
/// The decoded text is not sanitised: encoded-words can produce line breaks
/// and NUL. Escape it before writing it into another header or a log.
pub fn decode(
  value: BitArray,
  options: charset.Options,
) -> #(String, List(Kind)) {
  // Raw whitespace around the value is removed; whitespace that was
  // encoded (`=?utf-8?Q?=20x?=`) is kept.
  let value = structured.trim(value)
  let tokens =
    drop_whitespace_between_words(tokenise(value, value, 0, 0, False, []))
  let #(parts, kinds) = decode_tokens(tokens, options, [], [])
  #(string.concat(parts), diagnostic.merge(kinds))
}

// ---------------------------------------------------------------------------
// Tokenising

/// `exhausted` is set once an encoded-word has no closing `?=`: later ones
/// would search a suffix of the same text, so they cannot have one either.
/// This keeps tokenising linear.
fn tokenise(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  text_start: Int,
  exhausted: Bool,
  acc: List(Token),
) -> List(Token) {
  case rest {
    <<"=?", after:bytes>> if !exhausted ->
      case encoded_word(after) {
        Ok(#(label, encoding, text, length)) -> {
          let acc = case pos > text_start {
            True -> [Text(slice(input, text_start, pos)), ..acc]
            False -> acc
          }
          let end = pos + 2 + length
          let word = Word(label, encoding, text, slice(input, pos, end))
          tokenise(input, slice(input, end, -1), end, end, exhausted, [
            word,
            ..acc
          ])
        }
        Error(NoTerminator) ->
          tokenise(input, after, pos + 2, text_start, True, acc)
        Error(NotAWord) ->
          tokenise(input, after, pos + 2, text_start, exhausted, acc)
      }
    <<_, rest:bytes>> ->
      tokenise(input, rest, pos + 1, text_start, exhausted, acc)
    _ ->
      case pos > text_start {
        True -> list.reverse([Text(slice(input, text_start, pos)), ..acc])
        False -> list.reverse(acc)
      }
  }
}

type WordError {
  NotAWord
  NoTerminator
}

/// Parses `charset ["*" language] "?" encoding "?" text "?="` after `=?`.
/// Returns the charset, the encoding letter, the encoded text, and the
/// number of bytes the word uses.
fn encoded_word(
  after: BitArray,
) -> Result(#(String, Int, BitArray, Int), WordError) {
  case until_question_mark(after, 0) {
    Ok(charset_length) if charset_length > 0 -> {
      let label = slice(after, 0, charset_length)
      case slice(after, charset_length, -1) {
        <<"?", encoding, "?", text:bytes>>
          if encoding == 66
          || encoding == 98
          || encoding == 81
          || encoding == 113
        ->
          case until_end(text, 0) {
            Ok(text_length) -> {
              // A language suffix (RFC 2231 §5) is dropped.
              let label = result.unwrap(utf8.to_string(label), "")
              let label = case string.split_once(label, "*") {
                Ok(#(label, _)) -> label
                Error(_) -> label
              }
              Ok(#(
                label,
                encoding,
                slice(text, 0, text_length),
                charset_length + 3 + text_length + 2,
              ))
            }
            Error(_) -> Error(NoTerminator)
          }
        _ -> Error(NotAWord)
      }
    }
    _ -> Error(NotAWord)
  }
}

/// The length of a charset: up to the next `?`, without whitespace.
fn until_question_mark(bits: BitArray, length: Int) -> Result(Int, Nil) {
  case bits {
    <<"?", _:bytes>> -> Ok(length)
    <<c, _:bytes>> if c == 32 || c == 9 || c == 13 || c == 10 -> Error(Nil)
    <<_, rest:bytes>> -> until_question_mark(rest, length + 1)
    _ -> Error(Nil)
  }
}

/// The length of the encoded text: up to the next `?=`.
fn until_end(bits: BitArray, length: Int) -> Result(Int, Nil) {
  case bits {
    <<"?=", _:bytes>> -> Ok(length)
    <<_, rest:bytes>> -> until_end(rest, length + 1)
    _ -> Error(Nil)
  }
}

/// Whitespace between two encoded-words is not displayed (RFC 2047 §6.2).
fn drop_whitespace_between_words(tokens: List(Token)) -> List(Token) {
  drop_loop(tokens, [])
}

fn drop_loop(tokens: List(Token), acc: List(Token)) -> List(Token) {
  case tokens {
    [Word(..) as a, Text(space), Word(..) as b, ..rest] ->
      case structured.skip_whitespace(space) {
        <<>> -> drop_loop([b, ..rest], [a, ..acc])
        _ -> drop_loop([Text(space), b, ..rest], [a, ..acc])
      }
    [token, ..rest] -> drop_loop(rest, [token, ..acc])
    [] -> list.reverse(acc)
  }
}

// ---------------------------------------------------------------------------
// Decoding

fn decode_tokens(
  tokens: List(Token),
  options: charset.Options,
  parts: List(String),
  kinds: List(List(Kind)),
) -> #(List(String), List(Kind)) {
  case tokens {
    [] -> #(list.reverse(parts), list.flatten(list.reverse(kinds)))
    [Text(bytes), ..rest] -> {
      let #(text, text_kinds) = raw_text(bytes)
      decode_tokens(rest, options, [text, ..parts], [text_kinds, ..kinds])
    }
    [Word(charset: label, ..), ..] -> {
      let charset = charset.resolve(Some(label))
      let #(run, rest) = take_run(tokens, charset, [])
      let #(text, run_kinds) = decode_run(run, charset, options)
      decode_tokens(rest, options, [text, ..parts], [run_kinds, ..kinds])
    }
  }
}

/// Text outside encoded-words: UTF-8 (RFC 6532), or windows-1252 when it is
/// not valid UTF-8.
pub fn raw_text(bytes: BitArray) -> #(String, List(Kind)) {
  case utf8.to_string(bytes) {
    Ok(text) -> #(text, [])
    Error(_) -> {
      let #(text, _) = charset.utf8_or_windows_1252(bytes, [])
      #(result.unwrap(text, ""), [diagnostic.EightBitHeader])
    }
  }
}

/// The bytes of a word, with the recoveries made decoding them.
type Bytes {
  Decoded(bytes: BitArray, kinds: List(Kind))
  Undecodable
}

/// Takes the run of adjacent words in `charset`, as each word's raw bytes
/// and its decoded bytes. The first token is a word in `charset`.
fn take_run(
  tokens: List(Token),
  charset: charset.Charset,
  acc: List(#(BitArray, Bytes)),
) -> #(List(#(BitArray, Bytes)), List(Token)) {
  case tokens {
    [Word(charset: label, encoding:, text:, raw:), ..rest] ->
      case acc == [] || charset.same(charset.resolve(Some(label)), charset) {
        True ->
          take_run(rest, charset, [#(raw, word_bytes(encoding, text)), ..acc])
        False -> #(list.reverse(acc), tokens)
      }
    _ -> #(list.reverse(acc), tokens)
  }
}

fn word_bytes(encoding: Int, text: BitArray) -> Bytes {
  case encoding {
    66 | 98 -> {
      let #(bytes, kinds) = base64.decode(text, 0)
      let kinds = list.map(kinds, fn(kind) { kind.0 })
      let lost =
        list.any(kinds, fn(kind) {
          diagnostic.severity(kind) == diagnostic.DataLoss
          || case kind {
            diagnostic.InvalidBase64Characters(_) -> True
            _ -> False
          }
        })
      case lost {
        True -> Undecodable
        False -> Decoded(bytes, kinds)
      }
    }
    _ ->
      case q_decode(text, text, 0, 0, [], 0) {
        #(bytes, 0) -> Decoded(bytes, [])
        #(bytes, n) -> Decoded(bytes, [diagnostic.InvalidQuotedPrintable(n)])
      }
  }
}

/// Decodes a run of words in one charset, as the first word declares it.
fn decode_run(
  run: List(#(BitArray, Bytes)),
  charset: charset.Charset,
  options: charset.Options,
) -> #(String, List(Kind)) {
  // 1. Each word on its own, replacing malformed data, passing on the shift
  // state or byte order. A word that cannot be decoded is kept literally.
  let #(_, words) =
    list.map_fold(run, <<>>, fn(state, entry) {
      decode_word(entry, charset, options, state)
    })
  let text = string.concat(list.map(words, fn(word) { word.0 }))
  let kinds = list.flat_map(words, fn(word) { word.1 })
  case list.all(words, fn(word) { word.2 }) {
    True -> #(text, kinds)
    False ->
      // 2. When a word is not clean, and the charset's bytes can be joined,
      // the bytes of all the words together, to repair a multi-byte
      // character split between them. 3. Otherwise the words on their own.
      case join(run, charset, options) {
        Ok(joined) -> joined
        Error(_) ->
          case list.count(run, fn(entry) { entry.1 == Undecodable }) {
            0 -> #(text, kinds)
            n -> #(text, [diagnostic.InvalidEncodedWord(n), ..kinds])
          }
      }
  }
}

/// Decodes one word, given the state the word before passes on. Returns
/// the state to pass on, and the text, the diagnostics, and whether it was
/// decoded without replacing malformed data.
fn decode_word(
  entry: #(BitArray, Bytes),
  charset: charset.Charset,
  options: charset.Options,
  state: BitArray,
) -> #(BitArray, #(String, List(Kind), Bool)) {
  case entry.1 {
    Decoded(bytes, transfer) -> {
      let decoded = charset.decode_charset(bytes, charset, options, state)
      let kinds = list.append(transfer, decoded.kinds)
      case decoded.text {
        Ok(text) -> #(
          decoded.state,
          #(text, kinds, !list.any(decoded.kinds, is_malformed)),
        )
        Error(_) -> #(decoded.state, #(raw_text(entry.0).0, kinds, False))
      }
    }
    Undecodable -> #(<<>>, #(raw_text(entry.0).0, [], False))
  }
}

/// Decodes the bytes of two or more words together, without replacing
/// malformed data.
fn join(
  run: List(#(BitArray, Bytes)),
  charset: charset.Charset,
  options: charset.Options,
) -> Result(#(String, List(Kind)), Nil) {
  let decoded =
    list.try_map(run, fn(entry) {
      case entry.1 {
        Decoded(bytes, kinds) -> Ok(#(bytes, kinds))
        Undecodable -> Error(Nil)
      }
    })
  case decoded, charset.can_join(charset) {
    Ok([_, _, ..] as decoded), True -> {
      let bytes = bit_array.concat(list.map(decoded, fn(word) { word.0 }))
      case charset.decode_charset(bytes, charset, options, <<>>) {
        charset.Decoded(Ok(text), kinds, _) ->
          case list.any(kinds, is_malformed) {
            True -> Error(Nil)
            False -> {
              let transfer = list.flat_map(decoded, fn(word) { word.1 })
              Ok(
                #(text, [
                  diagnostic.EncodedWordSplitCharacter,
                  ..list.append(transfer, kinds)
                ]),
              )
            }
          }
        _ -> Error(Nil)
      }
    }
    _, _ -> Error(Nil)
  }
}

fn is_malformed(kind: Kind) -> Bool {
  case kind {
    diagnostic.MalformedCharsetData(_) -> True
    _ -> False
  }
}

/// The Q encoding (RFC 2047 §4.2): `_` is a space, `=XX` is a byte, and
/// anything else is literal. Returns the bytes and the number of malformed
/// `=` escapes, which are kept literally.
fn q_decode(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  run_start: Int,
  acc: List(BitArray),
  invalid: Int,
) -> #(BitArray, Int) {
  case rest {
    <<"_", rest:bytes>> ->
      q_decode(
        input,
        rest,
        pos + 1,
        pos + 1,
        [<<" ">>, slice(input, run_start, pos), ..acc],
        invalid,
      )
    <<"=", h, l, rest:bytes>> ->
      case quoted_printable.hex(h), quoted_printable.hex(l) {
        Ok(h), Ok(l) ->
          q_decode(
            input,
            rest,
            pos + 3,
            pos + 3,
            [<<{ h * 16 + l }>>, slice(input, run_start, pos), ..acc],
            invalid,
          )
        _, _ ->
          q_decode(
            input,
            slice(input, pos + 1, -1),
            pos + 1,
            run_start,
            acc,
            invalid + 1,
          )
      }
    <<"=", rest:bytes>> ->
      q_decode(input, rest, pos + 1, run_start, acc, invalid + 1)
    <<_, rest:bytes>> -> q_decode(input, rest, pos + 1, run_start, acc, invalid)
    _ -> #(
      [slice(input, run_start, pos), ..acc]
        |> list.reverse
        |> bit_array.concat,
      invalid,
    )
  }
}
