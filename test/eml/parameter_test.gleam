//// RFC 2231 parameters, filenames and safe names: assumptions.md §H.4, §I.1.

import eml
import eml/charset
import eml/diagnostic
import eml/filename
import eml/internal/structured
import eml/parameter
import eml/support
import gleam/option.{None, Some}
import gleam/string

fn resolve(value: String, name: String) {
  let assert #(Some(content_type), _) =
    structured.parse_content_type(<<"text/plain; ":utf8, value:utf8>>)
  parameter.resolve(content_type.parameters, name, charset.default_options())
}

pub fn plain_test() {
  assert resolve("name=report.pdf", "name")
    == #(parameter.Resolved("report.pdf"), [])
  assert resolve("x=y", "name") == #(parameter.Absent, [])
}

pub fn rfc_2231_extended_test() {
  // RFC 2231 §4.
  assert resolve(
      "title*=us-ascii'en-us'This%20is%20%2A%2A%2Afun%2A%2A%2A",
      "title",
    )
    == #(parameter.Resolved("This is ***fun***"), [])
}

pub fn rfc_2231_continuation_test() {
  // RFC 2231 §4.1, with the sections out of order.
  assert resolve(
      "title*1*=%2A%2A%2Afun%2A%2A%2A%20; "
        <> "title*0*=us-ascii'en'This%20is%20even%20more%20; "
        <> "title*2=\"isn't it!\"",
      "title",
    )
    == #(parameter.Resolved("This is even more ***fun*** isn't it!"), [])
}

pub fn utf8_extended_test() {
  assert resolve("filename*=UTF-8''%E2%82%AC%20rates.pdf", "filename")
    == #(parameter.Resolved("€ rates.pdf"), [])
  assert resolve("filename*=iso-8859-1'da'bl%E5b%E6r.txt", "filename")
    == #(parameter.Resolved("blåbær.txt"), [])
}

pub fn gap_falls_back_to_plain_test() {
  assert resolve(
      "filename=safe.txt; filename*0*=utf-8''evil; filename*2*=.exe",
      "filename",
    )
    == #(parameter.Resolved("safe.txt"), [
      diagnostic.AmbiguousParameter("filename"),
    ])
}

pub fn single_and_continued_is_ambiguous_test() {
  assert resolve("filename*=utf-8''one; filename*0*=utf-8''two", "filename")
    == #(parameter.Ambiguous, [diagnostic.AmbiguousParameter("filename")])
}

pub fn malformed_escape_test() {
  assert resolve("filename*=utf-8''%GG; filename=plain.txt", "filename")
    == #(parameter.Resolved("plain.txt"), [
      diagnostic.MalformedParameter("filename"),
    ])
  assert resolve("filename*=no-quotes", "filename")
    == #(parameter.Malformed, [diagnostic.MalformedParameter("filename")])
}

pub fn leading_zero_index_is_ambiguous_test() {
  assert resolve("f*0=a; f*01=b", "f")
    == #(parameter.Ambiguous, [diagnostic.AmbiguousParameter("f")])
}

pub fn encoded_word_in_plain_value_test() {
  // gen_smtp's utf-attachment-name.eml uses this nonstandard form.
  assert resolve(
      "name=\"=?UTF-8?B?0YLQtdGB0YLQvtCy0YvQuSDRhNCw0LnQuy50eHQ=?=\"",
      "name",
    )
    == #(parameter.Resolved("тестовый файл.txt"), [])
}

pub fn raw_eight_bit_value_test() {
  let assert #(Some(content_type), _) =
    structured.parse_content_type(<<"text/plain; name=caf", 0xE9, ".txt">>)
  assert parameter.resolve(
      content_type.parameters,
      "name",
      charset.default_options(),
    )
    == #(parameter.Resolved("café.txt"), [diagnostic.EightBitHeader])
}

pub fn filename_from_disposition_test() {
  let entity =
    support.root(
      "Content-Type: application/pdf; name=ct.pdf\r\n"
      <> "Content-Disposition: attachment;\r\n filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r\n\r\n",
    )
  assert eml.filename(entity) == Some("résumé.pdf")
  let assert Some(disposition) = eml.disposition(entity)
  assert disposition.type_ == "attachment"
}

pub fn filename_from_content_type_test() {
  let entity =
    support.root("Content-Type: application/pdf; name=ct.pdf\r\n\r\n")
  assert eml.filename(entity) == Some("ct.pdf")
  assert eml.filename(support.root("Subject: x\r\n\r\n")) == None
}

pub fn safe_filename_test() {
  assert filename.safe("report.pdf") == "report.pdf"
  assert filename.safe("../../etc/passwd") == "passwd"
  assert filename.safe("..\\..\\windows\\system32\\evil.dll") == "evil.dll"
  assert filename.safe("C:evil.exe") == "C_evil.exe"
  assert filename.safe("report.txt:payload") == "report.txt_payload"
  assert filename.safe("..") == "attachment"
  assert filename.safe(".") == "attachment"
  assert filename.safe("") == "attachment"
  assert filename.safe("/") == "attachment"
  assert filename.safe("report. . ") == "report"
  assert filename.safe("con.txt") == "_con.txt"
  assert filename.safe("a\u{0}b\u{7}c.txt") == "abc.txt"
  // Right-to-left override: "invoice[RLO]fdp.exe" shows as "invoiceexe.pdf".
  assert filename.safe("invoice\u{202E}fdp.exe") == "invoicefdp.exe"
  assert filename.safe("blåbær.txt") == "blåbær.txt"
  let long = filename.safe(string.repeat("é", 300) <> ".pdf")
  assert string.ends_with(long, ".pdf")
  assert string.byte_size(long) <= 255
}
