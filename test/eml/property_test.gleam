//// Property tests (assumptions.md §K.3, §K.5): parsing never crashes, the
//// segments always tile the source, and decoding never crashes.

import eml
import eml/address
import eml/charset
import eml/encoded_word
import eml/filename
import eml/internal/base64
import eml/internal/quoted_printable
import eml/internal/structured
import eml/parameter
import eml/support
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

fn config() {
  qcheck.default_config() |> qcheck.with_test_count(500)
}

fn check(input: BitArray) -> Nil {
  support.exercise(input)
}

pub fn arbitrary_bytes_never_crash_test() {
  use input <- qcheck.run(config(), qcheck.byte_aligned_bit_array())
  check(input)
}

/// Fragments that steer generated input into the interesting parts of the
/// parser: headers, folding, boundaries, encodings and broken framing.
fn fragment() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("Subject: hi"), [
    qcheck.return("Content-Type: multipart/mixed; boundary=b"),
    qcheck.return("Content-Type: multipart/alternative; boundary=\"b2\""),
    qcheck.return("Content-Type: message/rfc822"),
    qcheck.return("Content-Type: multipart/digest; boundary=b"),
    qcheck.return("Content-Transfer-Encoding: base64"),
    qcheck.return("Content-Transfer-Encoding: quoted-printable"),
    qcheck.return("Content-Transfer-Encoding: x-weird"),
    qcheck.return("--b"),
    qcheck.return("--b--"),
    qcheck.return("--b2"),
    qcheck.return("--b2--"),
    qcheck.return("--bjunk"),
    qcheck.return(" folded"),
    qcheck.return("\t"),
    qcheck.return(""),
    qcheck.return("garbage"),
    qcheck.return("QUJD=="),
    qcheck.return("=C3=A9=\r"),
    qcheck.return("From x"),
    qcheck.return("X : y"),
    qcheck.return("(comment"),
    qcheck.string_from(qcheck.bounded_codepoint(0, 255)),
  ])
}

fn line_ending() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("\r\n"), [
    qcheck.return("\n"),
    qcheck.return("\r"),
  ])
}

fn email_like() -> qcheck.Generator(BitArray) {
  qcheck.list_from(qcheck.tuple2(fragment(), line_ending()))
  |> qcheck.map(fn(lines) {
    lines
    |> list.map(fn(line) { line.0 <> line.1 })
    |> string.concat
    |> bit_array.from_string
  })
}

pub fn email_like_input_never_crashes_test() {
  use input <- qcheck.run(config(), email_like())
  check(input)
}

pub fn email_like_input_with_lf_never_crashes_test() {
  // Prefixing a valid field means most inputs are admitted.
  use input <- qcheck.run(config(), email_like())
  check(<<"Content-Type: multipart/mixed; boundary=b\n\n--b\n", input:bits>>)
}

pub fn decoders_never_crash_test() {
  use input <- qcheck.run(config(), qcheck.byte_aligned_bit_array())
  let _ = base64.decode(input, 0)
  let _ = quoted_printable.decode(input, 0)
  Nil
}

pub fn base64_round_trip_test() {
  // The encoder is gleam_stdlib's, independent of the decoder.
  use bytes <- qcheck.run(config(), qcheck.byte_aligned_bit_array())
  let encoded = bit_array.base64_encode(bytes, True)
  let #(decoded, kinds) = base64.decode(<<encoded:utf8>>, 0)
  assert decoded == bytes
  assert kinds == []
}

pub fn identity_bytes_survive_test() {
  use bytes <- qcheck.run(config(), qcheck.byte_aligned_bit_array())
  let assert Ok(message) =
    support.parse_bytes(<<"Subject: x\r\n\r\n", bytes:bits>>)
  let entity = eml.root(message)
  assert eml.raw_body(entity) == bytes
  assert eml.decode_body(entity).0 == bytes
}

pub fn line_endings_do_not_change_structure_test() {
  use bodies <- qcheck.run(
    config(),
    qcheck.list_from(qcheck.string_from(qcheck.bounded_codepoint(97, 122))),
  )
  let render = fn(eol) {
    "Content-Type: multipart/mixed; boundary=b"
    <> eol
    <> eol
    <> string.concat(
      list.map(bodies, fn(body) { "--b" <> eol <> eol <> body <> eol }),
    )
    <> "--b--"
    <> eol
  }
  let structure = fn(eol) {
    let assert Ok(message) = support.parse_bytes(<<render(eol):utf8>>)
    case eml.body(eml.root(message)) {
      eml.Multipart(parts:, ..) -> list.map(parts, eml.raw_body)
      _ -> []
    }
  }
  let expected = list.map(bodies, bit_array.from_string)
  assert structure("\r\n") == expected
  assert structure("\n") == expected
  assert structure("\r") == expected
}

// ---------------------------------------------------------------------------
// M2 functions (M2 code reviews: pi test notes, fable-F19). The alphabet is
// the bytes that drive the header grammars.

fn structural_byte() -> qcheck.Generator(Int) {
  qcheck.from_generators(qcheck.return(0x28), [
    // ( ) < > " \ : ; , @ = ? . [ ] _ * ' %
    qcheck.return(0x29),
    qcheck.return(0x3C),
    qcheck.return(0x3E),
    qcheck.return(0x22),
    qcheck.return(0x5C),
    qcheck.return(0x3A),
    qcheck.return(0x3B),
    qcheck.return(0x2C),
    qcheck.return(0x40),
    qcheck.return(0x3D),
    qcheck.return(0x3F),
    qcheck.return(0x2E),
    qcheck.return(0x5B),
    qcheck.return(0x5D),
    qcheck.return(0x5F),
    qcheck.return(0x2A),
    qcheck.return(0x27),
    qcheck.return(0x25),
    // Letters, digits, whitespace, high bytes, NUL.
    qcheck.return(0x61),
    qcheck.return(0x42),
    qcheck.return(0x51),
    qcheck.return(0x30),
    qcheck.return(0x20),
    qcheck.return(0x0A),
    qcheck.return(0xC3),
    qcheck.return(0xA9),
    qcheck.return(0x80),
    qcheck.return(0),
  ])
}

fn structural() -> qcheck.Generator(BitArray) {
  qcheck.generic_byte_aligned_bit_array(
    values_from: structural_byte(),
    byte_size_from: qcheck.bounded_int(0, 48),
  )
}

pub fn address_parse_never_crashes_test() {
  use input <- qcheck.run(config(), structural())
  let #(addresses, _) = address.parse(input, charset.default_options())
  // Formatting a parsed mailbox never crashes either.
  list.each(address.mailboxes(addresses), fn(mailbox) {
    let _ = address.to_string(mailbox)
    Nil
  })
}

pub fn encoded_word_decode_never_crashes_test() {
  use input <- qcheck.run(config(), structural())
  let _ =
    encoded_word.decode(
      <<"=?utf-8?q?", input:bits, "?=">>,
      charset.default_options(),
    )
  let _ = encoded_word.decode(input, charset.default_options())
  Nil
}

pub fn parameter_resolve_never_crashes_test() {
  use input <- qcheck.run(config(), structural())
  case
    structured.parse_content_type(<<"text/plain; filename*0*=", input:bits>>)
  {
    #(Some(content_type), _) -> {
      let _ =
        parameter.resolve(
          content_type.parameters,
          "filename",
          charset.default_options(),
        )
      Nil
    }
    #(None, _) -> Nil
  }
}

const labels = [
  "utf-8", "us-ascii", "iso-8859-1", "windows-1251", "koi8-r", "shift_jis",
  "utf-7", "x-unknown", "iso-8859-3",
]

pub fn charset_decode_never_crashes_test() {
  use input <- qcheck.run(config(), qcheck.byte_aligned_bit_array())
  list.each(labels, fn(label) {
    let _ = charset.decode(input, Some(label), charset.default_options())
    Nil
  })
}

pub fn safe_filename_invariants_test() {
  use name <- qcheck.run(
    config(),
    qcheck.string_from(qcheck.bounded_codepoint(0, 0x2100)),
  )
  let safe = filename.safe(name)
  assert safe != ""
  assert !string.ends_with(safe, ".")
  assert !string.ends_with(safe, " ")
  assert bit_array.byte_size(<<safe:utf8>>) <= 255
  assert !list.any(string.to_utf_codepoints(safe), fn(c) {
    case string.utf_codepoint_to_int(c) {
      0x3A | 0x2A | 0x3F | 0x22 | 0x3C | 0x3E | 0x7C | 0x2F | 0x5C -> True
      c -> c < 0x20 || c == 0x7F
    }
  })
  // It is idempotent.
  assert filename.safe(safe) == safe
}

pub fn bodies_and_diagnose_never_crash_test() {
  use input <- qcheck.run(config(), email_like())
  case support.parse_bytes(input) {
    Ok(message) -> {
      let _ = eml.bodies(message)
      let _ = eml.diagnose(message)
      Nil
    }
    Error(_) -> Nil
  }
}
