# eml: decisions and specification (v3)

Status: v3, 2026-11-12. This version incorporates the second-pass reviews
[v2-review-pi](reviews/2026-11-12-v2-review-pi.md) (V2-…) and
[v2-review-fable](reviews/2026-11-12-v2-review-fable.md) (F…), and the
owner's follow-up decisions. Earlier inputs:
[first review](reviews/2026-11-12-adversarial-review.md),
[error-model and charset survey](research-error-model-and-charsets.md),
[research](research.md).

Tags:

- **[decided]**: confirmed by the project owner
- **[adopted]**: taken from a review or survey; challenge it if needed
- **[assumed]**: still a working assumption
- **[M2]/[M3]**: specified here, implemented in a later milestone

Sections D, E and F are written as an executable specification. Where two
rules could apply to the same input, the order is stated explicitly.

---

## A. Scope and constraints

1. **[decided]** The library is pure Gleam. There are no dependencies on
   iconv, gen_smtp, NIFs or Elixir packages.
2. **[adopted]** eml has no `@external` of its own. It does rely on
   gleam_stdlib, whose functions are target-specific internally. Test tooling
   may use FFI.
3. **[adopted]** Erlang is the primary target. JavaScript is a conformance
   target: every test runs on both targets from milestone 1 onwards.
4. **[decided]** The work is split into milestones:
   - **M1:** framing, lossless headers, a minimal Content-Type/CTE parser, the
     MIME tree, and identity/base64/QP decoding (§L).
   - **M2:** unstructured header text (RFC 2047), filenames (RFC 2231), charset
     decoding, the address view, and body/attachment roles.
   - **M3:** dates, message IDs, format=flowed, more charsets, `Flatten`
     limits, and coverage-guided fuzzing.
5. **[adopted]** The library only parses. There is no renderer, and it makes
   no DKIM or re-serialisation promise. Encoders exist only in tests.
6. **[assumed]** The input is one message (a `.eml` file). Splitting mbox
   files and SMTP dot-unstuffing are out of scope.
7. **[decided]** The version is 0.x until M3, because every new diagnostic
   kind is a breaking change.
8. **[adopted]** Toolchain: Gleam 1.19.2. The dev shell uses OTP 28, the
   newest in nixos-unstable. CI runs OTP 28 and 29 and Node 24.

## B. Entry point, errors, options

1. **[decided]** The entry points are
   `parse(input) -> Result(Message, ParseError)` and
   `parse_with(input, options)`. The error type:

   ```gleam
   pub type ParseError {
     NotByteAligned        // bit_size(input) % 8 != 0
     EmptyInput            // after the BOM: zero bytes, or only SP/TAB/CR/LF
     NoHeaderBlock         // the root header block contains no valid field (§D.3)
     LimitExceeded(Limit)
   }
   ```

   The checks run in the order listed. Everything else parses successfully
   and is reported through diagnostics.
2. **[adopted]** (F11, V2-m2) `Options` is opaque. It is built with
   `default_options()` plus `with_*` setters, which clamp values to a valid
   range (documented), so `parse` never sees an invalid configuration.
   Options are never stored inside a `Message`.
3. **[decided]** In M1, limits only fail. `on_limit: Flatten` moves to M3,
   once a per-limit action matrix exists (F05, V2-B1).

   | Limit | Unit | Scope | Default |
   |---|---|---|---|
   | `max_depth` | Multipart/Embedded nesting along one path; the root is depth 0 | per path | 64 |
   | `max_parts` | entities created | whole parse | 10,000 |
   | `max_header_bytes` | bytes in one entity's header block | per entity | 1 MiB |
   | `max_header_lines` | field, anomaly and continuation lines in one header block | per entity | 10,000 |

   Grammar-level bounds are not errors. Comments nested deeper than 32 in a
   structured field extend to the end of the field.
4. **[adopted]** (F04) Diagnostics never cause failure. `parse` records at
   most `max_diagnostics` (default 1,000) and then appends one
   `DiagnosticsTruncated`. High-frequency kinds are aggregated: one diagnostic
   per entity or decode call, holding a count and the first span.
5. **[adopted]** (F04, V2-M6) A diagnostic has the shape
   `Diagnostic(kind, severity, path: List(Int), span: Option(Span))`.
   Severity is assigned by this rule:
   - **Info:** a nonconformance that does not change the interpreted result.
   - **Warning:** a recovery was applied. No input bytes were dropped, but
     another conforming parser may interpret the input differently.
   - **DataLoss:** input bytes are not represented in the interpreted result,
     or some content cannot be interpreted as declared (opaque bodies, unknown
     CTE). Its raw bytes are still reachable.

   Every row in §D–§F gives its severity under this rule.
6. **[adopted]** (F12, V2-M6) M1 ships no `validate` and no `decode_all`.
   They come back in M2 with a materialised report type.

## C. Data model

1. **[adopted]** (V2-M10, F02) Each `Message` has exactly **one source**, the
   input `BitArray`. The source is tiled by an ordered list of non-overlapping
   **segments** that run from offset 0 to the source size. The segment kinds
   are `Bom`, `Envelope`, `Field`, `Anomaly`, `Separator`, `Preamble`,
   `Delimiter`, `Body`, and `Epilogue`. Spans are half-open `[start, end)`,
   and zero-length segments are omitted. Other spans (an entity's extent, a
   field's name and value) are *reference spans* that must lie inside the
   source; they are not part of the tiling.
2. **[decided]** (F07, V2-B3) `Embedded` is only produced for identity-encoded
   `message/rfc822|global`. A base64 or QP message part becomes a `Leaf` with
   an `EncodedMessage` diagnostic, and `parse_embedded(entity, options)`
   returns a separate `Message` with its own source. Boundary stacks therefore
   never cross sources.
3. **[adopted]** (F11) Entities are opaque. Each one holds a reference to the
   source, so `raw_body(entity)` and `decode_body(entity)` need no second
   argument. A small slice keeps the whole input alive, and that is
   documented. `Body` is public, for pattern matching:

   ```gleam
   pub type Body {
     Leaf
     Multipart(boundary: BitArray, preamble: Span, parts: List(Entity), epilogue: Span)
     Embedded(Entity)
     Opaque(reason: OpaqueReason)   // NoBoundary | BadBoundary | NoStartDelimiter | NotMessage
   }
   ```

   `Leaf` covers every non-structural body, including one with an unknown
   CTE. Raw bytes are reachable for every variant (F06).
4. **[adopted]** (V2-M7) Each entity records its *effective* interpretation:
   - the content type (the RFC default, or the parsed value);
   - the transfer encoding (`multipart` always records `Identity`);
   - the boundary;
   - which header occurrence and parameter supplied each of these.

   Every accessor and decoder uses these recorded values and never
   recomputes them from the headers.
5. **[adopted]** Part paths: the root is `[]`. The children of a `Multipart`
   are numbered 0 to n−1. The child of an `Embedded` is `0`. `part_at(message,
   path)` returns the entity at that path.
6. **[adopted]** (F13) In M1, header values are exposed as raw bytes
   (`BitArray`), and unfolding is a separate accessor. M2 adds text accessors
   under new names, so the change is additive. Field names are a `String`;
   they are guaranteed ASCII by §D.1.

## D. Framing and header blocks

1. **Lines.** A line is its content plus a terminator: CRLF (matched first),
   LF, CR, or none at EOF. So `\r\r\n` is a CR-terminated line followed by
   an empty CRLF line. Classes, tested in this order:
   1. *Delimiter*: only inside a multipart (§E.4).
   2. *Empty*: zero-length content, with a terminator.
   3. *Continuation*: starts with SP or TAB. This includes lines containing
      only whitespace.
   4. *Field*: one or more ftext bytes (`%d33-57 / %d59-126`), then any
      SP/TAB, then `:`.
   5. *Other*: anything else.

2. **Root prefix.**
   - A UTF-8 BOM (`EF BB BF`) at offset 0 becomes a `Bom` segment and records
     `ByteOrderMark` (Info).
   - Next, if the remaining input starts with `From ` and the line *after*
     that line is a Field, the line becomes an `Envelope` segment. It is not
     unescaped.
   - `EmptyInput` is checked after the BOM and before the envelope check.
   - None of this applies inside multipart children or embedded messages.

3. **Header block algorithm.** The same algorithm runs in every context:
   - At each step, look at the next line:

     | Line | Action |
     |---|---|
     | Delimiter | The header block ends with no separator. The entity ends at this line. `NoBlankLineAfterHeaders` (Info). |
     | Empty | Becomes the `Separator`. The body starts after it. |
     | Field | Starts a new field record. |
     | Continuation, with a previous record | Appended to that record, which may be an anomaly. |
     | Continuation, as the first line | Starts an anomaly record. `FirstLineIsContinuation` (Warning). |
     | Other | Look ahead past any Continuations to the next line. If that line is a Field, this line starts an anomaly record: `NonHeaderLine` (Warning). Otherwise the header block ends, and the body starts *at* this line: `MissingHeaderBodySeparator` (Warning). |
     | EOF | The header block ends and the body is empty. `NoBlankLineAfterHeaders` (Info). |

   - The look-ahead only crosses Continuation lines, and it stops at a
     delimiter. The lines it scans are either consumed by the anomaly record
     or scanned once more as body, so total work is at most twice linear.
   - Anomaly records are kept as their own `Anomaly` segments. They are never
     merged into a field value. This deliberately differs from RFC 7103 §7.2
     option 3, which appends the line to the previous field (V2-M1).
     - Example: `Content-Type: multipart/mixed;` followed by an unindented
       `boundary=b` and then `X: y` gives a Content-Type with no boundary,
       which becomes `Opaque(MissingBoundary)`, with the anomaly recorded.

   | Context | A header block with zero Field records | First line Empty |
   |---|---|---|
   | Root | `Error(NoHeaderBlock)` | `NoHeaderBlock` (no fields) |
   | Multipart child | Allowed; the default content type applies | Allowed: empty header block, as in RFC 2046 |
   | Embedded (identity `message/*`) | The parent body becomes `Opaque(NotAMessage)`, DataLoss | `Opaque(NotAMessage)` |

   Checked examples:

   | Input | Result |
   |---|---|
   | `garbage\nSubject: x\n\nbody` | One anomaly, then Subject; body `body`. |
   | `Subject: hi\nHello Bob,\nthis…\n\nSecond…` | Subject only. The body starts at `Hello Bob,`. |
   | `Subject: x\nhello world` | The body is `hello world`. |
   | `X : y\n\nz` | Field `X` (with whitespace before the colon), body `z`. |
   | `\tgarbage\n` | An anomaly only, so `NoHeaderBlock`. |
   | `\nbody`, `garbage\nmore` | `NoHeaderBlock`. |
   | `\xEF\xBB\xBF`, ` \n` | `EmptyInput`. |
   | `Subject: a\rX-Injected: b` | Two fields. This is a known differential against LF-only parsers. |

4. **[adopted]** Whitespace before the colon is part of the name span and is
   recorded as `SpaceBeforeColon` (Info). Names are compared by ASCII case
   folding, done byte by byte.
5. **[adopted]** Unfolding removes each line terminator that is followed by
   SP/TAB and keeps the whitespace. This fixes gen_smtp #122 and #317.
6. **[decided]** (B02) Duplicate fields are all kept. Singleton accessors
   return `Missing | Single(v) | Multiple(vs)`. For structure (Content-Type,
   CTE), the **first occurrence** is used even when it is invalid, so an
   invalid first occurrence falls back to the defaults. `DuplicateField`
   (Warning).

## E. MIME structure

1. **Content-Type lexing (M1).** RFC 2045 lexing is applied to the unfolded
   value:
   - Lexical units are tokens, quoted strings (with quoted-pairs), comments
     (nested, depth at most 32), tspecials, and whitespace.
   - **Type and subtype** are lowercased as ASCII. They are parsed
     independently of the parameters: a parameter error never invalidates the
     type. The type is *invalid* if there is no `token "/" token` pair, after
     skipping comments and whitespace. An invalid type means the defaults
     apply and `InvalidContentType` (Warning) is recorded.
   - **Parameters** are `;` attribute `=` value. The value is either a quoted
     string, or an unquoted run up to the next top-level `;` or `(`, with
     trailing whitespace trimmed. A `(` starts a comment, which is skipped,
     and a `;` inside a comment does not end the value.
     - Malformed parameters are skipped, with `InvalidParameter` (Warning).
     - Duplicate attribute names: the first wins, with `DuplicateParameter`
       (Warning).
     - Attribute names are lowercased as ASCII. Values are kept as raw bytes.
   - **Default content type.** An absent or empty Content-Type means
     `text/plain; charset=us-ascii`, except directly inside
     `multipart/digest`, where it means `message/rfc822`.
   - **boundary**:
     - It is taken only from a plain `boundary` parameter. RFC 2231 forms
       (`boundary*`, `boundary*0`) are ignored and recorded as
       `IgnoredExtendedBoundary` (Warning). This is permanent, so the tree
       does not change in M2.
     - Usability:
       - 1–70 bytes from the RFC 2046 bchars set, with no trailing space:
         valid.
       - Longer than 70 bytes, other bytes, or a trailing space: usable as
         is, recorded as `NonstandardBoundary` (Warning). There is no length
         cap (see §J.1); the header limits bound it.
       - Empty, or containing CR, LF or NUL: unusable.
     - The boundary is never normalised.

2. **CTE lexing (M1).**
   - Skip comments and whitespace, then take one token (a quoted string is
     also accepted, with `NonstandardTransferEncoding` (Info)). Lowercase it
     as ASCII.
   - Anything after the token other than comments or whitespace is recorded
     as `NonstandardTransferEncoding` (Info).
   - An absent or empty value means `7bit`.
   - Closed alias list:

     | Value | Interpreted as | Diagnostic |
     |---|---|---|
     | `7bit`, `8bit`, `binary` | identity (`SevenBit`, `EightBit`, `Binary`) | none |
     | `7-bit`, `8-bit`, `8bits`, `none` | identity | `NonstandardTransferEncoding` (Info) |
     | `base64`, `quoted-printable` | as named | none |
     | anything else (e.g. `x-uuencode`) | `Unknown(label)` | see below |

3. **Body classification.** Rules are tested in order and the first match is
   terminal. Diagnostics from every rule that applied are accumulated in
   order.

   | # | Condition | Body | Diagnostic |
   |---|---|---|---|
   | 1 | `multipart/*` with a non-identity CTE (known or unknown) | The CTE is ignored and the effective CTE is Identity. Continue with rows 2–4. | `EncodedMultipart` (Warning) |
   | 2 | `multipart/*` with no boundary, or an unusable one | `Opaque(MissingBoundary \| UnusableBoundary)` | DataLoss |
   | 3 | `multipart/*` and the scan (§E.4) finds no delimiter for this boundary before the entity ends | `Opaque(StartDelimiterNotFound)` | DataLoss |
   | 4 | `multipart/*` otherwise | `Multipart`. An unknown subtype is treated as mixed. | per §E.4 |
   | 5 | `message/rfc822` or `message/global` with an identity CTE | `Embedded`, parsed in the same source (embedded context, §D.3) | none, or `NotAMessage` (DataLoss) |
   | 6 | `message/rfc822` or `message/global` with base64/QP | `Leaf` | `EncodedMessage` (Warning; use `parse_embedded`) |
   | 7 | any type with an `Unknown` CTE (rows 1–4 have already handled multipart) | `Leaf` | `UnknownTransferEncoding` (DataLoss) |
   | 8 | anything else, including `message/partial`, `message/external-body` and other `message/*` | `Leaf`. There is no recursion, fetching or reassembly. | none |

   `LimitExceeded` raised while parsing a child propagates up as the result of
   `parse`.

4. **Multipart scanning.** This applies within one source, with a stack of
   open boundaries ordered innermost first.
   - **Candidate classification** of a line's content `L` against boundary
     `b`. It applies only if `L` starts with `--` followed by `b`. Let `r` be
     the rest of the line. The checks run in order:
     1. `r = "--" + LWSP*`: an exact Close.
     2. `r = LWSP*`: an exact Open.
     3. `r` starts with `--`: a Close with trailing text.
     4. Otherwise: an Open with trailing text.

     Both trailing-text cases record `DelimiterTrailingText` (Warning), which
     keeps the full line.
   - **Owner selection.**
     1. Pass 1 checks the stack from innermost to outermost for an exact match.
     2. If there is none, pass 2 does the same for a trailing-text match.

     The first match owns the line; ties go to the innermost boundary. A
     closed multipart is popped from the stack.
   - **Collisions.** When a multipart is opened whose boundary equals an open
     ancestor's boundary, or one is a prefix of the other,
     `BoundaryCollision` (Warning) is recorded. The rules above still decide
     each line deterministically. Examples:
     - outer `a`, inner `a--`, line `--a--`: an exact inner Open;
     - equal boundaries: the innermost owns the line.
   - **States of a multipart M.** These rows are disjoint.

     | State | A line owned by M | A line owned by an ancestor | Any other line | EOF |
     |---|---|---|---|---|
     | BeforeFirst | Open: start part 0, go to InPart. Close: zero parts, `CloseWithoutOpen` (Warning), go to AfterClose. | M ends. If no line was owned by M: rule 3 (`Opaque`). | preamble | rule 3 (`Opaque`) |
     | InPart (a child is being parsed; it stops at any line owned by M or an ancestor) | Open: next part. Close: go to AfterClose. | M ends: `MissingCloseDelimiter` (Warning) on M only | — (consumed by the child) | M ends: `MissingCloseDelimiter` (Warning) |
     | AfterClose (M has been popped) | (cannot occur) | M ends | epilogue. A line matching M's own boundary is plain epilogue. | M ends |

   - Leaves and embedded messages have no close delimiter of their own, so
     ending them never records `MissingCloseDelimiter`.
   - **Line-break ownership.**
     - A line terminator belongs to the line it ends.
     - A `Delimiter` segment starts at the `--`. It also takes the *preceding*
       line terminator when that terminator ended a Body, Preamble or
       Epilogue line.
     - A terminator that ended a Field, an Anomaly, a Separator or another
       Delimiter keeps it.
   - **Consequences**, all of which are tested:

     | Input (boundary `b`) | Result |
     |---|---|
     | `…\r\n\r\nhello\r\n--b` | The body is `hello`. |
     | `hello\r\n\r\n--b` | The body is `hello\r\n`. |
     | `text\r\r\n--b` | The body is `text\r`. |
     | `--b\r\n--b--` | One part with empty headers and an empty body. |
     | `--b\r\nA: x\r\n\r\n--b--` | One part with field A and an empty body, kept. This was the production failure "empty attachment dropped". |

## F. Transfer decoding

`decode_body(entity)` returns `#(BitArray, List(Diagnostic))`. It uses the
entity's effective CTE (§C.4). Diagnostics are aggregated per call, with a
count and the first offset. Identity encodings pass every byte through
unchanged. An `Unknown` CTE returns the raw bytes with
`UnknownTransferEncoding`.

1. **Base64: a state machine** (V2-B4, F09).
   - **States:** `Q0`–`Q3` (the number of symbols held), `P1` (one `=` seen,
     a second expected) and `Done` (padding complete).
   - **Input classes:**
     - `A`: alphabet `A–Z a–z 0–9 + /`
     - `=`: the padding character
     - `W`: SP, TAB, CR or LF
     - `X`: any other byte, including `-` and `_`
     - `EOF`
   - **Transitions:**

     | State | `A` | `=` | `W` | `X` | `EOF` |
     |---|---|---|---|---|---|
     | Q0 | →Q1 | `StrayPadding` (Warning), stay | stay | `InvalidBase64Characters` (Warning), stay | done |
     | Q1 | →Q2 | `StrayPadding` (Warning), stay | stay | invalid chars, stay | drop 1 symbol: `InvalidBase64Length` (DataLoss) |
     | Q2 | →Q3 | emit 1 byte, →P1 | stay | invalid chars, stay | emit 1 byte, `MissingBase64Padding` (Info) |
     | Q3 | emit 3 bytes, →Q0 | emit 2 bytes, →Done | stay | invalid chars, stay | emit 2 bytes, `MissingBase64Padding` (Info) |
     | P1 | `MissingBase64Padding` (Info) and `Base64DataAfterPadding`, then as Done+`A` | →Done | stay | invalid chars, stay | `MissingBase64Padding` (Info) |
     | Done | `Base64DataAfterPadding(decoded_length)` (Warning, first occurrence only), →Q1 | `ExcessBase64Padding` (Info) | stay | invalid chars, stay | done |

     Nonzero pad bits recorded at emit time give `NonZeroPadBits` (Info).
     `decoded_length` lets a caller truncate output that has a list footer
     appended.
   - **Vectors** (exact bytes and exact diagnostics):

     | Input | Bytes | Diagnostics |
     |---|---|---|
     | `QQ==` | `A` | none |
     | `QUI=` | `AB` | none |
     | `QUJD` | `ABC` | none |
     | `QQ=` | `A` | MissingBase64Padding |
     | `QQ` | `A` | MissingBase64Padding |
     | `QQ===` | `A` | ExcessBase64Padding |
     | `QQ\r\n==` | `A` | none |
     | `QQ==Qg==` | `AB` | Base64DataAfterPadding(1) |
     | `=QQ==` | `A` | StrayPadding |
     | `Q` | empty | InvalidBase64Length |
     | `QR==` | `A` | NonZeroPadBits |
     | `QU*JD` | `ABC` | InvalidBase64Characters(1) |

2. **Quoted-printable: a single pass** (V2-M5). The decoder keeps a
   pending-whitespace start offset, so whitespace is never rescanned (F10).

   | Input | Action |
   |---|---|
   | SP or TAB | Extend the pending whitespace run. |
   | a line break (CRLF, then LF, then CR) | Drop the pending whitespace (RFC 2045 rule 3) and emit the line break bytes unchanged. |
   | `=` HEX HEX (either case) | Flush pending whitespace and emit the byte. |
   | `=` SP/TAB* line break | Flush pending whitespace. Soft break: all of it is consumed. |
   | `=` SP/TAB* EOF | Flush pending whitespace and drop the rest. `TrailingSoftBreak` (Info). |
   | `=` anything else (`=G1`, `=A` + non-hex, `=A` EOF) | Flush pending whitespace. Emit `=` literally and continue scanning *at the byte after* `=`. `InvalidQuotedPrintable` (Warning). |
   | any other byte | Flush pending whitespace and emit the byte. Bytes ≥ 0x80 or control bytes (other than TAB, CR, LF): `UnencodedOctets` (Info). |
   | EOF | Drop the pending whitespace. |

   Vectors:

   | Input | Bytes |
   |---|---|
   | `hello` | `hello` |
   | `a\tb` | `a\tb` |
   | `a  \r\nb` | `a\r\nb` |
   | `a \t` (EOF) | `a` |
   | `a =\r\nb` | `a b` |
   | `a= \t\r\nb` | `ab` |
   | `=C3=a9` | `C3 A9` |
   | `=G1` | `=G1` (Warning) |
   | `=A` (EOF) | `=A` (Warning) |
   | `x=` | `x` (Info) |
   | `=\r\nX` | `X` |

3. **Header Q-encoding** is a separate algorithm (`_` means SP; there are no
   soft breaks). It belongs to [M2].

## G. Charsets [M2] (decided)

The rules are applied in this order (V2-M8):

1. **Caller decoder.** If one is supplied it is consulted first, for any
   label. Its result type is `Result(String, DecodeFailure)`, and its code is
   trusted.
2. **No label**, or **an ASCII-family label** (`us-ascii`, `ascii`,
   `ansi_x3.4-1968`, `iso646-us`, and the rest):
   - all bytes below 0x80: plain ASCII;
   - otherwise UTF-8 if the bytes are valid UTF-8, else windows-1252, with
     `NonAsciiInAscii` (Warning).
3. **Latin-1 family labels** (`iso-8859-1`, `latin1`, `l1`, `cp819`, and the
   rest): decoded as windows-1252. When 0x80–0x9F occur,
   `C1ReinterpretedAsWindows1252` (Info).
4. **Other WHATWG labels** (UTF-8, the single-byte encodings, and since M3
   the CJK encodings and UTF-16): WHATWG decoding in *replacement* mode, by
   the separate pure Gleam package `text_encoding`. A malformed sequence
   gives U+FFFD and `MalformedCharsetData` (Warning). A declared label is
   never overridden by UTF-8 sniffing, unless the caller enables
   `with_utf8_override`, which applies to every label but UTF-8 and UTF-16.
   For the multi-byte CJK charsets it needs a UTF-8 sequence of three or
   more bytes: about 14% of GB2312 characters are valid two-byte UTF-8 by
   chance, and encoded-words are short.
   - Labels are normalised as WHATWG does: ASCII whitespace trimmed, ASCII
     letters lowercased, nothing else changed.
   - Mail names for the CJK code pages that WHATWG does not list are
     accepted: `cp932`, `windows-932` (Shift_JIS); `cp936`, `windows-936`,
     `ms936`, `euc-cn` (GBK); `cp949`, `ms949`, `uhc`, `x-windows-949`
     (EUC-KR); `cp950`, `ms950`, `windows-950` (Big5); `eucjp`, `euc_jp`,
     `ujis` (EUC-JP). Every other ISO-2022 variant (any label starting
     `iso-2022-`, and `cp50220` to `cp50222`) is unsupported (rule 5): they
     are 7-bit, so the unknown-label rule would pass their escape sequences
     off as text.
   - UTF-8: one leading byte order mark is removed.
   - UTF-16 (M3): as WHATWG. A leading byte order mark decides the byte
     order (a UTF-8 one decides UTF-8) and is removed; without one, `utf-16`
     and its aliases (`ucs-2`, `unicode`, ...) are little-endian. Browsers,
     Thunderbird, .NET (`Encoding.Unicode`, which writes no mark), Python
     and glibc's iconv (and so gen_smtp) all decode it that way, although
     RFC 2781 §4.3 says big-endian. When the mark contradicts a label that
     names a byte order (`utf-16be`, `utf-16le`, ...), or is UTF-8's,
     `DeclaredCharsetOverridden` (Warning).
5. **Known but unsupported** (UTF-7, UTF-32, DOS and EBCDIC code pages): left
   undecoded, `UnsupportedCharset` (DataLoss).
6. **WHATWG "replacement" labels** (ISO-2022-KR, HZ-GB-2312, ISO-2022-CN,
   ...): left undecoded, `UnsupportedCharset` (DataLoss), unless a caller
   decoder succeeded in step 1. WHATWG decodes them to a single U+FFFD,
   which would silently lose the text.
7. **Unknown labels:** UTF-8 if valid, else windows-1252, with
   `UnknownCharset(label)` (Warning).

Two further rules apply:

- NUL is preserved as U+0000, with `NulInText` (Info) aggregated.
- Raw 8-bit bytes in headers: UTF-8 if valid, otherwise windows-1252, with
  `EightBitHeader` (Warning).

## H. Structured headers [M2/M3]

1. The parsers share low-level scanning, but each follows its own grammar.
   Structure is parsed from bytes first, and encoded-words are decoded only in
   display text.
2. Addresses:
   - `Group` members are always mailboxes.
   - A malformed address is kept as `Invalid(raw)`.
   - The local part and domain are never charset-guessed.
   - Local parts and message IDs are never lowercased.
3. Encoded-words are decoded independently. A split multibyte character is
   repaired only on failure, only for charsets whose bytes can be joined
   (not ISO-2022-JP, not UTF-16), and only within one run of adjacent words
   that share a charset (V2-m3). Test vector:
   `=?utf-8?B?ww==?= =?utf-8?B?qQ==?=` decodes to `é`. A run is a sequence
   of words whose labels name the same charset (`utf-8` and `utf8`, say).
   An ISO-2022-JP word that does not end in ASCII passes its shift state to
   the next word, unless that word begins with a recognised escape sequence
   or decodes cleanly only on its own; a UTF-16 word whose byte order mark
   differs from the label's byte order passes it to following words without
   one. Both are reported as `EncodedWordSplitCharacter`, and both apply
   only to the built-in decoders: a caller's decoder and the UTF-8 override
   see each word's own bytes. A UTF-16 code unit split between words is not
   repaired. Counts in diagnostics are added up within one decoded text (a
   header value, or one phrase of an address), and merging sorts rather
   than hashes, so chosen labels cannot make it quadratic.
4. RFC 2231 (V2-M9). Raw sections are kept, without enumerating their
   combinations. The result is one of `Resolved(value)`, `Ambiguous`,
   `Malformed` or `Unsupported`:
   - a gap or a duplicated section index: `Ambiguous`;
   - a malformed `%` escape: `Malformed`.

   The filename comes from the first of these that resolves:
   1. an extended `filename*`;
   2. a plain `filename`;
   3. Content-Type `name`;
   4. RFC 2047 decoding, applied once, as a last resort.
5. Dates keep their components, a validity flag and the raw text. Converting
   to a timestamp returns a `Result`.

## I. Helpers [M2]

1. `safe_filename` is a suggestion only:
   - Applied after all decoding, it removes `/`, `\`, `:` (including NTFS
     alternate data streams), drive and UNC prefixes, and control and bidi
     characters.
   - It rejects `.` and `..`, strips trailing dots and spaces, applies the
     Windows reserved-name check after normalising, and limits the length to
     255 bytes.
   - The fallback is `attachment`.

   Callers should generate their own storage names.
2. HTML is not sanitised. CID and Content-Location resolution return a part
   reference or `Missing | Ambiguous`, scoped to the selected MIME context.
3. Body and attachment roles follow an RFC 8621 §4.1.4-based algorithm that
   returns a role and a reason. It never descends into attached messages when
   choosing the parent's body.

## J. Performance

1. **[adopted]** The parser runs in O(input + output). Only lines starting
   with `--` are compared with boundaries, and a comparison stops at the
   shorter of the line and the boundary, so boundary checks cost at most
   depth × line length. A boundary's length does not need a cap (the mime4j
   fixtures include 701- and 7,001-byte boundaries). Every byte of the body
   is visited in Gleam; there is no `memchr`.
2. **[adopted]** (F10) These implementation rules come from measurements of
   Gleam 1.19 on Erlang and JS:
   - Every loop over bytes or lines is **one self-recursive function** with
     the state as arguments. There is no mutual recursion over input, because
     on JS only self-recursion becomes a loop. There is no body recursion over
     lists whose length can reach the part or line limits.
   - Do not index by `bit_array.slice(src, i, 1)` in inner loops. Carry `rest`
     and an integer position instead.
   - Never append to a growing binary accumulator, which is quadratic on JS.
     Emit bounded chunks (at most about 100 bytes) to a list, reverse it, and
     concatenate once at the end. Better still, emit spans of the source and
     slice once.
   - Scan by line where possible.
3. **[adopted]** Doubling tests run on both targets for: long lines, many
   folded lines, many header lines, boundary near-matches, base64, QP
   (including a megabyte of trailing spaces), and deep nesting. Each test
   pins an acceptable growth ratio.

## K. Testing

1. **[adopted]** Every vendored corpus needs an import manifest listing its
   URL, commit, files with hashes, licence text, modifications, and what is
   asserted. Vendored fixtures are data; gen_smtp code is not used (K.7).
   - Do not vendor: Hunnysoft, Crispin, jwz, Enron, SpamAssassin, or Dovecot
     files that are not MIT.
2. **[adopted]** Tests assert exact decoded bytes and exact diagnostics
   (kind, severity, count). Snapshots are an extra.
3. **[adopted]** Invariants, tested by properties:
   - The segment tiling covers the source exactly.
   - Reference spans lie within the source.
   - Each delimiter line has exactly one owner.
   - Empty parts are preserved.
   - Paths are deterministic.
   - Every identity byte 0–255 survives.
   - Limits are enforced at zero, at the limit, and at the limit plus one.
4. **[adopted]** Codecs are tested against independent known-answer vectors
   (RFC, Go, CPython, WPT), in addition to round trips.
5. **[adopted]** qcheck properties:
   - Parsing never crashes, on arbitrary bytes and on a structured generator.
   - The invariants in K.3 hold.
   - Varying the line-ending style only in framing regions does not change
     the structure.
6. **[adopted]** Fuzzing [M3]. Evaluate jazzer.js on the JS build first. The
   seeds are go-fuzz-corpus/mail (Apache-2.0).
7. **[decided]** gen_smtp is not used, even for differential testing. leaf's
   fixtures stay out of this repo. A differential run can be done from
   leaf's side.

## M2 status

Status (2026-11-12): M2 is implemented and has been through two code
reviews ([pi](reviews/2026-11-12-m2-code-review-pi.md),
[fable](reviews/2026-11-12-m2-code-review-fable.md)). Every confirmed
finding has a regression test that was seen failing first
(`test/eml/review_regression_test.gleam`, plus doubling tests in
`perf_test.gleam` for the hangs and quadratic cases). The suite (279 tests)
passes on Erlang/OTP 28 and Node 24, as does the Elixir smoke test.

| Spec | Implementation |
|---|---|
| §B.3 | Header limits count only the lines that join the header block (fields, anomalies, continuations). The separator and the line that starts the body do not count. |
| §B.4 | `DiagnosticsTruncated(worst)` carries the worst severity among the diagnostics dropped after `max_diagnostics`, and has that severity, so `validate` cannot pass a message because its problems were truncated. |
| §B.6 | `eml.diagnose` returns parse diagnostics, then those from Subject and the address fields of the message and each embedded message, and from each body and file name. `eml.validate(message, at_least)` filters them by severity. An unknown transfer encoding is reported once, by `parse`. |
| §E.1 | The parameter list keeps every occurrence; lookups take the first (`DuplicateParameter` is still reported). In an unquoted value, `(` starts a comment only when nothing but whitespace follows it before the next `;`. In a quoted value, `\` escapes only `"` and `\` (Windows paths). An invalid Content-Type inside `multipart/digest` falls back to `message/rfc822`. |
| §G | `eml/charset`. Decoding is done by `text_encoding` (M3; before that, by tables generated in eml from the same WHATWG commit, `be17ac5c49881336538acfc7b40dba3c8009144b`), and checked against Python's codecs (`charset_vectors_test.gleam`). The ASCII and Latin-1 families include IANA aliases (`iso646-us`, `latin-1`, ...). Known legacy charsets (UTF-7, UTF-32, DOS and EBCDIC code pages) are `UnsupportedCharset`, not guessed. A caller decoder is consulted only for a declared label; its type is `fn(String, BitArray) -> Result(String, Nil)`. One leading UTF-8 byte order mark is removed when text is decoded as UTF-8; elsewhere U+FEFF is kept, identically on both targets (`eml/internal/utf8`). NUL is counted in the decoded text. |
| §H.2 | `eml/address`: `Individual(Mailbox)`, `Group(name, members)`, `Invalid(raw)`. Local parts and domains must be `word ("." word)*` (comments and whitespace around dots allowed) without control characters; anything else is `Invalid`. `a@b <c@d>` is the mailbox `c@d` named `a@b`, with `InvalidAddress`. Groups are never parsed inside groups. Encoded-words are single tokens, so a comma inside one does not split a display name. `eml.from` returns `Multiple` for more than one From field. |
| §H.3 | `eml/encoded_word`; `eml.header_text`, `eml.subject`, and `_with` variants taking charset options. Charset and transfer recoveries are reported. Split-character repair only joins words in charsets eml decodes itself, except ISO-2022-JP and UTF-16. Only raw whitespace around the value is trimmed. |
| §H.4 | `eml/parameter`; `eml.disposition`, `eml.filename`, `eml.filename_with`. RFC 2047 decoding of a plain `filename` happens before falling back to Content-Type `name` (more useful than the order listed in §H.4). An empty name falls through. An unsupported charset is reported as `UnsupportedCharset`, not as a malformed parameter. |
| §I.1 | `eml/filename.safe` works on code points, and checks the final, truncated result. It also removes zero-width characters, U+2028, U+2029 and U+FEFF, and reserves `COM0`, `LPT0`, `COM¹²³`, `LPT¹²³`, `CONIN$` and `CONOUT$`. |
| §I.3 | `eml.bodies`: RFC 8621 §4.1.4 `parseStructure`, unchanged. A multipart whose body is opaque is an attachment. |
| §J | Rules learned in review: on JavaScript, `==` on lists walks the whole tail, so lists are compared by their first element's offset; on Erlang, gleam_stdlib's `string.trim` is slow when called many times on a large heap, so whitespace is trimmed on bytes (`structured.trim`). Failed searches for a closing `?=`, quote or comment are not repeated over the same suffix. |

## M3 status

Charsets moved to the separate package `text_encoding` (pure Gleam, both
targets), which implements the decoders of the whole WHATWG Encoding
Standard, tested with web-platform-tests vectors and differential sweeps
against encoding_rs. eml now decodes GBK/gb18030, Big5, EUC-JP, ISO-2022-JP,
Shift_JIS, EUC-KR and UTF-16 itself; the policy in §G is unchanged
otherwise, with these additions:

- §G.4: UTF-16 follows WHATWG: a byte order mark decides, otherwise
  little-endian. Mail aliases for the CJK code pages are accepted.
- §G.6: "replacement" labels stay unsupported rather than becoming U+FFFD.
- §H.3: split-character repair joins encoded-words in every built-in
  charset except ISO-2022-JP, UTF-16 and "replacement". A Shift_JIS or GBK
  double-byte character split between words is the case the repair exists
  for. ISO-2022-JP words pass on their shift state instead.
- The gen_smtp fixtures `chinesemail` and `shift-jismail` are now decoded,
  and compared with text decoded independently by
  `dev/cjk_expectations.py`.

## L. M1 checklist

Status (2026-11-12): every gate below has tests, and the suite (149 tests)
passes on Erlang/OTP 28 and Node 24. The corpora results are in the manifests
under `test/fixtures/`: all 31 gen_smtp messages, and 72 of 80 mime4j
messages identical to mime4j, with 8 deliberate deviations.

| Gate | Requirement |
|---|---|
| API | `parse`, `parse_with`, `Options` builders, `ParseError` (4 variants), opaque `Message` and `Entity` with accessors, `Body`, `segments`, `part_at`, `raw_body`, `decode_body`, `parse_embedded`. |
| Admission and framing | Every example in §D.3. CRLF, LF, CR and mixed framing. BOM and envelope. |
| MIME composition | Each row of §E.3, combined with each CTE class and with absent, invalid and duplicate Content-Type. |
| Boundary lifecycle | Each cell of the §E.4 state table: collisions in both prefix directions, close without open, an ancestor terminating a part inside child headers, an empty child, no spurious part after the close delimiter. |
| Line-break ownership | The §E.4 consequences table. |
| Codecs | Every vector in §F, checking exact bytes and diagnostics. |
| Limits | Each limit at zero, at the limit, and at the limit plus one. Diagnostics truncation. |
| Preservation | The tiling property on arbitrary bytes. Identity bytes 0–255. |
| Portability | The same results on Erlang and JS for the whole suite. |
| Complexity | The §J.3 doubling tests on both targets. |
| Production regressions (byte-level) | 8-bit body bytes survive; LF-only messages parse; an empty attachment is kept; missing or broken boundaries do not crash; unfolding keeps whitespace. Subject and charset regressions are deferred to M2. |
| Corpora | gen_smtp's 27 fixtures and the mime4j structural cases, with a manifest. M1 asserts part count, effective types and CTEs, and digests of the decoded bytes. Assertions that belong to M2 are listed as deferred. |
| Never-crash | qcheck on arbitrary and structured input, on both targets. |
| Elixir smoke test | An Elixir script (`test/elixir_smoke/smoke.exs`, run in CI) that loads the compiled modules, calls `parse` and walks the tree. |
