//// RFC 2047 encoded-words in unstructured text: assumptions.md §H.3.

import eml/charset
import eml/diagnostic
import eml/encoded_word
import gleam/bit_array
import gleam/list
import gleam/string

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

/// ISO-2022-JP is stateful: its bytes are never joined, so a character
/// split between words is not repaired.
pub fn no_repair_for_iso_2022_jp_test() {
  let #(text, _) =
    decode(<<"=?iso-2022-jp?Q?=1B$B$?= =?iso-2022-jp?Q?=22=1B(B?=">>)
  assert text == "\u{FFFD}\""
}

/// pi-r4-2: the shift state continues only into words that the built-in
/// ISO-2022-JP decoder decodes; the UTF-8 override and a caller's decoder
/// see the word's own bytes.
pub fn state_continues_only_into_iso_2022_jp_test() {
  let override = charset.default_options() |> charset.with_utf8_override(True)
  let input = <<"=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?Q?=C3=A9?=">>
  assert encoded_word.decode(input, override)
    == #("あé", [diagnostic.DeclaredCharsetOverridden("iso-2022-jp")])
  let hex =
    charset.default_options()
    |> charset.with_decoder(fn(_, bytes) { Ok(bit_array.base16_encode(bytes)) })
  let input = <<"=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?Q?ABC?=">>
  assert encoded_word.decode(input, hex) == #("1B24422422414243", [])
}

/// pi-r4-5: only a recognised escape sequence at the start of a word
/// replaces the state it inherits.
pub fn invalid_escape_keeps_inherited_state_test() {
  assert decode(<<"=?iso-2022-jp?Q?=1B(J=5C?= =?iso-2022-jp?Q?=1BX=5C?=">>)
    == #("¥\u{FFFD}X¥", [
      diagnostic.EncodedWordSplitCharacter,
      diagnostic.MalformedCharsetData(1),
    ])
  // A recognised escape: no continuation.
  assert decode(<<"=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?Q?=1B$B$$=1B(B?=">>)
    == #("あい", [])
  // Roman is a state too.
  assert decode(<<"=?iso-2022-jp?Q?=1B(J=5C?= =?iso-2022-jp?Q?=5C?=">>)
    == #("¥¥", [diagnostic.EncodedWordSplitCharacter])
  // A word that cannot be decoded ends the state.
  let #(text, _) =
    decode(<<
      "=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?B?!!!?= =?iso-2022-jp?Q?$$?=",
    >>)
  assert string.ends_with(text, "$$")
  // A word that decodes cleanly on its own is not garbled by the state.
  let #(text, _) =
    decode(<<"=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?Q?_abc?=">>)
  assert text == "あ abc"
}

/// fable-r4-E1: a UTF-16 word without a byte order mark continues in the
/// byte order of the word before it.
pub fn utf16_byte_order_continues_test() {
  assert decode(<<"=?utf-16?B?/v8AQQ==?= =?utf-16?B?AEI=?=">>)
    == #("AB", [diagnostic.EncodedWordSplitCharacter])
}

/// fable-r4-E3: runs are grouped by charset, not by label text.
pub fn runs_group_by_charset_test() {
  assert decode(<<"=?utf-8?Q?=C3?= =?utf8?Q?=A9?=">>)
    == #("é", [diagnostic.EncodedWordSplitCharacter])
  assert decode(<<"=?shift_jis?Q?=82?= =?cp932?Q?=A0?=">>)
    == #("あ", [diagnostic.EncodedWordSplitCharacter])
}

/// pi-r4-3: a byte order mark in a label is kept on both targets.
pub fn label_with_byte_order_mark_test() {
  assert decode(<<"=?\u{FEFF}utf-16le?B?QQA=?=":utf8>>)
    == #("A\u{0000}", [
      diagnostic.UnknownCharset("\u{FEFF}utf-16le"),
      diagnostic.NulInText(1),
    ])
}
