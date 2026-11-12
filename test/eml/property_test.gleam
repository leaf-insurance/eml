//// Property tests (assumptions.md §K.3, §K.5): parsing never crashes, the
//// segments always tile the source, and decoding never crashes.

import eml
import eml/internal/base64
import eml/internal/quoted_printable
import eml/support
import gleam/bit_array
import gleam/list
import gleam/string
import qcheck

fn config() {
  qcheck.default_config() |> qcheck.with_test_count(500)
}

fn check(input: BitArray) -> Nil {
  case support.parse_bytes(input) {
    Ok(message) -> support.walk(eml.root(message))
    Error(_) -> Nil
  }
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
