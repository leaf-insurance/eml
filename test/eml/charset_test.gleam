//// Charset decoding: assumptions.md §G.

import eml/charset
import eml/diagnostic
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn decode(bytes: BitArray, label: String) {
  charset.decode(bytes, Some(label), charset.default_options())
}

pub fn ascii_test() {
  assert decode(<<"hello">>, "us-ascii") == #(Ok("hello"), [])
  assert charset.decode(<<"hello">>, None, charset.default_options())
    == #(Ok("hello"), [])
}

pub fn ascii_with_utf8_test() {
  assert decode(<<"caf", 0xC3, 0xA9>>, "US-ASCII")
    == #(Ok("café"), [diagnostic.NonAsciiInAscii])
  assert charset.decode(<<"caf", 0xC3, 0xA9>>, None, charset.default_options())
    == #(Ok("café"), [diagnostic.NonAsciiInAscii])
}

pub fn ascii_with_windows_1252_test() {
  assert decode(<<"caf", 0xE9, " ", 0x80>>, "ascii")
    == #(Ok("café €"), [diagnostic.NonAsciiInAscii])
}

pub fn latin1_as_windows_1252_test() {
  assert decode(<<"caf", 0xE9>>, "iso-8859-1") == #(Ok("café"), [])
  assert decode(<<0x80, "5.4bn">>, " ISO-8859-1 ")
    == #(Ok("€5.4bn"), [diagnostic.C1ReinterpretedAsWindows1252])
  assert decode(<<0x92>>, "latin1")
    == #(Ok("’"), [diagnostic.C1ReinterpretedAsWindows1252])
  assert decode(<<0x92>>, "windows-1252") == #(Ok("’"), [])
}

pub fn iso_8859_15_test() {
  assert decode(<<0xA4>>, "iso-8859-15") == #(Ok("€"), [])
}

pub fn declared_charset_is_not_overridden_test() {
  // UTF-8 bytes labelled ISO-8859-15 (the mislabelled Tryg case).
  assert decode(<<0xC3, 0xA5>>, "iso-8859-15") == #(Ok("Ã¥"), [])
}

pub fn utf8_override_test() {
  let options = charset.default_options() |> charset.with_utf8_override(True)
  assert charset.decode(<<0xC3, 0xA5>>, Some("iso-8859-15"), options)
    == #(Ok("å"), [diagnostic.DeclaredCharsetOverridden("iso-8859-15")])
  // Text that is not valid UTF-8 is decoded as declared.
  assert charset.decode(<<0xE5>>, Some("iso-8859-15"), options)
    == #(Ok("å"), [])
}

pub fn other_single_byte_test() {
  assert decode(<<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>, "windows-1251")
    == #(Ok("Привет"), [])
  assert decode(<<0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4>>, "koi8-r")
    == #(Ok("Привет"), [])
}

pub fn undefined_byte_test() {
  // 0xA5 has no entry in ISO-8859-3.
  assert decode(<<"a", 0xA5, "b">>, "iso-8859-3")
    == #(Ok("a\u{FFFD}b"), [diagnostic.MalformedCharsetData(1)])
}

pub fn utf8_replacement_test() {
  let replaced = fn(bytes) { decode(bytes, "utf-8") }
  assert replaced(<<"a", 0xFF, "b">>)
    == #(Ok("a\u{FFFD}b"), [diagnostic.MalformedCharsetData(1)])
  // A truncated sequence is one replacement.
  assert replaced(<<0xE2, 0x82>>)
    == #(Ok("\u{FFFD}"), [diagnostic.MalformedCharsetData(1)])
  // Overlong and surrogate encodings: one replacement per byte.
  assert replaced(<<0xF0, 0x80, 0x80>>)
    == #(Ok("\u{FFFD}\u{FFFD}\u{FFFD}"), [diagnostic.MalformedCharsetData(3)])
  assert replaced(<<0xED, 0xA0, 0x80>>)
    == #(Ok("\u{FFFD}\u{FFFD}\u{FFFD}"), [diagnostic.MalformedCharsetData(3)])
  assert replaced(<<0xC3, 0xA9, 0xE2, 0x82, 0xAC>>) == #(Ok("é€"), [])
}

/// WHATWG "replacement" labels would decode to a single U+FFFD, losing the
/// text, so they are reported as unsupported instead.
pub fn unsupported_test() {
  assert decode(<<"a">>, "iso-2022-kr")
    == #(Error(Nil), [diagnostic.UnsupportedCharset("iso-2022-kr")])
  assert decode(<<"a">>, "hz-gb-2312")
    == #(Error(Nil), [diagnostic.UnsupportedCharset("hz-gb-2312")])
}

/// The CJK encodings are decoded by text_encoding.
pub fn cjk_test() {
  assert decode(<<0x82, 0xA0>>, "Shift_JIS") == #(Ok("あ"), [])
  assert decode(<<0xB0, 0xA1>>, "ks_c_5601-1987") == #(Ok("가"), [])
  assert decode(<<0xC4, 0xE3>>, "gb2312") == #(Ok("你"), [])
  assert decode(<<0xA4, 0x40>>, "big5") == #(Ok("一"), [])
  assert decode(<<0xA4, 0xA2>>, "euc-jp") == #(Ok("あ"), [])
  assert decode(<<0x1B, "$B$\"", 0x1B, "(B">>, "iso-2022-jp") == #(Ok("あ"), [])
  assert decode(<<0x82, 0xFF, 0x82>>, "shift_jis")
    == #(Ok("\u{FFFD}\u{FFFD}"), [diagnostic.MalformedCharsetData(2)])
}

/// UTF-16: a byte order mark decides, and "utf-16" without one is
/// big-endian, as RFC 2781 says (WHATWG would choose little-endian).
pub fn utf16_test() {
  assert decode(<<0, 0x41>>, "utf-16be") == #(Ok("A"), [])
  assert decode(<<0x41, 0>>, "utf-16le") == #(Ok("A"), [])
  assert decode(<<0xFF, 0xFE, 0x41, 0>>, "utf-16le") == #(Ok("A"), [])
  assert decode(<<0, 0x41>>, "utf-16") == #(Ok("A"), [])
  assert decode(<<0xFE, 0xFF, 0, 0x41>>, "utf-16") == #(Ok("A"), [])
  assert decode(<<0xFF, 0xFE, 0x41, 0>>, "utf-16") == #(Ok("A"), [])
  assert decode(<<0x41>>, "utf-16be")
    == #(Ok("\u{FFFD}"), [diagnostic.MalformedCharsetData(1)])
}

pub fn custom_decoder_test() {
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, _bytes) {
      case label {
        "Shift_JIS" -> Ok("あ")
        _ -> Error(Nil)
      }
    })
  assert charset.decode(<<0x82, 0xA0>>, Some("Shift_JIS"), options)
    == #(Ok("あ"), [])
  // Falling back to the built-in decoders.
  assert charset.decode(<<"x">>, Some("utf-8"), options) == #(Ok("x"), [])
}

pub fn unknown_label_test() {
  assert decode(<<"caf", 0xC3, 0xA9>>, "x-unknown")
    == #(Ok("café"), [diagnostic.UnknownCharset("x-unknown")])
  assert decode(<<"caf", 0xE9>>, "unknown-8bit")
    == #(Ok("café"), [diagnostic.UnknownCharset("unknown-8bit")])
}

pub fn nul_is_preserved_test() {
  assert decode(<<"a", 0, "b", 0>>, "utf-8")
    == #(Ok("a\u{0}b\u{0}"), [diagnostic.NulInText(2)])
}

pub fn every_label_decodes_every_byte_test() {
  let bytes = all_bytes(255, <<>>)
  list.each(labels, fn(label) {
    let #(result, _) = decode(bytes, label)
    case result {
      // ASCII is unchanged in every supported single-byte encoding.
      Ok(text) -> {
        assert string.starts_with(
          text,
          bit_array_to_string(all_bytes(0x7F, <<>>)),
        )
      }
      Error(_) -> Nil
    }
  })
}

const labels = [
  "utf-8", "ibm866", "iso-8859-2", "iso-8859-3", "iso-8859-4", "iso-8859-5",
  "iso-8859-6", "iso-8859-7", "iso-8859-8", "iso-8859-8-i", "iso-8859-10",
  "iso-8859-13", "iso-8859-14", "iso-8859-15", "iso-8859-16", "koi8-r", "koi8-u",
  "macintosh", "windows-874", "windows-1250", "windows-1251", "windows-1252",
  "windows-1253", "windows-1254", "windows-1255", "windows-1256", "windows-1257",
  "windows-1258", "x-mac-cyrillic", "x-user-defined", "us-ascii", "iso-8859-1",
  "gbk", "x-unknown",
]

fn all_bytes(n: Int, acc: BitArray) -> BitArray {
  case n < 0 {
    True -> acc
    False -> all_bytes(n - 1, <<n, acc:bits>>)
  }
}

fn bit_array_to_string(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}
