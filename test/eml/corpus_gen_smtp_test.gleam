//// The gen_smtp fixtures (test/fixtures/gen_smtp/MANIFEST.md). This ports
//// the structural assertions of gen_smtp's `parse_example_mails_test_`.

import eml.{type Entity}
import eml/charset
import eml/diagnostic
import eml/mime
import eml/parameter
import eml/support
import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile

const dir = "test/fixtures/gen_smtp/"

fn load(name: String) -> eml.Message {
  let assert Ok(bytes) = simplifile.read_bits(dir <> name)
  let assert Ok(message) = support.parse_bytes(bytes)
  message
}

fn root(name: String) -> Entity {
  eml.root(load(name))
}

/// Renders the tree compactly: `type/subtype`, children in `[...]`, an
/// embedded message in `{...}`, and an opaque body as `!reason`.
fn shape(entity: Entity) -> String {
  let content_type = support.content_type(entity)
  case eml.body(entity) {
    eml.Leaf -> content_type
    eml.Multipart(parts:, ..) ->
      content_type <> "[" <> string.join(list.map(parts, shape), ",") <> "]"
    eml.Embedded(child) -> content_type <> "{" <> shape(child) <> "}"
    eml.Opaque(reason) -> content_type <> "!" <> string.inspect(reason)
  }
}

fn part(entity: Entity, index: Int) -> Entity {
  let assert [part, ..] = list.drop(support.parts(entity), index)
  part
}

fn embedded(entity: Entity) -> Entity {
  let assert eml.Embedded(child) = eml.body(entity)
  child
}

fn text(entity: Entity) -> String {
  let assert Ok(text) = bit_array.to_string(support.decoded(entity))
  text
}

/// An independent base64 decode, for comparison.
fn oracle(entity: Entity) -> BitArray {
  let assert Ok(raw) = bit_array.to_string(eml.raw_body(entity))
  let compact =
    raw
    // On Erlang, `\r\n` is one grapheme, so it is removed first.
    |> string.replace("\r\n", "")
    |> string.replace("\r", "")
    |> string.replace("\n", "")
  let assert Ok(bytes) = bit_array.base64_decode(compact)
  bytes
}

const plain_text = "This message contains only plain text.\r\n"

const rich_html =
  "<html><body style=\"word-wrap: break-word; -webkit-nbsp-mode: space; -webkit-line-break: after-white-space; \"><b>This </b><i>message </i><span class=\"Apple-style-span\" style=\"text-decoration: underline;\">contains </span>rich text.</body></html>"

const rtf =
  "{\\rtf1\\ansi\\ansicpg1252\\cocoartf949\\cocoasubrtf460\r\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\r\n{\\colortbl;\\red255\\green255\\blue255;}\r\n\\margl1440\\margr1440\\vieww9000\\viewh8400\\viewkind0\r\n\\pard\\tx720\\tx1440\\tx2160\\tx2880\\tx3600\\tx4320\\tx5040\\tx5760\\tx6480\\tx7200\\tx7920\\tx8640\\ql\\qnatural\\pardirnatural\r\n\r\n\\f0\\fs24 \\cf0 This is a basic rtf file.}"

pub fn every_fixture_parses_test() {
  let assert Ok(files) = simplifile.read_directory(dir)
  let files =
    list.filter(files, fn(file) { file != "LICENSE" && file != "MANIFEST.md" })
  assert list.length(files) == 31
  list.each(files, fn(file) {
    let message = load(file)
    // Decoding every body never crashes.
    support.walk(eml.root(message))
  })
}

pub fn plain_text_test() {
  let entity = root("Plain-text-only.eml")
  assert shape(entity) == "text/plain"
  assert text(entity) == plain_text
}

pub fn python_smtplib_test() {
  let entity = root("python-smtp-lib.eml")
  assert shape(entity) == "text/plain"
  assert text(entity) == "Hello world Python.\r\n"
}

pub fn no_content_type_test() {
  let entity = root("Plain-text-only-no-content-type.eml")
  assert shape(entity) == "text/plain"
  assert text(entity) == plain_text
}

pub fn no_mime_header_test() {
  assert text(root("Plain-text-only-no-MIME.eml")) == plain_text
  assert shape(root("rich-text-no-MIME.eml"))
    == "multipart/alternative[text/plain,text/html]"
}

pub fn multipart_without_delimiters_test() {
  // gen_smtp raises `missing_boundary`.
  let message = load("Plain-text-only-with-boundary-header.eml")
  assert shape(eml.root(message)) == "multipart/alternative!NoStartDelimiter"
  assert list.contains(
    support.kinds(message),
    diagnostic.StartDelimiterNotFound,
  )
}

pub fn rich_text_test() {
  let entity = root("rich-text.eml")
  assert shape(entity) == "multipart/alternative[text/plain,text/html]"
  assert text(part(entity, 0)) == "This message contains rich text."
  assert text(part(entity, 1)) == rich_html
}

pub fn rich_text_no_boundary_test() {
  // gen_smtp raises `no_boundary`.
  assert shape(root("rich-text-no-boundary.eml"))
    == "multipart/alternative!NoBoundary"
}

pub fn rich_text_missing_first_boundary_test() {
  let entity = root("rich-text-missing-first-boundary.eml")
  assert shape(entity) == "multipart/alternative[text/html]"
  assert text(part(entity, 0)) == rich_html
}

pub fn rich_text_missing_last_boundary_test() {
  // gen_smtp raises `missing_last_boundary`.
  let message = load("rich-text-missing-last-boundary.eml")
  assert shape(eml.root(message))
    == "multipart/alternative[text/plain,text/html]"
  assert list.contains(support.kinds(message), diagnostic.MissingCloseDelimiter)
}

pub fn rich_text_broken_last_boundary_test() {
  // gen_smtp raises `missing_last_boundary`. The file ends with an opening
  // delimiter, which opens a third, empty part (assumptions.md §E.4).
  let message = load("rich-text-broken-last-boundary.eml")
  let entity = eml.root(message)
  assert shape(entity)
    == "multipart/alternative[text/plain,text/html,text/plain]"
  assert eml.raw_body(part(entity, 2)) == <<>>
  assert list.contains(support.kinds(message), diagnostic.MissingCloseDelimiter)
}

pub fn rich_text_bad_boundary_test() {
  // The declared boundary has an extra `g`, so no delimiter matches.
  assert shape(root("rich-text-bad-boundary.eml"))
    == "multipart/alternative!NoStartDelimiter"
}

pub fn rich_text_no_text_content_type_test() {
  let entity = root("rich-text-no-text-contenttype.eml")
  assert shape(entity) == "multipart/alternative[text/plain,text/html]"
  assert text(part(entity, 0)) == "This message contains rich text."
  assert text(part(entity, 1)) == rich_html
}

pub fn text_attachment_only_test() {
  let entity = root("text-attachment-only.eml")
  assert shape(entity) == "multipart/mixed[text/rtf]"
  assert text(part(entity, 0)) == rtf
}

pub fn image_attachment_only_test() {
  let entity = root("image-attachment-only.eml")
  assert shape(entity) == "multipart/mixed[image/jpeg]"
  let image = part(entity, 0)
  assert eml.transfer_encoding(image) == mime.Base64
  assert support.decoded(image) == oracle(image)
  assert eml.decode_body(image).1 == []
  assert list.key_find(eml.content_type(image).parameters, "name")
    == Ok(<<"chili-pepper.jpg">>)
}

pub fn message_as_attachment_test() {
  let entity = root("message-as-attachment.eml")
  assert shape(entity) == "multipart/mixed[message/rfc822{text/plain}]"
  assert text(embedded(part(entity, 0))) == plain_text
}

pub fn message_image_text_attachments_test() {
  let entity = root("message-image-text-attachments.eml")
  assert shape(entity)
    == "multipart/mixed[message/rfc822{text/plain},text/rtf,image/jpeg]"
  assert text(embedded(part(entity, 0))) == plain_text
  assert text(part(entity, 1)) == rtf
  let image = part(entity, 2)
  assert support.decoded(image) == oracle(image)
}

pub fn calendar_attachment_test() {
  assert shape(root("message-text-html-attachment.eml"))
    == "multipart/mixed[multipart/alternative[text/plain,text/html],text/calendar]"
}

pub fn outlook_2007_test() {
  let entity = root("outlook-2007.eml")
  assert shape(entity) == "multipart/alternative[text/plain,text/html]"
  // Quoted-printable with leading tabs decodes without diagnostics.
  assert eml.decode_body(part(entity, 0)).1 == []
}

pub fn the_gamut_test() {
  let entity = root("the-gamut.eml")
  assert shape(entity)
    == "multipart/alternative[text/plain,multipart/mixed[text/html,message/rfc822{multipart/mixed[message/rfc822{text/plain}]},text/html,message/rfc822{text/plain},text/html,image/jpeg,text/html,text/rtf,text/html]]"
  assert text(part(entity, 0))
    == "This is rich text.\r\n\r\nThe list is html.\r\n\r\nAttchments:\r\nan email containing an attachment of an email.\r\nan email of only plain text.\r\nan image\r\nan rtf file.\r\n"
  let mixed = part(entity, 1)
  let nested = embedded(part(mixed, 1))
  assert text(embedded(part(nested, 0))) == plain_text
  let image = part(mixed, 5)
  assert support.decoded(image) == oracle(image)
  assert text(part(mixed, 7)) == rtf
  // The repeated `<br>` parts are identical.
  assert support.decoded(part(mixed, 2)) == support.decoded(part(mixed, 4))
}

pub fn two_identical_attachments_test() {
  let entity = root("plain-text-and-two-identical-attachments.eml")
  assert shape(entity) == "multipart/mixed[text/plain,text/rtf,text/rtf]"
  assert text(part(entity, 0)) == plain_text
  assert support.decoded(part(entity, 1)) == support.decoded(part(entity, 2))
}

pub fn no_line_break_before_first_boundary_test() {
  assert list.length(support.parts(root("html.eml"))) == 2
}

pub fn malformed_folded_multibyte_header_test() {
  let entity = root("malformed-folded-multibyte-header.eml")
  assert text(entity) == "Hello world\n"
  // A multibyte character is split across the two encoded-words.
  assert eml.subject(entity)
    == mime.Single("NOD32 Smart Security - бесплатная лицензия")
}

pub fn utf_attachment_name_test() {
  let entity = root("utf-attachment-name.eml")
  assert shape(entity) == "multipart/mixed[text/plain,text/plain]"
  assert text(part(entity, 0)) == "Hello\r\n"
  // KOI8-R encoded-words, in Content-Type `name` and in a folded
  // Content-Disposition `filename`.
  let attachment = part(entity, 1)
  assert eml.filename(attachment) == Some("тестовый файл.txt")
  let assert Ok(name) =
    list.key_find(eml.content_type(attachment).parameters, "name")
  assert parameter.resolve([#("name", name)], "name", charset.default_options()).0
    == parameter.Resolved("тестовый файл.txt")
  assert eml.bodies(load("utf-attachment-name.eml")).attachments
    |> list.map(eml.path)
    == [[1]]
}

pub fn unicode_subject_test() {
  assert eml.subject(root("unicode-subject.eml")) == mime.Single("①⓫⅓㏨♳𝄞λ")
}

pub fn unicode_body_test() {
  let entity = root("unicode-body.eml")
  let bodies = eml.bodies(load("unicode-body.eml"))
  let assert [text_part] = bodies.text
  let #(decoded, diagnostics) = eml.decode_text(text_part)
  let assert Ok(_) = decoded
  assert diagnostics == []
  assert shape(entity) != ""
}

pub fn gb2312_test() {
  // GB2312 (GBK) is not built in: the text is not decoded, and the
  // encoded-words are kept literally.
  let entity = root("chinesemail")
  let #(decoded, diagnostics) = eml.decode_text(entity)
  assert decoded == Error(Nil)
  assert list.map(diagnostics, fn(d) { d.kind })
    == [diagnostic.UnsupportedCharset("gb2312")]
  let assert mime.Single(subject) = eml.subject(entity)
  assert string.starts_with(subject, "=?GB2312?B?")
  // A caller-supplied decoder is used instead.
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, _) {
      case label {
        "GB2312" -> Ok("decoded")
        _ -> Error(Nil)
      }
    })
  assert eml.decode_text_with(entity, options).0 == Ok("decoded")
}

pub fn shift_jis_test() {
  let entity = root("shift-jismail")
  assert shape(entity) == "multipart/alternative[text/plain]"
  let #(decoded, diagnostics) = eml.decode_text(part(entity, 0))
  assert decoded == Error(Nil)
  assert list.map(diagnostics, fn(d) { d.kind })
    == [diagnostic.UnsupportedCharset("shift_jis")]
  let assert mime.Single(subject) = eml.subject(entity)
  assert string.starts_with(subject, "=?ISO-2022-JP?B?")
}

pub fn testcase1_test() {
  let entity = root("testcase1")
  assert shape(entity)
    == "multipart/mixed[multipart/alternative[text/plain,text/html],message/rfc822{multipart/alternative[text/plain,multipart/related[text/html,image/jpeg]]}]"
  let assert Ok(image) = eml.part_at(load("testcase1"), [1, 0, 1, 1])
  assert support.content_type(image) == "image/jpeg"
  assert support.decoded(image) == oracle(image)
}

pub fn testcase2_test() {
  assert shape(root("testcase2"))
    == "multipart/mixed[text/plain,application/octet-stream,message/rfc822{multipart/alternative[text/plain,text/html]}]"
}
