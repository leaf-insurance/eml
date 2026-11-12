//// Address lists: assumptions.md §H.2 and RFC 7103 §7.1.

import eml
import eml/address.{Group, Individual, Invalid, Mailbox}
import eml/charset
import eml/diagnostic
import eml/mime
import eml/support
import gleam/option.{None, Some}

fn parse(value: String) {
  address.parse(<<value:utf8>>, charset.default_options()).0
}

fn mailbox(name, local, domain) {
  Individual(Mailbox(name, local, Some(domain)))
}

pub fn simple_test() {
  assert parse("alice@example.com") == [mailbox(None, "alice", "example.com")]
  assert parse("Alice <alice@example.com>")
    == [mailbox(Some("Alice"), "alice", "example.com")]
  assert parse("\"Smith, Alice\" <alice@example.com>, bob@example.com")
    == [
      mailbox(Some("Smith, Alice"), "alice", "example.com"),
      mailbox(None, "bob", "example.com"),
    ]
}

pub fn rfc_5322_appendix_a_test() {
  // RFC 5322 §A.1.2 and §A.1.3.
  assert parse("\"Joe Q. Public\" <john.q.public@example.com>")
    == [mailbox(Some("Joe Q. Public"), "john.q.public", "example.com")]
  assert parse("Mary Smith <mary@x.test>, jdoe@example.org, Who? <one@y.test>")
    == [
      mailbox(Some("Mary Smith"), "mary", "x.test"),
      mailbox(None, "jdoe", "example.org"),
      mailbox(Some("Who?"), "one", "y.test"),
    ]
  assert parse(
      "<boss@nil.test>, \"Giant; \\\"Big\\\" Box\" <sysservices@example.net>",
    )
    == [
      mailbox(None, "boss", "nil.test"),
      mailbox(Some("Giant; \"Big\" Box"), "sysservices", "example.net"),
    ]
  assert parse(
      "A Group:Ed Jones <c@a.test>,joe@where.test,John <jdoe@one.test>;",
    )
    == [
      Group("A Group", [
        Mailbox(Some("Ed Jones"), "c", Some("a.test")),
        Mailbox(None, "joe", Some("where.test")),
        Mailbox(Some("John"), "jdoe", Some("one.test")),
      ]),
    ]
  assert parse("Undisclosed recipients:;")
    == [Group("Undisclosed recipients", [])]
}

pub fn rfc_5322_obsolete_and_comments_test() {
  // RFC 5322 §A.5 and §A.6.3.
  assert parse("Pete(A nice \\) chap) <pete(his account)@silly.test(his host)>")
    == [mailbox(Some("Pete"), "pete", "silly.test")]
  assert parse("John Q. Public <jqp@example.com>")
    == [mailbox(Some("John Q. Public"), "jqp", "example.com")]
}

pub fn legacy_comment_name_test() {
  assert parse("alice@example.com (Alice Smith)")
    == [mailbox(Some("Alice Smith"), "alice", "example.com")]
}

pub fn encoded_display_name_test() {
  assert parse("=?UTF-8?Q?Hedstr=C3=B8m?= <h@example.dk>")
    == [mailbox(Some("Hedstrøm"), "h", "example.dk")]
  // Encoded-words inside quoted strings are decoded too.
  assert parse("\"=?utf-8?B?SsO4cmdlbg==?=\" <j@example.dk>")
    == [mailbox(Some("Jørgen"), "j", "example.dk")]
}

pub fn raw_utf8_test() {
  assert parse("Jørgen <jørgen@exämple.dk>")
    == [mailbox(Some("Jørgen"), "jørgen", "exämple.dk")]
}

pub fn eight_bit_local_part_is_invalid_test() {
  let assert [Invalid(_)] =
    address.parse(<<"<j", 0xF8, "rgen@example.dk>">>, charset.default_options()).0
}

pub fn rfc_7103_recoveries_test() {
  // §7.1.1 source route.
  assert parse("<@example.net:fran@example.com>")
    == [mailbox(None, "fran", "example.com")]
  // §7.1.2 extra brackets.
  assert parse("<<<user@example.com>>>")
    == [mailbox(None, "user", "example.com")]
  // §7.1.3 unbalanced brackets.
  assert parse("<a@example.com") == [mailbox(None, "a", "example.com")]
  assert parse("a@example.com>") == [mailbox(None, "a", "example.com")]
  // §7.1.4 unclosed comment.
  assert parse("(Testing <fran@example.com>")
    == [mailbox(None, "fran", "example.com")]
  // §7.1.5 a comma ends an unclosed angle address.
  assert parse("<third@example.com, fourth@example.com>")
    == [
      mailbox(None, "third", "example.com"),
      mailbox(None, "fourth", "example.com"),
    ]
  // §7.1.6 unbalanced quote.
  assert parse("\"Joe <joe@example.com>")
    == [mailbox(Some("Joe"), "joe", "example.com")]
}

pub fn naked_local_part_test() {
  let #(addresses, kinds) = address.parse(<<"Joe">>, charset.default_options())
  assert addresses == [Individual(Mailbox(None, "Joe", None))]
  assert kinds == [diagnostic.InvalidAddress]
}

pub fn empty_elements_test() {
  assert parse(", a@x.test,, b@y.test ,")
    == [mailbox(None, "a", "x.test"), mailbox(None, "b", "y.test")]
  assert parse("") == []
}

pub fn null_return_path_test() {
  assert parse("<>") == [Individual(Mailbox(None, "", None))]
}

pub fn invalid_test() {
  let assert [Invalid("John Smith john@example.com")] =
    parse("John Smith john@example.com")
  let assert [Invalid(_), Individual(_)] = parse("@@@, a@b.test")
}

pub fn invalid_group_member_test() {
  assert parse("G: junk junk; a@b.test")
    == [Group("G", []), mailbox(None, "a", "b.test")]
}

pub fn to_string_test() {
  assert address.to_string(Mailbox(None, "alice", Some("example.com")))
    == "alice@example.com"
  assert address.to_string(Mailbox(None, "john smith", Some("example.com")))
    == "\"john smith\"@example.com"
}

pub fn from_accessor_test() {
  let entity =
    support.root(
      "From: Alice <alice@example.com>\r\nFrom: Mallory <m@evil.test>\r\n\r\n",
    )
  let assert mime.Multiple([[_], [_]]) = eml.from(entity)
  assert eml.from(support.root("Subject: x\r\n\r\n")) == mime.Missing
}
