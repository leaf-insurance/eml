//// Doubling tests (assumptions.md §J.3). Each family is timed at size n and
//// 8n. Linear work grows about 8 times; quadratic work grows about 64 times.
//// The threshold of 32 leaves room for BEAM heap growth, which makes large
//// parses grow somewhat faster than linearly with default heap settings.
//// Large inputs also catch stack overflows on the JavaScript target.

import eml
import eml/address
import eml/charset
import eml/encoded_word
import eml/filename
import eml/internal/base64
import eml/internal/quoted_printable
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

@external(erlang, "eml_perf_ffi", "now_us")
@external(javascript, "../eml_perf_ffi.mjs", "now_us")
fn now_us() -> Int

/// The best of three runs, in microseconds.
fn time(f: fn() -> a) -> Int {
  [1, 2, 3]
  |> list.map(fn(_) {
    let start = now_us()
    let _ = f()
    now_us() - start
  })
  |> list.fold(1_000_000_000, int.min)
}

fn assert_linear(
  name: String,
  make: fn(Int) -> BitArray,
  run: fn(BitArray) -> a,
) {
  let small = make(1)
  let large = make(8)
  let t_small = int.max(time(fn() { run(small) }), 1000)
  let t_large = time(fn() { run(large) })
  let ratio = t_large / t_small
  case ratio < 32 {
    True -> Nil
    False -> panic as { name <> ": growth ratio " <> int.to_string(ratio) }
  }
}

fn options() {
  eml.default_options()
  |> eml.with_max_header_lines(1_000_000)
  |> eml.with_max_header_bytes(100_000_000)
  |> eml.with_max_parts(1_000_000)
}

fn parse(input: BitArray) {
  let assert Ok(message) = eml.parse_with(input, options())
  message
}

const unit = 20_000

pub fn long_line_test() {
  assert_linear(
    "long line",
    fn(k) {
      <<
        "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\n":utf8,
        string.repeat("x", k * unit * 4):utf8,
        "\r\n--b--":utf8,
      >>
    },
    parse,
  )
}

pub fn many_header_lines_test() {
  assert_linear(
    "header lines",
    fn(k) { <<string.repeat("X-A: b\r\n", k * unit):utf8, "\r\nbody":utf8>> },
    parse,
  )
}

pub fn many_folded_lines_test() {
  assert_linear(
    "folded lines",
    fn(k) {
      <<
        "Subject: a\r\n":utf8,
        string.repeat(" b\r\n", k * unit):utf8,
        "\r\n":utf8,
      >>
    },
    fn(input) { eml.header_values(eml.root(parse(input)), "subject") },
  )
}

pub fn many_anomalies_test() {
  assert_linear(
    "anomalies",
    fn(k) {
      <<
        "A: b\r\n":utf8,
        string.repeat("junk\r\nX: y\r\n", k * unit / 2):utf8,
        "\r\n":utf8,
      >>
    },
    parse,
  )
}

pub fn many_parts_test() {
  assert_linear(
    "parts",
    fn(k) {
      <<
        "Content-Type: multipart/mixed; boundary=b\r\n\r\n":utf8,
        string.repeat("--b\r\n\r\nx\r\n", k * unit / 4):utf8,
        "--b--\r\n":utf8,
      >>
    },
    fn(input) { eml.segments(parse(input)) },
  )
}

pub fn boundary_near_matches_test() {
  assert_linear(
    "near matches",
    fn(k) {
      <<
        "Content-Type: multipart/mixed; boundary=boundary\r\n\r\n--boundary\r\n\r\n":utf8,
        string.repeat("--boundar\r\n--bound\r\n", k * unit / 2):utf8,
        "--boundary--":utf8,
      >>
    },
    parse,
  )
}

pub fn base64_test() {
  assert_linear(
    "base64",
    fn(k) { <<string.repeat("QUJDREVGR0hJSktM\r\n", k * unit / 2):utf8>> },
    fn(input) { base64.decode(input, 0) },
  )
}

pub fn quoted_printable_test() {
  assert_linear(
    "quoted-printable",
    fn(k) { <<string.repeat("caf=C3=A9 =\r\n", k * unit / 2):utf8>> },
    fn(input) { quoted_printable.decode(input, 0) },
  )
}

pub fn quoted_printable_trailing_spaces_test() {
  assert_linear(
    "quoted-printable spaces",
    fn(k) { <<string.repeat(" ", k * unit * 4):utf8, "x":utf8>> },
    fn(input) { quoted_printable.decode(input, 0) },
  )
}

pub fn many_parameters_test() {
  assert_linear(
    "parameters",
    fn(k) {
      <<
        "Content-Type: text/plain":utf8,
        string.repeat("; a=b", k * unit / 2):utf8,
        "\r\n\r\n":utf8,
      >>
    },
    parse,
  )
}

pub fn many_addresses_test() {
  assert_linear(
    "addresses",
    fn(k) {
      <<
        "To: ":utf8,
        string.repeat("Alice <a@b.test>, @@@, ", k * unit / 8):utf8,
        "\r\n\r\n":utf8,
      >>
    },
    fn(input) { eml.addresses(eml.root(parse(input)), "to") },
  )
}

pub fn long_encoded_subject_test() {
  assert_linear(
    "encoded words",
    fn(k) {
      <<
        "Subject: ":utf8,
        string.repeat("=?utf-8?q?caf=C3=A9?= ", k * unit / 8):utf8,
        "\r\n\r\n":utf8,
      >>
    },
    fn(input) { eml.subject(eml.root(parse(input))) },
  )
}

// Malformed inputs from the M2 code reviews (pi-M9, fable-F02, fable-F11,
// fable-F01). Each was quadratic, or overflowed the stack on JavaScript.

pub fn unclosed_encoded_words_test() {
  assert_linear(
    "unclosed encoded words",
    fn(k) { <<string.repeat("=?a?q?x", k * unit / 16):utf8>> },
    fn(input) { encoded_word.decode(input, charset.default_options()) },
  )
}

pub fn unclosed_comments_test() {
  assert_linear(
    "unclosed comments",
    fn(k) { <<string.repeat("(<", k * unit / 8):utf8, "a@b>":utf8>> },
    fn(input) { address.parse(input, charset.default_options()) },
  )
}

pub fn unclosed_quoted_strings_test() {
  assert_linear(
    "unclosed quoted strings",
    fn(k) { <<"\"":utf8, string.repeat("<\\\"", k * unit / 8):utf8>> },
    fn(input) { address.parse(input, charset.default_options()) },
  )
}

pub fn nested_groups_test() {
  assert_linear(
    "nested groups",
    fn(k) { <<string.repeat("a:", k * unit / 8):utf8>> },
    fn(input) { address.parse(input, charset.default_options()) },
  )
}

pub fn filename_trailing_dots_test() {
  assert_linear(
    "filename trailing dots",
    fn(k) { <<"a":utf8, string.repeat(". ", k * unit / 8):utf8>> },
    fn(input) {
      let assert Ok(name) = bit_array.to_string(input)
      filename.safe(name)
    },
  )
}

pub fn long_dotted_local_part_test() {
  assert_linear(
    "dotted local part",
    fn(k) { <<string.repeat("a.", k * unit / 8):utf8, "a@b.test":utf8>> },
    fn(input) { address.parse(input, charset.default_options()) },
  )
}
