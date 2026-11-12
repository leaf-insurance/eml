//// Admission and header blocks: assumptions.md §B.1, §D.

import eml
import eml/diagnostic
import eml/mime
import eml/support.{kinds, parse, root}
import gleam/list
import gleam/option.{None, Some}

pub fn simple_message_test() {
  let entity = root("Subject: hi\r\nFrom: a@b\r\n\r\nbody\r\n")
  assert support.header_names(entity) == ["Subject", "From"]
  assert eml.raw_body(entity) == <<"body\r\n">>
  assert eml.header(entity, "subject") == mime.Single(<<" hi">>)
}

pub fn lf_only_message_test() {
  // A production failure: LF-only files gave empty bodies.
  let entity = root("Subject: hi\nFrom: a@b\n\nbody\nmore\n")
  assert support.header_names(entity) == ["Subject", "From"]
  assert eml.raw_body(entity) == <<"body\nmore\n">>
}

pub fn cr_only_message_test() {
  let entity = root("Subject: hi\rFrom: a@b\r\rbody\r")
  assert support.header_names(entity) == ["Subject", "From"]
  assert eml.raw_body(entity) == <<"body\r">>
}

pub fn unfolding_keeps_whitespace_test() {
  // gen_smtp #122 and #317: "This\r\n is" became "Thisis".
  let entity = root("Subject: This\r\n is a test\r\n\r\n")
  assert eml.header_values(entity, "Subject") == [<<" This is a test">>]
}

pub fn eight_bit_bytes_survive_test() {
  // A production failure: encoding :none stripped every byte >= 128.
  let input = <<"Subject: caf", 0xC3, 0xA9, "\r\n\r\nbl", 0xE5, " ", 0xFF:8>>
  let assert Ok(message) = support.parse_bytes(input)
  let entity = eml.root(message)
  assert eml.header_values(entity, "subject") == [<<" caf", 0xC3, 0xA9>>]
  assert support.decoded(entity) == <<"bl", 0xE5, " ", 0xFF>>
}

pub fn garbage_then_field_test() {
  let message = parse("garbage\nSubject: x\n\nbody")
  let entity = eml.root(message)
  assert eml.anomalies(entity) == [<<"garbage\n">>]
  assert support.header_names(entity) == ["Subject"]
  assert eml.raw_body(entity) == <<"body">>
  assert kinds(message) == [diagnostic.NonHeaderLine]
}

pub fn body_paragraph_is_not_swallowed_test() {
  let message =
    parse("Subject: hi\nHello Bob,\nthis is the body.\n\nSecond paragraph.\n")
  let entity = eml.root(message)
  assert support.header_names(entity) == ["Subject"]
  assert eml.raw_body(entity)
    == <<"Hello Bob,\nthis is the body.\n\nSecond paragraph.\n">>
  assert kinds(message) == [diagnostic.MissingHeaderBodySeparator]
}

pub fn body_without_separator_at_eof_test() {
  let entity = root("Subject: x\nhello world")
  assert eml.raw_body(entity) == <<"hello world">>
}

pub fn header_only_message_test() {
  let message = parse("Subject: x\nFrom: y")
  assert eml.raw_body(eml.root(message)) == <<>>
  assert kinds(message) == [diagnostic.NoBlankLineAfterHeaders]
}

pub fn space_before_colon_test() {
  let message = parse("X : y\n\nz")
  let entity = eml.root(message)
  assert support.header_names(entity) == ["X"]
  assert eml.header_values(entity, "x") == [<<" y">>]
  assert eml.raw_body(entity) == <<"z">>
  assert kinds(message) == [diagnostic.SpaceBeforeColon]
}

pub fn continuation_after_anomaly_test() {
  let entity = root("Subject: alpha\nbeta\n gamma\nX: y\n\nbody")
  assert eml.anomalies(entity) == [<<"beta\n gamma\n">>]
  assert eml.header_values(entity, "subject") == [<<" alpha">>]
}

pub fn first_line_continuation_test() {
  let message = parse("  indented\nSubject: x\n\nbody")
  assert support.header_names(eml.root(message)) == ["Subject"]
  assert kinds(message) == [diagnostic.FirstLineIsContinuation]
}

pub fn whitespace_only_line_is_folding_test() {
  let entity = root("Subject: a\n \nX: b\n\nbody")
  assert support.header_names(entity) == ["Subject", "X"]
  assert eml.raw_body(entity) == <<"body">>
}

pub fn cr_inside_header_is_a_line_break_test() {
  // A known differential against parsers that only split on LF.
  let entity = root("Subject: a\rX-Injected: b\r\n\r\n")
  assert support.header_names(entity) == ["Subject", "X-Injected"]
}

pub fn no_header_block_test() {
  assert eml.parse(<<"\tgarbage\n">>) == Error(mime.NoHeaderBlock)
  assert eml.parse(<<"\nbody">>) == Error(mime.NoHeaderBlock)
  assert eml.parse(<<"garbage\nmore">>) == Error(mime.NoHeaderBlock)
  assert eml.parse(<<0, 1, 2, 3>>) == Error(mime.NoHeaderBlock)
}

pub fn empty_input_test() {
  assert eml.parse(<<>>) == Error(mime.EmptyInput)
  assert eml.parse(<<" \n">>) == Error(mime.EmptyInput)
  assert eml.parse(<<"\r\n\t ">>) == Error(mime.EmptyInput)
  assert eml.parse(<<0xEF, 0xBB, 0xBF>>) == Error(mime.EmptyInput)
}

pub fn not_byte_aligned_test() {
  assert eml.parse(<<"Subject: x\n\n", 1:3>>) == Error(mime.NotByteAligned)
}

pub fn byte_order_mark_test() {
  let assert Ok(message) =
    support.parse_bytes(<<0xEF, 0xBB, 0xBF, "Subject: x\n\nbody">>)
  assert support.header_names(eml.root(message)) == ["Subject"]
  assert kinds(message) == [diagnostic.ByteOrderMark]
}

pub fn envelope_from_test() {
  let message =
    parse("From alice@example.com Thu Jan  1 00:00:00 2026\nSubject: x\n\nb")
  assert eml.envelope_from(message)
    == Some(<<"From alice@example.com Thu Jan  1 00:00:00 2026">>)
  assert support.header_names(eml.root(message)) == ["Subject"]
}

pub fn from_line_without_header_is_not_an_envelope_test() {
  assert eml.parse(<<"From here on\nit is prose">>) == Error(mime.NoHeaderBlock)
}

pub fn envelope_absent_test() {
  assert eml.envelope_from(parse("Subject: x\n\n")) == None
}

pub fn duplicate_fields_test() {
  let message = parse("Subject: one\nSubject: two\n\n")
  assert eml.header(eml.root(message), "Subject")
    == mime.Multiple([<<" one">>, <<" two">>])
}

pub fn invalid_field_name_is_an_anomaly_test() {
  let entity = root("Foo Bar: x\nSubject: y\n\n")
  assert support.header_names(entity) == ["Subject"]
  assert list.length(eml.anomalies(entity)) == 1
}
