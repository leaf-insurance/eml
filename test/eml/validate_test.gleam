//// diagnose and validate (assumptions.md §B.5, §B.6).

import eml
import eml/diagnostic
import eml/support
import gleam/list

pub fn clean_message_test() {
  let message = support.parse("Subject: x\r\n\r\nbody")
  assert eml.diagnose(message) == []
  let assert Ok(_) = eml.validate(message, diagnostic.Info)
}

pub fn decode_problems_are_included_test() {
  // Structurally fine; the base64 body loses a byte when decoded.
  let message =
    support.parse(
      "Content-Type: application/pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nQUJDR",
    )
  assert eml.diagnostics(message) == []
  assert list.map(eml.diagnose(message), fn(d) { d.kind })
    == [diagnostic.InvalidBase64Length]
  let assert Error([_]) = eml.validate(message, diagnostic.DataLoss)
}

pub fn charset_problems_are_included_test() {
  let message =
    support.parse("Content-Type: text/plain; charset=shift_jis\r\n\r\nx")
  assert list.map(eml.diagnose(message), fn(d) { d.kind })
    == [diagnostic.UnsupportedCharset("shift_jis")]
}

pub fn threshold_test() {
  // A missing close delimiter is a Warning: accepted at DataLoss.
  let message =
    support.parse(
      "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\none\r\n",
    )
  let assert Ok(_) = eml.validate(message, diagnostic.DataLoss)
  let assert Error([found]) = eml.validate(message, diagnostic.Warning)
  assert found.kind == diagnostic.MissingCloseDelimiter
}
