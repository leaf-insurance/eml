//// Content-Type and Content-Transfer-Encoding lexing: assumptions.md §E.1,
//// §E.2.

import eml/diagnostic
import eml/internal/structured
import eml/mime.{ContentType}
import gleam/option.{None, Some}

fn content_type(value: String) {
  structured.parse_content_type(<<value:utf8>>)
}

pub fn simple_test() {
  assert content_type("text/plain; charset=utf-8")
    == #(Some(ContentType("text", "plain", [#("charset", <<"utf-8">>)])), [])
}

pub fn case_and_comments_test() {
  assert content_type(" (c) Text / HTML (c) ; CharSet = \"UTF-8\" (c)")
    == #(Some(ContentType("text", "html", [#("charset", <<"UTF-8">>)])), [])
}

pub fn invalid_type_test() {
  assert content_type("text") == #(None, [diagnostic.InvalidContentType])
  assert content_type("") == #(None, [diagnostic.InvalidContentType])
  assert content_type("/plain") == #(None, [diagnostic.InvalidContentType])
}

pub fn bad_parameter_keeps_type_test() {
  assert content_type("text/html; charset")
    == #(Some(ContentType("text", "html", [])), [diagnostic.InvalidParameter])
}

pub fn duplicate_parameter_first_wins_test() {
  assert content_type("multipart/mixed; boundary=a; boundary=b")
    == #(Some(ContentType("multipart", "mixed", [#("boundary", <<"a">>)])), [
      diagnostic.DuplicateParameter("boundary"),
    ])
}

pub fn unquoted_value_with_specials_test() {
  assert content_type("multipart/mixed; boundary=----=_Part_1:2?x")
    == #(
      Some(
        ContentType("multipart", "mixed", [
          #("boundary", <<"----=_Part_1:2?x">>),
        ]),
      ),
      [],
    )
}

pub fn unquoted_value_with_spaces_test() {
  assert content_type("application/pdf; name=my file.pdf ; x=y")
    == #(
      Some(
        ContentType("application", "pdf", [
          #("name", <<"my file.pdf">>),
          #("x", <<"y">>),
        ]),
      ),
      [],
    )
}

pub fn comment_after_value_test() {
  assert content_type("multipart/mixed; boundary=b (note; still a comment)")
    == #(Some(ContentType("multipart", "mixed", [#("boundary", <<"b">>)])), [])
}

pub fn parentheses_inside_quoted_value_test() {
  assert content_type("multipart/mixed; boundary=\"b(c)\"")
    == #(
      Some(ContentType("multipart", "mixed", [#("boundary", <<"b(c)">>)])),
      [],
    )
}

pub fn unterminated_quote_test() {
  assert content_type("multipart/mixed; boundary=\"abc")
    == #(Some(ContentType("multipart", "mixed", [#("boundary", <<"abc">>)])), [
      diagnostic.UnterminatedQuotedString,
    ])
}

pub fn quoted_pair_test() {
  assert content_type("text/plain; x=\"a\\\"b\"")
    == #(Some(ContentType("text", "plain", [#("x", <<"a\"b">>)])), [])
}

pub fn trailing_semicolons_test() {
  assert content_type("text/plain;; charset=x;")
    == #(Some(ContentType("text", "plain", [#("charset", <<"x">>)])), [])
}

fn encoding(value: String) {
  structured.parse_transfer_encoding(<<value:utf8>>)
}

pub fn transfer_encoding_test() {
  assert encoding("base64") == #(mime.Base64, [])
  assert encoding(" Quoted-Printable ") == #(mime.QuotedPrintable, [])
  assert encoding("8bit") == #(mime.EightBit, [])
  assert encoding("") == #(mime.SevenBit, [])
  assert encoding("base64 (comment)") == #(mime.Base64, [])
}

pub fn nonstandard_transfer_encoding_test() {
  assert encoding("\"base64\"")
    == #(mime.Base64, [diagnostic.NonstandardTransferEncoding("base64")])
  assert encoding("base64;")
    == #(mime.Base64, [diagnostic.NonstandardTransferEncoding("base64")])
  assert encoding("8-bit")
    == #(mime.EightBit, [diagnostic.NonstandardTransferEncoding("8-bit")])
  assert encoding("x-uuencode") == #(mime.Unknown("x-uuencode"), [])
}

pub fn boundary_status_test() {
  assert structured.boundary_status(<<"simple-boundary">>)
    == structured.ValidBoundary
  assert structured.boundary_status(<<"b ">>) == structured.NonstandardBoundary
  assert structured.boundary_status(<<"a@b">>) == structured.NonstandardBoundary
  assert structured.boundary_status(<<"a":utf8, 0:size(8)>>)
    == structured.UnusableBoundary
  assert structured.boundary_status(<<>>) == structured.UnusableBoundary
  assert structured.boundary_status(<<"a\nb">>) == structured.UnusableBoundary
}

pub fn unfold_test() {
  assert structured.unfold(<<" a\r\n b\n\tc">>) == <<" a b\tc">>
  assert structured.unfold(<<"plain">>) == <<"plain">>
}
