# M1/M2 adversarial code review — pi

Date: 2026-11-12. Scope: committed M1 and the uncommitted M2 implementation, against `docs/assumptions.md` v3, including its M2 status qualifications.

**Recommendation: do not ship M2 yet.** A one-byte address hangs both targets; a 9 KB address crashes JavaScript. Other confirmed defects affect filename safety, address identity, diagnostics, RFC 2231 ambiguity, and cross-target decoding.

## Method and results

Reviewed all handwritten modules in `src/`, `dev/charset_tables.py` rather than the generated table bodies, and the unit, property, performance, corpus and Elixir smoke tests.

Executed before and after probing:

- `nix develop -c gleam test`: **227 passed, no failures**.
- `nix develop -c gleam test --target javascript`: **227 passed, no failures**.
- `nix develop -c elixir -pa 'build/dev/erlang/*/ebin' test/elixir_smoke/smoke.exs`: **passed**.

Reproductions ran as `nix develop -c gleam run -m probe_pi_review` and the corresponding `--target javascript` command, with separate `probe_pi_hang`, `probe_pi_group`, and `probe_pi_perf` modules for unsafe/time-sensitive cases. All four probe source files were deleted. No existing repository files or `probe_fable_*` files were changed.

Unless stated otherwise, observations below were reproduced on **both Erlang and JavaScript**, with `charset.default_options()`. Strings use Gleam escapes; `repeat(s, n)` means `string.repeat(s, n)`. Parameter examples were passed through `structured.parse_content_type(<<"text/plain; ", input:utf8>>)` and then `parameter.resolve(parameters, "filename", options)`, so they exercise the actual lexer/resolver composition, not just manually constructed parameter lists.

## Blockers

### B1. A stray closing parenthesis makes address tokenisation nonterminating

**Location:** `src/eml/address.gleam:148–179` (`tokenise_loop`, `atom_end`).

**Reproducer:**

```gleam
address.parse(<<")">>, charset.default_options())
```

**Observed:** neither target returned. A six-second timeout terminated JavaScript with status 124; Erlang required the subsequent kill timeout, status 137. Both printed the marker immediately before `address.parse`, neither printed the marker after it.

**Expected:** a finite result such as `Invalid(")")` with `InvalidAddress`, not unbounded allocation/CPU. This is reachable through an otherwise ordinary `From: )\n\n` message when calling `eml.from`.

**Cause:** `atom_end` treats `)` and `]` as terminators, but `tokenise_loop` has no consuming branch for either. The fallback emits an empty atom and recurs at the same offset, growing the token accumulator forever. The later `invalid` progress check cannot help: parsing never reaches it.

**Fix:** explicitly consume unexpected closing delimiters into invalid tokens, and enforce that every tokenisation iteration advances. Add timeout-isolated regressions for every byte classified as an atom terminator, including `)` and `]`.

### B2. Nested address groups overflow the JavaScript stack

**Location:** `src/eml/address.gleam:318–321, 431–453` (`address` ↔ `group_members`).

**Reproducer:**

```gleam
let input = <<
  string.repeat("G:", 3000):utf8,
  "a@b",
  string.repeat(";", 3000):utf8,
>>
address.parse(input, charset.default_options())
```

**Observed:** JavaScript throws `RangeError: Maximum call stack size exceeded`, with alternating `address` and `group_members` frames. Erlang returns one address and 2,999 diagnostics. Input length is only 9,003 bytes, well below the default header limit.

**Expected:** malformed nested groups handled without recursion proportional to attacker-controlled nesting. §H.2 does not allow groups as group members; §J.2 prohibits this unbounded mutual-recursion pattern on JavaScript.

**Fix:** parse group members with a mailbox-only production, rejecting nested group syntax without recursively calling the general address parser. Preserve malformed input as appropriate rather than descending into it and subsequently dropping the result. Add the above vector to the JS stack-safety tests.

## Major findings

### M1. Combining marks bypass forbidden-character removal in safe filenames

**Location:** `src/eml/filename.gleam:35–37, 58–73`.

**Reproducers and observations:**

| Call | Actual result |
|---|---|
| `filename.safe("report.txt:\u{301}payload")` | unchanged, including `:` |
| `filename.safe("a*\u{301}b")` | unchanged, including `*` |

**Expected:** no colon or other forbidden Windows character survives, regardless of following combining marks (§I.1). In particular, the colon still separates an NTFS alternate stream; adding a combining mark after it does not neutralise that separator.

**Cause:** input is split into graphemes, then entire graphemes are compared to singleton strings such as `":"`. `":\u{301}"` is one grapheme, but is not equal to `":"`.

**Fix:** filter/replace forbidden **code points**, not whole grapheme strings. Grapheme-aware truncation may remain a separate step. Add a property asserting that the final result contains none of the forbidden code points, with combining marks following every punctuation candidate. The “suggestion only” warning does not make the advertised removal guarantee true.

### M2. Truncation can create reserved device names and trailing dots after safety checks

**Location:** `src/eml/filename.gleam:39–47, 96–130`.

**Reproducers and observations:**

```gleam
filename.safe("CONx" <> string.repeat("\u{301}", 300)) // "CON"
filename.safe("foo.x" <> string.repeat("\u{301}", 300)) // "foo."
```

**Expected:** a non-reserved name without trailing dots, still within 255 bytes (§I.1), e.g. `_CON` and `foo` under the current naming policy.

**Cause:** reserved-name and trailing-dot checks run before truncation. The final oversized grapheme is discarded as a unit, exposing a previously internal reserved stem or dot. The post-truncation check handles only empty string, `.` and `..`.

**Fix:** validate and normalise the **final** truncated result, including device-name protection and trailing-dot/space removal, while reserving room for any added prefix. Test adversarial oversized graphemes as well as ordinary long names; assert final-output invariants and sanitiser idempotence.

### M3. Address parsing silently invents or truncates mailbox identities

**Location:** `src/eml/address.gleam:308–335, 395–427, 457–476`.

**Reproducer:** call `address.parse` with each input:

| Input | Actual mailbox interpretation; diagnostics |
|---|---|
| `<a b@example.com>` | `ab@example.com`; `[]` |
| `<victim@example.com@evil.test>` | `victim@example.com`; `[]` |
| `alice@example.com evil.test` | `alice@example.comevil.test`; `[]` |
| `@example.com` | empty local part at `example.com`; `[]` |
| `a..b@example.com` | accepted unchanged; `[]` |
| bytes `a 00 @ b` | local part contains NUL; `[]` |

There are false rejections too: `a@ex(comment).com` becomes mailbox `a@ex` with display name `comment`, followed by `Invalid(".com")`; `a . b@example.com` becomes `Invalid`, rather than handling the obsolete dot-separated CFWS forms.

**Expected:** preserve the actual identity for accepted syntax. Malformed forms should be `Invalid(raw)` under §H.2, or undergo an explicitly defined, diagnosed recovery—not silently concatenate separate atoms or discard a second `@domain`. Valid obsolete CFWS around dots should not change the domain/local part.

**Cause:** `mailbox` validates UTF-8 but not mailbox grammar, concatenates token bytes, and does not require a nonempty local part. Angle parsing discards arbitrary remaining tokens through `to_closing`. Domain parsing ignores token spacing and treats a comment as the end of the domain.

**Fix:** implement explicit local-part/domain productions with CFWS handling, dot placement and control-character validation; retain token boundaries. Require the remaining angle content to be permitted closing syntax. Propagate recovery diagnostics and preserve rejected spans. Add identity-focused assertions, not just “returned a mailbox” checks.

### M4. Diagnostic truncation makes validation fail open, including with default options

**Location:** `src/eml/internal/parser.gleam:170–194`; `src/eml/diagnostic.gleam:119`; `src/eml.gleam:247–277`.

**Minimal reproducer:** parse `Content-Type: multipart/mixed\n\nx` with `with_max_diagnostics(0)`, then call `eml.validate(message, diagnostic.DataLoss)`.

**Observed:** `diagnose` returns only `DiagnosticsTruncated` at `Info`; validation returns `Ok`, although the root is opaque because it has no boundary.

**Default-options reproducer:**

```gleam
let input = <<
  string.repeat("X : a\n", 1000):utf8,
  "Content-Type: multipart/mixed\n\nx",
>>
```

**Observed:** the diagnostic kinds are 1,000 `SpaceBeforeColon` entries followed by `DiagnosticsTruncated`; validation at `DataLoss` again accepts. The later `MissingBoundary` was discarded. Decoding an opaque entity does not reconstruct that structural diagnostic.

**Expected:** truncating diagnostic storage must not turn a known uninterpretable body into a successful validation result. This is a validation bug, not a request to make diagnostic limits fail `parse`.

**Fix:** retain severity/completeness information independently of the bounded diagnostic list, or make validation explicitly refuse an incomplete report. Reconstructing opaque-body failures helps but does not cover every discarded structural warning. Test truncation before failures at each validation threshold, with default and zero budgets.

### M5. Encoded-word and address-display decoding discard recovery diagnostics

**Location:** `src/eml/encoded_word.gleam:223–240, 245–307, 354–385`; `src/eml/address.gleam:497–526`.

**Reproducers:** call `encoded_word.decode`:

| Input | Actual | Expected diagnostic accompanying recovery |
|---|---|---|
| `=?x-unknown?Q?=FF?=` | `"ÿ", []` | `UnknownCharset("x-unknown")` |
| `=?iso-8859-1?Q?=80?=` | `"€", []` | `C1ReinterpretedAsWindows1252` |
| `=?utf-8?Q?=00?=` | U+0000, `[]` | `NulInText(1)` |
| `=?utf-8?B?QQ?=` | `"A", []` | missing-padding recovery reported |
| `=?utf-8?Q?=GG?=` | `"=GG", []` | malformed encoded-word/escape warning |

Additionally, `address.parse(<<"=?shift_jis?B?gqA=?= <a@b>">>, options)` returns the literal undecoded display name and **no diagnostics**, whereas decoding that word directly reports `UnsupportedCharset("shift_jis")`.

**Expected:** successful text recovery must retain the applicable §G diagnostics. An address parser's diagnostic return must include failures in its display text. These are direct low-level APIs that explicitly return diagnostics; the documented exclusion of nonstructural headers from `eml.diagnose` does not explain the loss.

**Cause:** `strict_decode` keeps only the string and rejects only `MalformedCharsetData`; the successful `decode_run` branch returns `[]`. Base64 diagnostics are reduced to an accept/reject boolean, Q-decoding does not report malformed escapes, and address display-name helpers take only tuple field `.0`.

**Fix:** carry text **and diagnostics** through successful word decoding, transfer recovery, split repair, and address display-name parsing. Distinguish a genuinely strict decode from charset fallback. Add malformed-Q diagnostics. Update `test/eml/encoded_word_test.gleam`'s `latin1_word_with_c1_test`, which currently explicitly expects the incorrect empty diagnostic list.

### M6. RFC 2231 decoding loses charset warnings and downgrades unsupported charsets

**Location:** `src/eml/parameter.gleam:42–48, 210–218`.

**Reproducers and observations:**

| Parameter input | Actual resolver result |
|---|---|
| `filename*=x-unknown''%FF` | `Resolved("ÿ"), []` |
| `filename*=utf-8''%FF` | `Resolved("�"), []` |
| `filename*=shift_jis''%82%A0` | `Unsupported, [MalformedParameter("filename")]` |

**Expected:** respectively retain `UnknownCharset`, `MalformedCharsetData(1)`, and `UnsupportedCharset("shift_jis")` at their specified severities. The last value is syntactically well-formed but unsupported; §G.5 calls that `DataLoss`, not a malformed-parameter `Warning`.

**Cause:** `decode_charset` discards the diagnostic half of `charset.decode`, and `resolve` maps `Unsupported` to `MalformedParameter`.

**Fix:** return diagnostics alongside the internal extended-value result and thread them through both success and fallback. Preserve the unsupported label and severity. Add tests for charset failures in single extended values and assembled continuations, with and without a plain fallback.

### M7. The lexer removes duplicated continuation indices before RFC 2231 can reject ambiguity

**Location:** `src/eml/internal/structured.gleam:108–119`; `src/eml/parameter.gleam:77–116, 137–145`; `src/eml.gleam:604–619`.

**Reproducer:**

```text
Content-Disposition: attachment; filename=safe.txt; filename*0*=utf-8''evil; filename*0*=utf-8''other; filename*1*=.exe

```

**Observed:** `eml.filename` returns `Some("evil.exe")`. At the lexer/resolver boundary, the lexer has removed the second `filename*0*` and emitted `DuplicateParameter("filename*0*")`; the resolver sees a contiguous sequence and returns `Resolved("evil.exe"), []`.

**Expected:** §H.4 explicitly makes a duplicated **section index** ambiguous. The extended value must not resolve; the plain fallback should produce `safe.txt`, with `AmbiguousParameter("filename")`. Without that fallback, the result should be `Ambiguous`.

**Fix:** retain raw parameter occurrences or duplicate-index metadata for RFC 2231 resolution. Keep M1's effective first-wins structural parameter policy, especially for boundaries, separate from the raw occurrence information M2 needs. Test duplicated identical attribute names through the lexer, not just distinct spellings that happen to denote the same index.

### M8. Native UTF-8 conversion silently strips BOMs only on JavaScript, including in identities

**Location:** `src/eml/charset.gleam:234–239, 282–287`; `src/eml/address.gleam:463–473`; also native conversion in `encoded_word.raw_text` and parameter decoding.

**Reproducers:**

```gleam
charset.decode(<<239, 187, 191, "x">>, Some("utf-8"), options)
address.parse(<<"a@", 239, 187, 191, "evil.test">>, options)
```

**Observed:**

| Call | Erlang | JavaScript |
|---|---|---|
| charset decode | `Ok("\u{FEFF}x"), []` | `Ok("x"), []` |
| address domain | `Some("\u{FEFF}evil.test")`, no diagnostics | `Some("evil.test")`, no diagnostics |

**Expected:** identical interpretation across targets. In an identity token, U+FEFF must not silently disappear merely because the bytes were passed to a native string decoder; retain it consistently or reject the identity consistently. Any BOM policy for display text should be explicit and separate from identity handling and the initial message BOM.

**Cause:** the installed stdlib's JavaScript `bit_array.to_string` uses `new TextDecoder("utf-8", { fatal: true })`, which consumes a leading BOM; Erlang preserves it. eml relies on this conversion in multiple semantic contexts.

**Fix:** centralise a byte-preserving UTF-8 conversion, using a dependency fix/configuration equivalent to `ignoreBOM: true`, or a portable wrapper that preserves initial U+FEFF explicitly. Define any deliberate display-text BOM stripping above that layer. Add byte/codepoint assertions on both targets, including BOMs at token and recovered UTF-8-run boundaries.

### M9. Malformed M2 inputs trigger quadratic rescanning at small sizes

**Locations and reproducing families:**

1. `src/eml/encoded_word.gleam:47–61, 117–123`: `encoded_word.decode(<<repeat("=?utf-8?Q?x", n):utf8>>, options)`.
2. `src/eml/address.gleam:226–247`: `address.parse(<<repeat("(x<", n):utf8, "a@b>">>, options)`.
3. `src/eml/filename.gleam:79–84`: `filename.safe("a" <> repeat(".", n))`.

**Observed:** elapsed milliseconds for the individual calls, excluding compilation/input construction:

| Family / target | n=500 | n=1,000 | n=2,000 | n=4,000 |
|---|---:|---:|---:|---:|
| Unclosed encoded words / JS | 143 | 797 | 3,327 | — |
| Unclosed encoded words / Erlang | 9 | 48 | 132 | — |
| Unclosed comments / JS | 66 | 313 | 922 | — |
| Unclosed comments / Erlang | 3 | 9 | 40 | — |
| Trailing filename dots / JS | 153 | 243 | 900 | 4,178 |
| Trailing filename dots / Erlang | 14 | 24 | 92 | 303 |

These are illustrative single-run timings, not stable benchmark thresholds. The source explains the quadratic growth: each encoded-word start searches the remaining suffix for a nonexistent terminator; each failed comment scans to EOF before recovering at an earlier `<`; filename trimming repeatedly segments/copies an ever-shorter string. The largest encoded-word case is only 22 KB; the slowest filename is 4,001 ASCII characters.

**Expected:** bounded, approximately linear processing of malformed as well as valid input (§J), without seconds of JS event-loop blocking for kilobyte-scale headers/names.

**Fix:** avoid retrying suffix-wide failed searches—use a forward scanner, bounded token recognition or cached delimiter/search results while preserving recovery semantics. Locate the filename trim boundary in one pass. Add all three malformed families to the performance suite; its current M2 cases exercise ordinary addresses and successfully terminated words, not these failure paths.

### M10. Invalid Content-Type inside multipart/digest uses the wrong default

**Location:** `src/eml/internal/parser.gleam:740–773`, particularly `default_content_type(False)` on parse failure.

**Reproducer:**

```text
Content-Type: multipart/digest; boundary=b

--b
Content-Type: bad

Subject: nested

body
--b--
```

**Observed:** the digest child has effective type `text/plain; charset=us-ascii` and body `Leaf`. Changing `Content-Type: bad` to an empty `Content-Type:` correctly produces `message/rfc822` and `Embedded`.

**Expected:** §D's invalid-first-occurrence rule and §E.1 say invalid types fall back to the defaults; the contextual default here is `message/rfc822`. The nested message should remain structurally reachable, with `InvalidContentType` reporting the recovery.

**Fix:** use the inherited/default content type already passed into `content_type`, rather than constructing the non-digest default in this branch. Test absent, empty and invalid types inside and outside a digest, including a duplicate whose first occurrence is invalid.

## Minor findings

### m1. Header limits count lines/bytes that are not part of the header block

**Location:** `src/eml/internal/parser.gleam:450–468`; `test/eml/limits_test.gleam` (`header_lines_test`).

**Reproducers:**

- `parse_with(<<"X:y\nbody is long">>, default_options() |> with_max_header_bytes(5))` returns `Error(LimitExceeded(MaxHeaderBytes))`.
- `parse_with(<<"X:y\n\n">>, default_options() |> with_max_header_lines(1))` returns `Error(LimitExceeded(MaxHeaderLines))`.

**Expected:** the first has a four-byte header followed by a recovered body; it should succeed with `MissingHeaderBodySeparator`. The second has one field line, satisfying §B.3's count of field/anomaly/continuation lines, and should succeed.

**Cause:** limits are checked before distinguishing header lines from body, separator or delimiter lines. The current line-limit test explicitly counts the separator, contrary to that documented unit.

**Fix:** classify the line before charging the appropriate header budget, preserving limits on actual fields/anomalies/continuations. Test a body beginning exactly at the budget boundary and a parent delimiter terminating child headers, in addition to blank separators.

### m2. Base64 P1→alphabet loses MissingBase64Padding

**Location:** `src/eml/internal/base64.gleam:85–94, 151–166`.

**Reproducer:** `base64.decode(<<"QQ=Qg==">>, 0)`.

**Observed:** bytes `AB`, with only `Base64DataAfterPadding(1)` at span `[3,4)`.

**Expected:** the same bytes and data-after-padding diagnostic, **plus `MissingBase64Padding`**, as explicitly required by the P1 + alphabet transition in §F.1.

**Fix:** distinguish P1 from Done when consuming the next alphabet byte; record missing padding before starting the next quantum. Do not rely on EOF to detect it, since the previous state has been lost. Add this transition combination to the exact diagnostic vectors.

### m3. NulInText counts input zero bytes, not decoded NUL characters

**Location:** `src/eml/charset.gleam:98–109`.

**Reproducers:**

- Install a callback returning `Ok("ok")`; decode `<<65, 0>>` with label `utf-16le`. Actual: `Ok("ok"), [NulInText(1)]`.
- Install a callback returning `Ok("a\u{0}b")`; decode `<<65>>` with label `x-test`. Actual: decoded text contains NUL, but diagnostics are `[]`.

**Expected:** respectively no NUL diagnostic, and `NulInText(1)`. A real UTF-16 decoder makes the first issue routine: zero bytes in code units do not imply decoded U+0000.

**Fix:** count NULs in the successful decoded string, not the source bytes. Keep the count aggregated and add custom-decoder tests that change the relationship between input zero bytes and output NULs.

### m4. Split-character repair is applied to stateful charsets

**Location:** `src/eml/encoded_word.gleam:265–280`.

**Reproducer:** install a caller decoder that returns `Ok("あ")` for label `iso-2022-jp` and bytes `1B 24 42 24 22 1B 28 42`, otherwise `Error(Nil)`. Decode:

```text
=?iso-2022-jp?Q?=1B$B$?= =?iso-2022-jp?Q?=22=1B(B?=
```

**Observed:** `"あ", [EncodedWordSplitCharacter]`; the callback is allowed to decode the concatenation of both words.

**Expected:** no cross-word repair for ISO-2022-JP. §H.3 expressly restricts this recovery to stateless charsets. Independently undecodable words should remain undecoded, with their diagnostics, rather than acquiring meaning from another word's state.

**Fix:** gate concatenation on explicit stateless-charset knowledge. Unknown/custom labels must not implicitly be assumed stateless; expose a capability if custom decoders need this recovery. Keep the existing UTF-8 split-character regression.

### m5. Address formatting fails to quote specials followed by combining marks

**Location:** `src/eml/address.gleam:39–63`.

**Reproducer:**

```gleam
address.to_string(
  address.Mailbox(None, "a@\u{301}b", Some("example.com")),
)
```

**Observed:** `a@\u{301}b@example.com`, without quotes.

**Expected:** `"a@\u{301}b"@example.com`. This local part is representable in a quoted UTF-8 address; emitting its internal `@` unquoted destroys the mailbox boundary and breaks parse/format round trips.

**Cause:** `needs_quoting` searches for entire graphemes in an ASCII-specials string, so `@` followed by a combining mark no longer matches.

**Fix:** inspect code points for quoting requirements, and escape only the local-part content before enclosing it in quotes. Add round trips for quoted local parts containing each special followed by combining marks.

## Test coverage and review notes

The passing suite is useful evidence for the existing M1 vectors, not evidence that these M2 paths are safe:

- `test/eml/property_test.gleam` exercises MIME parsing and transfer decoding, not the new address/encoded-word/parameter/filename functions. Add direct M2 generators and composed header-to-accessor tests. Run hang/crash cases in isolated processes with timeouts.
- `test/eml/perf_test.gleam:174–200` tests ordinary address lists and valid encoded words. Keep its larger-size ratio approach, but add the malformed families above and nested-group stack tests.
- `test/eml/parameter_test.gleam` needs identical duplicated continuation attributes, extended-charset diagnostics, and final filename invariants across arbitrary Unicode. Its ordinary traversal/ADS/device-name examples do not cover grapheme or truncation interactions.
- `test/eml/encoded_word_test.gleam` currently locks in lost Latin-1 C1 diagnostics. Its “missing padding” example `SGVq` is actually a complete three-byte quantum requiring no padding; add `QQ` inside a B word.
- `test/eml/charset_test.gleam`'s all-label/all-byte test checks the ASCII prefix and permits `Error`, so it is not an oracle for the upper-half mappings or support completeness. Add independent expected mappings, aliases, BOM preservation and callback-produced NULs. The generator's explicit null-entry handling, 128-entry assertion, Unicode literal generation and ISO-8859-8-I sharing were reviewed; no additional concrete generator defect was established. Generated table bodies were not manually audited.
- `test/eml/validate_test.gleam` needs truncation-before-failure cases. The documented exclusion of display-only headers from `diagnose` was treated as intentional, not itself reported as a defect.
- The Elixir smoke test passed and the opaque types/builders remain usable from Elixir. Add malformed/recovered cases to that smoke coverage; the semantic and nontermination bugs are shared with Erlang callers, not hidden by tuple interop.
- M1's source separation for encoded embedded messages, first-wins structural interpretation, bounded-chunk transfer decoding, boundary lifecycle tests and segment tiling received review. The findings above do not require reversing those policies. `Flatten`, broad CJK support and fuzz infrastructure remain M3 work and were not counted as missing M2 features.

No nit-only findings are included. Fix the two availability blockers first, then filename/identity safety and diagnostic integrity, before relying on the current green suite as an M2 release gate.
