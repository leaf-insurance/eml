//// Regressions for the M2 code reviews:
//// docs/reviews/2026-11-12-m2-code-review-pi.md (pi-…) and
//// docs/reviews/2026-11-12-m2-code-review-fable.md (fable-…).
//// Hangs and quadratic cases are in perf_test.gleam.

import eml
import eml/address.{Group, Individual, Invalid, Mailbox}
import eml/charset
import eml/diagnostic
import eml/encoded_word
import eml/filename
import eml/internal/base64
import eml/internal/structured
import eml/mime
import eml/parameter
import eml/support
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn addresses(value: BitArray) {
  address.parse(value, charset.default_options())
}

fn is_invalid(results: List(address.Address)) -> Bool {
  case results {
    [Invalid(_)] -> True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Addresses

/// fable-F03: a bare address followed by an angle address is one mailbox.
pub fn bare_address_before_angle_address_test() {
  let expected = [
    Individual(Mailbox(Some("ceo@company.com"), "attacker", Some("evil.com"))),
  ]
  assert addresses(<<"ceo@company.com <attacker@evil.com>">>)
    == #(expected, [diagnostic.InvalidAddress])
  assert addresses(<<"ceo@company.com<attacker@evil.com>">>)
    == #(expected, [diagnostic.InvalidAddress])
}

/// pi-M3, fable-F04: whitespace between words, a second `@`, an empty
/// local part, misplaced dots and control bytes make an address invalid.
pub fn malformed_identities_are_invalid_test() {
  assert is_invalid(addresses(<<"<a b@example.com>">>).0)
  assert is_invalid(addresses(<<"<victim@example.com@evil.test>">>).0)
  assert is_invalid(addresses(<<"alice@example.com evil.test">>).0)
  assert is_invalid(addresses(<<"a@b c@d">>).0)
  assert is_invalid(addresses(<<"a@b@c">>).0)
  assert is_invalid(addresses(<<"@example.com">>).0)
  assert is_invalid(addresses(<<"a..b@example.com">>).0)
  assert is_invalid(addresses(<<"a", 0, "@b.test">>).0)
  assert is_invalid(addresses(<<"<a@b", 0, ".com>">>).0)
}

/// pi-M3, fable-F04: comments and whitespace around dots are allowed.
pub fn obsolete_dots_and_comments_test() {
  assert addresses(<<"a@ex(comment).com">>).0
    == [Individual(Mailbox(None, "a", Some("ex.com")))]
  assert addresses(<<"<a@b (c) .com>">>).0
    == [Individual(Mailbox(None, "a", Some("b.com")))]
  assert addresses(<<"a . b@example.com">>).0
    == [Individual(Mailbox(None, "a.b", Some("example.com")))]
}

/// fable-F05: a source route without a colon does not swallow the list.
pub fn route_without_colon_test() {
  let #(results, _) = addresses(<<"<@a.com>, bob@x.com, grp: c@d;">>)
  let assert [Invalid(_), Individual(bob), Group("grp", [c])] = results
  assert bob == Mailbox(None, "bob", Some("x.com"))
  assert c == Mailbox(None, "c", Some("d"))
  assert is_invalid(addresses(<<"<@example.com>">>).0)
}

/// fable-F14: a comma inside an encoded-word display name.
pub fn comma_in_encoded_display_name_test() {
  assert addresses(<<"=?utf-8?Q?Doe,_John?= <j@x.test>">>).0
    == [Individual(Mailbox(Some("Doe, John"), "j", Some("x.test")))]
}

/// pi-M5: display name decoding problems are reported.
pub fn display_name_diagnostics_test() {
  let #(_, kinds) = addresses(<<"=?iso-2022-kr?B?gqA=?= <a@b.test>">>)
  assert list.contains(kinds, diagnostic.UnsupportedCharset("iso-2022-kr"))
}

/// pi-M8, fable-F07: the same identity on both targets.
pub fn byte_order_mark_in_domain_test() {
  assert addresses(<<"a@", 0xEF, 0xBB, 0xBF, "evil.test">>).0
    == [Individual(Mailbox(None, "a", Some("\u{FEFF}evil.test")))]
}

// ---------------------------------------------------------------------------
// Encoded-words

fn decode_words(value: BitArray) {
  encoded_word.decode(value, charset.default_options())
}

/// pi-M5, fable-F08: charset and transfer recoveries are reported.
pub fn encoded_word_diagnostics_test() {
  assert decode_words(<<"=?x-unknown?Q?=FF?=">>)
    == #("ÿ", [diagnostic.UnknownCharset("x-unknown")])
  assert decode_words(<<"=?us-ascii?Q?=E9?=">>)
    == #("é", [diagnostic.NonAsciiInAscii])
  assert decode_words(<<"=?iso-8859-1?Q?=80?=">>)
    == #("€", [diagnostic.C1ReinterpretedAsWindows1252])
  assert decode_words(<<"=?utf-8?Q?a=00b?=">>)
    == #("a\u{0}b", [diagnostic.NulInText(1)])
  assert decode_words(<<"=?utf-8?B?QQ?=">>)
    == #("A", [diagnostic.MissingBase64Padding])
  assert decode_words(<<"=?utf-8?Q?=GG?=">>)
    == #("=GG", [diagnostic.InvalidQuotedPrintable(1)])
}

/// pi-m4: no split-character repair for stateful charsets. The bytes are
/// not joined; only the shift state continues into the next word.
pub fn no_repair_for_stateful_charsets_test() {
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, bytes) {
      case label, bytes {
        "iso-2022-jp", <<0x1B, "$B$\"", 0x1B, "(B">> -> Ok("あ")
        _, _ -> Error(Nil)
      }
    })
  let #(text, kinds) =
    encoded_word.decode(
      <<"=?iso-2022-jp?Q?=1B$B$?= =?iso-2022-jp?Q?=22=1B(B?=">>,
      options,
    )
  assert text == "\u{FFFD}\u{FFFD}"
  assert list.contains(kinds, diagnostic.MalformedCharsetData(2))
}

/// fable-F18: an encoded leading space is kept; only raw whitespace is
/// trimmed.
pub fn encoded_leading_space_test() {
  assert decode_words(<<" =?utf-8?Q?=20lead?= ">>) == #(" lead", [])
}

// ---------------------------------------------------------------------------
// Parameters and filenames

fn resolve(value: String) {
  let assert #(Some(content_type), _) =
    structured.parse_content_type(<<"text/plain; ":utf8, value:utf8>>)
  parameter.resolve(
    content_type.parameters,
    "filename",
    charset.default_options(),
  )
}

/// pi-M6, fable-F08: RFC 2231 charset problems are reported, and an
/// unsupported charset is not "malformed".
pub fn extended_value_diagnostics_test() {
  assert resolve("filename*=x-unknown''%FF")
    == #(parameter.Resolved("ÿ"), [diagnostic.UnknownCharset("x-unknown")])
  assert resolve("filename*=utf-8''%FF")
    == #(parameter.Resolved("\u{FFFD}"), [diagnostic.MalformedCharsetData(1)])
  assert resolve("filename*=iso-2022-kr''%82%A0")
    == #(parameter.Unsupported, [diagnostic.UnsupportedCharset("iso-2022-kr")])
  assert resolve("filename*=shift_jis''%82%A0")
    == #(parameter.Resolved("あ"), [])
}

/// pi-M7: a duplicated section index is ambiguous, even with the same
/// attribute name.
pub fn duplicated_section_index_test() {
  let entity =
    support.root(
      "Content-Disposition: attachment; filename=safe.txt; "
      <> "filename*0*=utf-8''evil; filename*0*=utf-8''other; filename*1*=.exe\r\n\r\n",
    )
  assert eml.filename(entity) == Some("safe.txt")
}

/// fable-F13: an empty filename falls through to Content-Type `name`.
pub fn empty_filename_falls_through_test() {
  let entity =
    support.root(
      "Content-Type: text/plain; name=real.txt\r\n"
      <> "Content-Disposition: attachment; filename=\"\"\r\n\r\n",
    )
  assert eml.filename(entity) == Some("real.txt")
}

/// fable-F13: parentheses inside an unquoted filename.
pub fn parentheses_in_unquoted_filename_test() {
  let entity =
    support.root(
      "Content-Disposition: attachment; filename=foo (1).pdf\r\n\r\n",
    )
  assert eml.filename(entity) == Some("foo (1).pdf")
}

/// fable-F13: backslashes in quoted Windows paths are literal.
pub fn backslashes_in_quoted_filename_test() {
  let entity =
    support.root(
      "Content-Disposition: attachment; filename=\"C:\\dir\\file.txt\"\r\n\r\n",
    )
  assert eml.filename(entity) == Some("C:\\dir\\file.txt")
  assert filename.safe("C:\\dir\\file.txt") == "file.txt"
}

const forbidden = [":", "*", "?", "\"", "<", ">", "|", "/", "\\"]

/// The invariants `filename.safe` promises, on its final output.
fn assert_safe(name: String) -> Nil {
  let codepoints =
    list.map(string.to_utf_codepoints(name), string.utf_codepoint_to_int)
  let characters =
    list.filter_map(codepoints, fn(c) {
      case string.utf_codepoint(c) {
        Ok(c) -> Ok(string.from_utf_codepoints([c]))
        Error(_) -> Error(Nil)
      }
    })
  assert !list.any(characters, fn(c) { list.contains(forbidden, c) })
  assert !list.any(codepoints, fn(c) { c < 0x20 || c == 0x7F })
  assert !string.ends_with(name, ".")
  assert !string.ends_with(name, " ")
  assert bit_array.byte_size(<<name:utf8>>) <= 255
  assert name != ""
  let stem =
    case string.split_once(name, ".") {
      Ok(#(stem, _)) -> stem
      Error(_) -> name
    }
    |> string.trim
    |> string.uppercase
  assert !list.contains(["CON", "PRN", "AUX", "NUL", "COM1", "LPT1"], stem)
  Nil
}

/// pi-M1, fable-F06: combining and prepend characters do not hide
/// forbidden characters.
pub fn forbidden_characters_in_clusters_test() {
  assert_safe(filename.safe("report.txt:\u{301}payload"))
  assert_safe(filename.safe("a*\u{301}b"))
  assert_safe(filename.safe("file.txt\u{600}:evil"))
  assert_safe(filename.safe("\u{600}|x\u{600}?"))
}

/// pi-M2, fable-F12: the checks hold after truncation.
pub fn truncation_keeps_invariants_test() {
  assert_safe(filename.safe("CONx" <> string.repeat("\u{301}", 300)))
  assert_safe(filename.safe("foo.x" <> string.repeat("\u{301}", 300)))
  assert_safe(filename.safe(
    string.repeat("a", 254) <> "." <> string.repeat("b", 20),
  ))
}

/// fable-F12: more reserved names, and invisible characters.
pub fn more_reserved_and_invisible_test() {
  assert filename.safe("COM¹") == "_COM¹"
  assert filename.safe("LPT0.txt") == "_LPT0.txt"
  assert filename.safe("CONIN$") == "_CONIN$"
  assert filename.safe("con .txt") == "_con .txt"
  assert filename.safe("foo\u{2028}bar") == "foobar"
  assert filename.safe("a\u{200B}b\u{FEFF}c") == "abc"
}

// ---------------------------------------------------------------------------
// Charsets

fn decode(bytes: BitArray, label) {
  charset.decode(bytes, label, charset.default_options())
}

/// pi-M8, fable-F07: one leading byte order mark is removed from UTF-8 text,
/// on both targets; others are kept.
pub fn byte_order_mark_test() {
  assert decode(<<0xEF, 0xBB, 0xBF, "x">>, Some("utf-8")) == #(Ok("x"), [])
  // Without a label, the BOM is 8-bit data under the implied US-ASCII.
  assert decode(<<0xEF, 0xBB, 0xBF, "x">>, None)
    == #(Ok("x"), [diagnostic.NonAsciiInAscii])
  assert decode(<<"a", 0xEF, 0xBB, 0xBF, "x">>, Some("utf-8"))
    == #(Ok("a\u{FEFF}x"), [])
  assert decode(<<0xFF, 0xEF, 0xBB, 0xBF, "x">>, Some("utf-8"))
    == #(Ok("\u{FFFD}\u{FEFF}x"), [diagnostic.MalformedCharsetData(1)])
}

/// pi-m3, fable-F15: NUL is counted in the decoded text.
pub fn nul_counted_in_output_test() {
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, _) {
      case label {
        "utf-16le" -> Ok("ok")
        _ -> Ok("a\u{0}b")
      }
    })
  assert charset.decode(<<65, 0>>, Some("utf-16le"), options) == #(Ok("ok"), [])
  assert charset.decode(<<65>>, Some("x-test"), options)
    == #(Ok("a\u{0}b"), [diagnostic.NulInText(1)])
}

/// fable-F15: known legacy charsets are unsupported, not guessed.
pub fn known_legacy_charsets_test() {
  assert decode(<<"+AOk-">>, Some("utf-7"))
    == #(Error(Nil), [diagnostic.UnsupportedCharset("utf-7")])
  assert decode(<<"x">>, Some("ibm437"))
    == #(Error(Nil), [diagnostic.UnsupportedCharset("ibm437")])
}

// ---------------------------------------------------------------------------
// Parser, decoders and validation

/// pi-M10: an invalid Content-Type inside a digest uses the digest default.
pub fn invalid_content_type_in_digest_test() {
  let entity =
    support.root(
      "Content-Type: multipart/digest; boundary=b\r\n\r\n--b\r\n"
      <> "Content-Type: bad\r\n\r\nSubject: nested\r\n\r\nbody\r\n--b--\r\n",
    )
  let assert [part] = support.parts(entity)
  assert support.content_type(part) == "message/rfc822"
  let assert eml.Embedded(_) = eml.body(part)
}

/// pi-m1, fable-F10: only lines that belong to the header block count.
pub fn header_limits_count_header_lines_only_test() {
  let bytes = fn(n) { eml.default_options() |> eml.with_max_header_bytes(n) }
  let lines = fn(n) { eml.default_options() |> eml.with_max_header_lines(n) }
  let assert Ok(_) = eml.parse_with(<<"X:y\nbody is long">>, bytes(5))
  let assert Ok(_) = eml.parse_with(<<"X:y\n\n">>, lines(1))
  let assert Ok(_) =
    eml.parse_with(<<"A: b\r\n", { string.repeat("x", 200) }:utf8>>, bytes(100))
}

/// pi-m2, fable-F16: P1 followed by data records the missing padding.
pub fn base64_p1_then_data_test() {
  let #(bytes, kinds) = base64.decode(<<"QQ=Qg==">>, 0)
  assert bytes == <<"AB">>
  assert list.map(kinds, fn(kind) { kind.0 })
    == [diagnostic.MissingBase64Padding, diagnostic.Base64DataAfterPadding(1)]
}

/// fable-F17: an unknown transfer encoding is reported once.
pub fn unknown_encoding_reported_once_test() {
  let message = support.parse("Content-Transfer-Encoding: x-foo\r\n\r\nbody")
  assert list.map(eml.diagnose(message), fn(d) { d.kind })
    == [diagnostic.UnknownTransferEncoding("x-foo")]
}

/// pi-M4: truncating diagnostics does not make validation pass.
pub fn validation_after_truncation_test() {
  let input = <<"Content-Type: multipart/mixed\n\nx">>
  let options = eml.default_options() |> eml.with_max_diagnostics(0)
  let assert Ok(message) = eml.parse_with(input, options)
  let assert Error(_) = eml.validate(message, diagnostic.DataLoss)

  let input = <<
    string.repeat("X : a\n", 1000):utf8,
    "Content-Type: multipart/mixed\n\nx",
  >>
  let assert Ok(message) = eml.parse(input)
  let assert Error(_) = eml.validate(message, diagnostic.DataLoss)
}

/// fable-F08: header problems are part of `diagnose`.
pub fn header_problems_are_diagnosed_test() {
  let message =
    support.parse(
      "From: a@b c@d\r\nSubject: =?iso-2022-kr?B?GyRCJCIbKEI=?=\r\n\r\nbody",
    )
  let kinds = list.map(eml.diagnose(message), fn(d) { d.kind })
  assert list.contains(kinds, diagnostic.InvalidAddress)
  assert list.contains(kinds, diagnostic.UnsupportedCharset("iso-2022-kr"))
  let assert Error(_) = eml.validate(message, diagnostic.Warning)
}

/// pi-B1: a stray `)` or `]` made address tokenising loop forever. Every
/// byte that ends an atom must be consumed.
pub fn atom_terminators_terminate_test() {
  [")", "]", "(", "[", "\"", "<", ">", "@", ",", ";", ":", ".", "\\"]
  |> list.each(fn(c) {
    let #(_, _) = addresses(<<c:utf8>>)
    let #(_, _) = addresses(<<"a", c:utf8, "b@c.test">>)
    Nil
  })
  assert addresses(<<")">>).0 == [Invalid(")")]
}

/// pi-B2, fable-F01: groups do not nest, and nested group syntax is not
/// parsed recursively.
pub fn nested_groups_test() {
  let #(results, _) =
    addresses(<<
      string.repeat("G:", 3000):utf8,
      "a@b",
      string.repeat(";", 3000):utf8,
    >>)
  let assert [Group("G", _), ..] = results
}

/// pi-m5: a special followed by a combining mark is still quoted.
pub fn quoting_with_combining_mark_test() {
  assert address.to_string(Mailbox(None, "a@\u{301}b", Some("example.com")))
    == "\"a@\u{301}b\"@example.com"
}

/// fable-F09: the accessors can use a caller's charset decoder.
pub fn accessors_with_charset_options_test() {
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, _) {
      case label {
        "iso-2022-jp" -> Ok("custom")
        _ -> Error(Nil)
      }
    })
  let entity =
    support.root(
      "Subject: =?iso-2022-jp?B?GyRCN29MPhsoQg==?=\r\n"
      <> "From: =?iso-2022-jp?B?GyRCN29MPhsoQg==?= <a@b.test>\r\n"
      <> "Content-Disposition: attachment; filename*=iso-2022-jp''%1B%24B\r\n\r\n",
    )
  assert eml.subject_with(entity, options) == mime.Single("custom")
  assert eml.addresses_with(entity, "from", options)
    == mime.Single([Individual(Mailbox(Some("custom"), "a", Some("b.test")))])
  assert eml.filename_with(entity, options) == Some("custom")
  // Without the decoder, the built-in ISO-2022-JP decoder is used.
  assert eml.subject(entity) == mime.Single("件名")
}

/// pi-r4-3: a byte order mark in a Content-Type charset label is kept on
/// both targets, so the label is unknown on both.
pub fn content_type_label_with_byte_order_mark_test() {
  let input = <<
    "Content-Type: text/plain; charset=\"\u{FEFF}utf-16le\"\n\n":utf8,
    65,
    0,
  >>
  let assert Ok(message) = eml.parse(input)
  let #(text, diagnostics) = eml.decode_text(eml.root(message))
  assert text == Ok("A\u{0000}")
  assert list.map(diagnostics, fn(d) { d.kind })
    == [diagnostic.UnknownCharset("\u{FEFF}utf-16le"), diagnostic.NulInText(1)]
}
