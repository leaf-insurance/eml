# Review of the v2 decision record (fable)

Date: 2026-11-12. Reviewed `docs/assumptions.md` (v2) against `docs/research.md`,
`docs/research-error-model-and-charsets.md` and the first adversarial review.
Findings from the first review are not repeated unless v2 left them unresolved.

**Verdict:** v2 is a sound basis, and the decided items (Result entry point,
fail-by-default limits, WHATWG charsets, no gen_smtp) hold up. Three things must
be settled before the first line of the header splitter or tree builder is
written: the header-block table (F01), what "lossless spans" means (F02), and
the fact that M1 depends on header parsing that is scheduled for M2 (F03). Most
of the remaining findings are table rows that overlap or are missing, and
Gleam-on-JavaScript performance traps that the plan does not yet name.

## How claims were checked

- **RFCs:** RFC 7103, 2045 and 2046 were fetched from rfc-editor.org and quoted
  from the text.
- **Reference behaviour:** counterexamples were run through CPython 3.14.8
  `email` with `policy.default`. Other parsers (MimeKit, mail-parser) were
  **not** run. Claims about them in v2 remain unverified.
- **Gleam behaviour:** a throwaway project outside this repository was built
  with the installed toolchain (Gleam 1.19.2, gleam_stdlib 1.0.5, Erlang/OTP 28,
  Node 24.22). Timings are single runs on one machine. Treat them as orders of
  magnitude.
- **Not checked:** an end-to-end Mix build of a Gleam dependency, and anything
  about leaf's private fixtures.

## Blockers

### F01: The header-block rules contradict each other and can swallow the body

**Sections:** B.1, B.2, D.3, D.4, E.3, E.4.

**Problem 1: the first line has two outcomes.** B.1 says a first line that is
not a valid `name:` field gives `NoHeaderBlock`. D.4 row 2 says a colon-less
line followed by a header-looking line is kept as an anomalous line with a
Warning. Both apply to this input:

```
garbage
Subject: x

body
```

**Problem 2: rows 2, 3 and 5 of D.4 overlap.** Row 2 fires when "a later
header-looking line *or empty line*" exists. Row 3 fires when "nothing
header-like follows (EOF or body-like text)". Row 5 fires on "EOF with no empty
line".

| Input | Rows that match | Outcomes they give |
|---|---|---|
| `Subject: x\nhello world` (EOF) | 3 and 5 | body is `hello world` / body is empty |
| The message below | 2 and 3 | first paragraph is header anomalies / first paragraph is body |

```
Subject: hi
Hello Bob,
this is the body.

Second paragraph.
```

Read literally, row 2 wins on the second input because an empty line exists
later. The body then becomes `Second paragraph.` and the first paragraph is
reported as two anomalous header lines. Any line such as `Note: see below`,
`PS: thanks` or `12:30 lunch` in that paragraph becomes a header field.

**Evidence.**

- RFC 7103 §7.2 really does give this heuristic: "Search forward for an empty
  line. If one is found, then apply option 3". It names no fallback step, and it
  presents rejection (option 4) as the alternative. So row 2 is faithful to the
  RFC, and the RFC heuristic is what swallows the paragraph.
- CPython does not use this heuristic. On the message above it returns headers
  `['Subject']`, defect `MissingHeaderBodySeparatorDefect`, and the body starting
  at `Hello Bob,`. On the `garbage` input it returns no headers and the whole
  input as the body. D.4's open question ("confirm against Python's behaviour")
  therefore already has an answer: Python starts the body at the first
  non-header line, always.

**Problem 3: three entry contexts, one rule.** The same header splitter runs in
three places with different stated outcomes, and they are spread over four
sections:

| Context | First line is not a field | Empty header block |
|---|---|---|
| Top level (B.1) | `NoHeaderBlock` error | unspecified |
| Multipart child (E.4) | unspecified | allowed, default type |
| Embedded message (E.3) | `Opaque(NotAMessage)` | unspecified |

A top-level input that starts with a blank line (`\nSubject: hi\n\nbody`) is not
covered. CPython accepts it as an empty header block with everything else as
the body. B.1 read literally rejects it. The research survey says mail-parser
1.0 fails on "no header field *and* no blank line", which suggests it accepts
this input, so "this matches mail-parser 1.0" may be wrong. I did not verify
mail-parser.

**Problem 4: B.2 makes indentation decide success.** `  indented text\nmore`
parses successfully (a synthetic nameless field, then a body). `plain text\nmore`
fails with `NoHeaderBlock`.

**Recommendation.**

1. Write one table with a column per context (top level, multipart child,
   embedded) and a row per first-line class: valid field, continuation, empty
   line, colon-less, invalid name, delimiter line.
2. Define `NoHeaderBlock` by outcome, not by the first line: the header block
   contains zero valid fields and the input did not start with an empty line.
3. Give D.4 an explicit evaluation order and make the rows disjoint. Bound the
   RFC 7103 lookahead. My suggestion: a colon-less line is an anomalous header
   line only if the *next* non-continuation line is a valid field. Otherwise the
   body starts at it, as in Python. This keeps the common generator bug (a
   Subject that was not folded) working and stops body paragraphs being
   consumed.
4. State where a continuation line that follows an anomalous line attaches.
5. State that an ancestor delimiter line ends the header block before any of
   these rules apply (E.4 implies it, D.4 does not say it).

### F02: "Lossless spans" is not defined well enough to implement or test

**Sections:** C.1, C.2, E.4, K.3, L.

**Problem.** L requires "concatenating all spans reproduces the input". The
spans in C.1 are hierarchical (an entity contains fields, which contain name and
value spans), so "all spans" is not a sequence. Decoded embedded sources (C.2)
are not in the input at all. And E.4 assigns the line ending before a delimiter
to the delimiter, which breaks down when that line ending is already owned by
something else.

**Counterexamples.** With boundary `b`:

| Input | Which CRLF is in question | Competing owners |
|---|---|---|
| `--b\r\n--b--` | the one after the first `--b` | end of the first delimiter line / start of the close delimiter |
| `--b\r\nA: x\r\n\r\n--b--` | the empty line | header/body separator / start of the close delimiter |
| `A: multipart/…\r\n\r\n--b` | the empty line of the parent | parent's separator / first delimiter (no preamble) |
| `text\r\r\n--b` | CR, CRLF | body ends in CR / the delimiter takes CRLF only |

The second row is exactly the production failure "empty attachment dropped", so
it cannot be left to the implementation. RFC 2046 defines
`body-part := MIME-part-headers [CRLF *OCTET]` and
`delimiter := CRLF dash-boundary`, so strictly that part has headers and no
body at all, and the CRLF is the delimiter's. Common generators emit it meaning
"empty body".

**Recommendation.**

1. Define a flat *tiling*: an ordered list of leaf-level segments per source
   (BOM, envelope line, field, anomalous line, separator, preamble, delimiter,
   body, epilogue). The invariant is that segments are contiguous, start at 0
   and end at the source size. Expose it (or keep it internal) and property-test
   it on arbitrary bytes. Replace the L wording with this.
2. Give delimiter ownership an order: a line ending is owned by the first
   construct that ends with it (delimiter line, field, separator). The following
   delimiter takes the preceding line ending only when it is otherwise unowned
   body content.
3. State the outcome for both empty-part shapes above: a part is kept, with an
   empty body, in both.

### F03: M1 depends on header parsing that is scheduled for M2

**Sections:** A.4, E.1 to E.3, H.4, H.5, L.

**Problem.** The M1 tree builder needs `Content-Type` (type, subtype and the
`boundary` parameter with quoted strings and comments) and
`Content-Transfer-Encoding`. The parameter rules are in H, which is headed
"Structured headers (M2 and M3)". E.2 also relies on "syntactically invalid"
without defining it.

**Counterexamples that M1 has to decide.**

| Field | Question |
|---|---|
| `Content-Type: multipart/mixed; boundary="abc` | Invalid (so text/plain, exposing MIME framing as text), or multipart with boundary `abc`? |
| `Content-Type: text/html; charset` | Does a bad parameter invalidate the type? |
| `Content-Type: multipart/mixed; boundary=a; boundary=b` | Which boundary? Not in any table. |
| `Content-Type: multipart/mixed; boundary*0=ab; boundary*1=cd` | RFC 2231 is M2. Is this "missing boundary" in M1 and a different tree in M2? |
| `Content-Transfer-Encoding: base64 (comment)`, `"base64"`, `base64;` | E.1 says "trimmed". Is the comment, quote or semicolon stripped? |
| Two `Content-Type` fields, the first one garbage | D.7 says the first is used for structure. First, or first valid? |

**Recommendation.** Move a minimal `Content-Type` and CTE parser into M1 and
specify it next to E:

- Type and subtype are parsed independently of parameters. A parameter error
  never changes the type. "Invalid" means no `type/subtype` token pair.
- `boundary`: first occurrence wins, later ones record a diagnostic. Decide
  whether RFC 2231 continuations of `boundary` are honoured, and do it in M1 so
  the tree does not change between milestones.
- CTE: the value is the first RFC 2045 token after comments are skipped. Replace
  "and similar spellings" with a closed list.
- Decide "first" versus "first valid" for duplicate structural fields and add
  the row to D.7.

## Major findings

### F04: The diagnostics limit turns harmless mail into a parse error

**Sections:** B.3, B.4, B.6, F.

**Problem.** "Total diagnostics 10,000" is a limit, and limits fail by default.
A message with 10,001 trivial recoveries therefore returns
`Error(LimitExceeded(..))` and the caller gets nothing. Several diagnostics in F
are per occurrence (`LowercaseHex`, "8-bit or control bytes passed through"),
so one QP body written by a generator that emits `=c3=a9` reaches the limit
within a few kilobytes. It is also unclear how decode functions, which are
separate pure calls after `parse`, could share the parse budget at all.

**Problem.** Severity is not applied by its own definition. B.4 says `DataLoss`
means "bytes were dropped or could not be interpreted". These are all Warning:

- `Opaque(UnknownTransferEncoding)` and `Opaque(MissingBoundary)`: could not be
  interpreted.
- `InvalidBase64Characters(n)`: bytes dropped.

So `validate(message, at_least: DataLoss)` passes a message whose whole body is
opaque.

**Recommendation.**

1. Diagnostics never cause failure. On overflow, stop recording and add one
   `DiagnosticsTruncated` entry. Remove this item from the limits list.
2. High-frequency kinds are aggregated per decode call or per entity: a count
   plus the first span. Drop `LowercaseHex` entirely, since RFC 2045 already
   tells robust decoders to accept it.
3. Decode functions have their own cap and do not touch the parse budget.
4. Write the severity rule as a test (for example: output bytes differ from
   what a strict decoder would give, or content is unavailable, means
   `DataLoss`) and re-audit every row in E and F against it.

### F05: `Flatten` is undefined for most limits, and one limit fights D.4

**Section:** B.3, D.4.

**Problem.** "Turns the over-limit entity into an opaque leaf" only has a clear
meaning for depth.

| Limit | Which entity is "over the limit"? |
|---|---|
| Parts (10,000) | Part 10,001? Then parts 10,002 onward each need the same treatment and a diagnostic. |
| Header bytes | The entity whose header is too long. Does it keep any fields? |
| Header fields | Same question. |
| Diagnostics | There is no entity. |

B.3 also says all limits share one cumulative budget, yet two of them are
defined "per entity".

The 1 MiB header limit also collides with D.4 row 5 ("EOF with no empty line:
the whole input is the header block"). A 5 MB input with no empty line is then
a hard `LimitExceeded` instead of a recovery.

**Recommendation.** Add a table of limit by mode (fail, flatten). For parts,
follow mail-parser: the enclosing multipart stops splitting and the remainder
becomes one final opaque child. For header size, end the header block at the
limit and treat the rest as body, with a `DataLoss` diagnostic. Say which
limits are cumulative and which are per entity. Consider shipping M1 with
fail-only and adding `Flatten` once the table exists (see F14).

### F06: An unknown CTE on a multipart discards the whole tree

**Sections:** E.3 rows 1 and 3, C.4.

**Problem.** Row 1 (unknown CTE gives `Opaque`, "whatever the type") is
evaluated before row 3 (a non-identity CTE on a multipart is ignored). So
`base64` on a multipart is ignored and the parts are found, while a typo is
fatal:

```
Content-Type: multipart/mixed; boundary=X
Content-Transfer-Encoding: x-foo

--X

one
--X--
```

v2 gives `Opaque(UnknownTransferEncoding)` for the root. Every attachment
vanishes, which is the class of failure this project exists to remove.

**Evidence.** Both rules come from RFC 2045 §6.4: an unrecognised CTE "must be
treated as if it has a Content-Type of application/octet-stream", and a
multipart "is not permitted to have any value other than 7bit, 8bit or binary".
A multipart cannot legitimately carry any encoding, so an unknown label there
is as meaningless as `base64`. CPython on the input above records
`InvalidMultipartContentTransferEncodingDefect` and returns the one part.

**Recommendation.** For `multipart/*`, ignore every non-identity CTE, known or
unknown, with `EncodedMultipart`. Keep the opaque rule for leaves and
`message/*`. This reverses part of the first review's B03 advice, on the
evidence above.

**Related ADT problem.** `Opaque` merges three unrelated situations: a leaf
whose encoding is unknown, a container whose framing is broken, and a
truncation. A consumer that lists attachments by walking to `Leaf` nodes will
skip an `application/pdf` part with `x-uuencode`, although its headers,
filename and raw bytes are all intact. Recommend that an unknown CTE stays a
`Leaf` whose decode function returns the raw bytes with a diagnostic, and that
`Opaque` is kept for structural failure. Whatever the shape, state that raw
bytes are reachable for every `Body` variant.

### F07: Decoded embedded messages must not see the outer boundary stack

**Sections:** E.3, E.4, C.2.

**Problem.** E.4 says ancestor delimiters are honoured "inside child headers
and inside embedded messages". That is right for an identity-encoded embedded
message, whose bytes are part of the outer body. It is wrong for one that was
base64 or QP decoded: its extent is fixed by the outer part, and a line
`--outer` inside the decoded bytes is ordinary content. Closing "every
intermediate multipart" there would close entities that live in a different
source.

**Counterexample.** An outer multipart with boundary `X` has a child
`message/rfc822` with `Content-Transfer-Encoding: base64`. The decoded message
contains a text line `--X--`. With the stack carried over, the decoded message
is cut short and the outer multipart is "closed" from inside a decoded buffer.

**Recommendation.** State that the boundary stack is reset at every decoded
source.

**Simplification worth considering.** Multiple sources (C.2) add a source
identifier to every span, a second coordinate space to diagnostics and paths,
and eager decoding inside `parse`. The case is rare, and RFC 2046 §5.2.1
forbids it for message/rfc822 ("No encoding other than 7bit, 8bit, or binary is
permitted"). The alternative: `Embedded` only for identity CTE. An encoded
message part is a `Leaf` with a diagnostic, and a helper
`parse_embedded(entity, options)` returns a new `Message` with its own single
source. Every `Message` then has exactly one source and `Span` loses a field.

### F08: Delimiter matching has inputs that fall through

**Section:** E.4, E.3 row 4.

| Input (boundary `b`) | Gap |
|---|---|
| `--b--junk` | Close followed by other text. The three-way split in E.4 allows `--` then LWSP, or LWSP, or other text. Is this a close with trailing text or an open with trailing text `--junk`? The answer changes whether more parts follow. |
| `pre\r\n--b--\r\nepi` (close, no open) | "Start delimiter never appears" gives `Opaque`. But a delimiter did appear. Zero-part multipart, or opaque? CPython reports `StartBoundaryNotFoundDefect` and treats the body as non-multipart. |
| Only `--bjunk` lines exist | Does a trailing-text match count as the start delimiter? |
| Inner `b`, outer `b--` | A line `--b--` is an exact inner close and an exact outer open. "Innermost first" decides it, but the rule should say that ties between exact matches go to the innermost. |
| `boundary="b "` (trailing space) | The comparison value is not defined. RFC 2046 forbids a trailing space in a boundary. Trim, or opaque? |

**Trailing text is a real differential.** RFC 2046 §5.1.1 does support prefix
comparison ("An exact match of the entire candidate line is not required").
CPython does not implement it. For this input it returns one part whose body is
`one\n--Xfoo\n\ntwo`, where v2 returns two parts:

```
Content-Type: multipart/mixed; boundary=X

--X

one
--Xfoo

two
--X--
```

A scanner on one side and a viewer on the other will disagree about what the
attachments are. `DelimiterTrailingText` is a Warning, which is right. I would
add that a child `Opaque(MissingBoundary)` whose bytes contain `--X_inner`
lines is split by the outer boundary `X` under this rule, and that this is a
second reason the Warning must be visible to `validate`.

**Recommendation.** Add the rows above to E.4. Define the candidate grammar as
an ordered check: `--` boundary `--` then LWSP then end of line is a close.
`--` boundary then LWSP then end of line is an open. Anything else is trailing
text, classified as an open, with the full line kept in the diagnostic.

### F09: The base64 table lists triggers without states

**Section:** F (base64).

**Problem.** The rows are keyed on "position in the quantum", but padding
changes what position means, and the table does not say how. The fully valid
input `QQ==` matches two rows:

1. First `=` after 2 symbols: "padding; the quantum ends".
2. Second `=` is now at position 0 of a new quantum: "skipped,
   `InvalidBase64Padding` (Warning)".

So correct padding produces a Warning. The same applies to `QUI=` followed by a
stray `=`, and to `QQ=` (one `=` where two are expected), which is not listed.

A second gap: text after the padding is common in real mail, because list
software appends footers to base64 bodies.

```
SGVsbG8=
--
Sent via the example list
```

Under "decoding continues with a new quantum", the letters of the footer are
alphabet bytes and are decoded into garbage that is appended to the attachment.
The Warning is correct, but the caller has no way to cut the output at the
right place.

**Recommendation.** Specify a state machine. The states are: 0, 1, 2 or 3
symbols held; one more `=` expected; padded. Give one outcome per state and
input class (alphabet, `=`, whitespace, other, EOF), so every cell is filled
exactly once. Make `Base64DataAfterPadding` carry the decoded length at the
first padding, so a caller can truncate there.

### F10: The performance plan does not name the JavaScript traps

**Sections:** J.1, J.2, A.3, C.3.

J.1 says "cursors, spans, reverse accumulators and byte builders". The idioms
that satisfy that sentence behave very differently on the two targets. Measured
with the installed toolchain (16 MB input unless noted):

| Idiom | Erlang | JavaScript |
|---|---|---|
| Self-recursive `<<c, rest:bytes>>` scan | 0.19 s | 0.92 s |
| Index by offset with `bit_array.slice(src, i, 1)` | 0.89 s | 4.5 s |
| Accumulate 3-byte chunks in a list, then `bit_array.concat` | 2.8 s | 6.5 s |
| Append to a binary accumulator, `<<acc:bits, x>>`, 400 KB | 8 ms | 11.8 s |
| Two mutually tail-recursive functions, 4 MB | 17 ms | `RangeError: Maximum call stack size exceeded` |

What follows from this:

1. **Accumulator append is quadratic on JS.** Doubling the input from 200 KB to
   400 KB took 3.0 s to 11.8 s. On Erlang it is the fastest way to build output.
   A base64 decoder written the natural Erlang way will fail J.2 on JS. A
   decoder written with small list chunks is linear on both but slow on Erlang.
   Recommendation: accumulate into a small bounded binary (one encoded line,
   under about 100 bytes), push it onto a list, and concatenate once at the end.
   Add a doubling test for each decoder on JS specifically.
2. **Only self-recursion is turned into a loop on JS.** The compiled
   `count_lf` is a `while (true)` loop. A scanner written as mutually recursive
   states (`in_name` calls `in_value` calls `in_fold`) overflows the stack on
   any multi-megabyte input. Rule: every loop over input bytes or lines is a
   single self-recursive function with the state as an argument. No body
   recursion over lists that can reach the part or field limits.
3. **Each matched byte allocates on JS.** `<<c, rest:bytes>>` compiles to
   `bitArraySlice(b, 8)`, a new object per byte. It is linear, about 5 times
   slower than Erlang. Where possible, scan by line and match several bytes per
   step.
4. **Do not index by offset.** "Cursors" should mean carrying `rest` and an
   integer position together, never `bit_array.slice` in an inner loop. It is
   about 5 times slower on both targets.
5. **Every body byte is visited in Gleam.** With no FFI there is no
   `binary:match`. The boundary scan and the decoder each walk the body once.
   That is acceptable at the rates above. State it in J so nobody expects
   memchr speeds.
6. **QP trailing whitespace.** "SP/TAB just before a line ending is removed"
   needs lookahead. Rescanning ahead from each space is quadratic on a line of a
   megabyte of spaces. Hold pending whitespace in a counter and flush it when a
   non-space byte arrives. Add this input to J.2.

**On C.3 (detach).** A pure helper is feasible but has a trap. On OTP 28,
`list_to_bitstring([Slice])` returned a binary that still referenced the full
1 MB parent. Concatenating with a second element, or rebuilding with
`<<slice:bits>>`, produced an independent copy. If `detach` is added, test it
with a size assertion in test-only FFI.

### F11: The API is not yet shaped for an Elixir caller

**Sections:** A.7, B.1, B.3, B.4, C.1, C.4, G.3.

What works well from Elixir: `:eml.parse(bin)` returns `{:ok, msg}`,
`{:error, :empty_input}` or `{:error, {:limit_exceeded, limit}}`. Variants
without fields are atoms, and labelled arguments are positional.

Problems:

1. **`Options` as a record is brittle.** A Gleam record is a positional tagged
   tuple, `{:options, 64, 10000, …}`. Every added field changes the arity and
   breaks each Elixir caller that builds or matches it. B.1 also shows `parse`
   with one argument, with no way to pass options. Recommendation: an opaque
   `Options` built with `default_options()` and `with_max_depth(options, n)`
   style setters, plus `parse_with(input, options)`. From Elixir that reads
   `:eml.default_options() |> :eml.with_on_limit(:flatten)`.
2. **Closures and `Message`.** The caller's charset decoder (G.3) is a
   function. If `Options` is stored inside `Message` so that decode functions
   can find it, C.5 is violated and the message can no longer be compared,
   snapshotted or safely serialised. State that decode-time options are passed
   to the decode call and never stored.
3. **A `Span` is useless without the message.** Matching
   `{:multipart, preamble, parts, epilogue}` yields integers. State the
   accessor that turns a span into bytes. Prefer that each `Entity` carries a
   reference to its source, which costs one pointer on both targets, so
   `raw_body(entity)` and `decode_body(entity)` need no second argument.
4. **Inspecting.** If entities carry the source, `IO.inspect(msg)`, `echo` and
   equality in tests all involve the full input. Document it and provide a
   `summary` function for logging.
5. **Part paths.** B.4 uses `List(Int)`. Define the index for the single child
   of `Embedded`, and provide `part_at(message, path)`.
6. **Record headers.** Gleam generated `include/<module>_<Record>.hrl` for each
   public record in my test build (`probe_Span.hrl`, `probe_Options.hrl`). Leaf
   can use these with `Record.extract` instead of matching tuples by position.
   Worth a line in the README.
7. **Build integration.** The gleam_stdlib Hex package contains compiled
   `.erl` files and an `.app.src`, so a published eml should build under Mix
   without the Gleam compiler. Before publication (a git or path dependency)
   that is not the case. I did not test a Mix build end to end. Add an interop
   smoke test to L (see F14).

### F12: `validate` and `decode_all` give a false sense of completeness

**Sections:** B.5, B.6, C.5.

**Problem.** `validate(message, at_least:)` can only see diagnostics that exist
in the `Message`. Decode diagnostics are returned by decode calls (B.6) and are
not stored, because there are no caches (C.5). So `validate` returns `Ok` for a
message whose only attachment has `InvalidBase64Length` (DataLoss).

`decode_all(message)` "produces the complete report", which means it decodes
every body, discards the bytes and returns diagnostics. A caller who wants both
the report and the content pays for every decode twice.

**Recommendation.** Either name the function for what it checks
(`validate_structure`) and document the gap, or make `decode_all` return a
materialised value (decoded leaves plus all diagnostics) that `validate` can
accept. For M1, I would ship neither (F14).

## Minor findings

### F13: Smaller gaps in the tables

- **B.1, non-octet input.** The first review raised this and v2 does not answer
  it. A `BitArray` can hold a partial trailing byte. In my test a byte-matching
  scan of `<<1:3>>` hit the catch-all and returned as if the input were empty.
  Add `ParseError` variant `NotByteAligned`, or document truncation with a
  diagnostic.
- **D.1, lone CR.** RFC 7103 §6 supports the decision ("treat an isolated CR or
  LF as equivalent to a CRLF"). Two consequences need tests and a sentence
  each. `Subject: a\r\r\nTo: b` has an empty line after the first field, so the
  header block ends there. And `Subject: a\rX-Injected: b` is two fields here
  and one field in any parser that splits on LF only.
- **D.3, whitespace-only separator.** A generator that emits ` \r\n` as the
  separator sends the body into the header rules, and with F01 unresolved the
  first paragraph is swallowed. RFC 7103 §7.3 backs the decision. Add the test.
- **E.1.** "Absent" should also cover an empty value.
- **E.3.** `message/rfc822` with `Content-Disposition: attachment` is still
  `Embedded`. State that the raw bytes of the embedded message are available,
  since saving it as a `.eml` is the usual need.
- **F, quoted-printable.** Missing rows: literal whitespace at EOF with no line
  ending, and `=A` at EOF (one hex digit). Say whether "kept literally"
  re-scans the bytes after the `=`.
- **G.1.** The first two bullets disagree for `us-ascii` with 8-bit bytes
  `C3 A9`: bullet 1 gives windows-1252 (`Ã©`), bullet 2 gives UTF-8 (`é`).
  State that bullet 2 takes precedence for `us-ascii`. Also missing: what a
  declared `utf-8` with invalid sequences produces (replacement characters, or
  a fallback), and what "decoded strictly" yields for bytes that are unmapped
  in a WHATWG index. `bit_array.to_string` is all or nothing, so a lossy UTF-8
  decoder has to be written by hand. These are M2, but they belong in the
  record.
- **Header value type.** M1 ships "lossless headers" and M2 adds decoding. Fix
  the M1 accessor as raw unfolded bytes (`BitArray`) and add text accessors
  under new names in M2, so M2 is additive.

### F14: M1 scope and exit criteria

**Section:** L, A.4.

M1 as written is achievable, but several criteria cannot be tested as stated,
and some v2 features are not needed to meet them.

**Criteria to fix.**

- "Concatenating all spans reproduces the input": replace with the tiling
  invariant in F02.
- "Ported gen_smtp fixtures (27)": their expectations are Erlang assertions on
  decoded subjects and charset-converted bodies, which are M2. Say what M1
  asserts: part count, declared types, transfer encodings and digests of decoded
  bytes. The same applies to mime4j, whose expected output is XML.
- K.7 says gen_smtp is not used in this repo. L vendors its fixtures. Both can
  be true (fixtures are data, under BSD-2), but say so.
- "8-bit body bytes survive" is a byte-level test in M1, since charsets are M2.
  Word it that way.

**Criteria to add.**

- A never-crash property test on arbitrary bytes and on the structured
  generator, on both targets.
- One doubling test per hot loop on JS: line scan, base64, QP (F10).
- A smoke test from Elixir: a small Mix project, or a script in leaf, that
  calls `parse` and walks the tree through the chosen integration path.
- A test per limit, in each mode that ships.
- The header-block table (F01), case by case, like the one for E.

**What I would cut from M1.**

- `on_limit: Flatten` (ship fail-only until F05 is specified).
- `validate` and `decode_all` (F12).
- Decoding of encoded embedded messages, and with it multi-source spans (F07).
- The mbox `From ` line and BOM handling can stay. They are small, and leaf's
  files may have them.

**A caution about the milestone split.** M1 cannot replace `mimemail` in leaf:
there is no decoded Subject, filename or text body until M2. That is a decided
split and I am not disputing it. It does mean the first comparison against real
production mail happens late. A differential run of the M1 tree (part counts,
types, attachment digests) from leaf's side, against leaf's private fixtures,
would bring that forward at no cost to this repository.

## Nits

- **Toolchain.** `research.md` says OTP 29. `flake.nix` pins `erlang_28` and
  the dev shell runs OTP 28. Pin one and record it.
- **Version.** `gleam.toml` says 1.0.0, while B.4 accepts that each new
  diagnostic kind is a breaking change. Publish as 0.x until M3.
- **E.3, 200 bytes.** RFC 2046 allows 70 characters. 200 is a fine leniency
  bound. Say that it is deliberate and that it is what bounds J.1.
- **B.1.** "This matches mail-parser 1.0 and MimeKit 5" is asserted, not
  tested, and the survey's own wording for mail-parser differs (see F01).
- **D.5.** Folding case with a general lowercase function is correct for valid
  names (they are ASCII) but slow on Erlang. Compare bytes with an ASCII fold.
