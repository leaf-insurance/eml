//// Charset decoding (assumptions.md §G).
////
//// Labels are resolved, and text decoded, with the WHATWG Encoding Standard
//// (the text_encoding package), with these adjustments for mail:
////
//// - US-ASCII labels, and an absent label, decode as UTF-8 when the bytes
////   are valid UTF-8, and as windows-1252 otherwise.
//// - ISO-8859-1 labels decode as windows-1252, as browsers and most mail
////   clients do. Bytes 0x80-0x9F are reported, since strictly they are C1
////   control characters.
//// - WHATWG's "replacement" labels (ISO-2022-KR, HZ-GB-2312, ...) are
////   reported as unsupported, rather than decoded to a single U+FFFD.
//// - "utf-16" follows RFC 2781: a byte order mark decides the byte order,
////   and without one the text is big-endian. A byte order mark also decides
////   for the other UTF-16 labels.
////
//// A declared single-byte charset is never overridden by sniffing, unless
//// the caller asks for it with `with_utf8_override`.

import eml/diagnostic.{type Kind}
import eml/internal/structured
import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import text_encoding.{type Encoding, KeepBom}

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
  Whatwg(Encoding)
  /// A known charset that is not built in.
  Legacy
  UnknownLabel
}

/// Charsets in use in mail that are not WHATWG encodings. They are reported
/// as unsupported rather than guessed.
const legacy_labels = [
  "utf-7", "utf7", "unicode-1-1-utf-7", "csunicode11utf7", "utf-32", "utf-32le",
  "utf-32be", "ucs-4", "437", "cp437", "ibm437", "850", "cp850", "ibm850", "852",
  "cp852", "ibm852", "855", "cp855", "ibm855", "857", "cp857", "ibm857", "860",
  "cp860", "ibm860", "861", "cp861", "ibm861", "862", "cp862", "ibm862", "863",
  "cp863", "ibm863", "865", "cp865", "ibm865", "869", "cp869", "ibm869", "cp037",
  "ibm037", "cp1047", "ibm1047", "cp500", "ibm500", "tis-620-2533", "viscii",
  "armscii-8", "georgian-ps", "koi8-t", "cp1125",
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
      case text_encoding.get(label) {
        Ok(encoding) -> Whatwg(encoding)
        Error(_) ->
          case list.contains(legacy_labels, label) {
            True -> Legacy
            False -> UnknownLabel
          }
      }
  }
}

/// Whether a label names a built-in charset without shift states, so that
/// the bytes of adjacent encoded-words may be joined to repair a character
/// split between them. ISO-2022-JP is stateful; unknown labels, and
/// charsets left to a caller's decoder, are not assumed to be stateless.
pub fn is_stateless(label: String) -> Bool {
  case family(normalise(label)) {
    AsciiFamily | Latin1Family -> True
    Whatwg(text_encoding.Iso2022Jp) | Whatwg(text_encoding.Replacement) -> False
    Whatwg(_) -> True
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
  let unsupported = fn() {
    #(Error(Nil), [diagnostic.UnsupportedCharset(option.unwrap(normalised, ""))])
  }
  case family {
    AsciiFamily ->
      case is_ascii(bytes) {
        True -> #(Ok(ascii(bytes)), [])
        False -> utf8_or_windows_1252(bytes, [diagnostic.NonAsciiInAscii])
      }
    Latin1Family ->
      override(bytes, label, options, fn() {
        let text = windows_1252(bytes)
        case has_c1(bytes) {
          True -> #(Ok(text), [diagnostic.C1ReinterpretedAsWindows1252])
          False -> #(Ok(text), [])
        }
      })
    Whatwg(text_encoding.Replacement) -> unsupported()
    Whatwg(text_encoding.Utf8) -> {
      let #(text, errors) = utf8(utf8.strip_mark(bytes))
      #(Ok(text), malformed(errors))
    }
    Whatwg(text_encoding.Utf16Be as declared)
    | Whatwg(text_encoding.Utf16Le as declared) -> {
      let #(bytes, encoding) = case bytes {
        <<0xFE, 0xFF, rest:bytes>> -> #(rest, text_encoding.Utf16Be)
        <<0xFF, 0xFE, rest:bytes>> -> #(rest, text_encoding.Utf16Le)
        _ if normalised == Some("utf-16") -> #(bytes, text_encoding.Utf16Be)
        _ -> #(bytes, declared)
      }
      let #(text, errors) = whatwg(bytes, encoding)
      #(Ok(text), malformed(errors))
    }
    Whatwg(encoding) ->
      case is_single_byte(encoding) {
        True ->
          override(bytes, label, options, fn() {
            let #(text, errors) = whatwg(bytes, encoding)
            #(Ok(text), malformed(errors))
          })
        False -> {
          let #(text, errors) = whatwg(bytes, encoding)
          #(Ok(text), malformed(errors))
        }
      }
    Legacy -> unsupported()
    UnknownLabel ->
      utf8_or_windows_1252(bytes, [
        diagnostic.UnknownCharset(option.unwrap(normalised, "")),
      ])
  }
}

fn is_single_byte(encoding: Encoding) -> Bool {
  case encoding {
    text_encoding.Utf8
    | text_encoding.Utf16Be
    | text_encoding.Utf16Le
    | text_encoding.Gbk
    | text_encoding.Gb18030
    | text_encoding.Big5
    | text_encoding.EucJp
    | text_encoding.Iso2022Jp
    | text_encoding.ShiftJis
    | text_encoding.EucKr
    | text_encoding.Replacement
    | text_encoding.XUserDefined -> False
    _ -> True
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
    Error(_) -> #(Ok(windows_1252(bytes)), kinds)
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

/// Decodes UTF-8, replacing each maximal invalid subpart with U+FFFD as the
/// WHATWG UTF-8 decoder does. A byte order mark is kept. Returns the text
/// and the number of replacements.
pub fn utf8(bytes: BitArray) -> #(String, Int) {
  whatwg(bytes, text_encoding.Utf8)
}

/// Runs a WHATWG decoder, without byte order mark handling. Returns the
/// text and the number of replacements.
fn whatwg(bytes: BitArray, encoding: Encoding) -> #(String, Int) {
  let decoded = text_encoding.decode_with(bytes, encoding, KeepBom)
  #(decoded.text, decoded.errors)
}

/// windows-1252, which has an entry for every byte.
fn windows_1252(bytes: BitArray) -> String {
  whatwg(bytes, text_encoding.Windows1252).0
}
