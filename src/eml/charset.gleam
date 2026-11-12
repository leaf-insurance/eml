//// Charset decoding (assumptions.md §G).
////
//// Labels are resolved with the WHATWG Encoding Standard, with two
//// adjustments for mail:
////
//// - US-ASCII labels, and an absent label, decode as UTF-8 when the bytes
////   are valid UTF-8, and as windows-1252 otherwise.
//// - ISO-8859-1 labels decode as windows-1252, as browsers and most mail
////   clients do. Bytes 0x80-0x9F are reported, since strictly they are C1
////   control characters.
////
//// A declared single-byte charset is never overridden by sniffing, unless
//// the caller asks for it with `with_utf8_override`. Multi-byte charsets
//// other than UTF-8 (CJK and UTF-16) are not built in; a caller-supplied
//// decoder can provide them.

import eml/diagnostic.{type Kind}
import eml/internal/charset_tables.{type Table}
import eml/internal/structured.{slice}
import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type Options {
  Options(
    decoder: Option(fn(String, BitArray) -> Result(String, Nil)),
    utf8_override: Bool,
  )
}

pub fn default_options() -> Options {
  Options(decoder: None, utf8_override: False)
}

/// A decoder consulted first, for any declared label. It receives the
/// label as declared and the bytes, and returns `Error(Nil)` to fall back to
/// the built-in decoders. It is trusted code: it must terminate.
pub fn with_decoder(
  options: Options,
  decoder: fn(String, BitArray) -> Result(String, Nil),
) -> Options {
  Options(..options, decoder: Some(decoder))
}

/// When enabled, text that declares a single-byte charset but is valid
/// UTF-8 containing non-ASCII bytes is decoded as UTF-8, and
/// `DeclaredCharsetOverridden` is reported. This helps with senders that
/// mislabel UTF-8. It is off by default, because valid UTF-8 is not proof of
/// intent.
pub fn with_utf8_override(options: Options, enabled: Bool) -> Options {
  Options(..options, utf8_override: enabled)
}

type Family {
  AsciiFamily
  Latin1Family
  Encoding(name: String)
  /// A known charset that is not built in.
  Legacy
  UnknownLabel
}

/// Charsets in use in mail that are neither WHATWG encodings nor built in.
/// They are reported as unsupported rather than guessed.
const legacy_labels = [
  "utf-7", "utf7", "unicode-1-1-utf-7", "csunicode11utf7", "utf-32", "utf-32le",
  "utf-32be", "ucs-2", "ucs-4", "iso-10646-ucs-2", "437", "cp437", "ibm437",
  "850", "cp850", "ibm850", "852", "cp852", "ibm852", "855", "cp855", "ibm855",
  "857", "cp857", "ibm857", "860", "cp860", "ibm860", "861", "cp861", "ibm861",
  "862", "cp862", "ibm862", "863", "cp863", "ibm863", "865", "cp865", "ibm865",
  "869", "cp869", "ibm869", "cp037", "ibm037", "cp1047", "ibm1047", "cp500",
  "ibm500", "tis-620-2533", "viscii", "armscii-8", "georgian-ps", "koi8-t",
  "cp1125",
]

const ascii_labels = [
  "us-ascii", "ascii", "ansi_x3.4-1968", "ansi_x3.4-1986", "iso646-us", "us",
  "iso-ir-6", "iso_646.irv:1991", "cp367", "ibm367", "csascii", "646",
]

const latin1_labels = [
  "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987",
  "latin1", "latin-1", "l1", "cp819", "ibm819", "csisolatin1", "iso-ir-100",
]

/// Normalises a label: trims ASCII whitespace and lowercases it.
pub fn normalise(label: String) -> String {
  let trimmed = structured.trim(bit_array.from_string(label))
  case bit_array.to_string(trimmed) {
    Ok(label) -> string.lowercase(label)
    Error(_) -> string.lowercase(label)
  }
}

fn family(label: String) -> Family {
  case list.contains(ascii_labels, label), list.contains(latin1_labels, label) {
    True, _ -> AsciiFamily
    _, True -> Latin1Family
    False, False ->
      case charset_tables.encoding(label) {
        Ok(name) -> Encoding(name)
        Error(_) ->
          case list.contains(legacy_labels, label) {
            True -> Legacy
            False -> UnknownLabel
          }
      }
  }
}

/// Whether a label names a stateless charset that eml decodes itself:
/// UTF-8 or a single-byte encoding. Only these may have bytes from adjacent
/// encoded-words joined. Unknown labels, and charsets left to a caller's
/// decoder, are not assumed to be stateless.
pub fn is_stateless(label: String) -> Bool {
  case family(normalise(label)) {
    AsciiFamily | Latin1Family -> True
    Encoding("UTF-8") | Encoding("x-user-defined") -> True
    Encoding(name) -> result.is_ok(charset_tables.table(name))
    Legacy | UnknownLabel -> False
  }
}

/// Decodes `bytes` declared with `label` (`None` when no charset is
/// declared). Returns the text, or `Error(Nil)` when the charset is not
/// supported, with the diagnostics.
pub fn decode(
  bytes: BitArray,
  label: Option(String),
  options: Options,
) -> #(Result(String, Nil), List(Kind)) {
  let custom = case label, options.decoder {
    Some(label), Some(decoder) -> decoder(label, bytes)
    _, _ -> Error(Nil)
  }
  let #(result, kinds) = case custom {
    Ok(text) -> #(Ok(text), [])
    Error(_) -> builtin(bytes, label, options)
  }
  // NUL is counted in the decoded text: a decoder (UTF-16, say) can turn
  // zero bytes into other characters.
  case result {
    Ok(text) ->
      case count_nul(bit_array.from_string(text), 0) {
        0 -> #(result, kinds)
        n -> #(Ok(text), list.append(kinds, [diagnostic.NulInText(n)]))
      }
    Error(_) -> #(result, kinds)
  }
}

fn builtin(
  bytes: BitArray,
  label: Option(String),
  options: Options,
) -> #(Result(String, Nil), List(Kind)) {
  let normalised = option.map(label, normalise)
  let family = case normalised {
    None -> AsciiFamily
    Some(label) -> family(label)
  }
  case family {
    AsciiFamily ->
      case is_ascii(bytes) {
        True -> #(Ok(ascii(bytes)), [])
        False -> utf8_or_windows_1252(bytes, [diagnostic.NonAsciiInAscii])
      }
    Latin1Family ->
      override(bytes, label, options, fn() {
        let text = single_byte(bytes, charset_tables.Windows1252)
        case has_c1(bytes) {
          True -> #(Ok(text.0), [diagnostic.C1ReinterpretedAsWindows1252])
          False -> #(Ok(text.0), [])
        }
      })
    Encoding("UTF-8") -> {
      let #(text, errors) = utf8(utf8.strip_mark(bytes))
      #(Ok(text), malformed(errors))
    }
    Encoding("x-user-defined") -> #(Ok(user_defined(bytes)), [])
    Encoding(name) ->
      case charset_tables.table(name) {
        Ok(table) ->
          override(bytes, label, options, fn() {
            let #(text, errors) = single_byte(bytes, table)
            #(Ok(text), malformed(errors))
          })
        // A multi-byte encoding other than UTF-8 (CJK or UTF-16), or a
        // WHATWG "replacement" label.
        Error(_) -> #(Error(Nil), [
          diagnostic.UnsupportedCharset(option.unwrap(normalised, "")),
        ])
      }
    Legacy -> #(Error(Nil), [
      diagnostic.UnsupportedCharset(option.unwrap(normalised, "")),
    ])
    UnknownLabel ->
      utf8_or_windows_1252(bytes, [
        diagnostic.UnknownCharset(option.unwrap(normalised, "")),
      ])
  }
}

fn override(
  bytes: BitArray,
  label: Option(String),
  options: Options,
  otherwise: fn() -> #(Result(String, Nil), List(Kind)),
) -> #(Result(String, Nil), List(Kind)) {
  // The flag is tested first, so the extra passes only happen when it is
  // enabled.
  case options.utf8_override {
    False -> otherwise()
    True ->
      case is_ascii(bytes), utf8.to_string(utf8.strip_mark(bytes)) {
        False, Ok(text) -> #(Ok(text), [
          diagnostic.DeclaredCharsetOverridden(option.unwrap(label, "")),
        ])
        _, _ -> otherwise()
      }
  }
}

fn malformed(errors: Int) -> List(Kind) {
  case errors {
    0 -> []
    n -> [diagnostic.MalformedCharsetData(n)]
  }
}

/// UTF-8 if the bytes are valid UTF-8 (a leading byte order mark is
/// removed), otherwise windows-1252.
pub fn utf8_or_windows_1252(
  bytes: BitArray,
  kinds: List(Kind),
) -> #(Result(String, Nil), List(Kind)) {
  case utf8.to_string(utf8.strip_mark(bytes)) {
    Ok(text) -> #(Ok(text), kinds)
    Error(_) -> #(Ok(single_byte(bytes, charset_tables.Windows1252).0), kinds)
  }
}

fn is_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<c, rest:bytes>> if c < 0x80 -> is_ascii(rest)
    <<>> -> True
    _ -> False
  }
}

fn has_c1(bytes: BitArray) -> Bool {
  case bytes {
    <<c, _:bytes>> if c >= 0x80 && c <= 0x9F -> True
    <<_, rest:bytes>> -> has_c1(rest)
    _ -> False
  }
}

fn count_nul(bytes: BitArray, count: Int) -> Int {
  case bytes {
    <<0, rest:bytes>> -> count_nul(rest, count + 1)
    <<_, rest:bytes>> -> count_nul(rest, count)
    _ -> count
  }
}

fn ascii(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(_) -> ""
  }
}

// ---------------------------------------------------------------------------
// Decoders. Each builds a list of strings: runs of ASCII or valid UTF-8 are
// sliced from the input, and other bytes are looked up.

/// Decodes UTF-8, replacing each maximal invalid subpart with U+FFFD as the
/// WHATWG UTF-8 decoder does. Returns the text and the number of
/// replacements.
pub fn utf8(bytes: BitArray) -> #(String, Int) {
  case utf8.to_string(bytes) {
    Ok(text) -> #(text, 0)
    Error(_) -> utf8_loop(bytes, bytes, 0, 0, [], 0)
  }
}

fn utf8_loop(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  run_start: Int,
  acc: List(String),
  errors: Int,
) -> #(String, Int) {
  case rest {
    <<c, rest:bytes>> if c < 0x80 ->
      utf8_loop(input, rest, pos + 1, run_start, acc, errors)
    <<_, _:bytes>> ->
      case sequence(rest) {
        Ok(length) ->
          utf8_loop(
            input,
            slice(rest, length, -1),
            pos + length,
            run_start,
            acc,
            errors,
          )
        Error(skip) -> {
          let acc = ["\u{FFFD}", run(input, run_start, pos), ..acc]
          utf8_loop(
            input,
            slice(rest, skip, -1),
            pos + skip,
            pos + skip,
            acc,
            errors + 1,
          )
        }
      }
    _ -> #(
      [run(input, run_start, pos), ..acc] |> list.reverse |> string.concat,
      errors,
    )
  }
}

fn run(input: BitArray, from: Int, to: Int) -> String {
  case utf8.to_string(slice(input, from, to)) {
    Ok(text) -> text
    Error(_) -> ""
  }
}

/// The length of the valid UTF-8 sequence at the start of `bytes`, or the
/// number of bytes to replace with a single U+FFFD.
fn sequence(bytes: BitArray) -> Result(Int, Int) {
  case bytes {
    <<lead, rest:bytes>> -> {
      let #(length, low, high) = case lead {
        _ if lead >= 0xC2 && lead <= 0xDF -> #(2, 0x80, 0xBF)
        0xE0 -> #(3, 0xA0, 0xBF)
        0xED -> #(3, 0x80, 0x9F)
        _ if lead >= 0xE1 && lead <= 0xEF -> #(3, 0x80, 0xBF)
        0xF0 -> #(4, 0x90, 0xBF)
        0xF4 -> #(4, 0x80, 0x8F)
        _ if lead >= 0xF1 && lead <= 0xF3 -> #(4, 0x80, 0xBF)
        _ -> #(0, 0, 0)
      }
      case length {
        0 -> Error(1)
        _ ->
          case rest {
            <<c, rest:bytes>> if c >= low && c <= high ->
              continuation(rest, 2, length)
            _ -> Error(1)
          }
      }
    }
    _ -> Error(1)
  }
}

fn continuation(rest: BitArray, seen: Int, length: Int) -> Result(Int, Int) {
  case seen == length, rest {
    True, _ -> Ok(length)
    False, <<c, rest:bytes>> if c >= 0x80 && c <= 0xBF ->
      continuation(rest, seen + 1, length)
    False, _ -> Error(seen)
  }
}

/// Decodes a legacy single-byte encoding. Bytes without an entry in the
/// index become U+FFFD. Returns the text and the number of replacements.
fn single_byte(bytes: BitArray, table: Table) -> #(String, Int) {
  single_byte_loop(bytes, bytes, table, 0, 0, [], 0)
}

fn single_byte_loop(
  input: BitArray,
  rest: BitArray,
  table: Table,
  pos: Int,
  run_start: Int,
  acc: List(String),
  errors: Int,
) -> #(String, Int) {
  case rest {
    <<c, rest:bytes>> if c < 0x80 ->
      single_byte_loop(input, rest, table, pos + 1, run_start, acc, errors)
    <<c, rest:bytes>> -> {
      let #(decoded, errors) = case charset_tables.high_byte(table, c) {
        "" -> #("\u{FFFD}", errors + 1)
        decoded -> #(decoded, errors)
      }
      let acc = [decoded, run(input, run_start, pos), ..acc]
      single_byte_loop(input, rest, table, pos + 1, pos + 1, acc, errors)
    }
    _ -> #(
      [run(input, run_start, pos), ..acc] |> list.reverse |> string.concat,
      errors,
    )
  }
}

/// x-user-defined maps bytes 0x80-0xFF to U+F780-U+F7FF.
fn user_defined(bytes: BitArray) -> String {
  user_defined_loop(bytes, bytes, 0, 0, [])
}

fn user_defined_loop(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  run_start: Int,
  acc: List(String),
) -> String {
  case rest {
    <<c, rest:bytes>> if c < 0x80 ->
      user_defined_loop(input, rest, pos + 1, run_start, acc)
    <<c, rest:bytes>> -> {
      let decoded = case string.utf_codepoint(0xF780 + c - 0x80) {
        Ok(codepoint) -> string.from_utf_codepoints([codepoint])
        Error(_) -> "\u{FFFD}"
      }
      let acc = [decoded, run(input, run_start, pos), ..acc]
      user_defined_loop(input, rest, pos + 1, pos + 1, acc)
    }
    _ -> [run(input, run_start, pos), ..acc] |> list.reverse |> string.concat
  }
}
