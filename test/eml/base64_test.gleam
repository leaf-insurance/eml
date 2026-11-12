//// The base64 vectors from assumptions.md §F.1: exact bytes and exact
//// diagnostics.

import eml/diagnostic.{type Kind}
import eml/internal/base64
import gleam/bit_array
import gleam/list

fn decode(input: String) -> #(BitArray, List(Kind)) {
  let #(bytes, kinds) = base64.decode(<<input:utf8>>, 0)
  #(bytes, list.map(kinds, fn(kind) { kind.0 }))
}

pub fn padded_one_byte_test() {
  assert decode("QQ==") == #(<<"A">>, [])
}

pub fn padded_two_bytes_test() {
  assert decode("QUI=") == #(<<"AB">>, [])
}

pub fn full_quantum_test() {
  assert decode("QUJD") == #(<<"ABC">>, [])
}

pub fn empty_test() {
  assert decode("") == #(<<>>, [])
}

pub fn one_pad_missing_test() {
  assert decode("QQ=") == #(<<"A">>, [diagnostic.MissingBase64Padding])
}

pub fn no_padding_test() {
  assert decode("QQ") == #(<<"A">>, [diagnostic.MissingBase64Padding])
  assert decode("QUI") == #(<<"AB">>, [diagnostic.MissingBase64Padding])
}

pub fn excess_padding_test() {
  assert decode("QQ===") == #(<<"A">>, [diagnostic.ExcessBase64Padding(1)])
}

pub fn whitespace_inside_padding_test() {
  assert decode("QQ\r\n==") == #(<<"A">>, [])
}

pub fn line_wrapped_test() {
  // gleam_stdlib's base64_decode rejects this on Erlang.
  assert decode("QUJD\r\nREVG") == #(<<"ABCDEF">>, [])
  assert decode("QUJD\r\n\r\nREVG\r\n") == #(<<"ABCDEF">>, [])
}

pub fn data_after_padding_test() {
  assert decode("QQ==Qg==")
    == #(<<"AB">>, [diagnostic.Base64DataAfterPadding(1)])
}

pub fn stray_leading_padding_test() {
  assert decode("=QQ==") == #(<<"A">>, [diagnostic.StrayPadding(1)])
}

pub fn lone_symbol_test() {
  assert decode("Q") == #(<<>>, [diagnostic.InvalidBase64Length])
  assert decode("QUJDR") == #(<<"ABC">>, [diagnostic.InvalidBase64Length])
}

pub fn nonzero_pad_bits_test() {
  assert decode("QR==") == #(<<"A">>, [diagnostic.NonZeroPadBits])
}

pub fn invalid_characters_test() {
  assert decode("QU*JD")
    == #(<<"ABC">>, [diagnostic.InvalidBase64Characters(1)])
  // URL-safe characters are not accepted; they are skipped.
  assert decode("Q-U_JD")
    == #(<<"ABC">>, [diagnostic.InvalidBase64Characters(2)])
}

pub fn list_footer_test() {
  // A footer appended after the padding: the caller can truncate at the
  // reported decoded length.
  let #(_, kinds) = decode("SGVsbG8=\r\n--\r\nfooter\r\n")
  assert list.contains(kinds, diagnostic.Base64DataAfterPadding(5))
}

pub fn all_bytes_round_trip_test() {
  let bytes = all_bytes(255, <<>>)
  let #(decoded, kinds) = decode(bit_array_base64(bytes))
  assert decoded == bytes
  assert kinds == []
}

pub fn long_input_test() {
  // Spans several output chunks.
  let bytes = repeat(all_bytes(255, <<>>), 20, <<>>)
  let #(decoded, _) = decode(bit_array_base64(bytes))
  assert decoded == bytes
}

fn all_bytes(n: Int, acc: BitArray) -> BitArray {
  case n < 0 {
    True -> acc
    False -> all_bytes(n - 1, <<n, acc:bits>>)
  }
}

fn repeat(bits: BitArray, n: Int, acc: BitArray) -> BitArray {
  case n {
    0 -> acc
    _ -> repeat(bits, n - 1, <<acc:bits, bits:bits>>)
  }
}

fn bit_array_base64(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, True)
}
