//// RFC 2047 encoded-words in unstructured text: assumptions.md §H.3.

import eml/charset
import eml/diagnostic
import eml/encoded_word
import gleam/list

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
  assert decode(<<"=?iso-2022-kr?B?gqA=?=">>)
    == #("=?iso-2022-kr?B?gqA=?=", [
      diagnostic.UnsupportedCharset("iso-2022-kr"),
    ])
}

pub fn cjk_word_test() {
  assert decode(<<"=?shift_jis?B?gqA=?=">>) == #("あ", [])
  assert decode(<<"=?ISO-2022-JP?B?GyRCJCIbKEI=?=">>) == #("あ", [])
}

/// A double-byte character split between two words is repaired in a
/// stateless multi-byte charset.
pub fn split_double_byte_character_test() {
  assert decode(<<"=?shift_jis?B?gg==?= =?shift_jis?B?oA==?=">>)
    == #("あ", [diagnostic.EncodedWordSplitCharacter])
}

/// A word that ends in a two-byte state continues in that state in the next
/// word, when that word does not begin with an escape sequence.
pub fn iso_2022_jp_state_continues_test() {
  assert decode(<<"=?ISO-2022-JP?B?GyRCJCI=?= =?ISO-2022-JP?B?JCQbKEI=?=">>)
    == #("あい", [diagnostic.EncodedWordSplitCharacter])
  // Words that end in ASCII are unchanged.
  assert decode(<<"=?ISO-2022-JP?B?GyRCJCIbKEI=?= =?ISO-2022-JP?B?JCQ=?=">>)
    == #("あ$$", [])
}

/// UTF-16 words are not joined: a byte order mark in one word must not
/// decide the byte order of another.
pub fn no_repair_for_utf16_test() {
  let #(text, kinds) =
    decode(<<"=?utf-16le?B?QQ==?= =?utf-16le?B?AA==?= =?utf-16le?B?/v8AQg==?=">>)
  assert text == "\u{FFFD}\u{FFFD}B"
  assert !list.contains(kinds, diagnostic.EncodedWordSplitCharacter)
  assert decode(<<"=?utf-16?B?//5IAA==?= =?utf-16?B?aQA=?=">>) == #("Hi", [])
}

/// Counts are added up across words, not deduplicated.
pub fn counts_add_up_test() {
  assert decode(<<"=?shift_jis?B?/w==?= =?shift_jis?B?/w==?=">>)
    == #("\u{FFFD}\u{FFFD}", [diagnostic.MalformedCharsetData(2)])
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

pub fn word_diagnostics_in_order_test() {
  // A word's diagnostics are in the order the decoders report them, whether
  // the word is well-formed or not.
  assert decode(<<"=?iso-8859-1?q?=80=00?=">>)
    == #("\u{20AC}\u{0}", [
      diagnostic.C1ReinterpretedAsWindows1252,
      diagnostic.NulInText(1),
    ])
  assert decode(<<"=?utf-8?b?/wA=?=">>)
    == #("\u{FFFD}\u{0}", [
      diagnostic.MalformedCharsetData(1),
      diagnostic.NulInText(1),
    ])
}
