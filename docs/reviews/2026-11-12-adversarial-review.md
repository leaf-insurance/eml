# Adversarial pre-implementation review

Date: 2026-11-12. Reviewed `docs/research.md` and `docs/assumptions.md`.

**Verdict:** the pure-Gleam constraint is reasonable. The dangerous part is not the absence of iconv; it is treating lossy recovery, ambiguous structure, and incomplete parsing as ordinary successful data. Settle the four blockers before freezing the public types. Do not build a full mail client or a fuzzing framework first.

Assumption references below use section/item IDs, such as **E.3**. Research references identify sections. “Blocker” means a contract/design decision needed before implementation, not an assertion that an unimplemented library already has an exploitable vulnerability.

## Verification method and limits

I fetched primary RFC texts from rfc-editor.org, the WHATWG standard and repository license, HexDocs, GitHub repository trees and license/provenance files, and the gen_smtp 1.3.0 source. I also exercised the already-built gleam_stdlib 1.0.5 base64 decoder on the installed OTP 29. No implementation or corpus was added to this repository.

Repository inspections were pinned to these observed revisions: Stalwart `a56d5f1dc0050a9de123df926081e436334ba9e5`; gen_smtp 1.3.0 `68ab11101a0710a13d39d73ff780dc9d76ffa15f`; mime4j `a3a9ec2e578e5fd05bf4bbb58e904237f09e9cb5`; CPython `9f386367333f7845095d764fad3ad9b397d04672`; MimeKit `d3884a84ef98fa203d7ffd29f0c90ce16ec7e713`; Go `f37eedeb17ddc24aeeb66e69b9f94a99d23d5504`; enmime `4e8e7f28b7b63e7367a1c39bf9ccc5f6a3be2255`; postal-mime `5828feb9a79e48f8d64bfd0b9ef71c7f607bfb5d`; mailparser `eaffc16edb4826555327a976b9a631f185c848bd`. Some explanatory links below use branch names for readability; imports must use immutable revisions.

Private leaf fixtures, the Tryg example, and the fork's typespec fix were not available for independent verification. I did not run Thunderbird/MimeKit/Python against a shared differential corpus. Their supposed agreement must not be treated as verified. License observations are a provenance review, not legal advice or clearance of every embedded message/attachment.

## Blockers

### B01 — The totality and limit contracts contradict each other

**Claims:** B.1–B.2, E.7, G.2; research §3.

**What is wrong:** `parse(BitArray) -> Message` cannot also return an error when a configurable limit is exceeded. A defect on an otherwise normal tree does not distinguish “complete but malformed” from “the parser stopped before an attachment.” That distinction matters to downstream security scanning and ordinary attachment extraction. “Never crashes” also cannot cover VM exhaustion or a caller-supplied decoder that panics, loops, or allocates without bound.

The proposed limits omit aggregate header bytes, unfolded field length, comment/quote nesting, parameter/continuation counts, encoded-word count, defect count, decoded output, and cumulative work across embedded messages. Per-part budgets reset by recursion are bypassable. An input-size limit alone does not bound the cost of repeatedly parsing/decoding that input.

**Evidence:** [RFC 7103 §9.1](https://www.rfc-editor.org/rfc/rfc7103.html#section-9.1) explicitly identifies attacks hidden past a truncation point. [Gleam bit_array](https://hexdocs.pm/gleam_stdlib/gleam/bit_array.html) exposes bit arrays, not an octet-only input type; a trailing partial byte is another currently unspecified case.

**Recommendation:** make the public bounded entry point return `Result(Message, ParseError)`. Malformed content normally succeeds with diagnostics; invalid options, non-octet input, and resource exhaustion have explicit outcomes. Error by default on limits. If partial results are wanted, use a visibly separate incomplete-result variant with the limit, location, and unconsumed region—not an ordinary `Message`. Define one cumulative budget shared by MIME parsing, structured-header parsing, and eager embedded-message decoding. Scope the totality guarantee to supported octet inputs, valid configuration, and trusted terminating callbacks.

### B02 — “First duplicate wins” is not RFC 7103's safety recommendation

**Claims:** B.5–B.7, B.6 specifically; research §2 “RFC 7103 rules”.

**What is wrong:** the research attributes first-wins behavior to RFC 7103, but that RFC warns about precisely this differential. Two `From` fields can cause a displayed identity to differ from an authenticated one; duplicate Content-Type/CTE/boundary parameters can cause two components to inspect different attachments. Keeping duplicates in a raw list does not help a caller whose convenient accessor discards the ambiguity.

“Thunderbird, then MimeKit, then Python” is not a reproducible policy: versions, Python policies, and client preferences matter. A MUA's display recovery is not automatically appropriate for an ingestion service.

**Evidence:** [RFC 7103 §7.5](https://www.rfc-editor.org/rfc/rfc7103.html#section-7.5): an MUA could show “the first of two From fields” while authentication “only verified the second.” The listed mitigations are rejection, refusing excess fields, combination where meaningful, or renaming—not a blanket first-wins rule. §7.5.1 gives concatenated Subjects and combined From addresses as possible interpretations.

**Recommendation:** retain ordered occurrences, but have security-relevant accessors expose Missing/Single/Invalid/Ambiguous, with the chosen display interpretation separate. Never merge Content-Type or CTE as if they were address lists. A first-value convenience accessor can exist if explicitly named/documented as such. Freeze a versioned recovery policy with concrete examples, and state that parsing does not authenticate senders or make messages safe to relay. A complete strict parser can wait; an ambiguity/completeness check cannot.

### B03 — MIME recovery can silently change which bytes constitute an attachment

**Claims:** E.3, E.6–E.8; research §3 MIME/transfer-decoding layers.

**What is wrong:** there is no defined precedence between “ignore a non-identity CTE on multipart” and “unknown CTE means opaque octet-stream.” Missing multipart boundary becomes text/plain, exposing uninterpreted structural/binary material as displayable text. Missing start delimiter becomes a synthetic opaque child whose relationship to the original entity is unclear.

Innermost-first matching is underdefined for equal nested boundaries and prefix-related boundaries. With outer `a` and inner `ab`, accepting trailing garbage lets a line beginning `--ab` also match `a`. With identical boundaries there is no unique tree to recover. A repaired tree alone hides that uncertainty.

**Evidence:** [RFC 2046 §§5.1.1–5.1.2](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1) prohibits a nested boundary using an enclosing boundary as a prefix and requires recognition of outer boundaries at any nesting level. It also says prefix comparison is sufficient, so simply calling every trailing-text acceptance “against the RFC” would be wrong: the prose and strict delimiter grammar need an explicit policy. [RFC 2049 §2](https://www.rfc-editor.org/rfc/rfc2049.html#section-2) requires unknown CTEs to be treated as octet-stream regardless of recognized content type. [RFC 6532 §3.7](https://www.rfc-editor.org/rfc/rfc6532.html#section-3.7) permits any CTE on message/global.

**Recommendation:** specify a decision table before writing the tree builder. Unknown CTE takes the opaque path before structural interpretation. A declared multipart with unusable framing stays an opaque entity with its declared metadata and a structural defect, not silently text/plain. Equal/prefix boundary collisions must produce an explicit ambiguous/recovered status and a documented conservative recovery, not a claim of a canonical tree. Test ancestor termination while inside child headers, bodies, embedded messages, and epilogues. Decode supported message/global CTEs before recursion; label base64/QP message/rfc822 handling as compatibility recovery.

### B04 — The sketched ADTs do not meet the raw-preservation promise

**Claims:** B.4, C.2, E.4–E.5; research §3 ADT and “needed for DKIM, re-serialising”.

**What is wrong:** a header name plus raw value, and bodies plus preamble/epilogue, cannot reconstruct all input bytes. The sketch loses delimiter lines and their padding, original field-name spacing/case if normalized, invalid header lines, exact header separators, the BOM/envelope prefix, and the encoded representation of `Embedded(Message)`. A `String` envelope line also cannot preserve arbitrary bytes. Decoded embedded messages have offsets in a different byte source.

This is not just about future rendering: signature verification and incident investigation require the actual original representation. Conversely, retaining a tiny sub-binary can retain an entire large input allocation.

**Evidence:** [RFC 7103 §4](https://www.rfc-editor.org/rfc/rfc7103.html#section-4) distinguishes internal interpretation from invariant external content. [RFC 6376 §3.4](https://www.rfc-editor.org/rfc/rfc6376.html#section-3.4) defines header/body canonicalizations sensitive to information the sketch discards. [RFC 1847 §2.1](https://www.rfc-editor.org/rfc/rfc1847.html#section-2.1) requires protection of signed MIME content from transformations.

**Recommendation:** retain the original byte source and explicit source spans for entities, fields, separators, and boundaries. Retain the raw encoded container for embedded messages and identify decoded byte sources separately. Typed/recovered values are derived views, not replacements. Do not advertise reconstructed bytes as suitable for DKIM. Document source-buffer retention and provide an explicit way for consumers to detach selected data if necessary.

## Major findings

### M01 — WHATWG aliases are real, but they are not MIME charset semantics

**Claims:** F.4–F.6; research §§2, 4.

**What is wrong:** WHATWG does map `us-ascii`, `iso-8859-1`, and `latin1` to windows-1252. Calling that “decode as declared” is nevertheless false for MIME: ASCII must reject bytes above 127; ISO-8859-1 byte 0x80 is U+0080, whereas windows-1252 yields U+20AC. Mapping ASCII first to a permissive single-byte decoder also prevents the stated UTF-8 fallback from ever running for many mislabeled messages.

F.4 says unsupported CJK remains raw; F.5 instead turns it into guessed UTF-8/windows-1252. Valid ISO-2022-JP is 7-bit and valid UTF-8 at the byte level, so this can report successful decoding of escape sequences instead of Japanese. Known-but-unsupported and unknown are not the same state.

**Evidence:** [WHATWG names and labels](https://encoding.spec.whatwg.org/#names-and-labels) confirms the aliases; its [security background](https://encoding.spec.whatwg.org/#security-background) explains why decoder disagreements matter. [RFC 2046 §4.1.2](https://www.rfc-editor.org/rfc/rfc2046.html#section-4.1.2) defines the MIME charset context. [RFC 2049 §2](https://www.rfc-editor.org/rfc/rfc2049.html#section-2) says unknown-charsets material is treated as octet-stream; it does not mandate windows-1252 fallback.

**Recommendation:** implement actual ASCII and ISO-8859-1 separately. Reuse appropriate WHATWG tables, not wholesale browser semantics. Offer a named display-compatibility policy that records declared label, canonical decoder, recovery, and whether the output is guessed/lossy. Known unsupported charsets should remain undecoded by default and invoke the caller decoder before any optional guess. Do not automatically reinterpret valid Latin-1 as UTF-8: both interpretations can be valid. Make the leaf-specific override explicit.

### M02 — RFC 7103 header recovery has been simplified into a different algorithm

**Claims:** C.1–C.5, B.5; research §2 broken-address table and §3 tokenizer.

**What is wrong:** §7.2 does not say unconditionally append every colon-less line. It recommends rejecting the anomaly or, if accepting, looking ahead for an empty line or another header-looking line. It also inserts a separating space. Without the lookahead conditions and an EOF policy, body-only input and a missing separator can be swallowed into a header. Repeating a forward scan at every anomaly can be quadratic.

“Close everything at EOF” also does not implement §7.1's examples. `(Testing <fran@example.com>` is repaired to `(Testing) <fran@example.com>`, not `(Testing <fran@example.com>)`, which would hide the address inside a comment. The same issue applies to the unclosed display-name quote example. The naked-local-part recommendation is eml's own choice, not a faithful summary of §7.1.7.

**Evidence:** [RFC 7103 §§7.1.4–7.2](https://www.rfc-editor.org/rfc/rfc7103.html#section-7.1.4). §6 limits its line-ending advice to raw framing, not decoded MIME entities. §7.3 does support whitespace-only continuation lines.

**Recommendation:** specify separate outcomes for body-only input, EOF without a separator, initial continuation, invalid field names, and orphan colon-less lines. Retain anomalous lines independently of any recovered field value. If adopting §7.2, implement bounded/two-pass lookahead and preserve ambiguity; it is not universally safer than body-start interpretation. Do not silently apply “close at EOF” to addresses. Never apply framing normalization to decoded attachment bytes.

### M03 — One universal CFWS tokenizer and raw-8-bit address recovery are unsafe abstractions

**Claims:** C.7–C.8, D.2–D.3, D.7; research §3 field lexing.

**What is wrong:** RFC 5322 atoms, MIME tokens, unstructured fields, quoted strings, domain literals, and obsolete productions have different grammar and semantics. A tokenizer that treats all high bytes as atext and always repairs quotes is not a general substitute. A permissive unquoted parameter scanner must still recognize quotes/comments; `boundary=foo (comment)` must not accidentally include a syntactic comment in the delimiter.

Decoding an invalid 8-bit addr-spec as windows-1252 can invent a different mailbox identity. Decoding encoded-words before structured parsing can turn display text into syntax, including commas, angle brackets, CR, and LF. A parsed Subject can itself contain control characters decoded from an encoded-word; it is not safe to put back into a header or a log unescaped.

**Evidence:** [RFC 2045 §5.1](https://www.rfc-editor.org/rfc/rfc2045.html#section-5.1) defines MIME `token`/`tspecials`; [RFC 5322 §3.2](https://www.rfc-editor.org/rfc/rfc5322.html#section-3.2) defines different lexical rules. [RFC 2047 §6.2](https://www.rfc-editor.org/rfc/rfc2047.html#section-6.2): decoding occurs **after** structured-field tokenization. [RFC 7103 §7.7](https://www.rfc-editor.org/rfc/rfc7103.html#section-7.7) advises excluding unrepairable non-EAI addresses from processing. [RFC 6532 §3](https://www.rfc-editor.org/rfc/rfc6532.html#section-3) permits valid UTF-8 field values, not arbitrary 8-bit data or non-ASCII field names.

**Recommendation:** share low-level scanning primitives, not one recovery grammar. Parse structure from bytes, then decode display-bearing components. Invalid identity bytes remain invalid/raw, not a guessed deliverable address. Separate Unicode display strings from validated mailbox identities. Use ASCII-only case folding for protocol names, and never lowercase local-parts or whole Message-IDs. Valid UTF-8 headers do not automatically warrant a defect merely because SMTPUTF8 negotiation is unknown in a stored `.eml` file.

### M04 — RFC 2231 needs a conflict and failure policy, not just sorting

**Claims:** D.5, D.7; research §2 RFC table.

**What is wrong:** sorting numbered sections leaves duplicate indices, gaps, leading-zero indices, conflicting `filename*`/`filename*0*`, enormous numeric suffixes, malformed `%` escapes, missing charset/language delimiters, and invalid extended values versus valid plain fallbacks unspecified. An attacker can use these ambiguities to make a security filter and extraction UI see different filenames. Allocating an array up to the largest supplied section number is an obvious resource attack.

Mixed starred/unstarred sections matter: percent-decode only the encoded sections, assemble resulting bytes, then charset-decode once. Percent-decoding the whole assembled string would corrupt literal percent sequences in unstarred sections. RFC 8187 is HTTP-specific and excludes MIME continuations; it is not a drop-in replacement.

**Evidence:** [RFC 2231 §§3–4](https://www.rfc-editor.org/rfc/rfc2231.html#section-3): indices start at zero, with neither leading zeroes nor gaps; mixed encoded and unencoded segments are allowed. [RFC 8187 §§1, 3.1](https://www.rfc-editor.org/rfc/rfc8187.html#section-3.1) distinguishes its HTTP profile.

**Recommendation:** bound both index length and actual segment count; use a sparse representation, not allocation by index. Define duplicate/conflict selection and retain all alternatives. Prefer a **successfully decoded, unambiguous** extended filename over a plain fallback; expose failure otherwise. Apply RFC 2047 filename compatibility only as an explicit final recovery and never decode repeatedly. Test `%2f`, `%5c`, `%00`, `%252f`, literal `+`, split multibyte sequences, mixed sections, and unsupported charsets.

### M05 — Unconditional encoded-word byte concatenation corrupts the standards model

**Claims:** D.3–D.4; research §§1, 3.

**What is wrong:** recovering a split UTF-8 character can be useful, but every encoded-word is supposed to be independently decodable. Joining every same-charset pair also crosses state boundaries in stateful encodings and gives malformed words more authority than their literal surrounding text. Do not concatenate the base64 spelling itself: each word has its own padding and transfer decoding.

Missing cases include charset-language syntax from RFC 2231, Q `_` meaning space, context-specific Q restrictions, invalid B padding, whitespace next to an undecodable word, and a literal string that merely resembles an encoded-word. Permissive decoding in all parameters would affect structural parameters such as boundary, not just filenames.

**Evidence:** [RFC 2047 §5](https://www.rfc-editor.org/rfc/rfc2047.html#section-5): “A multi-octet character may not be split across adjacent 'encoded-word's.” §6.2 gives the per-word state/display rules. [RFC 2231 §5](https://www.rfc-editor.org/rfc/rfc2231.html#section-5) adds language tagging. gen_smtp's [strict-then-permissive implementation](https://github.com/gen-smtp/gen_smtp/blob/1.3.0/src/mimemail.erl) is a retry, not unconditional concatenation.

**Recommendation:** decode independently first. Add a narrowly scoped, diagnosed split-character recovery only on failure, for supported encodings where it is justified. Preserve undecodable words literally and make whitespace handling explicit. Limit nonstandard encoded-word decoding to display-name/filename compatibility contexts; never apply it to boundary or addr-spec syntax.

### M06 — Transfer-decoder recovery must report incomplete or changed payloads

**Claims:** F.2–F.3, E.6, H.5.

**What is wrong:** “stop at padding” does not define leading/mid-quantum `=`, excessive padding, trailing alphabet data, or concatenated padded streams. `QQ==Qg==` must not silently become a complete attachment containing only `A`. “Does not accept URL-safe characters” conflicts with “skips non-alphabet bytes”: skipping `-` and `_` is still accepting and changing that input. MIME's ignore rule is not a guarantee that a recovery matches another decoder.

QP trailing-whitespace removal must operate on literal encoded-line whitespace, not on already-decoded output: `=20` at end of line encodes a significant space. Bare-CR soft breaks, a terminal `=`, `=\r` at EOF, soft breaks with padding, and preservation of hard line endings are unspecified. Header Q encoding is not the body QP algorithm.

**Evidence:** [RFC 2045 §§6.7–6.8](https://www.rfc-editor.org/rfc/rfc2045.html#section-6.7) specifies QP whitespace and base64 recovery. [RFC 7103 §8.2](https://www.rfc-editor.org/rfc/rfc7103.html#section-8.2) explicitly warns of attacks using different base64 interpretations. [RFC 4648 §§3.3–3.5](https://www.rfc-editor.org/rfc/rfc4648.html#section-3.3) covers nonalphabet data, padding, and pad bits, subject to the MIME profile.

**Recommendation:** write an explicit state/outcome table for malformed encodings. Return decoded bytes with completeness/recovery diagnostics, including ignored junk and trailing data, rather than quietly returning an apparently exact file. Keep raw CTE bytes available. Default identity encodings must preserve every octet, including NUL and bytes ≥128; aliases such as `none`, `7-bit`, and `x-uuencode` need explicit policy rather than accidental passthrough.

### M07 — NUL removal repeats the same class of silent corruption being replaced

**Claims:** F.7; research §2 “NUL bytes: drop them”.

**What is wrong:** unconditional removal changes text content and can join tokens. It also conflates an isolated construction error with a binary payload mislabeled text. Decoding UTF-16 bytes through the wrong fallback and then removing zero bytes can manufacture convincing-looking ASCII. Gleam strings do not require C-style NUL termination.

**Evidence:** [RFC 7103 §7.6](https://www.rfc-editor.org/rfc/rfc7103.html#section-7.6) distinguishes “a few null bytes in isolation,” which it recommends dropping, from “large numbers,” for which it recommends refusing processing. The current summary omits the latter half. [WHATWG UTF-16 decoders](https://encoding.spec.whatwg.org/#shared-utf-16-decoder) illustrate why zero octets are not equivalent to decoded U+0000 characters.

**Recommendation:** preserve decoded U+0000 in the faithful text view and report it; provide an explicitly sanitized display view if leaf needs one. If choosing RFC 7103's deletion recovery, make it an opt-in presentation policy and expose that it was lossy. Never remove bytes before charset decoding. Large-NUL/unsupported-encoding cases should remain visibly undecoded or suspect, not silently “cleaned.”

### M08 — Filename sanitization and HTML/CID helpers need a security boundary

**Claims:** A.6, D.5; research §§2–3 filename sanitizing, HTML bodies, CID resolution.

**What is wrong:** “terminal component only” is necessary, not sufficient. Unix basename handling does not handle Windows backslashes, drive/UNC paths, alternate data streams, `CON`/`NUL`, trailing dots/spaces, empty names, control/bidi characters, or filename collisions. Sanitizing before RFC 2231/2047 decoding is bypassable. Even a safe basename does not prevent symlink races or overwriting an existing file.

HTML is active, untrusted content; a MIME parser does not sanitize it. CID and Content-Location values are not file paths, and message/external-body must not cause automatic fetches. Treating Content-Location as a trusted URL invites SSRF/tracking if helpers later grow network behavior.

**Evidence:** [RFC 2183 §§2.3, 5](https://www.rfc-editor.org/rfc/rfc2183.html#section-2.3) requires checking overwrite/security problems, not merely dropping directories. [RFC 2392 §2](https://www.rfc-editor.org/rfc/rfc2392.html#section-2) defines URL escaping and allows duplicate Content-IDs in specific MIME contexts. [RFC 2046 §5.2.3](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.2.3) defines external-body rather than ordinary inline content.

**Recommendation:** expose the original decoded filename as untrusted metadata and a separately named safe-name suggestion with a documented target-platform policy. Recommend caller-generated storage names and safe file-creation APIs. No extraction or fetching in core. Document HTML as unsanitized. CID resolution should return a scoped part reference or ambiguity, never a filesystem path or network request, and decode URL escaping exactly once.

### M09 — Body/attachment selection is a separate specified algorithm, not a boolean

**Claims:** A.6, E.8; research §3 helpers.

**What is wrong:** the same tree can have different body roles depending on ancestry and disposition. An attached message's HTML is not the parent message's HTML; an inline part can still have a filename; an attachment disposition on a multipart applies to the container; an alternative should not be concatenated as if mixed. A binary “inline vs attachment” classification is insufficient for related resources, body alternatives, attached containers, and unknown roles.

**Evidence:** [RFC 2046 §5.1.4](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.4) orders alternatives by increasing fidelity. [RFC 2387 §3](https://www.rfc-editor.org/rfc/rfc2387.html#section-3) says `start` chooses the root, otherwise the first child; `type` is required and disagreement with the root is undefined. §4 gives related processing precedence over disposition. [RFC 8621 §4.1.4](https://www.rfc-editor.org/rfc/rfc8621.html#section-4.1.4) supplies a useful, previously omitted body-structure algorithm, but is an explicit JMAP policy, not universal MIME semantics.

**Recommendation:** core returns structure and declared metadata. Helpers return role/classification plus part references and reasons, with a documented policy and ambiguous outcomes. Do not descend into attached messages when selecting the parent's body. Test related-within-alternative and alternative-within-related, missing/duplicate `start` targets, disposition on containers, empty alternatives, and repeated CIDs scoped to alternative branches. Consider adapting RFC 8621 rather than inventing a global filename heuristic.

### M10 — “Linear throughout” is not established by using slices

**Claims:** G.1–G.3, E.3, C.4; research §4.

**What is wrong:** comparing each candidate line against every active boundary costs roughly O(input × depth × boundary length), unless the latter two are strictly bounded constants. Recursive rescanning of embedded containers, repeated forward lookahead, repeated list append, progressive bit-array/string concatenation, and rescanning all headers for each accessor can introduce quadratic work. Closing unbounded nested comments recursively can overflow the JS stack even when MIME depth is bounded.

Zero-copy is also not zero-allocation or low retained memory. Small views can pin a large source. Erlang match-context optimizations depend on generated code and how tails escape; they are not guaranteed by writing recursive Gleam.

**Evidence:** [bit_array.from_string](https://hexdocs.pm/gleam_stdlib/gleam/bit_array.html#from_string) explicitly has different Erlang/JS complexity. The [Gleam JS prelude's bitArraySlice](https://github.com/gleam-lang/gleam/blob/main/compiler-core/templates/prelude.mjs) currently uses buffer views, so a blanket claim that JS slicing necessarily copies would also be incorrect. [Erlang binary handling](https://www.erlang.org/doc/system/binaryhandling.html) documents the optimization/retention model.

**Recommendation:** specify complexity in terms of input bytes, total produced bytes, bounded depth, and boundary length. Bound grammar nesting separately. Use cursors/spans, reverse accumulators, and chunked byte builders; do not repeatedly convert full tails to String. Add doubling-size timing/allocation tests for long lines, folded headers, boundary near-matches, invalid encoded-words, thousands of continuations, and deeply nested embedded messages on both targets. Preserve the pure constraint; measure before choosing an optimization or a heavier search algorithm.

### M11 — Lazy decoding and lazy defects need an explicit public contract

**Claims:** B.3, C.8, F.4; research §3 layers and decoder callback.

**What is wrong:** a parsed node's defect list cannot include errors in a body or structured field that has not been decoded. Pure immutable values do not automatically memoize a lazy function; repeated accessor calls may repeatedly decode megabytes. A stored closure complicates equality, snapshots, serialization, and leaf's Elixir interop. `Result(String, Nil)` cannot distinguish unknown charset, unsupported charset, malformed input, or a limit.

Embedded-message transfer decoding is already necessarily eager if its tree is returned. Decoder callbacks can break both purity assumptions and bounded execution; the library cannot sandbox them without target-specific machinery.

**Evidence:** the contradiction follows directly from the proposed `Single` versus `Embedded` constructors and C.8. [RFC 6532 §3.5](https://www.rfc-editor.org/rfc/rfc6532.html#section-3.5) specifically allows nested transfer encodings. [Birdie](https://hexdocs.pm/birdie/) snapshots supplied Strings, not execution of deferred decoders.

**Recommendation:** eagerly parse framing/tree metadata, retain raw leaf bytes, and provide explicit decode functions returning a value plus their own diagnostics and selected charset. Provide an optional “decode/validate all” operation for consumers needing a complete diagnostic report. Avoid thunk-bearing public ADTs. Let callers retain decoded results; document repeat-call cost and budget lifetime. Give the callback a typed outcome, original label/bytes, and a clear trusted-code contract; never silently discard its failure.

### M12 — Corpus licensing contains material errors and needs per-file provenance

**Claims:** H.1–H.2; research §5.

**What is wrong:** the blanket Dovecot exclusion and “unclear” Stalwart malformed/thirdparty provenance are overstated. Their actual COPYING files explicitly identify MIT-licensed material. Conversely, a repository's root license does not automatically clear all third-party emails, attachments, or quoted works. Fetching unlicensed material during tests is not a substitute for provenance review, and CI caches/snapshots/artifacts may redistribute it.

Mailparser's current LICENSE text is MIT-0-style (no notice-retention condition), although its package metadata still says MIT. Postal-mime's MIT-0 description is supported. CPython's top-level LICENSE contains historical agreements, not just a short PSF-2.0 notice.

**Evidence and verified observations:**

| Source | Primary evidence | Review result |
|---|---|---|
| Stalwart | [Apache-2.0](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/LICENSES/Apache-2.0.txt), [MIT](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/LICENSES/MIT.txt), Cargo `Apache-2.0 OR MIT` | Root dual-license claim supported. Still inspect imported material. |
| Stalwart malformed/thirdparty | [malformed/COPYING](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/resources/eml/malformed/COPYING), [thirdparty/COPYING](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/resources/eml/thirdparty/COPYING) | Both explicitly say Dovecot authors, MIT; malformed identifies a separate provenance for `023.eml`. Check that exception. |
| Dovecot upstream | [COPYING](https://github.com/dovecot/core/blob/main/COPYING), [test-message-parser.c](https://github.com/dovecot/core/blob/main/src/lib-mail/test-message-parser.c) | Mixed licensing: several directories MIT, remainder generally LGPL unless marked otherwise. Do not claim every Dovecot parser test is MIT; trace the actual imported files/version. |
| Stalwart legacy | [legacy/COPYING](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/resources/eml/legacy/COPYING) | Hunnysoft attribution/readme, no clear redistribution grant in the inspected file. Conservative exclusion is justified. |
| gen_smtp | [LICENSE](https://github.com/gen-smtp/gen_smtp/blob/1.3.0/LICENSE) | BSD-2-Clause supported. |
| mime4j | [LICENSE](https://github.com/apache/james-mime4j/blob/a3a9ec2e578e5fd05bf4bbb58e904237f09e9cb5/LICENSE), [NOTICE](https://github.com/apache/james-mime4j/blob/a3a9ec2e578e5fd05bf4bbb58e904237f09e9cb5/NOTICE), [Artistic license](https://github.com/apache/james-mime4j/blob/a3a9ec2e578e5fd05bf4bbb58e904237f09e9cb5/core/src/test/resources/mimetools-testmsgs/ARTISTIC-LICENSE.txt) | Apache for project; NOTICE explicitly identifies MIME-tools data under Artistic. Preserve the actual old Artistic text and relevant notices, not just a label. |
| CPython | [LICENSE](https://github.com/python/cpython/blob/9f386367333f7845095d764fad3ad9b397d04672/LICENSE) | Broad PSF description reasonable; retain applicable full license/attributions and inspect fixture origins. |
| MimeKit | [LICENSE](https://github.com/jstedfast/MimeKit/blob/d3884a84ef98fa203d7ffd29f0c90ce16ec7e713/LICENSE) | MIT supported; this does not independently establish permission for jwz/Crispin material. |
| Go | [LICENSE](https://github.com/golang/go/blob/f37eedeb17ddc24aeeb66e69b9f94a99d23d5504/LICENSE) | BSD-3-Clause supported. |
| enmime | [LICENSE](https://github.com/jhillyerd/enmime/blob/4e8e7f28b7b63e7367a1c39bf9ccc5f6a3be2255/LICENSE) | MIT supported. |
| postal-mime | [LICENSE.txt](https://github.com/postalsys/postal-mime/blob/5828feb9a79e48f8d64bfd0b9ef71c7f607bfb5d/LICENSE.txt), [mimetorture.eml](https://github.com/postalsys/postal-mime/blob/5828feb9a79e48f8d64bfd0b9ef71c7f607bfb5d/test/fixtures/mimetorture.eml) | MIT-0-style text; Ryan Finnie's test identifies its separate author. Do not infer the fixture's entire provenance from the root license. |
| mailparser | [LICENSE](https://github.com/nodemailer/mailparser/blob/eaffc16edb4826555327a976b9a631f185c848bd/LICENSE), [package.json](https://github.com/nodemailer/mailparser/blob/eaffc16edb4826555327a976b9a631f185c848bd/package.json) | License text/metadata mismatch; record it rather than asserting MIT unconditionally. |

**Recommendation:** use an import manifest containing URL, commit, file list/hash, provenance, license text, modifications, and expected-output adapter. Keep uncertain material out of published fixtures and CI artifacts until resolved. Preserve H.8's customer-data exclusion; anonymization needs to remove attachments, addresses, identifiers, URLs, and encoded copies too. Correct the Dovecot/Stalwart statements, but do not turn that correction into blanket permission to import every file.

### M13 — The proposed tests can pass while bytes are still corrupted

**Claims:** H.3–H.5; research §6.

**What is wrong:** a parser returning everything as opaque can pass never-crash tests. A snapshot showing only a preview and length can miss corruption in the middle of an attachment. A custom encoder and custom decoder can share the same bug and pass round-trips. “Idempotence” is undefined for a parser whose output is not its input type. Global line-ending normalization is not a safe MIME property: binary bodies, signatures, and boundary-related newlines are significant.

**Evidence:** [Birdie documentation](https://hexdocs.pm/birdie/) says it compares only the supplied String and recommends small, focused snapshots. [RFC 2046 §5.1.1](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1) assigns the newline before a delimiter to the delimiter, not the body. [RFC 2045 §6.8](https://www.rfc-editor.org/rfc/rfc2045.html#section-6.8) distinguishes binary data from text canonicalization.

**Recommendation:** add independent known-answer decoder vectors and exact decoded-byte assertions/full-content digests alongside snapshots. Assert raw-source conservation, exact empty-part preservation, deterministic part order, monotonically advancing cursors, boundary ownership, and budget enforcement. Keep both arbitrary-octet and structured generators. Vary line endings only in known framing regions of generated inputs, preserving body bytes. Differential tests should include independent parsers outside gen_smtp, with versions/policies pinned and disagreements triaged rather than majority-voted. Do not bring gen_smtp into this repo contrary to H.7.

### M14 — The DIY fuzzer justification is factually weak and its isolation is incomplete

**Claims:** H.6; research §6.

**What is wrong:** “jazzer.js is deprecated” is not supported by the inspected primary repository: it is unarchived and actively updated. “No BEAM-native fuzzer exists” is an unsupported universal negative, not a reason to build one. Function coverage quickly saturates in recursive parsers and is a weak proxy for input exploration.

OTP native coverage is real, but requires JIT support and load-time instrumentation; setting the mode after modules are loaded is insufficient. Per-process `max_heap_size` alone misses the very large off-heap binaries this library manipulates unless configured appropriately. Killing an Erlang process also does not test JS stack/memory behavior.

**Evidence:** [Jazzer.js repository](https://github.com/CodeIntelligenceTesting/jazzer.js) and [repository API](https://api.github.com/repos/CodeIntelligenceTesting/jazzer.js) showed `archived: false`, with a 2026-11-09 push during review. [OTP code/native coverage](https://www.erlang.org/doc/apps/kernel/code.html#native-coverage-support) documents JIT/load-time constraints. [process_flag/max_heap_size](https://www.erlang.org/doc/apps/erts/erlang.html#process_flag/2) documents `include_shared_binaries`, default false, and GC-dependent enforcement.

**Recommendation:** start with seeded qcheck, mutation tests, bounded per-input workers, and explicit complexity tests. Evaluate a maintained JS coverage fuzzer against generated JS as dev tooling; it does not violate library purity. If adding the OTP loop, instrument before loading, reset/collect coverage consistently, avoid concurrent coverage contamination, include shared binaries, and use an external worker/OS memory limit for a real containment boundary. Keep timeout/OOM reproducers and shrink them. Do not make a bespoke coverage engine a v1 dependency.

## Minor findings

### m01 — The base64 experiment is valid, but its explanation is too broad

**Claims:** F.1 [verified]; research §4.

**What is wrong:** gleam_stdlib 1.0.5 does reject the reported string, but it does not reject all line-wrapped base64. Its wrapper pads based on the entire input byte length, including whitespace, before invoking Erlang's decoder.

**Evidence:** [stdlib implementation](https://github.com/gleam-lang/stdlib/blob/v1.0.5/src/gleam/bit_array.gleam) and [HexDocs](https://hexdocs.pm/gleam_stdlib/gleam/bit_array.html#base64_decode). On installed OTP 29: raw `base64:decode` accepts `QUJD\r\nREVG`; Gleam's wrapper returns Error for it, but returns `ABCDEF` for `QUJD\r\n\r\nREVG`. The extra CRLF changes the wrapper's padding arithmetic.

**Recommendation:** retain the pure MIME decoder plan, but describe the verified failure precisely and add both examples as regressions. Do not attribute the behavior simply to Erlang rejecting whitespace or assume native `atob` matches the Gleam wrapper.

### m02 — The address/date ADTs need validity and provenance, not more permissiveness

**Claims:** D.1–D.2, D.6; research §3 ADT.

**What is wrong:** `Group(members: List(Address))` permits nested groups, which the grammar does not. `domain: Option` conflates a useful malformed fragment with a real mailbox. A `List(Address)` alone cannot distinguish missing From, invalid From, a valid empty group, or multiple occurrences. The consumer's requested “from address” may legitimately not be unique. Reply-To and Sender are also relevant to that consumer, not only From.

A timestamp alone cannot faithfully represent leap seconds, unknown local offset, obsolete zones, invalid calendar dates, or an inconsistent weekday. `-0000` denotes UTC time with unknown originating local-zone information, not an invitation to use the machine timezone.

**Evidence:** [RFC 5322 §§3.3–3.4, 4.3](https://www.rfc-editor.org/rfc/rfc5322.html#section-3.3); [RFC 6854 §2.1](https://www.rfc-editor.org/rfc/rfc6854.html#section-2.1) supports groups in From/Sender but constrains Sender to at most one mailbox, including within a group.

**Recommendation:** group members should be mailboxes; malformed address fragments need an explicit status/raw representation. Keep structured components plus validation for dates and make timestamp conversion a separate Result. Test empty groups/Bcc, obsolete routes, quoted local-parts containing `@`, domain literals, UTF-8 local-parts/domains, leap seconds, years 49/50, invalid dates, and unknown zones. Do not use a best-effort display identity as an authenticated or routable one.

### m03 — Several important MIME/RFC cases are missing from the implementation contract

**Claims:** E.1–E.8, F.4; research §2 RFC list.

**What is wrong:** the standards list is a good start, but the boundary between “implemented,” “opaque,” and “helper” is missing for common real mail.

**Evidence and recommendation:** add explicit tests/policies for:

- [RFC 6657 §§3–4](https://www.rfc-editor.org/rfc/rfc6657.html#section-3): charset defaults are subtype-specific; text/plain still defaults to ASCII. Do not extrapolate E.1 to every `text/*`; define how HTML/XML in-band declarations are handled or explicitly leave them to callers.
- [RFC 1847](https://www.rfc-editor.org/rfc/rfc1847.html), [RFC 3156](https://www.rfc-editor.org/rfc/rfc3156.html), [RFC 8551](https://www.rfc-editor.org/rfc/rfc8551.html): preserve signed/encrypted containers byte-for-byte; do not imply authentication/decryption support or classify a signature as message text.
- [RFC 3464](https://www.rfc-editor.org/rfc/rfc3464.html), [RFC 6533](https://www.rfc-editor.org/rfc/rfc6533.html), [RFC 8098](https://www.rfc-editor.org/rfc/rfc8098.html): delivery/disposition reports, message/global-headers and global delivery-status. These are not all recursively parsed full messages. Opaque handling is acceptable for v1.
- [RFC 2046 §5.2](https://www.rfc-editor.org/rfc/rfc2046.html#section-5.2): unknown `message/*`, message/partial, external-body. Do not auto-reassemble partial messages or fetch external data. Distinguish invalid Content-Type from a syntactically valid but unsupported type.
- [RFC 3676](https://www.rfc-editor.org/rfc/rfc3676.html): if implementing flowed text, handle `delsp`, quote depth, space stuffing, and the `-- ` signature separator after transfer/charset decoding; do not apply it to all plain text.

UTF-16LE/BE are missing despite not being CJK. Either support them early with BOM/odd-length/surrogate tests or expose UnsupportedCharset. Do not silently treat them as windows-1252 and remove their zero bytes. UTF-7 and other obsolete encodings can remain explicitly unsupported.

### m04 — BOM and mbox recognition can consume real message content

**Claims:** A.5, C.2.

**What is wrong:** “leading `From ` with no colon before first space” is nearly tautological and recognizes ordinary body prose as an envelope line. Supporting an mbox delimiter without specifying `>From ` unescaping leaves a half-mbox parser. Applying BOM/envelope stripping recursively would also alter embedded messages unexpectedly.

**Evidence:** [RFC 4155 §2](https://www.rfc-editor.org/rfc/rfc4155.html#section-2) describes variants and inconsistent escaping. It does not make every leading `From ` line an unambiguous mbox wrapper.

**Recommendation:** preserve the raw prefix and make mbox-envelope recognition an explicit option or separate wrapper, disabled for embedded MIME parts. Define whether input is a raw `.eml`, an already-extracted mbox message, or an mbox fragment. Do not guess/unescape the body. Also document that SMTP dot-stuffing/terminator removal is out of scope for `.eml` parsing.

### m05 — Purity does not prove cross-target equivalence

**Claims:** A.1–A.3, G.2–G.3; research hard constraint and §4.

**What is wrong:** absence of eml-owned `@external` does not prove identical semantics, exceptions, complexity, or integer behavior. Stdlib itself uses target-specific implementations. If “no runtime FFI” literally forbids even normal stdlib-backed primitives, the design already contradicts its use of `bit_array.slice`; this boundary needs stating, not silently relaxing.

**Evidence:** [stdlib bit_array source](https://github.com/gleam-lang/stdlib/blob/v1.0.5/src/gleam/bit_array.gleam) contains Erlang/JS externals. [HexDocs](https://hexdocs.pm/gleam_stdlib/gleam/bit_array.html) documents target-dependent performance. [qcheck's bit-array documentation](https://hexdocs.pm/qcheck/qcheck.html) explicitly warns that its non-byte-aligned generators can crash on JS.

**Recommendation:** keep eml's implementation and charset algorithms pure Gleam, with no custom runtime FFI/native decoders. Explicitly state the permitted standard runtime/stdlib foundation. Pin compiler/stdlib/runtime versions, compare canonical outputs across targets, and keep numeric counters within a defined safe range. Treat JS as supported only after correctness and size/stack benchmarks pass; pure source alone is not that evidence.

### m06 — Generated charset data needs its own license and reproducibility story

**Claims:** F.4, G.4; research §4.

**What is wrong:** generated source is still derived from third-party data. “About 28” is correct—the WHATWG machine-readable list has 28 legacy single-byte encodings—but their decoder algorithms also define undefined entries/error handling. A table without those rules is not a complete decoder. WHATWG labels include deliberately destructive `replacement` mappings that should not become successful MIME decoding.

**Evidence:** [encodings.json](https://encoding.spec.whatwg.org/encodings.json), [single-byte decoder](https://encoding.spec.whatwg.org/#single-byte-decoder), [WHATWG LICENSE](https://github.com/whatwg/encoding/blob/main/LICENSE): CC BY 4.0 generally, with portions incorporated into source code under BSD-3-Clause instead.

**Recommendation:** pin indexes/labels to a revision/hash, retain required notices in generated code/distribution, and test regeneration. Distinguish label normalization from actual supported decoders. Specify invalid-byte policy, BOM preservation, and error/replacement behavior independently of browser TextDecoder defaults. Test all 256 bytes per table.

### m07 — Additional high-value corpora are available without a huge new harness

**Claims:** H.2–H.5; research §§5–6.

**What is wrong:** the current corpus plan favors parse-tree snapshots over codec correctness, parser stress, and the body-selection behavior leaf actually needs.

**Evidence:** [web-platform-tests/encoding](https://github.com/web-platform-tests/wpt/tree/master/encoding) includes single-byte, invalid-label, fatal-decoder, BOM, UTF-8 EOF and stateful-encoding tests; its [LICENSE](https://github.com/web-platform-tests/wpt/blob/master/LICENSE.md) is BSD-3-Clause. [go-fuzz-corpus/mail](https://github.com/dvyukov/go-fuzz-corpus/tree/c42c1b2914c7503500996ee15927d3ab3d2ba968/mail) has a substantial mutation corpus; its [LICENSE](https://github.com/dvyukov/go-fuzz-corpus/blob/c42c1b2914c7503500996ee15927d3ab3d2ba968/LICENSE) is Apache-2.0. Stalwart's [regressions README](https://github.com/stalwartlabs/mail-parser/blob/a56d5f1dc0050a9de123df926081e436334ba9e5/resources/eml/regressions/README.md) maps existing fixtures to selection/structural regressions and notes LF and CRLF expected outputs.

**Recommendation:** adapt WPT codec cases, audit the Go fuzz corpus as seeds rather than an oracle, and prioritize Stalwart's named structure/attachment regressions. Add self-authored cases for every recovery decision in this review. Investigate Dovecot-derived subsets using M12's provenance checks rather than rejecting all of them. Generated huge/pathological fixtures are preferable to checking in enormous DoS files.

### m08 — The first implementation plan is unnecessarily broad

**Claims:** A.4, A.6, D.*, H.4; research §§3, 5–6.

**What is wrong:** a general CFWS framework, complete date/address/Received parsing, 670 header vectors, an XML comparator, format=flowed, custom codec encoders, and a coverage-guided fuzzer can delay the actual replacement: preserving bodies/attachments reliably. Of the advertised 670 Stalwart vectors, 202 are Received tests, which are not in leaf's stated initial requirements.

**Evidence:** the [Stalwart header resources](https://github.com/stalwartlabs/mail-parser/tree/a56d5f1dc0050a9de123df926081e436334ba9e5/resources) confirm the breakdown; A.6 states the narrower consumer need. [Birdie](https://hexdocs.pm/birdie/) explicitly recommends focused snapshots rather than huge ones.

**Recommendation:** milestone 1: bounded framing, lossless headers, MIME tree, identity/base64/QP and opaque failures. Milestone 2: Subject, safe filename decoding, explicit charset outcomes, from-address view and body-role helpers. Milestone 3: dates/IDs/flowed/additional charsets and fuzz sophistication. Port selected XML expectations to a simple neutral test format rather than building an XML tooling project. Keep encoders in tests and make no renderer commitment for v1.

### m09 — Public constructor invariants and defect evolution need a versioning decision

**Claims:** B.3–B.4, C.8; research §3 public ADTs.

**What is wrong:** exposing a freely constructible `Part` with both authoritative raw headers and parsed Content-Type lets callers construct contradictory values. Derived fields can become stale if callers rebuild a record with changed headers. A closed public `Defect` union is pleasant to pattern-match, but every newly discovered defect variant can break consumers' exhaustive matches. Defects attached only to a part cannot identify which duplicate field, continuation section, or byte range caused the problem.

**Evidence:** [Gleam custom types](https://tour.gleam.run/data-types/custom-types/) expose constructors and support pattern matching; [opaque types](https://tour.gleam.run/advanced-features/opaque-types/) are the language mechanism for restricting construction. The proposed `Part` independently stores `headers`, `content_type`, and `body`, without a stated consistency invariant.

**Recommendation:** choose explicitly between an opaque parsed entity with read-only accessors and a public immutable data model whose invariants are documented and maintained by the library. Keep identity/location information in diagnostics: part path/source ID, byte span, field occurrence, recovery kind, and bounded detail. A closed defect type is acceptable if additions follow the project's breaking-change policy; otherwise use a stable category plus extensible diagnostic code/detail. Do not expose arbitrary huge raw fragments in every defect or unbounded diagnostic lists.

## Nits and evidence hygiene

### n01 — Several gen_smtp claims need narrower wording or corrected counts

**Claims:** research §§1, 5.

**What is wrong/evidence:** the actual [1.3.0 source](https://github.com/gen-smtp/gen_smtp/blob/1.3.0/src/mimemail.erl) supports the important complaint: `decode_body(..., none)` filters source bytes to `<128`; `parse_headers` replaces non-ASCII values; empty bodies are filtered out of multipart children. However, byte stripping happens before transfer decoding in that path, so it is not literally every non-ASCII byte in every decoded body. Base64/QP-encoded high bytes can survive. A no-CRLF input reaches `parse_headers`' `{[], Body}` branch, so “all LF-only files give empty bodies” is not a universal upstream behavior; pin the failing MIME fixture. Much of the failure code uses `erlang:error`, while QP uses `throw`; say “raises” rather than implying one exception class. The return tuple is awkward but not literally untyped in Erlang: the module defines a `mimetuple()` typespec.

[Issue #36](https://github.com/gen-smtp/gen_smtp/issues/36) is closed, not open. [#342](https://github.com/gen-smtp/gen_smtp/issues/342) concerns sending via smtp_util/Swoosh, not evidence of a mimemail decode crash. #122/#317, #88/#145, #10 and #284 were open when checked. The pinned 1.3.0 tree has **27**, not 34, `.eml` files under `test/fixtures`.

**Recommendation:** retain the production motivation, but distinguish private observations, upstream reproducible behavior, send-path issues, and historical reports. Include exact version, options, input, and expected bytes for each replacement regression.

### n02 — Some research is correctly verified; do not turn that into broader claims

**Claims:** research §§2, 4–6; H.1, H.5.

**Evidence:** the seven named Stalwart JSON files do contain **670** vectors with the stated individual counts. mime4j has **32 + 48** `.msg` files in the named directories; CPython's data directory contains **48 `.txt`** message fixtures, not only 48 total files. MimeKit has **23** compliance messages, while its **35** `messages/` files include auxiliary `.events` outputs. enmime's **43/32/12** file counts and Stalwart's **76/10** message counts match the inspected trees. These counts say nothing about unique coverage or clean provenance. I did not independently recount every inline Go/CPython test row or gen_smtp test group.

[RFC 5322 §4](https://www.rfc-editor.org/rfc/rfc5322.html#section-4) really does require obsolete syntax to be accepted/interpreted by conforming receivers; that does not require accepting every invalid syntax in RFC 7103 or abandoning resource limits. Errata [1905](https://www.rfc-editor.org/errata/eid1905), [1908](https://www.rfc-editor.org/errata/eid1908), and [6639](https://www.rfc-editor.org/errata/eid6639) are all Verified and worth tests. RFC 2045 supports the proposed absent/invalid Content-Type default; RFC 2046 supports digest defaults, empty part headers, unknown multipart-as-mixed, and delimiter-newline ownership. RFC 2183 supports unknown disposition-as-attachment. These sound decisions should remain.

[qcheck 1.0.5](https://hexdocs.pm/qcheck/qcheck.html) really documents the byte-aligned-generator distinction. [qcheck_gleeunit_utils](https://hexdocs.pm/qcheck_gleeunit_utils/) is a **separate package**, confirms the five-second EUnit default, and says its timeout/parallel wrappers do not manage JS tests properly. “No existing Gleam MIME/QP/RFC 2047 library” and “no pure Erlang charset library” remain search observations, not proven ecosystem-wide facts.

**Recommendation:** preserve verified findings with pinned sources, qualify negative ecosystem claims, and use separate JS timeout supervision. Keep counts descriptive rather than making them test-completion targets.

## Section I: explicit recommendations

| Open question | Recommendation |
|---|---|
| Total plus defects, Result, or separate validation? | **Bounded `Result` entry point, successful malformed parses carrying diagnostics.** Keep structural diagnostics on the parse; return lazy decode/field diagnostics with those operations. Add a complete validation/materialization helper. Do not hide all defects behind an optional validation call. See B01, B02, M11. |
| Resource limits: truncate or error? | **Error by default.** Optional partial-result API must mark incompleteness in its type and retain the location/remainder; never return a normal complete-looking tree after truncation. |
| Colon-less line: continuation or body? | **Neither is intrinsically safer across parsers.** For the tolerant parser, use the actual bounded RFC 7103 lookahead heuristic, record the malformed line and ambiguity, and define EOF/initial-line cases. Security-sensitive consumers should reject/quarantine that ambiguity rather than assume recovery eliminates smuggling. |
| Map ISO-8859-1 and US-ASCII to windows-1252? | **Not in the faithful MIME decoder.** Implement true ASCII/Latin-1; offer separately named, diagnosed browser-compatible display behavior. |
| Detect valid UTF-8 under a single-byte label? | **No automatic override of a valid declared single-byte decoding.** UTF-8 validity is not proof of intent. Offer an opt-in recovery policy or leaf-specific override; invalid ASCII can legitimately trigger a diagnosed fallback. |
| Lazy or eager decoding? | **Eager framing/tree, explicit on-demand leaf decoding**, plus an eager convenience/materialization operation. No hidden mutable cache or thunk-bearing public tree. Eagerly decode supported embedded-message wrappers when required to build their trees, under the same budget. |
| Is JS support worth the cost? | **Yes as a conformance target, conditionally as a production promise.** Keep dual-target tests from day one because they expose assumptions; Erlang remains primary. Gate advertised JS support on representative multi-MB, pathological nesting, stack, and allocation benchmarks. Defer browser packaging/streaming and the custom fuzzer rather than introducing FFI or weakening byte correctness. |

**Minimum pre-code exit criteria:** agree on the bounded result type; raw-source/span ownership; duplicate/ambiguous-header API; opaque MIME failure policy; charset identity versus display recovery; and a small set of exact-byte golden tests covering the original production failures. The other refinements can follow without changing those foundations.
