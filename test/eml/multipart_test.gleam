//// MIME structure: assumptions.md §E.3 and §E.4.

import eml
import eml/diagnostic
import eml/mime
import eml/support.{content_type, decoded, kinds, parse, parts, root}
import gleam/list

const mixed = "Content-Type: multipart/mixed; boundary=b\r\n\r\n"

pub fn simple_multipart_test() {
  let entity =
    root(
      mixed
      <> "preamble\r\n--b\r\nContent-Type: text/plain\r\n\r\nhello\r\n--b\r\n"
      <> "Content-Type: text/html\r\n\r\n<p>hi</p>\r\n--b--\r\nepilogue\r\n",
    )
  let assert [text, html] = parts(entity)
  assert eml.raw_body(text) == <<"hello">>
  assert eml.raw_body(html) == <<"<p>hi</p>">>
  assert content_type(html) == "text/html"
  assert eml.path(html) == [1]
}

pub fn lf_only_multipart_test() {
  let entity =
    root(
      "Content-Type: multipart/mixed; boundary=b\n\n--b\n\none\n--b\n\ntwo\n--b--\n",
    )
  assert list.map(parts(entity), eml.raw_body) == [<<"one">>, <<"two">>]
}

pub fn line_break_ownership_test() {
  let bodies = fn(input) { list.map(parts(root(mixed <> input)), eml.raw_body) }
  assert bodies("--b\r\n\r\nhello\r\n--b--") == [<<"hello">>]
  assert bodies("--b\r\n\r\nhello\r\n\r\n--b--") == [<<"hello\r\n">>]
  assert bodies("--b\r\n\r\ntext\r\r\n--b--") == [<<"text\r">>]
}

pub fn empty_part_without_headers_test() {
  let assert [part] = parts(root(mixed <> "--b\r\n--b--"))
  assert eml.headers(part) == []
  assert eml.raw_body(part) == <<>>
}

pub fn empty_attachment_is_kept_test() {
  // A production failure: gen_smtp dropped empty parts.
  let entity =
    root(
      mixed
      <> "--b\r\nContent-Type: text/plain\r\n\r\nbody\r\n--b\r\n"
      <> "Content-Type: application/pdf\r\n"
      <> "Content-Disposition: attachment; filename=empty.pdf\r\n\r\n--b--\r\n",
    )
  let assert [_, attachment] = parts(entity)
  assert content_type(attachment) == "application/pdf"
  assert eml.raw_body(attachment) == <<>>
}

pub fn nested_multipart_test() {
  let entity =
    root(
      mixed
      <> "--b\r\nContent-Type: multipart/alternative; boundary=\"in ner\"\r\n\r\n"
      <> "--in ner\r\n\r\nplain\r\n--in ner\r\nContent-Type: text/html\r\n\r\n"
      <> "html\r\n--in ner--\r\n--b\r\nContent-Type: image/png\r\n"
      <> "Content-Transfer-Encoding: base64\r\n\r\nQUJD\r\n--b--\r\n",
    )
  let assert [alternative, image] = parts(entity)
  assert list.map(parts(alternative), eml.raw_body) == [<<"plain">>, <<"html">>]
  assert decoded(image) == <<"ABC">>
  assert eml.path(image) == [1]
}

pub fn missing_close_delimiter_test() {
  let message = parse(mixed <> "--b\r\n\r\none\r\n--b\r\n\r\ntwo\r\n")
  assert list.map(parts(eml.root(message)), eml.raw_body)
    == [<<"one">>, <<"two\r\n">>]
  assert kinds(message) == [diagnostic.MissingCloseDelimiter]
}

pub fn ancestor_delimiter_closes_inner_test() {
  let message =
    parse(
      mixed
      <> "--b\r\nContent-Type: multipart/mixed; boundary=c\r\n\r\n"
      <> "--c\r\n\r\ninner\r\n--b\r\n\r\nouter\r\n--b--\r\n",
    )
  let assert [nested, outer] = parts(eml.root(message))
  assert list.map(parts(nested), eml.raw_body) == [<<"inner">>]
  assert eml.raw_body(outer) == <<"outer">>
  assert kinds(message) == [diagnostic.MissingCloseDelimiter]
}

pub fn ancestor_delimiter_inside_child_headers_test() {
  let message =
    parse(
      mixed
      <> "--b\r\nContent-Type: multipart/mixed; boundary=c\r\n\r\n--c\r\n"
      <> "Content-Type: text/plain\r\n--b--\r\n",
    )
  let assert [nested] = parts(eml.root(message))
  let assert [inner] = parts(nested)
  assert support.header_names(inner) == ["Content-Type"]
  assert eml.raw_body(inner) == <<>>
}

pub fn start_delimiter_not_found_test() {
  let message = parse(mixed <> "just text\r\n")
  let entity = eml.root(message)
  assert eml.body(entity) == eml.Opaque(mime.NoStartDelimiter)
  assert eml.raw_body(entity) == <<"just text\r\n">>
  assert kinds(message) == [diagnostic.StartDelimiterNotFound]
}

pub fn missing_boundary_test() {
  let message = parse("Content-Type: multipart/mixed\r\n\r\n--b\r\n\r\nx\r\n")
  let entity = eml.root(message)
  // Never re-typed as text/plain.
  assert content_type(entity) == "multipart/mixed"
  assert eml.body(entity) == eml.Opaque(mime.NoBoundary)
  assert kinds(message) == [diagnostic.MissingBoundary]
}

pub fn unusable_boundary_test() {
  let message = parse("Content-Type: multipart/mixed; boundary=\"\"\r\n\r\nx")
  assert eml.body(eml.root(message)) == eml.Opaque(mime.BadBoundary)
  assert kinds(message) == [diagnostic.UnusableBoundary]
}

pub fn extended_boundary_is_ignored_test() {
  let message =
    parse("Content-Type: multipart/mixed; boundary*0=ab; boundary*1=cd\r\n\r\n")
  assert kinds(message)
    == [diagnostic.IgnoredExtendedBoundary, diagnostic.MissingBoundary]
}

pub fn close_without_open_test() {
  let message = parse(mixed <> "pre\r\n--b--\r\nepi\r\n")
  let assert eml.Multipart(parts: [], ..) = eml.body(eml.root(message))
  assert kinds(message) == [diagnostic.CloseWithoutOpen]
}

pub fn no_spurious_part_after_close_test() {
  let entity =
    root(mixed <> "--b\r\n\r\none\r\n--b--\r\n--b\r\nX: y\r\n\r\nlate\r\n")
  assert list.length(parts(entity)) == 1
}

pub fn trailing_text_delimiter_test() {
  let message = parse(mixed <> "--b\r\n\r\none\r\n--bfoo\r\n\r\ntwo\r\n--b--")
  assert list.length(parts(eml.root(message))) == 2
  assert kinds(message) == [diagnostic.DelimiterTrailingText]
}

pub fn close_with_trailing_text_test() {
  let message = parse(mixed <> "--b\r\n\r\none\r\n--b--junk\r\nepilogue")
  assert list.length(parts(eml.root(message))) == 1
  assert kinds(message) == [diagnostic.DelimiterTrailingText]
}

pub fn transport_padding_test() {
  let message = parse(mixed <> "--b \t\r\n\r\none\r\n--b-- \r\n")
  assert list.map(parts(eml.root(message)), eml.raw_body) == [<<"one">>]
  assert kinds(message) == []
}

pub fn boundary_collision_test() {
  // Outer `a`, inner `a--`: `--a--` is an exact inner open.
  let message =
    parse(
      "Content-Type: multipart/mixed; boundary=a\r\n\r\n--a\r\n"
      <> "Content-Type: multipart/mixed; boundary=a--\r\n\r\n--a--\r\n\r\n"
      <> "inner\r\n--a----\r\n--a--\r\n",
    )
  let assert [nested] = parts(eml.root(message))
  assert list.map(parts(nested), eml.raw_body) == [<<"inner">>]
  assert list.contains(kinds(message), diagnostic.BoundaryCollision)
}

pub fn encoded_multipart_test() {
  let message =
    parse(
      "Content-Type: multipart/mixed; boundary=b\r\n"
      <> "Content-Transfer-Encoding: x-foo\r\n\r\n--b\r\n\r\none\r\n--b--",
    )
  let entity = eml.root(message)
  assert list.map(parts(entity), eml.raw_body) == [<<"one">>]
  assert eml.transfer_encoding(entity) == mime.SevenBit
  assert kinds(message) == [diagnostic.EncodedMultipart]
}

pub fn unknown_encoding_leaf_test() {
  let message =
    parse("Content-Transfer-Encoding: x-uuencode\r\n\r\nbegin 644 x\r\n")
  let entity = eml.root(message)
  assert eml.body(entity) == eml.Leaf
  assert eml.transfer_encoding(entity) == mime.Unknown("x-uuencode")
  assert decoded(entity) == <<"begin 644 x\r\n">>
  assert kinds(message) == [diagnostic.UnknownTransferEncoding("x-uuencode")]
}

/// An unknown encoding is reported for every leaf type, and a message with
/// one is a leaf: its bytes cannot be parsed as a message.
pub fn unknown_encoding_any_type_test() {
  list.each(["application/octet-stream", "message/rfc822"], fn(content_type) {
    let message =
      parse(
        "Content-Type: "
        <> content_type
        <> "\r\nContent-Transfer-Encoding: x-uuencode\r\n\r\nbegin 644 x\r\n",
      )
    assert eml.body(eml.root(message)) == eml.Leaf
    assert kinds(message) == [diagnostic.UnknownTransferEncoding("x-uuencode")]
  })
}

pub fn embedded_message_test() {
  let entity =
    root("Content-Type: message/rfc822\r\n\r\nSubject: inner\r\n\r\ninner body")
  let assert eml.Embedded(inner) = eml.body(entity)
  assert support.header_names(inner) == ["Subject"]
  assert eml.raw_body(inner) == <<"inner body">>
  assert eml.path(inner) == [0]
}

pub fn embedded_message_in_multipart_test() {
  let message =
    parse(
      mixed
      <> "--b\r\nContent-Type: message/rfc822\r\n\r\nSubject: inner\r\n"
      <> "Content-Type: multipart/mixed; boundary=c\r\n\r\n--c\r\n\r\nx\r\n"
      <> "--c--\r\n--b--\r\n",
    )
  let assert Ok(inner) = eml.part_at(message, [0, 0])
  assert support.header_names(inner) == ["Subject", "Content-Type"]
  let assert Ok(leaf) = eml.part_at(message, [0, 0, 0])
  assert eml.raw_body(leaf) == <<"x">>
}

pub fn not_a_message_test() {
  let message = parse("Content-Type: message/rfc822\r\n\r\njust text")
  assert eml.body(eml.root(message)) == eml.Opaque(mime.NotMessage)
  assert kinds(message) == [diagnostic.NotAMessage]
}

pub fn encoded_embedded_message_test() {
  let message =
    parse(
      "Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64\r\n\r\n"
      <> "U3ViamVjdDogaW5uZXINCg0KYm9keQ==\r\n",
    )
  let entity = eml.root(message)
  assert eml.body(entity) == eml.Leaf
  assert kinds(message) == [diagnostic.EncodedMessage]
  let assert Ok(inner) = eml.parse_embedded(entity, eml.default_options())
  assert eml.raw_body(eml.root(inner)) == <<"body">>
}

pub fn digest_default_type_test() {
  let entity =
    root(
      "Content-Type: multipart/digest; boundary=b\r\n\r\n--b\r\n\r\n"
      <> "Subject: one\r\n\r\nbody\r\n--b--",
    )
  let assert [part] = parts(entity)
  assert content_type(part) == "message/rfc822"
  let assert eml.Embedded(_) = eml.body(part)
}

pub fn invalid_content_type_test() {
  let message = parse("Content-Type: garbage\r\n\r\nx")
  assert content_type(eml.root(message)) == "text/plain"
  assert kinds(message) == [diagnostic.InvalidContentType]
}

pub fn duplicate_content_type_uses_first_test() {
  let message =
    parse("Content-Type: text/html\r\nContent-Type: text/plain\r\n\r\nx")
  assert content_type(eml.root(message)) == "text/html"
  assert kinds(message) == [diagnostic.DuplicateField("content-type")]
}

pub fn part_at_test() {
  let message = parse(mixed <> "--b\r\n\r\none\r\n--b--")
  assert eml.part_at(message, [1]) == Error(Nil)
  assert eml.part_at(message, [0, 0]) == Error(Nil)
  let assert Ok(_) = eml.part_at(message, [0])
}
