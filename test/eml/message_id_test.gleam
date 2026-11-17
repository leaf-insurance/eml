//// Message IDs (RFC 5322 §3.6.4 and §4.5.4).

import eml
import eml/diagnostic.{InvalidMessageId}
import eml/message_id
import gleam/list
import gleam/option.{None, Some}

fn parse(value: String) {
  message_id.parse(<<value:utf8>>)
}

/// Cases from Stalwart mail-parser's `resources/id.json` (Apache-2.0 or
/// MIT) whose expected results follow RFC 5322.
pub fn stalwart_vectors_test() {
  assert parse("<1234@local.machine.example>")
    == #(["1234@local.machine.example"], [])
  assert parse("<1234@local.machine.example> <3456@example.net>")
    == #(["1234@local.machine.example", "3456@example.net"], [])
  assert parse("              <testabcd.1234@silly.test>  ")
    == #(["testabcd.1234@silly.test"], [])
  assert parse("<5678.21-Nov-1997@example.com>")
    == #(["5678.21-Nov-1997@example.com"], [])
  assert parse("<a@b>,<c@d>") == #(["a@b", "c@d"], [])
  assert parse("(comment) <a@b> (other)") == #(["a@b"], [])
  assert parse("<aé@b>") == #(["aé@b"], [])
  assert parse("") == #([], [])
  assert parse("   ") == #([], [])
}

/// Whitespace and comments inside the brackets are removed (obs-id-left is
/// a local part, which allows CFWS); quoted strings are kept.
pub fn obsolete_syntax_test() {
  assert parse("<1234   @   local(blah)  .machine .example>")
    == #(["1234@local.machine.example"], [])
  assert parse("<\"a b\"@example.com>") == #(["\"a b\"@example.com"], [])
  // Phrases between IDs (obs-in-reply-to).
  assert parse("\"Joe\" <a@b> (Joe's message of Monday) foo <c@d>")
    == #(["a@b", "c@d"], [])
}

pub fn recoveries_test() {
  assert parse("malformed@id.machine.example")
    == #(["malformed@id.machine.example"], [InvalidMessageId])
  assert parse("<a@b") == #(["a@b"], [InvalidMessageId])
  assert parse("<a@b c <d@e>") == #(["a@b", "d@e"], [InvalidMessageId])
  assert parse("<<a@b>>") == #(["a@b"], [])
  assert parse("<12345>") == #(["12345"], [InvalidMessageId])
  assert parse("<> <x@y>") == #(["x@y"], [InvalidMessageId])
  assert parse("<>") == #([], [InvalidMessageId])
  assert parse("m") == #([], [InvalidMessageId])
  assert parse("< \r\n >") == #([], [InvalidMessageId])
}

pub fn accessors_test() {
  let assert Ok(message) =
    eml.parse(<<
      "Message-ID: <id-1@example.com>\r\n",
      "In-Reply-To: <a@example.com>\r\n",
      "References: <b@example.com>\r\n <a@example.com>\r\n",
      "Date: Tue, 1 Jul 2003 10:52:37 +0200\r\n",
      "\r\n",
    >>)
  let root = eml.root(message)
  assert eml.message_id(root) == Some("id-1@example.com")
  assert eml.in_reply_to(root) == ["a@example.com"]
  assert eml.references(root) == ["b@example.com", "a@example.com"]
  assert eml.diagnose(message) == []
  let assert Ok(message) = eml.parse(<<"Subject: x\r\n\r\n">>)
  assert eml.message_id(eml.root(message)) == None
  assert eml.references(eml.root(message)) == []
}

pub fn diagnose_test() {
  let assert Ok(message) =
    eml.parse(<<
      "Message-ID: id@example.com\r\n",
      "Date: 31 Apr 2003 10:00 +0000\r\n",
      "Resent-Date: yesterday\r\n",
      "\r\n",
    >>)
  assert list.map(eml.diagnose(message), fn(d) { d.kind })
    == [InvalidMessageId, diagnostic.InvalidDate, diagnostic.InvalidDate]
}
