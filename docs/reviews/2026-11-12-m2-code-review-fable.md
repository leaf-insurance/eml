# Code review of milestones 1 and 2 (fable)

Date: 2026-11-12. Reviewed all of `src/` against `docs/assumptions.md` (v3), the
generator `dev/charset_tables.py`, and the tests in `test/`. Milestone 2 is the
uncommitted working copy.

**Verdict:** the M1 parser core (framing, header blocks, MIME tree, base64, QP)
held up well. I found two limit bugs and one spec deviation there, and no crash
or superlinear path. The M2 modules are not ready to ship. `eml/address` crashes
on JavaScript with a 4 KB header, three header decoders are quadratic on input
that fits inside the default 1 MiB header limit, `eml.from` can be made to
report an attacker-chosen address first with no diagnostic, and `filename.safe`
can be bypassed.

## How findings were verified

- Every finding marked **Ran** was reproduced with throwaway probe modules under
  `test/probe_fable_*.gleam`, run with `gleam run -m` in the dev shell on
  Erlang/OTP 28 and on Node 24. The probes are deleted.
- Timings are single runs on one machine. Read them as growth rates.
- Findings marked **Read** come from reading the code only.
- I ran one cross-target check: 136 probe results were produced on both
  targets and compared. They were identical except for F07.
- Not done: a run of the full test suite (another reviewer was using the same
  checkout), differential runs against other parsers, and any review of the
  generated table bodies.

## Blockers

### F01: Nested groups overflow the stack on JavaScript, and are quadratic on Erlang

**Where:** `src/eml/address.gleam:318-321` and `431-455`. **Ran.**

`address` calls `group_members`, which calls `address` for each member. A colon
inside a group starts another group, so the recursion depth equals the number
of colons. This is mutual recursion over input, which §J.2 forbids.

**Input:** `To: ` followed by `a:` repeated 3,000 times (6 KB), then
`eml.addresses(root, "to")`.

| Target | Observed | Expected |
|---|---|---|
| JavaScript | `RangeError: Maximum call stack size exceeded` (also at 2,000 repeats, 4 KB) | A result. §K.5: never crashes. |
| Erlang | Returns, but time grows 4x per doubling: 0.15 s, 0.43 s, 1.8 s, 7.0 s for 3k, 6k, 12k, 24k repeats | Linear |

The Erlang growth comes from `list.append(member_kinds, kinds)` at line 446:
each level re-appends the diagnostics of every level below it.

**Fix:** groups do not nest (§H.2). Parse group members with a function that
only accepts mailboxes: on a second `:` before the `;`, emit `Invalid` for the
member and skip to the next `,` or `;` without recursing. Add this input to the
doubling tests on both targets.

### F02: Three header decoders are quadratic within the default limits

**Ran.** All three are reachable through `eml.subject`, `eml.header_text`,
`eml.addresses`, `eml.from` and `eml.filename`, on a single header that fits in
the default `max_header_bytes` of 1 MiB.

| Where | Input pattern (repeated n times) | Erlang: n = 5k, 10k, 20k | JavaScript: n = 1k, 2k, 4k |
|---|---|---|---|
| `encoded_word.gleam:47-58`, `117-123` | `=?a?q?x` | 0.8 s, 2.2 s, 10.4 s | 0.5 s, 1.9 s, 6.5 s |
| `address.gleam:226-234` (comment) | `(<` | 0.3 s, 0.9 s, 3.3 s | 0.1 s, 0.5 s, 1.9 s |
| `address.gleam:193-200` (quoted string) | `"` once, then `<\"` | 0.5 s, 2.8 s, 15.6 s | 0.4 s, 1.2 s, 5.7 s |

In a separate JavaScript run, the first pattern took 30 s at n = 5,000, which
is a 35 KB Subject. A 1 MiB Subject holds about 150,000 repeats. Extrapolating
the Erlang column gives roughly ten minutes for one call.

**Causes.**

- *Encoded-words:* each `=?charset?q?` prefix makes `until_end` scan to the end
  of the value for a `?=` that is not there. Then the tokeniser moves two bytes
  and does it again.
- *Comments and quoted strings:* an unterminated one is scanned to the end of
  the value, then "recovered" to end before the next `<`. The next `(` or `"`
  after that `<` repeats the full scan. In the quoted case, `\"` hides the later
  quotes from the scan but not from the tokeniser.

**Fix.**

- Encoded-words: bound the scan. RFC 2047 limits an encoded-word to 75 bytes;
  a generous cap such as 1,000 bytes for `until_end` and `until_question_mark`
  makes the tokeniser linear. Alternatively, find the last `?=` once and stop
  trying when `pos` passes it.
- Address tokeniser: once one unterminated comment or quoted string has been
  found, remember it. No later `(` or `"` can be terminated either (for
  quotes, track "no unescaped quote remains"), so skip the scan.
- Add each pattern to `perf_test.gleam`. The current M2 doubling tests
  (`many_addresses_test`, `long_encoded_subject_test`, lines 175 and 189) use
  only well-formed input.

### F03: `eml.from` reports an attacker-chosen address first, with no diagnostic

**Where:** `src/eml/address.gleam:323-337`. **Ran.**

**Input:** `From: ceo@company.com <attacker@evil.com>`

| | Result |
|---|---|
| Observed | `[Single(Mailbox(None, "ceo", Some("company.com"))), Single(Mailbox(None, "attacker", Some("evil.com")))]`, diagnostics `[]` |
| Expected | One mailbox `attacker@evil.com` whose display name is `ceo@company.com`, or `Invalid` with `InvalidAddress` |

The bare-address branch ends the first address at the end of the domain and
does not look at what follows. The `<` then starts a second address. The same
happens without the space (`ceo@company.com<attacker@evil.com>`).

Mail clients show this header as one sender, `attacker@evil.com`, with the text
`ceo@company.com` as its name. A consumer that takes the first mailbox from
`eml.from`, or that checks "does any From mailbox match our domain", gets
`ceo@company.com`. `validate` returns `Ok` for the message.

**Fix:** after a bare `local@domain`, the only tokens that may follow are a
comment, a `,`, a `;` or the end. If a `<` follows, treat everything before it
as the display name of the angle address and record `InvalidAddress`
(Warning). Add the case to `address_test.gleam`.

## Major findings

### F04: Whitespace is silently removed inside local parts and domains

**Where:** `src/eml/address.gleam:385-391` (`is_domain`), `411-415` (`angle`),
`462-468` (`mailbox`). **Ran.**

Adjacent atoms are concatenated without checking that a `.` separates them, so
whitespace between two words disappears and a different identity results. None
of these record a diagnostic.

| Input | Observed | Expected |
|---|---|---|
| `a@b c@d` | `a@bc`, then a mailbox with local part `""` and domain `d` | `Invalid`, or `a@b` and `c@d` |
| `<john doe@x.com>` | local part `johndoe` | `Invalid` |
| `user@example.com .evil.net` | domain `example.com.evil.net` | domain `example.com`, rest `Invalid` |
| `a@b@c` | `a@b`, then local part `""` with domain `c` | `Invalid` |
| `<a@b (c) .com>` | domain `b` (the `.com` is dropped) | domain `b.com` |

RFC 5322 allows whitespace and comments around the dots of an obsolete
dot-atom (`a @ b . com` is `a@b.com`, and the code handles that). It never
allows two atoms with only whitespace between them.

**Fix:** validate the token sequence of a local part and a domain as
`word ("." word)*`. Two words in a row end the component. An empty local part
is `Invalid` except for the null path `<>`. Skip comments inside a domain
instead of stopping at them.

### F05: A source route without a colon swallows later addresses

**Where:** `src/eml/address.gleam:400-410`. **Ran.**

The route skipper searches for the next `:` anywhere in the remaining tokens,
past the closing `>` and past commas.

| Input | Observed | Expected |
|---|---|---|
| `<@a.com>, bob@x.com, grp: c@d;` | `[Single(c@d)]`, no diagnostic. `bob@x.com` and the group are gone. | `Invalid("<@a.com>")`, `bob@x.com`, the group |
| `<@example.com>` | A mailbox with local part `""` and domain `example.com` | `Invalid` |

**Fix:** stop the route search at `>` or `,`. If no `:` is found before either,
the angle address is `Invalid`.

### F06: `filename.safe` can be bypassed with a Unicode prepend character

**Where:** `src/eml/filename.gleam:58-77`. **Ran,** same result on both
targets.

`clean` splits the name into grapheme clusters, checks only the *first* code
point of each cluster for control and bidi characters, and compares the *whole*
cluster against `:`, `*`, `?` and so on. A Unicode "Prepend" character such as
U+0600 joins the following character into one cluster, so the comparison never
matches.

| Input | Observed | Expected |
|---|---|---|
| `file.txt\u{0600}:evil` | unchanged; the `:` survives (an NTFS alternate data stream) | `:` replaced by `_` |
| `\u{0600}\|x\u{0600}?` | unchanged | `\|` and `?` replaced |

**Fix:** iterate over code points (`string.to_utf_codepoints`), not graphemes.
Add these inputs to `safe_filename_test`.

### F07: UTF-8 text with a byte order mark decodes differently on the two targets

**Where:** every `bit_array.to_string` on decoded text, for example
`src/eml/charset.gleam:190`, `235`, `283`. **Ran.**

**Input:** bytes `EF BB BF 68 69` with `charset=utf-8`, through
`eml.decode_text`.

| Target | Observed |
|---|---|
| Erlang | `"\u{FEFF}hi"` (length 3) |
| JavaScript | `"hi"` (length 2) |

gleam_stdlib's JavaScript `bit_array.to_string` uses `TextDecoder`, which drops
a leading BOM. This breaks the §L portability gate ("the same results on Erlang
and JS"). Files exported from Windows tools often start with a BOM.

**Fix:** decide the rule (WHATWG decode strips one leading BOM; I would follow
that) and apply it explicitly in `charset.decode` before `to_string` on both
targets. Add a test that runs on both.

### F08: The M2 accessors drop diagnostics, and `validate` cannot see header problems

**Where:** `src/eml/encoded_word.gleam:262-263`, `src/eml/parameter.gleam:43`
and `215-218`, `src/eml.gleam:550-621` and `247-262`. **Ran.**

Three layers each discard information:

1. `decode_run` returns `[]` when every word decodes, so charset diagnostics
   never surface for encoded-words.

   | Input | Observed kinds | Expected |
   |---|---|---|
   | `=?x-unknown?Q?=E9?=` | `[]` | `UnknownCharset("x-unknown")` |
   | `=?us-ascii?Q?=E9?=` | `[]` | `NonAsciiInAscii` |
   | `=?iso-8859-1?Q?=80?=` | `[]` | `C1ReinterpretedAsWindows1252` |
   | `=?utf-8?Q?a=00b?=` | `[]` | `NulInText(1)` |

2. `parameter.resolve` returns `[]` for an extended value and ignores what
   `charset.decode` reported. `filename*=utf-8'en'%E2%82` gives
   `Resolved("\u{FFFD}")` with no `MalformedCharsetData`.
3. `eml.header_text`, `eml.subject`, `eml.addresses`, `eml.from` and
   `eml.filename` return only the value. `eml.diagnose` covers bodies only.

The combined effect: a message with `From: a@b c@d` and a Subject in
ISO-2022-JP that could not be decoded passes
`eml.validate(message, diagnostic.Info)`. The doc comment on `diagnose` says
this, but `validate`'s own comment promises "all of its content could be
interpreted as declared".

**Fix:** fix layers 1 and 2 (return the kinds). For layer 3, either add
`_with_diagnostics` variants, or have `diagnose` include Subject, the address
fields and each part's filename. At minimum, correct the `validate` comment.

### F09: The convenience accessors cannot use a caller's charset decoder

**Where:** `src/eml.gleam:554`, `573`, `605`. **Read.**

`header_text`, `subject`, `addresses`, `from` and `filename` hard-code
`charset.default_options()`. Only `decode_text_with` takes options. CJK
charsets are not built in until M3, and they are the common case for encoded
Subjects and filenames in East Asian mail. A caller who supplies a decoder
still gets `=?ISO-2022-JP?B?...?=` back from `eml.subject`, and `None` from
`eml.filename` for `filename*=iso-2022-jp''...`.

**Fix:** add `header_text_with`, `addresses_with` and `filename_with` taking
`charset.Options`, as `decode_text_with` does.

### F10: `max_header_lines` is off by one, and `max_header_bytes` is applied to a body line

**Where:** `src/eml/internal/parser.gleam:453-458`. **Ran.**

The limits are checked before the line is classified, so the line that *ends*
the header block is counted as part of it.

| Input | Options | Observed | Expected (§B.3) |
|---|---|---|---|
| `A: b\r\n\r\nbody` | `max_header_lines = 1` | `LimitExceeded(MaxHeaderLines)` | `Ok`. One field line; the separator is not a "field, anomaly or continuation line". |
| `A: b\r\n` then 200 `x` (no separator) | `max_header_bytes = 100` | `LimitExceeded(MaxHeaderBytes)` | `Ok` with `MissingHeaderBodySeparator`. The long line is body. |
| `A: b\r\n\r\n` then 200 `x` | `max_header_bytes = 100` | `Ok` | `Ok` |

With the defaults, the second row means a message with a missing separator
whose first body line is longer than 1 MiB (base64 or minified HTML on one
line) fails to parse instead of being recovered.

**Fix:** classify the line first. Apply the limits only when the step is
`Continue` (the line became part of the block). `limits_test.gleam` should test
each limit with a block of exactly the limit followed by a separator.

### F11: `filename.safe` is quadratic on trailing dots

**Where:** `src/eml/filename.gleam:79-85`. **Ran.**

`trim` removes one trailing dot per recursion and runs `string.trim` and
`string.drop_end` on the whole name each time.

| Input | Erlang | JavaScript |
|---|---|---|
| `a` + `.` × 5k, 10k, 20k | 0.7 s, 2.1 s, 8.9 s | (1k, 2k, 4k) 0.3 s, 1.2 s, 3.5 s |
| `a` + ` .` × 5k, 10k | 9.5 s, 27.6 s | (500, 1k) 0.1 s, 0.9 s |

A filename parameter can be close to 1 MiB.

**Fix:** truncate the input to a sane length first (for example 4 KB of code
points), then strip trailing dots and spaces in one pass from the end.

## Minor findings

### F12: `filename.safe` gaps

**Where:** `src/eml/filename.gleam:16-20`, `40`, `63-67`, `96-115`. **Ran.**

| Input | Observed | Problem |
|---|---|---|
| 254 × `a`, `.`, 20 × `b` | 254 × `a` then `.` | Truncation runs after trimming, so the result can end in a dot or space, which Windows strips. |
| `COM¹`, `LPT0`, `CONIN$`, `con .txt` | unchanged | Windows also reserves `COM0`, `LPT0`, the superscript forms `COM¹²³` and `LPT¹²³`, `CONIN$` and `CONOUT$`. A reserved stem followed by spaces is still reserved. |
| `foo\u{2028}bar`, `a\u{200B}b\u{FEFF}c` | unchanged | Line and paragraph separators and zero-width characters are kept. §I.1 says control characters are removed. |
| `.htaccess`, `-rf`, `~` | unchanged | Probably intended. Say so in the doc comment, since callers may assume otherwise. |

**Fix:** trim again after truncating, extend the reserved list and compare the
stem after trimming spaces, and add U+2028, U+2029, U+200B to U+200D and U+FEFF
to the removed set.

### F13: Filename resolution edge cases

**Where:** `src/eml.gleam:604-621`, `src/eml/parameter.gleam`,
`src/eml/internal/structured.gleam:184`, `203`. **Ran.**

| Header | Observed | Expected |
|---|---|---|
| `Content-Disposition: attachment; filename=""` with `Content-Type: …; name=real.txt` | `Some("")` | `Some("real.txt")`. An empty name should fall through. It also makes `bodies` classify the part as an attachment (`filename(part) == None` is false). |
| `filename=foo (1).pdf` | `Some("foo")` | `foo (1).pdf`, or at least a diagnostic. The `(` rule in §E.1 was written for `boundary`; for filenames it silently loses the extension, and `eml.filename` returns no diagnostics. |
| `filename="C:\dir\file.txt"` | `Some("C:dirfile.txt")` | Windows clients write unescaped backslashes. Consider treating `\` as literal unless it precedes `"` or `\`, for `filename` and `name` only. As it stands, `safe` cannot take the basename. |
| `filename*=foo.txt` (no `charset''`) | `None`, `MalformedParameter` | Consider accepting it as plain text. Some generators omit the quotes. |
| `filename*=iso-2022-jp''x` | `Unsupported`, reported as `MalformedParameter("filename")` | `UnsupportedCharset("iso-2022-jp")`. The value is not malformed. |

### F14: Address details

**Where:** `src/eml/address.gleam`. **Ran.**

- A NUL or other control byte in a domain is accepted:
  `<a@b\u{0}.com>` gives domain `"b\u{0}.com"`. Expected: `Invalid`.
- `=?utf-8?Q?Doe,_John?= <j@x>` splits at the comma inside the encoded-word and
  yields a mailbox with local part `=?utf-8?Q?Doe` plus `j@x` named `_John?=`.
  This is malformed input (the comma should be encoded), but it is common.
  Consider recognising `=?…?=` as one atom in the tokeniser.
- `<x@y> (comment) more` and `Bob <a@b>, Alice` produce mailboxes with no
  domain for `more` and `Alice`. That follows RFC 7103 §7.1.7 as adopted, with
  `InvalidAddress`. Callers of `address.mailboxes` then get entries with
  `domain: None` mixed in. Document it on `mailboxes`.
- `Name <>` gives `Mailbox(Some("Name"), "", None)`. Fine for Return-Path;
  document that an empty local part with no domain means the null path.

### F15: Charset details

**Where:** `src/eml/charset.gleam`. **Ran** unless noted.

- Line 97-100: the caller decoder is only consulted when a label is present.
  §G.1 says "for any label"; an absent charset never reaches it. Decide which
  is intended and say so in the doc comment.
- Line 105-112: `NulInText` counts NUL *bytes in the input*, not U+0000 in the
  text. With a caller decoder for UTF-16, `<<0, 97, 0, 98>>` decoded to `"ab"`
  reports `NulInText(2)`. Count in the decoded text, or skip the count when the
  caller decoder produced the result.
- `utf-7`, `cp850`, `ibm437` and similar are `UnknownLabel`, so they are decoded
  as UTF-8 or windows-1252 with a Warning. `charset=utf-7` text comes out as
  `+AOk-`. §G.5 lists only CJK and UTF-16 as known-but-unsupported. Consider a
  short list of known legacy labels that return `UnsupportedCharset`.
- Line 170 (**Read**): `override` evaluates `is_ascii(bytes)` and
  `bit_array.to_string(bytes)` for every Latin-1 and single-byte decode, even
  when `utf8_override` is off, because case subjects are evaluated eagerly.
  That is two extra passes over every body. Test the flag first.
- Throughput: 1 MB of high bytes in windows-1251 takes 0.9 s on Erlang and
  3.5 s on JavaScript; 1 MB of invalid UTF-8 takes 1.6 s and 5.4 s. Both are
  linear. The cost is one `run` slice, one `to_string` and two list cells per
  high byte. Batching consecutive high bytes would help Cyrillic and Greek
  bodies.
- The spec's `Result(String, DecodeFailure)` for the caller decoder is
  `Result(String, Nil)` in the code. Update one of them.

### F16: Base64 P1 state deviates from §F.1

**Where:** `src/eml/internal/base64.gleam:85-93`. **Ran.**

| Input | Observed | §F.1 (state P1, class `A`) |
|---|---|---|
| `QQ=Qg==` | `AB`, `[Base64DataAfterPadding(1)]` | `AB`, `[MissingBase64Padding, Base64DataAfterPadding(1)]` |

**Fix:** record `MissingBase64Padding` when alphabet data arrives in state 4, or
change the table.

### F17: `diagnose` reports an unknown transfer encoding twice

**Where:** `src/eml.gleam:247-262`, `673-686`. **Ran.**

For `Content-Transfer-Encoding: x-foo`, `eml.diagnose` returns
`[UnknownTransferEncoding("x-foo"), UnknownTransferEncoding("x-foo")]`: once
from `parse` and once from `decode_body`. `validate` then lists it twice.

**Fix:** drop it from one of the two. Since `parse` already records it with a
span, `decode_body` can return the raw bytes with no diagnostic.

### F18: Decoded header text can contain line breaks and NUL

**Where:** `src/eml/encoded_word.gleam`. **Ran.**

`Subject: =?utf-8?Q?a=0D=0AX:_1?=` decodes to `"a\r\nX: 1"`. That is the
faithful result, and §G keeps NUL too. It is also a header-injection and
log-injection hazard for a caller who writes the subject into another header
or a log line. State it in the doc comments of `subject`, `header_text` and
the address types. Also note that `decode` trims the *decoded* text, so an
encoded leading space (`=?utf-8?Q?=20lead?=`) is removed.

### F19: Gaps in the tests

- **No never-crash property for M2.** `property_test.gleam` runs arbitrary
  bytes through `parse`, base64 and QP only. `address.parse`,
  `encoded_word.decode`, `parameter.resolve`, `filename.safe`, `charset.decode`,
  `eml.bodies` and `eml.diagnose` are not covered. A property over a small
  alphabet of structural bytes (`( ) < > " \ : ; , @ = ?` plus letters) would
  have found F01, and with a time budget F02.
- **Doubling tests use well-formed input only** (F02, F11).
- **No cross-target comparison of results.** F07 shows the two targets can
  disagree while both suites pass. A golden file of decoded outputs checked on
  both targets would catch it.
- **Charset tables have no known-answer vectors.** `every_label_decodes_every_byte_test`
  only checks that the ASCII half is unchanged. §K.4 calls for independent
  vectors (WPT). One fixed 128-character expected string per table would do.
- **The generator is not exercised.** Nothing checks that
  `charset_tables.gleam` matches what `dev/charset_tables.py` produces, and the
  commit hash is a command-line argument that is written into the header
  without being compared with the checkout.
- **Limits** are not tested at "exactly the limit, then a separator" (F10).
- **Addresses:** no test for a bare address followed by `<` (F03), adjacent
  atoms (F04), or a route without a colon (F05).

## Nits

- `src/eml.gleam:603`: the doc comment refers to `safe_filename`, which does
  not exist. The function is `eml/filename.safe`.
- `address.Single` and `mime.Single` share a name. `eml.from` returns
  `Single([Single(Mailbox(..))])`, and in Elixir
  `{:single, [{:single, {:mailbox, …}}]}`. Renaming the address variant (for
  example `Mailbox`/`Group`/`Invalid` with a separate record type) would read
  better in both languages.
- `src/eml/parameter.gleam`: RFC 2047 decoding is applied to the plain
  `filename` before Content-Type `name` is tried. §H.4 lists it as the last
  step. The code's order is the more useful one; update the spec.
- `src/eml/internal/parser.gleam:773`: an invalid Content-Type directly inside
  `multipart/digest` falls back to `text/plain`, not to the digest default.
  §E.1 says "the defaults apply". Pick one and state it.
- Embedded messages that begin with an empty line become `Opaque(NotMessage)`.
  That is §D.3 as written. I mention it because bounce generators sometimes
  emit exactly that.
- `dev/charset_tables.py`: `high_byte` compiles to a chain of up to 128
  comparisons per byte on JavaScript. It is included in the F15 timings and is
  acceptable; a 128-entry string table indexed by slice would be constant time.
