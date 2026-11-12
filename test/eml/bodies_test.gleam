//// Body and attachment roles: RFC 8621 §4.1.4 (assumptions.md §I.3).

import eml
import eml/support
import gleam/list

/// The paths of the text, html and attachment parts.
fn roles(
  input: String,
) -> #(List(List(Int)), List(List(Int)), List(List(Int))) {
  let bodies = eml.bodies(support.parse(input))
  #(
    list.map(bodies.text, eml.path),
    list.map(bodies.html, eml.path),
    list.map(bodies.attachments, eml.path),
  )
}

fn multipart(subtype: String, boundary: String, parts: List(String)) -> String {
  "Content-Type: multipart/"
  <> subtype
  <> "; boundary="
  <> boundary
  <> "\r\n\r\n"
  <> list.fold(parts, "", fn(acc, part) {
    acc <> "--" <> boundary <> "\r\n" <> part <> "\r\n"
  })
  <> "--"
  <> boundary
  <> "--\r\n"
}

const plain = "Content-Type: text/plain\r\n\r\ntext"

const html = "Content-Type: text/html\r\n\r\n<p>html</p>"

const image = "Content-Type: image/png\r\nContent-ID: <logo>\r\n\r\nPNG"

const pdf =
  "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename=a.pdf\r\n\r\nPDF"

pub fn single_text_test() {
  assert roles(plain) == #([[]], [[]], [])
}

pub fn alternative_test() {
  assert roles(multipart("alternative", "a", [plain, html]))
    == #([[0]], [[1]], [])
}

pub fn mixed_with_attachment_test() {
  let input =
    multipart("mixed", "m", [multipart("alternative", "a", [plain, html]), pdf])
  assert roles(input) == #([[0, 0]], [[0, 1]], [[1]])
}

pub fn inline_image_between_text_test() {
  assert roles(multipart("mixed", "m", [plain, image, plain]))
    == #([[0], [1], [2]], [[0], [1], [2]], [])
}

pub fn related_test() {
  let input =
    multipart("alternative", "a", [
      plain,
      multipart("related", "r", [html, image]),
    ])
  assert roles(input) == #([[0]], [[1, 0]], [[1, 1]])
}

pub fn html_only_alternative_test() {
  // The HTML part is used for the text body too.
  assert roles(multipart("alternative", "a", [html])) == #([[0]], [[0]], [])
}

pub fn plain_only_alternative_test() {
  assert roles(multipart("alternative", "a", [plain])) == #([[0]], [[0]], [])
}

pub fn attached_message_test() {
  let message =
    "Content-Type: message/rfc822\r\n\r\nSubject: inner\r\n\r\ninner body"
  // The attached message's own text is not part of the bodies.
  assert roles(multipart("mixed", "m", [plain, message]))
    == #([[0]], [[0]], [[1]])
}

pub fn text_attachment_test() {
  let attached =
    "Content-Type: text/plain\r\nContent-Disposition: attachment\r\n\r\nnotes"
  assert roles(multipart("mixed", "m", [plain, attached]))
    == #([[0]], [[0]], [[1]])
}

pub fn named_text_part_after_first_test() {
  // A text part with a filename, not first, is assumed to be an attachment.
  let named = "Content-Type: text/plain; name=notes.txt\r\n\r\nnotes"
  assert roles(multipart("mixed", "m", [plain, named]))
    == #([[0]], [[0]], [[1]])
}

pub fn image_in_alternative_test() {
  assert roles(multipart("alternative", "a", [plain, image]))
    == #([[0]], [[0]], [[1]])
}

pub fn opaque_multipart_is_an_attachment_test() {
  let broken = "Content-Type: multipart/mixed\r\n\r\nno boundary"
  assert roles(multipart("mixed", "m", [plain, broken]))
    == #([[0]], [[0]], [[1]])
}
