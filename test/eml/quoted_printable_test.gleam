//// The quoted-printable vectors from assumptions.md §F.2.

import eml/diagnostic.{type Kind}
import eml/internal/quoted_printable
import gleam/list

fn decode(input: BitArray) -> #(BitArray, List(Kind)) {
  let #(bytes, kinds) = quoted_printable.decode(input, 0)
  #(bytes, list.map(kinds, fn(kind) { kind.0 }))
}

pub fn plain_test() {
  assert decode(<<"hello">>) == #(<<"hello">>, [])
}

pub fn interior_whitespace_test() {
  assert decode(<<"a\tb c">>) == #(<<"a\tb c">>, [])
}

pub fn trailing_whitespace_before_break_test() {
  assert decode(<<"a  \r\nb">>) == #(<<"a\r\nb">>, [])
  assert decode(<<"a \t\nb">>) == #(<<"a\nb">>, [])
}

pub fn trailing_whitespace_at_eof_test() {
  assert decode(<<"a \t">>) == #(<<"a">>, [])
}

pub fn whitespace_before_soft_break_is_kept_test() {
  assert decode(<<"a =\r\nb">>) == #(<<"a b">>, [])
}

pub fn padded_soft_break_test() {
  assert decode(<<"a= \t\r\nb">>) == #(<<"ab">>, [])
}

pub fn soft_breaks_test() {
  assert decode(<<"=\r\nX">>) == #(<<"X">>, [])
  assert decode(<<"a=\nb">>) == #(<<"ab">>, [])
  assert decode(<<"a=\rb">>) == #(<<"ab">>, [])
}

pub fn escapes_test() {
  assert decode(<<"=C3=a9">>) == #(<<0xC3, 0xA9>>, [])
  assert decode(<<"=3D=20x">>) == #(<<"= x">>, [])
}

pub fn encoded_space_before_break_is_kept_test() {
  assert decode(<<"a=20\r\nb">>) == #(<<"a \r\nb">>, [])
}

pub fn invalid_escape_test() {
  assert decode(<<"=G1">>)
    == #(<<"=G1">>, [diagnostic.InvalidQuotedPrintable(1)])
  assert decode(<<"=A">>) == #(<<"=A">>, [diagnostic.InvalidQuotedPrintable(1)])
  assert decode(<<"a=Ag=zz">>)
    == #(<<"a=Ag=zz">>, [diagnostic.InvalidQuotedPrintable(2)])
}

pub fn trailing_equals_test() {
  assert decode(<<"x=">>) == #(<<"x">>, [diagnostic.TrailingSoftBreak])
  assert decode(<<"x= \t">>) == #(<<"x">>, [diagnostic.TrailingSoftBreak])
}

pub fn hard_breaks_are_kept_test() {
  assert decode(<<"a\r\nb\nc\rd">>) == #(<<"a\r\nb\nc\rd">>, [])
}

pub fn unencoded_octets_test() {
  assert decode(<<"caf", 0xE9, 0>>)
    == #(<<"caf", 0xE9, 0>>, [diagnostic.UnencodedOctets(2)])
}
