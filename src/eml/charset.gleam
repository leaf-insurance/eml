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
//// - Mail names for the CJK code pages (`cp932`, `cp936`, `cp949`,
////   `cp950`, `eucjp`, ...) are accepted, and extensions of ISO-2022-JP are
////   reported as unsupported.
//// - A byte order mark decides the byte order of UTF-16, as in WHATWG, and
////   `DeclaredCharsetOverridden` is reported when it contradicts a label
////   that names a byte order.
////
//// A declared single-byte charset is never overridden by sniffing, unless
//// the caller asks for it with `with_utf8_override`.

import eml/diagnostic.{type Kind}
import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import text_encoding.{type Encoding, KeepBom, SniffBom}

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

/// When enabled, text that declares a charset other than UTF-8 or UTF-16
/// but is valid UTF-8 containing non-ASCII bytes is decoded as UTF-8, and
/// `DeclaredCharsetOverridden` is reported. This helps with senders that
/// mislabel UTF-8. For the multi-byte CJK charsets the text must contain a
/// UTF-8 sequence of three or more bytes, since short CJK text is often
/// valid two-byte UTF-8 by chance; even so, a short name in Shift_JIS can be
/// misread. Adjacent encoded-words in one charset are decided together,
/// except in ISO-2022-JP. It is off by default, because valid UTF-8 is not
/// proof of intent.
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
  "armscii-8", "georgian-ps", "koi8-t", "cp1125", "cp50220", "cp50221",
  "cp50222", "csiso2022jp2",
]

/// Names for WHATWG encodings that mail uses and WHATWG does not list.
const mail_aliases = [
  #("cp932", text_encoding.ShiftJis),
  #("windows-932", text_encoding.ShiftJis),
  #("cp936", text_encoding.Gbk),
  #("windows-936", text_encoding.Gbk),
  #("ms936", text_encoding.Gbk),
  #("euc-cn", text_encoding.Gbk),
  #("cp949", text_encoding.EucKr),
  #("ms949", text_encoding.EucKr),
  #("uhc", text_encoding.EucKr),
  #("x-windows-949", text_encoding.EucKr),
  #("cp950", text_encoding.Big5),
  #("ms950", text_encoding.Big5),
  #("windows-950", text_encoding.Big5),
  #("eucjp", text_encoding.EucJp),
  #("euc_jp", text_encoding.EucJp),
  #("ujis", text_encoding.EucJp),
]

const ascii_labels = [
  "us-ascii", "ascii", "ansi_x3.4-1968", "ansi_x3.4-1986", "iso646-us", "us",
  "iso-ir-6", "iso_646.irv:1991", "cp367", "ibm367", "csascii", "646",
]

const latin1_labels = [
  "iso-8859-1", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987",
  "latin1", "latin-1", "l1", "cp819", "ibm819", "csisolatin1", "iso-ir-100",
]

/// Normalises a label as WHATWG does: trims ASCII whitespace and lowercases
/// ASCII letters. Other characters are kept.
pub fn normalise(label: String) -> String {
  string.to_utf_codepoints(label)
  |> list.map(string.utf_codepoint_to_int)
  |> list.drop_while(is_whitespace)
  |> list.reverse
  |> list.drop_while(is_whitespace)
  |> list.reverse
  |> list.filter_map(fn(c) {
    case c >= 0x41 && c <= 0x5A {
      True -> string.utf_codepoint(c + 32)
      False -> string.utf_codepoint(c)
    }
  })
  |> string.from_utf_codepoints
}

fn is_whitespace(c: Int) -> Bool {
  c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20
}

fn family(label: String) -> Family {
  case list.contains(ascii_labels, label), list.contains(latin1_labels, label) {
    True, _ -> AsciiFamily
    _, True -> Latin1Family
    False, False ->
      case list.key_find(mail_aliases, label), text_encoding.get(label) {
        Ok(encoding), _ | _, Ok(encoding) -> Whatwg(encoding)
        _, _ ->
          // Every ISO-2022 variant but ISO-2022-JP is 7-bit, so the
          // unknown-label rule would pass its escape sequences off as text.
          case
            list.contains(legacy_labels, label)
            || string.starts_with(label, "iso-2022-")
          {
            True -> Legacy
            False -> UnknownLabel
          }
      }
  }
}

/// A declared charset label, resolved once.
@internal
pub opaque type Charset {
  Charset(declared: Option(String), label: String, family: Family)
}

@internal
pub fn resolve(declared: Option(String)) -> Charset {
  case declared {
    None -> Charset(None, "", AsciiFamily)
    Some(declared) -> {
      let label = normalise(declared)
      Charset(Some(declared), label, family(label))
    }
  }
}

/// Whether two labels name the same charset, so that their encoded-words
/// form one run. A UTF-16 label that names a byte order is not the same as
/// one that does not, since only the latter follows a byte order mark in
/// the word before.
@internal
pub fn same(a: Charset, b: Charset) -> Bool {
  case a.family, b.family {
    Legacy, Legacy | UnknownLabel, UnknownLabel -> a.label == b.label
    Whatwg(text_encoding.Utf16Be), _ | Whatwg(text_encoding.Utf16Le), _ ->
      a.family == b.family && names_order(a) == names_order(b)
    a, b -> a == b
  }
}

fn names_order(charset: Charset) -> Bool {
  list.contains(
    ["utf-16be", "utf-16le", "unicodefffe", "unicodefeff"],
    charset.label,
  )
}

/// Whether the bytes of adjacent encoded-words in this charset may be
/// joined to repair a character split between them: the multi-byte
/// charsets without state. Not ISO-2022-JP, which has shift states, nor
/// UTF-16, where a byte order mark in one word would decide the byte order
/// of the others. Unknown labels are never joined.
fn can_join(charset: Charset) -> Bool {
  case charset.family {
    Whatwg(text_encoding.Iso2022Jp)
    | Whatwg(text_encoding.Replacement)
    | Whatwg(text_encoding.Utf16Be)
    | Whatwg(text_encoding.Utf16Le) -> False
    Whatwg(_) -> True
    _ -> False
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
  let decoded = decode_charset(bytes, resolve(label), options, <<>>)
  #(decoded.text, decoded.kinds)
}

/// The result of decoding an encoded-word. `custom` is whether the
/// caller's decoder decoded it.
@internal
pub type Decoded {
  Decoded(
    text: Result(String, Nil),
    kinds: List(Kind),
    state: BitArray,
    custom: Bool,
  )
}

/// Decodes one encoded-word of a run. `state` is what the previous word
/// passes on to this one: the escape sequence of the ISO-2022-JP state it
/// ended in, or the byte order mark that decided its UTF-16 byte order, or
/// `<<>>`. The result has the state to pass on to the next word. The UTF-8
/// override is left to `decode_together`, except for ISO-2022-JP, whose
/// words are 7-bit and so valid UTF-8 whatever they mean.
@internal
pub fn decode_word(
  bytes: BitArray,
  charset: Charset,
  options: Options,
  state: BitArray,
) -> Decoded {
  let options = case charset.family {
    Whatwg(text_encoding.Iso2022Jp) -> options
    _ -> Options(..options, utf8_override: False)
  }
  decode_charset(bytes, charset, options, state)
}

/// Decodes the words of a run that the built-in decoders decoded, together,
/// when that is better than one by one: as UTF-8, when the override applies
/// to them together, or else, when `repair` is set, by joining their bytes,
/// when that leaves no malformed data. The charset is the first word's.
@internal
pub fn decode_together(
  words: List(#(BitArray, Charset)),
  options: Options,
  repair: Bool,
) -> Result(Decoded, Nil) {
  case words {
    [] -> Error(Nil)
    [#(_, charset), ..] -> {
      let pieces = list.map(words, fn(word) { word.0 })
      let as_utf8 = case charset.family {
        Whatwg(text_encoding.Iso2022Jp) -> Error(Nil)
        _ -> as_utf8(pieces, charset, options)
      }
      case as_utf8, repair && can_join(charset) {
        Ok(text), _ ->
          Ok(
            with_nul(done(
              Ok(text),
              list.map(words, fn(word) { overridden(word.1) }),
            )),
          )
        Error(_), True -> {
          // A byte order mark at the start of a UTF-8 word is not text.
          let pieces = case charset.family {
            Whatwg(text_encoding.Utf8) -> list.map(pieces, utf8.strip_mark)
            _ -> pieces
          }
          let decoded = builtin(bit_array.concat(pieces), charset, <<>>)
          case list.any(decoded.kinds, is_malformed) {
            True -> Error(Nil)
            False ->
              Ok(with_nul(
                Decoded(..decoded, kinds: [
                  diagnostic.EncodedWordSplitCharacter,
                  ..decoded.kinds
                ]),
              ))
          }
        }
        Error(_), False -> Error(Nil)
      }
    }
  }
}

fn decode_charset(
  bytes: BitArray,
  charset: Charset,
  options: Options,
  state: BitArray,
) -> Decoded {
  let custom = case charset.declared, options.decoder {
    Some(label), Some(decoder) -> decoder(label, bytes)
    _, _ -> Error(Nil)
  }
  case custom {
    Ok(text) -> with_nul(Decoded(Ok(text), [], <<>>, True))
    Error(_) ->
      case as_utf8([bytes], charset, options) {
        Ok(text) -> with_nul(done(Ok(text), [overridden(charset)]))
        Error(_) -> with_nul(builtin(bytes, charset, state))
      }
  }
}

/// NUL is counted in the decoded text: a decoder (UTF-16, say) can turn
/// zero bytes into other characters.
fn with_nul(decoded: Decoded) -> Decoded {
  case decoded.text {
    Ok(text) ->
      case count_nul(bit_array.from_string(text), 0) {
        0 -> decoded
        n ->
          Decoded(
            ..decoded,
            kinds: list.append(decoded.kinds, [diagnostic.NulInText(n)]),
          )
      }
    Error(_) -> decoded
  }
}

fn done(text: Result(String, Nil), kinds: List(Kind)) -> Decoded {
  Decoded(text, kinds, <<>>, False)
}

fn builtin(bytes: BitArray, charset: Charset, state: BitArray) -> Decoded {
  case charset.family {
    AsciiFamily ->
      case is_ascii(bytes) {
        True -> done(bit_array.to_string(bytes), [])
        False -> {
          let #(text, kinds) =
            utf8_or_windows_1252(bytes, [diagnostic.NonAsciiInAscii])
          done(text, kinds)
        }
      }
    Latin1Family ->
      done(Ok(windows_1252(bytes)), case has_c1(bytes) {
        True -> [diagnostic.C1ReinterpretedAsWindows1252]
        False -> []
      })
    Whatwg(text_encoding.Replacement) | Legacy ->
      done(Error(Nil), [diagnostic.UnsupportedCharset(charset.label)])
    Whatwg(text_encoding.Utf8) -> {
      let #(text, errors) = utf8(utf8.strip_mark(bytes))
      done(Ok(text), malformed(errors))
    }
    Whatwg(text_encoding.Utf16Be as declared)
    | Whatwg(text_encoding.Utf16Le as declared) ->
      utf16(bytes, charset, declared, state)
    Whatwg(text_encoding.Iso2022Jp) -> iso_2022_jp(bytes, state)
    Whatwg(encoding) -> {
      let #(text, errors) = whatwg(bytes, encoding)
      done(Ok(text), malformed(errors))
    }
    UnknownLabel -> {
      let #(text, kinds) =
        utf8_or_windows_1252(bytes, [diagnostic.UnknownCharset(charset.label)])
      done(text, kinds)
    }
  }
}

/// A byte order mark decides, and is passed on to the next piece when it
/// differs from the declared byte order. A piece without one continues in
/// the byte order passed on to it.
fn utf16(
  bytes: BitArray,
  charset: Charset,
  declared: Encoding,
  state: BitArray,
) -> Decoded {
  let #(bytes, continued) = case state, bytes, text_encoding.bom_sniff(bytes) {
    <<>>, _, _ | _, <<>>, _ | _, _, Some(_) -> #(bytes, [])
    _, _, None -> #(<<state:bits, bytes:bits>>, [
      diagnostic.EncodedWordSplitCharacter,
    ])
  }
  let decoded = text_encoding.decode_with(bytes, declared, SniffBom)
  let overridden = case decoded.encoding, names_order(charset) {
    encoding, _ if encoding == declared -> []
    text_encoding.Utf8, _ | _, True -> [overridden(charset)]
    _, False -> []
  }
  let next = case bytes, decoded.encoding {
    <<>>, _ -> state
    _, encoding if encoding == declared -> <<>>
    _, text_encoding.Utf16Be -> <<0xFE, 0xFF>>
    _, text_encoding.Utf16Le -> <<0xFF, 0xFE>>
    _, _ -> <<>>
  }
  Decoded(
    Ok(decoded.text),
    list.flatten([continued, overridden, malformed(decoded.errors)]),
    next,
    False,
  )
}

/// Each ISO-2022-JP word should end in ASCII. When one does not, the next
/// continues in its state, unless it begins with an escape sequence of its
/// own.
fn iso_2022_jp(bytes: BitArray, state: BitArray) -> Decoded {
  let #(bytes, continued) = case state, bytes, escape(bytes) {
    <<>>, _, _ | _, <<>>, _ | _, _, Ok(_) -> #(bytes, [])
    _, _, Error(_) -> #(<<state:bits, bytes:bits>>, [
      diagnostic.EncodedWordSplitCharacter,
    ])
  }
  let #(text, errors) = whatwg(bytes, text_encoding.Iso2022Jp)
  Decoded(
    Ok(text),
    list.append(continued, malformed(errors)),
    final_state(bytes, state),
    False,
  )
}

/// The escape sequence of the ISO-2022-JP state that `bytes` end in, or
/// `<<>>` for ASCII.
fn final_state(bytes: BitArray, state: BitArray) -> BitArray {
  case escape(bytes) {
    Ok(#(state, rest)) -> final_state(rest, state)
    Error(_) ->
      case bytes {
        <<_, rest:bytes>> -> final_state(rest, state)
        _ -> state
      }
  }
}

/// An ISO-2022-JP escape sequence that selects a state, at the start of
/// `bytes`: the state's escape sequence (`<<>>` for ASCII), and the rest.
fn escape(bytes: BitArray) -> Result(#(BitArray, BitArray), Nil) {
  case bytes {
    <<0x1B, 0x28, 0x42, rest:bytes>> -> Ok(#(<<>>, rest))
    <<0x1B, 0x28, c, rest:bytes>> if c == 0x4A || c == 0x49 ->
      Ok(#(<<0x1B, 0x28, c>>, rest))
    <<0x1B, 0x24, c, rest:bytes>> if c == 0x40 || c == 0x42 ->
      Ok(#(<<0x1B, 0x24, c>>, rest))
    _ -> Error(Nil)
  }
}

/// With the UTF-8 override enabled, pieces that together are valid UTF-8,
/// with a byte of at least the charset's threshold, as UTF-8.
fn as_utf8(
  pieces: List(BitArray),
  charset: Charset,
  options: Options,
) -> Result(String, Nil) {
  case options.utf8_override, override_threshold(charset) {
    True, Ok(threshold) ->
      case list.any(pieces, has_byte_at_least(_, threshold)) {
        True ->
          list.map(pieces, utf8.strip_mark)
          |> bit_array.concat
          |> utf8.to_string
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// The lowest byte that lets the UTF-8 override apply. Short CJK text is
/// often valid two-byte UTF-8 by chance, so for a multi-byte charset it
/// takes a longer UTF-8 sequence.
fn override_threshold(charset: Charset) -> Result(Int, Nil) {
  case charset.family {
    Latin1Family -> Ok(0x80)
    Whatwg(text_encoding.Utf8)
    | Whatwg(text_encoding.Utf16Be)
    | Whatwg(text_encoding.Utf16Le)
    | Whatwg(text_encoding.Replacement) -> Error(Nil)
    Whatwg(text_encoding.Gbk)
    | Whatwg(text_encoding.Gb18030)
    | Whatwg(text_encoding.Big5)
    | Whatwg(text_encoding.EucJp)
    | Whatwg(text_encoding.ShiftJis)
    | Whatwg(text_encoding.EucKr) -> Ok(0xE0)
    Whatwg(_) -> Ok(0x80)
    AsciiFamily | Legacy | UnknownLabel -> Error(Nil)
  }
}

fn overridden(charset: Charset) -> Kind {
  diagnostic.DeclaredCharsetOverridden(option.unwrap(charset.declared, ""))
}

fn is_malformed(kind: Kind) -> Bool {
  case kind {
    diagnostic.MalformedCharsetData(_) -> True
    _ -> False
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
  !has_byte_at_least(bytes, 0x80)
}

fn has_byte_at_least(bytes: BitArray, threshold: Int) -> Bool {
  case bytes {
    <<c, _:bytes>> if c >= threshold -> True
    <<_, rest:bytes>> -> has_byte_at_least(rest, threshold)
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
