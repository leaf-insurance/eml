//// RFC 2047 encoded-words in unstructured text: assumptions.md §H.3.

import eml/charset
import eml/diagnostic
import eml/encoded_word

fn decode(value: BitArray) {
  encoded_word.decode(value, charset.default_options())
}

pub fn plain_test() {
  assert decode(<<" Hello world ">>) == #("Hello world", [])
}

pub fn q_word_test() {
  // From leaf: Q-encoded UTF-8 bytes.
  assert decode(<<"=?UTF-8?Q?HEDSTR=C3=98M_A/S?=">>) == #("HEDSTRØM A/S", [])
}

pub fn b_word_test() {
  assert decode(<<"=?utf-8?B?SGVqIHZlcmRlbg==?=">>) == #("Hej verden", [])
  // Missing padding is accepted.
  assert decode(<<"=?utf-8?b?SGVq?=">>) == #("Hej", [])
}

pub fn rfc_2047_examples_test() {
  // RFC 2047 §8.
  assert decode(<<"(=?ISO-8859-1?Q?a?=)">>) == #("(a)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a?= b)">>) == #("(a b)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?=)">>) == #("(ab)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a?=  =?ISO-8859-1?Q?b?=)">>) == #("(ab)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a?=\r\n    =?ISO-8859-1?Q?b?=)">>)
    == #("(ab)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a_b?=)">>) == #("(a b)", [])
  assert decode(<<"(=?ISO-8859-1?Q?a?= =?ISO-8859-2?Q?_b?=)">>)
    == #("(a b)", [])
  assert decode(<<"=?ISO-8859-1?Q?Andr=E9?= Pirard">>) == #("André Pirard", [])
}

pub fn language_suffix_test() {
  assert decode(<<"=?US-ASCII*EN?Q?Keith_Moore?=">>) == #("Keith Moore", [])
}

pub fn no_surrounding_whitespace_test() {
  assert decode(<<"foo=?utf-8?q?bar?=baz">>) == #("foobarbaz", [])
}

pub fn split_multibyte_character_test() {
  // `é` (C3 A9) split across two words.
  assert decode(<<"=?utf-8?B?ww==?= =?utf-8?B?qQ==?=">>)
    == #("é", [diagnostic.EncodedWordSplitCharacter])
  assert decode(<<"=?utf-8?Q?=C3?= =?utf-8?Q?=A9?=">>)
    == #("é", [diagnostic.EncodedWordSplitCharacter])
}

pub fn malformed_b_word_is_kept_test() {
  // A malformed B-encoded Subject was dropped by gen_smtp.
  assert decode(<<"=?utf-8?B?!!!?=">>)
    == #("=?utf-8?B?!!!?=", [diagnostic.InvalidEncodedWord(1)])
}

pub fn unsupported_charset_is_kept_test() {
  assert decode(<<"=?shift_jis?B?gqA=?=">>)
    == #("=?shift_jis?B?gqA=?=", [diagnostic.UnsupportedCharset("shift_jis")])
}

pub fn not_an_encoded_word_test() {
  assert decode(<<"=?broken">>) == #("=?broken", [])
  assert decode(<<"=?utf-8?x?abc?=">>) == #("=?utf-8?x?abc?=", [])
  assert decode(<<"a =? b">>) == #("a =? b", [])
}

pub fn raw_utf8_test() {
  assert decode(<<"caf", 0xC3, 0xA9>>) == #("café", [])
}

pub fn raw_eight_bit_test() {
  assert decode(<<"caf", 0xE9>>) == #("café", [diagnostic.EightBitHeader])
}

pub fn latin1_word_with_c1_test() {
  // mail-parser issue #131: `=80` under iso-8859-1 is the euro sign.
  assert decode(<<"=?iso-8859-1?Q?=805.4bn?=">>)
    == #("€5.4bn", [diagnostic.C1ReinterpretedAsWindows1252])
}
