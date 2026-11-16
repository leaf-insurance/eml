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
import eml/internal/structured.{slice}
import eml/internal/utf8
import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option.{Some}
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
  #(string.concat(parts), merge(kinds))
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
              let label = case string.split_once(ascii(label), "*") {
                Ok(#(label, _)) -> label
                Error(_) -> ascii(label)
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

fn ascii(bits: BitArray) -> String {
  case bit_array.to_string(bits) {
    Ok(text) -> text
    Error(_) -> ""
  }
}

/// Whitespace between two encoded-words is not displayed (RFC 2047 §6.2).
fn drop_whitespace_between_words(tokens: List(Token)) -> List(Token) {
  drop_loop(tokens, [])
}

fn drop_loop(tokens: List(Token), acc: List(Token)) -> List(Token) {
  case tokens {
    [Word(..) as a, Text(space), Word(..) as b, ..rest] ->
      case is_whitespace(space) {
        True -> drop_loop([b, ..rest], [a, ..acc])
        False -> drop_loop([Text(space), b, ..rest], [a, ..acc])
      }
    [token, ..rest] -> drop_loop(rest, [token, ..acc])
    [] -> list.reverse(acc)
  }
}

fn is_whitespace(bits: BitArray) -> Bool {
  case bits {
    <<c, rest:bytes>> if c == 32 || c == 9 || c == 13 || c == 10 ->
      is_whitespace(rest)
    <<>> -> True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Decoding

fn decode_tokens(
  tokens: List(Token),
  options: charset.Options,
  parts: List(String),
  kinds: List(Kind),
) -> #(List(String), List(Kind)) {
  case tokens {
    [] -> #(list.reverse(parts), list.reverse(kinds))
    [Text(bytes), ..rest] -> {
      let #(text, text_kinds) = raw_text(bytes)
      decode_tokens(
        rest,
        options,
        [text, ..parts],
        list.append(text_kinds, kinds),
      )
    }
    [Word(..) as word, ..] -> {
      // A run of adjacent words with the same charset.
      let label = charset.normalise(word.charset)
      let #(run, rest) =
        list.split_while(tokens, fn(token) {
          case token {
            Word(charset: other, ..) -> charset.normalise(other) == label
            Text(_) -> False
          }
        })
      let #(text, run_kinds) = decode_run(run, options)
      decode_tokens(
        rest,
        options,
        [text, ..parts],
        list.append(run_kinds, kinds),
      )
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
      #(result_text(text), [diagnostic.EightBitHeader])
    }
  }
}

fn result_text(result: Result(String, Nil)) -> String {
  case result {
    Ok(text) -> text
    Error(_) -> ""
  }
}

/// The bytes of a word, with the recoveries made decoding them.
type Bytes {
  Decoded(bytes: BitArray, kinds: List(Kind))
  Undecodable
}

fn word_bytes(token: Token) -> Bytes {
  case token {
    Word(encoding:, text:, ..) if encoding == 66 || encoding == 98 -> {
      let kinds = base64.decode(text, 0)
      let lost =
        list.any(kinds.1, fn(kind) {
          diagnostic.severity(kind.0) == diagnostic.DataLoss
          || case kind.0 {
            diagnostic.InvalidBase64Characters(_) -> True
            _ -> False
          }
        })
      case lost {
        True -> Undecodable
        False -> Decoded(kinds.0, list.map(kinds.1, fn(kind) { kind.0 }))
      }
    }
    Word(text:, ..) ->
      case q_decode(text, text, 0, 0, [], 0) {
        #(bytes, 0) -> Decoded(bytes, [])
        #(bytes, n) -> Decoded(bytes, [diagnostic.InvalidQuotedPrintable(n)])
      }
    Text(_) -> Undecodable
  }
}

fn decode_run(
  run: List(Token),
  options: charset.Options,
) -> #(String, List(Kind)) {
  let label = case run {
    [Word(charset:, ..), ..] -> charset
    _ -> ""
  }
  let decoded =
    list.map(run, fn(word) { #(word, word_bytes(word)) })
    |> continue_states(label, <<>>, [])
  // 1. Each word on its own, without replacement characters.
  let strict =
    list.try_map(decoded, fn(entry) {
      case entry.1 {
        Decoded(bytes, transfer) ->
          case strict_decode(bytes, label, options) {
            Ok(#(text, kinds)) -> Ok(#(text, list.append(transfer, kinds)))
            Error(_) -> Error(Nil)
          }
        Undecodable -> Error(Nil)
      }
    })
  case strict {
    Ok(words) -> #(
      string.concat(list.map(words, fn(word) { word.0 })),
      list.flat_map(words, fn(word) { word.1 }),
    )
    Error(_) -> {
      // 2. For a charset whose bytes can be joined, the bytes of all the
      // words together, to repair a multi-byte character split between them.
      let all =
        list.try_map(decoded, fn(entry) {
          case entry.1 {
            Decoded(bytes, _) -> Ok(bytes)
            Undecodable -> Error(Nil)
          }
        })
      let joined = case all, charset.can_join(label) {
        Ok([_, _, ..] as bytes), True ->
          strict_decode(bit_array.concat(bytes), label, options)
        _, _ -> Error(Nil)
      }
      case joined {
        Ok(#(text, kinds)) -> {
          let transfer =
            list.flat_map(decoded, fn(entry) {
              case entry.1 {
                Decoded(_, kinds) -> kinds
                Undecodable -> []
              }
            })
          #(text, [
            diagnostic.EncodedWordSplitCharacter,
            ..list.append(transfer, kinds)
          ])
        }
        Error(_) -> lenient_run(decoded, label, options)
      }
    }
  }
}

/// Each ISO-2022-JP word should end in ASCII. When one ends in another
/// state, the next word continues in that state, unless it begins with an
/// escape sequence of its own.
fn continue_states(
  decoded: List(#(Token, Bytes)),
  label: String,
  state: BitArray,
  acc: List(#(Token, Bytes)),
) -> List(#(Token, Bytes)) {
  case decoded {
    [] -> list.reverse(acc)
    [#(word, Decoded(bytes, kinds)), ..rest] -> {
      let #(bytes, kinds) = case state, bytes {
        <<>>, _ | _, <<0x1B, _:bytes>> -> #(bytes, kinds)
        _, _ -> #(<<state:bits, bytes:bits>>, [
          diagnostic.EncodedWordSplitCharacter,
          ..kinds
        ])
      }
      continue_states(rest, label, charset.final_state(label, bytes), [
        #(word, Decoded(bytes, kinds)),
        ..acc
      ])
    }
    [entry, ..rest] -> continue_states(rest, label, <<>>, [entry, ..acc])
  }
}

/// Combines the diagnostics of all the words: counts are added up, and
/// other kinds are kept once, in order of first occurrence.
fn merge(kinds: List(Kind)) -> List(Kind) {
  let #(order, counts) =
    list.fold(kinds, #([], dict.new()), fn(acc, kind) {
      let #(order, counts) = acc
      let #(key, n) = split_count(kind)
      case dict.get(counts, key) {
        Ok(total) -> #(order, dict.insert(counts, key, total + n))
        Error(_) -> #([key, ..order], dict.insert(counts, key, n))
      }
    })
  list.reverse(order)
  |> list.map(fn(key) {
    let assert Ok(n) = dict.get(counts, key)
    with_count(key, n)
  })
}

/// A kind with a count, as the kind with a zero count and the count.
fn split_count(kind: Kind) -> #(Kind, Int) {
  case kind {
    diagnostic.MalformedCharsetData(n) -> #(with_count(kind, 0), n)
    diagnostic.NulInText(n) -> #(with_count(kind, 0), n)
    diagnostic.InvalidQuotedPrintable(n) -> #(with_count(kind, 0), n)
    diagnostic.InvalidEncodedWord(n) -> #(with_count(kind, 0), n)
    diagnostic.StrayPadding(n) -> #(with_count(kind, 0), n)
    diagnostic.InvalidBase64Characters(n) -> #(with_count(kind, 0), n)
    diagnostic.ExcessBase64Padding(n) -> #(with_count(kind, 0), n)
    diagnostic.UnencodedOctets(n) -> #(with_count(kind, 0), n)
    _ -> #(kind, 0)
  }
}

fn with_count(kind: Kind, n: Int) -> Kind {
  case kind {
    diagnostic.MalformedCharsetData(_) -> diagnostic.MalformedCharsetData(n)
    diagnostic.NulInText(_) -> diagnostic.NulInText(n)
    diagnostic.InvalidQuotedPrintable(_) -> diagnostic.InvalidQuotedPrintable(n)
    diagnostic.InvalidEncodedWord(_) -> diagnostic.InvalidEncodedWord(n)
    diagnostic.StrayPadding(_) -> diagnostic.StrayPadding(n)
    diagnostic.InvalidBase64Characters(_) ->
      diagnostic.InvalidBase64Characters(n)
    diagnostic.ExcessBase64Padding(_) -> diagnostic.ExcessBase64Padding(n)
    diagnostic.UnencodedOctets(_) -> diagnostic.UnencodedOctets(n)
    _ -> kind
  }
}

/// Decodes without replacement characters: fails on malformed data and
/// unsupported charsets. Other recoveries are returned as diagnostics.
fn strict_decode(
  bytes: BitArray,
  label: String,
  options: charset.Options,
) -> Result(#(String, List(Kind)), Nil) {
  case charset.decode(bytes, Some(label), options) {
    #(Ok(text), kinds) ->
      case
        list.any(kinds, fn(kind) {
          case kind {
            diagnostic.MalformedCharsetData(_) -> True
            _ -> False
          }
        })
      {
        True -> Error(Nil)
        False -> Ok(#(text, kinds))
      }
    #(Error(_), _) -> Error(Nil)
  }
}

/// Decodes each word, replacing malformed data. Words that cannot be decoded
/// at all are kept literally.
fn lenient_run(
  decoded: List(#(Token, Bytes)),
  label: String,
  options: charset.Options,
) -> #(String, List(Kind)) {
  let #(texts, kinds, invalid) =
    list.fold(decoded, #([], [], 0), fn(acc, entry) {
      let #(texts, kinds, invalid) = acc
      let literal = case entry.0 {
        Word(raw:, ..) -> raw_text(raw).0
        Text(bytes) -> raw_text(bytes).0
      }
      case entry.1 {
        Undecodable -> #([literal, ..texts], kinds, invalid + 1)
        Decoded(bytes, transfer) -> {
          let kinds = list.append(transfer, kinds)
          case charset.decode(bytes, Some(label), options) {
            #(Ok(text), word_kinds) -> #(
              [text, ..texts],
              list.append(word_kinds, kinds),
              invalid,
            )
            #(Error(_), word_kinds) -> #(
              [literal, ..texts],
              list.append(word_kinds, kinds),
              invalid,
            )
          }
        }
      }
    })
  let kinds = case invalid {
    0 -> kinds
    n -> [diagnostic.InvalidEncodedWord(n), ..kinds]
  }
  #(string.concat(list.reverse(texts)), list.reverse(kinds))
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
      case hex(h), hex(l) {
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

fn hex(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 48 && c <= 57 -> Ok(c - 48)
    _ if c >= 65 && c <= 70 -> Ok(c - 55)
    _ if c >= 97 && c <= 102 -> Ok(c - 87)
    _ -> Error(Nil)
  }
}
