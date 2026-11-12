//// Limits fail by default; diagnostics are truncated (assumptions.md §B.3,
//// §B.4).

import eml
import eml/diagnostic
import eml/mime
import gleam/list
import gleam/string

fn nested(depth: Int) -> String {
  case depth {
    0 -> "Subject: leaf\r\n\r\nbody"
    _ -> "Content-Type: message/rfc822\r\n\r\n" <> nested(depth - 1)
  }
}

pub fn depth_test() {
  let input = <<nested(3):utf8>>
  let options = fn(max) { eml.default_options() |> eml.with_max_depth(max) }
  let assert Ok(_) = eml.parse_with(input, options(3))
  assert eml.parse_with(input, options(2))
    == Error(mime.LimitExceeded(mime.MaxDepth))
}

pub fn parts_test() {
  let input = <<
    "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\n1\r\n--b\r\n\r\n2\r\n--b--":utf8,
  >>
  let options = fn(max) { eml.default_options() |> eml.with_max_parts(max) }
  let assert Ok(_) = eml.parse_with(input, options(3))
  assert eml.parse_with(input, options(2))
    == Error(mime.LimitExceeded(mime.MaxParts))
  assert eml.parse_with(input, options(0))
    == Error(mime.LimitExceeded(mime.MaxParts))
}

pub fn header_bytes_test() {
  let input = <<"Subject: 12345\r\n\r\n":utf8>>
  let options = fn(max) {
    eml.default_options() |> eml.with_max_header_bytes(max)
  }
  let assert Ok(_) = eml.parse_with(input, options(18))
  assert eml.parse_with(input, options(17))
    == Error(mime.LimitExceeded(mime.MaxHeaderBytes))
}

pub fn header_lines_test() {
  let input = <<"A: 1\r\nB: 2\r\n continued\r\n\r\n":utf8>>
  let options = fn(max) {
    eml.default_options() |> eml.with_max_header_lines(max)
  }
  let assert Ok(_) = eml.parse_with(input, options(4))
  assert eml.parse_with(input, options(3))
    == Error(mime.LimitExceeded(mime.MaxHeaderLines))
}

pub fn diagnostics_are_truncated_test() {
  let input = <<string.repeat("garbage\nX: y\n", 10):utf8, "\nbody">>
  let options = eml.default_options() |> eml.with_max_diagnostics(3)
  let assert Ok(message) = eml.parse_with(input, options)
  let kinds = eml.diagnostics(message) |> list.map(fn(d) { d.kind })
  assert kinds
    == [
      diagnostic.NonHeaderLine,
      diagnostic.NonHeaderLine,
      diagnostic.NonHeaderLine,
      diagnostic.DiagnosticsTruncated,
    ]
}

pub fn diagnostics_cap_zero_test() {
  let input = <<"garbage\nX: y\n\nbody">>
  let options = eml.default_options() |> eml.with_max_diagnostics(0)
  let assert Ok(message) = eml.parse_with(input, options)
  assert list.map(eml.diagnostics(message), fn(d) { d.kind })
    == [diagnostic.DiagnosticsTruncated]
}
