# eml: research notes

Goal: a robust, total (never-crashing) **pure Gleam** parser for MIME email /
`.eml` files that produces algebraic data types, replacing gen_smtp's
`mimemail:decode/1`.

**Hard constraint:** pure Gleam. No dependency on iconv, gen_smtp or any NIF.
The library ships no target-specific FFI either; charset tables, base64, QP and
byte searching are all written in Gleam, so the library behaves identically on
Erlang and JavaScript.

Researched 2026-11-12. Toolchain at the time: Gleam 1.19.2, OTP 29,
gleam_stdlib 1.0.5, gleeunit 1.11.0, qcheck 1.0.5, birdie 2.0.2.

## 1. Why gen_smtp's `mimemail` fails us

Observed in leaf/master (`lib/leaf/emails/eml_parser.ex`, tracker notes):

- The default decoding needs the optional `iconv` NIF; without it it raises
  `UndefinedFunctionError iconv:convert/3`. So we use `encoding: :none`,
  which **silently strips every byte >= 128** in bodies.
- `parse_headers` replaces non-ASCII header bytes with `?`.
- LF-only `.eml` files parse to an empty body (it only works with CRLF).
- Empty MIME parts are dropped, so zero-byte attachments vanish.
- A malformed B-encoded Subject is silently dropped.
- Mislabelled charsets (declares ISO-8859-15, is actually UTF-8).
- Wrong typespecs (we run a fork for the type fix).
- Untyped 5-tuple output, so classification (for example inline image vs.
  attachment) is ad hoc in our code.

Upstream source and issues (gen_smtp 1.3.0):

- It *throws* `non_mime_multipart`, `no_boundary`, `missing_last_boundary`,
  `bad_content_type`, and QP `badchar`.
- It discards the preamble and epilogue.
- Open issues:
  - #122 and #317: unfolding drops whitespace (`"This\r\n is"` becomes
    `"Thisis"`).
  - #88 and #145: `bad_charset` crashes.
  - #36: non-Latin RFC 2231 and 2047 filenames are not decoded.
  - #10: no permissive mode.
  - #342: non-ASCII addresses crash.
  - #284: 8BITMIME and UTF-8 handling is untested.
- Worth copying: the "permissive retry" that joins multibyte characters
  split across adjacent encoded-words.

## 2. Relevant RFCs

| RFC | What we need from it |
|---|---|
| 5322 (+ errata 1905, 1908, 6639) | Message and header syntax, folding, CFWS and comments, addresses and groups, date-time, msg-id. **§4 obsolete syntax must be accepted.** |
| 2045 | Content-Type and parameters, Content-Transfer-Encoding, QP and base64 rules (with explicit robustness advice in §6.7). The default type is `text/plain; charset=us-ascii`, also when the field is invalid. |
| 2046 | Multipart grammar: the boundary is 1–70 chars, the CRLF before a delimiter belongs to the delimiter, transport padding, preamble and epilogue, the multipart/digest default, message/rfc822. Unknown multipart subtypes are treated as mixed. |
| 2047 | Encoded-words: where they are allowed (unstructured text, comments, phrases), where they are not, and that whitespace between adjacent encoded-words is dropped. |
| 2049 | Conformance: an unknown CTE or an unknown charset means octet-stream. |
| 2231 (and RFC 8187) | Parameter continuations `name*0*=`, `charset'lang'%XX`. Parts may arrive out of order. Assemble the bytes, then decode once. |
| 2183 | Content-Disposition. An unknown type means attachment. The filename is a terminal component only (sanitise it). |
| 6532 | UTF-8 in headers (raw 8-bit is legal in phrases, unstructured text, and local-parts), message/global. |
| 6854 | Groups are allowed in From and Sender, so `from: List(Address)`. |
| 3676 | format=flowed (an optional post-decode helper). |
| 2387, 2392, 2557 | multipart/related `start` and `type`, `cid:` URLs, Content-Location (exposed as fields only). |
| 4648 | Base64 details (MIME overrides "reject non-alphabet" with "ignore"). |
| **7103** | **Advice for the Safe Handling of Malformed Messages.** This is the leniency reference (details below). |
| 4155 | mbox and the leading `From ` line. |

The RFC texts are downloaded to the session scratchpad. Re-fetch them from
rfc-editor.org as needed.

### RFC 7103 rules we adopt (key leniency points)

- Treat a lone CR or LF as CRLF in raw message framing (§6). Never rewrite the
  bytes globally; the line splitter accepts all three.
- Use the internal interpretations in §7.1 for broken addresses:

  | Input | Interpret as |
  |---|---|
  | `<@route:a@b>` | `<a@b>` |
  | `<<<a@b>>>` | `<a@b>` |
  | `<a@b` | `<a@b>` |
  | `a@b>` | `a@b` |
  | Unclosed comment | close it |
  | Unbalanced quote | close it |
  | `<a@x, b@y>` | two addresses |
  | Naked local-part | keep it, with no domain |

- A colon-less line in the header block (§7.2) is a continuation if the header
  block continues afterwards. Record a defect.
- A whitespace-only line inside the header is folding, not the separator
  (§7.3).
- Accept whitespace before the colon (§7.4).
- Duplicate fields (§7.5): keep all of them, the accessor picks the first,
  and record a defect.
- A missing MIME-Version is not a problem if the message has MIME structure
  (§8.1).
- Do not truncate lines longer than 998 octets (§9.1).
- NUL bytes: drop them from decoded text and record a defect.

### Other real-world deviations to tolerate

- **BOM and envelope line:** a UTF-8 BOM, or a leading mbox `From ` line
  (keep it as `envelope_from`).
- **Header block:** the whole file is header with no body separator, the
  first header line is a continuation line, or a header name contains
  invalid characters.
- **Header bytes:** raw 8-bit or UTF-8 in headers without RFC 6532. Fallback
  order: UTF-8 if it validates, otherwise windows-1252.
- **Encoded-word placement:** inside quoted strings (`"=?utf-8?B?..?=" <a@b>`),
  in parameters (`filename="=?UTF-8?B?..?="`), or without surrounding
  whitespace.
- **Encoded-word content:** B-encoding without padding, spaces in Q text,
  unknown charsets, and charset aliases (`utf8`, `latin1`,
  `ks_c_5601-1987`).
- **Unquoted parameter values:** boundaries containing `:=?`, or filenames
  with spaces.
- **Content-Type:** a missing boundary, a value without a `/`, or multiple
  Content-Type fields (use the first).
- **Composite parts:** a base64 or QP CTE on a multipart (ignore it and record
  a defect), or a base64-encoded message/rfc822 (decode it, then parse it).
- **Boundaries:** a missing close or first boundary, an ancestor boundary
  terminating a nested part, the same boundary nested inside itself, or
  trailing garbage after a delimiter.
- **CTE spelling:** values such as `8-bit`, `7-bit`, `none` or `x-uuencode`.
- **Charsets:** `charset=us-ascii` or `unknown-8bit` on 8-bit text, or a
  declared charset that does not match the bytes.

## 3. Proposed architecture

Every layer is pure and total, returning a value plus defects.

0. **Framing.** Strip the BOM and the envelope `From ` line. The line
   splitter accepts CRLF, LF, and CR.
1. **Header/body split.** Produce an ordered `List(RawField(name, raw_value: BitArray))`
   and a body slice (a `bit_array.slice` sub-binary). Apply the RFC 7103 heuristics.
2. **Field lexing.** Unfold. Use one shared CFWS-aware tokenizer for structured
   fields: atoms, quoted strings with quoted-pairs, nested comments, and
   domain literals. It never fails, closes anything left unbalanced at the
   end of input, and treats 8-bit bytes as atext.
3. **Structured parsers**, each returning `Result(Typed, raw)` plus defects:
   - addresses and groups
   - dates (raw value always kept)
   - msg-id lists
   - Content-Type and Content-Disposition with RFC 2231
   - CTE
   - unstructured text with RFC 2047 (concatenate the bytes of adjacent words
     that share a charset before decoding)
4. **MIME tree.** Split multiparts with a stack of active boundaries, keeping
   the preamble and epilogue. Parse message/rfc822 and message/global
   recursively. Enforce depth, part-count, and size limits.
5. **Transfer decoding**, lazily per leaf, with lenient base64 and QP.
6. **Charset decoding** for text parts and encoded-words, using WHATWG labels
   and single-byte tables plus a pluggable decoder for CJK and other
   charsets. Always keep the raw bytes.
7. **Helpers** outside the core:
   - text and HTML body selection (multipart/alternative and related)
   - attachment listing (disposition plus name heuristics; inline vs.
     attachment)
   - `cid:` resolution
   - format=flowed
   - filename sanitising

### Leniency and error model

- `parse(BitArray) -> Message` is **total**. Reserve `Error` for resource
  limits (or an opt-in strict mode).
- Use a closed `Defect` sum type attached to the node it concerns. Examples:
  `MissingCloseBoundary`, `NonHeaderLine`, `InvalidBase64(..)`,
  `UnknownCharset`, `EightBitInHeader`, `DuplicateField`, `NulBytesRemoved`.
  This mirrors Python's `email` `.defects` and makes the policy testable.
- The raw bytes always sit next to every typed view (needed for DKIM,
  re-serialising, and debugging).

### ADT sketch (to be refined)

```gleam
pub type Message {
  Message(envelope_from: Option(String), root: Part)
}

pub type Part {
  Part(
    headers: List(Header),          // ordered, raw, authoritative
    content_type: ContentType,      // parsed, or the RFC default
    disposition: Option(Disposition),
    body: Body,
    defects: List(Defect),
  )
}

pub type Body {
  Single(encoding: TransferEncoding, raw: BitArray)   // decode lazily
  Multipart(boundary: String, preamble: BitArray, parts: List(Part), epilogue: BitArray)
  Embedded(Message)                                    // message/rfc822 | message/global
}

pub type Address {
  Mailbox(name: Option(String), local_part: String, domain: Option(String))
  Group(name: String, members: List(Address))
}
```

## 4. Building blocks (Gleam ecosystem)

- There is **no existing Gleam MIME parser.** The Gleam email packages are all
  senders. Peers to learn from:
  - Elixir `mailex` (NimbleParsec; has a conformance corpus, codepagex
    charsets)
  - Elixir `mail` (pluggable `charset_handler`, but breaks on bare LF and
    raises on bad input)
- **Do not use `bit_array.base64_decode` for MIME.** It was verified on OTP 29
  to fail on line-wrapped input (`"QUJD\r\nREVG"` gives an error), and its
  behaviour differs from JS `atob`. Write our own lenient decoder in Gleam.
- There are no QP or RFC 2047 libraries, so we write our own.
- **Charsets:** there is no pure Erlang or Gleam charset library (`iconv` is
  a NIF, and `codepagex` is Elixir). Plan:
  - Code-generate the single-byte tables (about 28) from the WHATWG Encoding
    Standard indexes, and use WHATWG label aliasing.
  - Handle UTF-8 natively.
  - CJK (Shift_JIS, EUC-JP, ISO-2022-JP, GBK/GB18030, Big5, EUC-KR) later,
    generated from the WHATWG indexes in Gleam, possibly as a separate package
    because the tables are large. Until then, expose an optional caller-supplied
    `fn(label, BitArray) -> Result(String, Nil)` and keep the raw bytes.
- **Parsing approach:** hand-written recursion over `BitArray` pattern
  matching (zero-copy match contexts on Erlang). Boundary search is done in
  Gleam: scan line starts for `--` and compare the prefix, with no FFI. Combinator libraries (`nibble`,
  `atto`, `party`) are String-oriented and fail-fast. `bitty` 1.1.0 works on
  BitArray and is an option for small grammars, but tolerance is easier to
  hand-roll.
- **JS target:** avoid `utf8_codepoint` patterns and `native` endianness.

## 5. Test corpora (ranked by value for the porting effort)

| # | Source | License | What | Expected output |
|---|---|---|---|---|
| 1 | Stalwart `mail-parser` `resources/*.json` | Apache-2.0 / MIT | 670 header vectors: address 132, content_type 126, date 84, received 202, id 34, list 38, unstructured 54 | **JSON** |
| 2 | gen_smtp `test/fixtures` + eunit in `src/mimemail.erl` | BSD-2 | 34 `.eml` files, 19 test groups, `prop_mimemail.erl` | Erlang asserts |
| 3 | mime4j `testmsgs` + `mimetools-testmsgs` | Apache-2.0 / Artistic | 32 + 48 messages (boundary edge cases, malformed headers) | **XML tree + decoded bodies** |
| 4 | CPython `Lib/test/test_email` | PSF-2.0 | 48 messages; 373 header-value-parser tests with expected **defect lists**; `test_defect_handling.py` | Python (extractable) |
| 5 | MimeKit `UnitTests/TestData` | MIT | 23 `compliance/` + 35 `messages/` files; jwz mbox + `jwz-summary.txt` structure oracle | partial |
| 6 | Go `net/mail`, `mime`, `mime/multipart`, `quotedprintable` | BSD-3 | about 42 address, 43 media-type, and 48 encoded-word table rows | Go tables |
| 7 | enmime `testdata` | MIT | 43 mail + 32 parts + 12 low-quality files; `mediatype_test.go` (about 180 broken Content-Type rows) | Go asserts |
| 8 | Stalwart `resources/eml/regressions` (76) and `rfc` (10) | Apache-2.0 / MIT | full messages | JSON (library-specific) |
| 9 | postal-mime (MIT-0), mailparser (MIT) | | Ryan Finnie's MIME torture test; DoS fixtures (`outofmemory.eml`) | JS asserts |

**Do not vendor:**
- Dovecot and GMime tests (LGPL/GPL; re-derive the cases by hand instead)
- Stalwart `legacy/` (Hunnysoft, no license grant)
- Stalwart `malformed/` and `thirdparty/` (Dovecot provenance unclear)
- the Crispin torture test and jwz messages (no license; fetch at test time)
- Enron and SpamAssassin (use locally for crash and differential runs only)

**Our own corpus:** the 33 `.eml` fixtures in leaf/master are customer-ish
data. Use them for local differential testing only, and add anonymised
reductions as regressions.

Keep a `LICENSE`/`NOTICE` file next to each vendored fixture set under
`test/fixtures/<source>/`.

## 6. Testing and fuzzing plan

- **Unit and table tests:** port the vectors listed above. Use a JSON-driven
  runner for the Stalwart vectors and an XML-to-tree comparator for mime4j.
- **Snapshot tests (birdie):** a deterministic pretty-printer of the parse
  tree (bodies shown as a truncated preview plus their length), with one
  snapshot per corpus file.
- **Property tests (qcheck):**
  - Never crash on arbitrary bytes, using a structured email-like generator
    that splices random bytes into headers, boundaries, encoded-words, and QP.
    Uniform bytes rarely get past the header parser.
  - Round-trips: base64, QP, RFC 2047, and render-then-parse.
  - Idempotence.
  - Use the byte-aligned generators only (the others crash on JS).
  - Watch the EUnit timeout of about 5 s (`qcheck_gleeunit_utils`).
- **Differential:** gen_smtp is *not* a dependency, not even a dev dependency.
  If we want to compare against `mimemail:decode/1`, do it from leaf/master or
  a throwaway script outside this repo.
- **Coverage-guided fuzzing:** no BEAM-native fuzzer exists. PropEr is GPL,
  triq is dead, and jazzer.js is deprecated. DIY plan (test tooling only, in
  `dev/` or `test/`, never part of the published library):
  - Use OTP 27+ native coverage (`code:set_coverage_mode(function)` /
    `get_coverage`) to guide a mutation loop. Mutate with our own mutators or
    `erlamsa` (MIT), seeded from the corpora plus the Stalwart
    `fuzz/mime.dict`.
  - Run each input in its own process with `max_heap_size` and a timeout, so
    quadratic blowups count as failures.
  - Run it as a nightly or weekly CI job. Minimised crashers go into
    `test/corpus/regressions/`.
- **CI:** `gleam test` on Erlang and JavaScript, plus `gleam format --check`.
