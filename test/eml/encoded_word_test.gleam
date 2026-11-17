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
  assert text == "\u{FFFD}\u{FFFD}"
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
}

/// fable-r5-E1, pi-r5: a word that continues a shift state is decoded in
/// it, even when it would decode cleanly on its own, as Python does. Japanese
/// text is never silently read as ASCII.
pub fn iso_2022_jp_state_continues_despite_errors_test() {
  // い, an emoji WHATWG lacks (0x7521), う.
  assert decode(<<
      "=?iso-2022-jp?B?GyRCJCI=?= =?iso-2022-jp?B?JCR1ISQmGyhC?=",
    >>)
    == #("あい\u{FFFD}う", [
      diagnostic.EncodedWordSplitCharacter,
      diagnostic.MalformedCharsetData(1),
    ])
  // Katakana is a state too.
  assert decode(<<"=?iso-2022-jp?B?GyhJMQ==?= =?iso-2022-jp?B?MjM=?=">>)
    == #("ｱｲｳ", [diagnostic.EncodedWordSplitCharacter])
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

/// pi-r5-1, fable-r5-E2: each word of a run is decoded with its own label.
pub fn words_keep_their_labels_test() {
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(label, _) {
      case label {
        "cp932" -> Ok("CUSTOM")
        _ -> Error(Nil)
      }
    })
  assert encoded_word.decode(<<"=?shift_jis?Q?A?= =?cp932?Q?B?=">>, options)
    == #("ACUSTOM", [])
  assert encoded_word.decode(<<"=?cp932?Q?A?= =?shift_jis?Q?B?=">>, options)
    == #("CUSTOMB", [])
  // A label that names a byte order does not inherit one.
  assert decode(<<"=?utf-16?B?/v8AQQ==?= =?utf-16le?B?QgA=?=">>) == #("AB", [])
  assert decode(<<"=?utf-16?B?/v8AQQ==?= =?utf-16le?B?/v8AQg==?=">>)
    == #("AB", [diagnostic.DeclaredCharsetOverridden("utf-16le")])
  assert decode(<<"=?utf-16le?B?QQA=?= =?utf-16?B?/v8AQg==?=">>) == #("AB", [])
}

/// pi-r5-2: repairing a split character does not change the words around
/// it: a UTF-8 byte order mark at the start of a word is still dropped, and
/// a word the caller's decoder decoded is kept.
pub fn repair_keeps_other_words_test() {
  assert decode(<<"=?utf-8?Q?=C3?= =?utf-8?Q?=A9?= =?utf-8?B?77u/Qg==?=">>)
    == #("éB", [diagnostic.EncodedWordSplitCharacter])
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(_, bytes) {
      case bytes {
        <<"A">> -> Ok("CUSTOM")
        _ -> Error(Nil)
      }
    })
  assert encoded_word.decode(
      <<"=?utf-8?Q?A?= =?utf-8?Q?=C3?= =?utf-8?Q?=A9?=">>,
      options,
    )
    == #("CUSTOMé", [diagnostic.EncodedWordSplitCharacter])
}

/// fable-r5-E3: the UTF-8 override is decided for a run of words together.
pub fn utf8_override_per_run_test() {
  let override = charset.default_options() |> charset.with_utf8_override(True)
  let decode = encoded_word.decode(_, override)
  assert decode(<<"=?gbk?Q?Caf=C3=A9_?= =?gbk?Q?=E4=B8=AD=E6=96=87?=">>)
    == #("Café 中文", [diagnostic.DeclaredCharsetOverridden("gbk")])
  assert decode(<<"=?gb2312?Q?=E4=B8=AD=E6=96=87_?= =?gb2312?Q?Ren=C3=A9?=">>)
    == #("中文 René", [diagnostic.DeclaredCharsetOverridden("gb2312")])
  // A character split between words.
  assert decode(<<"=?gbk?Q?=E4=B8?= =?gbk?Q?=AD=E6?= =?gbk?Q?=96=87?=">>)
    == #("中文", [diagnostic.DeclaredCharsetOverridden("gbk")])
  // Two-byte UTF-8 alone is not enough for a CJK charset.
  assert decode(<<"=?shift_jis?B?xaM=?=">>) == #("ﾅ｣", [])
  // ISO-2022-JP still decides word by word: its words are 7-bit, so valid
  // UTF-8 whatever they mean.
  assert decode(<<
      "=?iso-2022-jp?Q?=1B$B$=22=1B(B?= =?iso-2022-jp?Q?=C3=A9?=",
    >>)
    == #("あé", [diagnostic.DeclaredCharsetOverridden("iso-2022-jp")])
}

/// fable-r5-E4: an undecodable word's diagnostic is in order.
pub fn invalid_encoded_word_in_order_test() {
  assert decode(<<"=?utf-8?Q?=00?= =?utf-8?B?!!?=">>)
    == #("\u{0}=?utf-8?B?!!?=", [
      diagnostic.NulInText(1),
      diagnostic.InvalidEncodedWord(1),
    ])
}

/// fable-r5-E6: state transitions the suite did not pin.
pub fn state_transitions_test() {
  // An empty word keeps the state.
  assert decode(<<
      "=?iso-2022-jp?Q?=1B$B$\"?= =?iso-2022-jp?Q??= =?iso-2022-jp?Q?$$?=",
    >>)
    == #("あい", [diagnostic.EncodedWordSplitCharacter])
  assert decode(<<"=?utf-16?B?/v8=?= =?utf-16?Q??= =?utf-16?B?AEI=?=">>)
    == #("B", [diagnostic.EncodedWordSplitCharacter])
  // A byte order mark that agrees with the label resets the byte order.
  assert decode(<<
      "=?utf-16?B?/v8AQQ==?= =?utf-16?B?//5CAA==?= =?utf-16?B?QwA=?=",
    >>)
    == #("ABC", [])
  // A little-endian mark is passed on under a big-endian label.
  assert decode(<<"=?utf-16be?B?//5BAA==?= =?utf-16be?B?QgA=?=">>)
    == #("AB", [
      diagnostic.DeclaredCharsetOverridden("utf-16be"),
      diagnostic.EncodedWordSplitCharacter,
    ])
  // A word the caller's decoder decodes passes on no state.
  let options =
    charset.default_options()
    |> charset.with_decoder(fn(_, bytes) {
      case bytes {
        <<"X">> -> Ok("CUSTOM")
        _ -> Error(Nil)
      }
    })
  assert encoded_word.decode(
      <<
        "=?iso-2022-jp?Q?=1B$B$=22?= =?iso-2022-jp?Q?X?= =?iso-2022-jp?Q?$$?=",
      >>,
      options,
    )
    == #("あCUSTOM$$", [])
  // NUL counts add up.
  assert decode(<<"=?utf-8?Q?=00?= =?utf-8?Q?=00?=">>)
    == #("\u{0}\u{0}", [diagnostic.NulInText(2)])
}

/// fable-r5-E6: merged counts take the position of their first occurrence.
pub fn merged_counts_keep_first_position_test() {
  assert decode(<<"=?utf-8?B?/w==?= =?iso-8859-1?Q?=80?= =?utf-8?B?/w==?=">>)
    == #("\u{FFFD}€\u{FFFD}", [
      diagnostic.MalformedCharsetData(2),
      diagnostic.C1ReinterpretedAsWindows1252,
    ])
}
