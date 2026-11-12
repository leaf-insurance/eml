# What other parsers do: error model and charset labels

Researched 2026-11-12 by reading the source of each library (main branches
unless a version is noted). This document follows up review findings B01 and
M01 in [reviews/2026-11-12-adversarial-review.md](reviews/2026-11-12-adversarial-review.md).

## 1. Top-level error model

| Library | Return type | What fails the whole parse | Recovered from | How problems are reported | What happens at a limit |
|---|---|---|---|---|---|
| Rust `mail-parser` 1.0.1 (Stalwart) | `Option<Message>` | Empty input; no header field and no blank line (**new in 1.0**, where 0.11 returned an empty message); input of 4 GiB or more | Everything else | Per-part `PartFlags` (MISSING_DELIMITER, NO_BLANK_LINE, UNTERMINATED, NESTING_LIMIT, LIMIT_REACHED, …). Decode problems are reported lazily via `text_checked()` | **Flatten**: the over-limit part becomes an opaque leaf with a flag (depth 64, 10k parts) |
| Rust `mailparse` 0.18 | `Result<ParsedMail, MailParseError>` | A header line starting with a space; a lone CR; depth over 100 | Missing colon, missing close boundary | None | **Error** (depth) |
| Rust `email-parser` (unmaintained) | `Result` | Anything that is not RFC 5322, including a missing From or Date | Nothing | n/a | n/a |
| Python `email` | `Message` | Never fails ("will never raise a parsing exception") | Everything | Typed defects in `msg.defects` on each part | No limits |
| Python strict mode | `policy.raise_on_defect=True` turns every defect into an exception | | | | |
| MimeKit 5.0 | throws `FormatException` | Empty input; a first line that is garbage (not a header and not an mbox `From `); a header over 16 KB | Missing boundaries, missing separator, … | Opt-in `ComplianceLogger` with about 100 violation codes, each with offset and line | **Flatten** at depth 1024; **error** at header length |
| Go `net/mail` | `(*Message, error)` | Empty input; a first line with leading whitespace; any header line without a colon | Body not parsed | None | n/a |
| Go `mime/multipart` | errors | Strict, HTTP-oriented | | | Error |
| Go `enmime` | `(*Envelope, error)` | I/O errors; an unparseable media type; child failures unless `SkipMalformedParts` is set | Continuations, unclosed boundary | Per-part `Errors{Name, Detail, Severe}`, where Severe means "a portion of the message was lost" | **Flatten** at depth; **error** at part count |
| Apache mime4j | throws `MimeException` | Lenient by default; `setStrictParsing` makes every event throw | | `DecodeMonitor` events | **Error** (all limits; profiles STRICT, DEFAULT and PERMISSIVE) |
| postal-mime | throws `PostalMimeError` | Only an invalid input *type* or options | All content | None | **Error** (closed set of codes) |
| mailparser (nodemailer) | throws | Only null input | All content | `textConversionError` | **Error** (EMAXLEN) |
| Dovecot lib-mail | n/a | Cannot reject content (only I/O errors) | Everything | Flags (`HAS_NULS`, OVERFLOW) | **Flatten or truncate** |
| Thunderbird JSMime | n/a | Never fails | Everything | None | n/a |

**What they agree on.** Malformed mail that can be recovered is recovered,
and the modern parsers record what they recovered from. Every maintained
parser does this; the only strict-by-default one is abandoned. Strictness,
where offered, is an opt-in layer (Python `raise_on_defect`, mime4j strict
mode, the MimeKit compliance logger) rather than a separate parser.

**Where they split.**

- Input that is *not a message at all* (empty, or no header block). The
  newest redesigns reject it: mail-parser 1.0 changed to rejecting it, and
  MimeKit 5 rejects it, as does Go. Python, Dovecot and postal-mime accept it
  as a body without headers.
- Limits. Archive and IMAP stores (Dovecot, Stalwart, MimeKit) flatten the
  over-limit content to an opaque leaf. Pipelines and filters (mime4j,
  postal-mime, mailparser) raise an error.

## 2. Charset labels

| Library | `iso-8859-1` / `latin1` | `us-ascii` with 8-bit bytes | Unknown label | Raw 8-bit bytes in headers |
|---|---|---|---|---|
| mail-parser 1.0 | windows-1252 (**switched in 1.0**, issue #131: `=80` should be €) | windows-1252 | lossy UTF-8 plus UNKNOWN_CHARSET | lossy UTF-8 |
| mailparse (`encoding_rs`) | windows-1252 | windows-1252 | ASCII plus U+FFFD; encoded-word left literal | UTF-8, else strict Latin-1 |
| Thunderbird (`encoding_rs`) | windows-1252 | windows-1252 | raw bytes passed through; encoded-word left literal | UTF-8, else the part's charset |
| postal-mime (TextDecoder) | windows-1252 | windows-1252 | **UTF-8 if valid, else windows-1252** | UTF-8, else windows-1252 |
| libmime / mailparser | windows-1252 | windows-1252 (libmime) | UTF-8 | lossy UTF-8 |
| enmime | strict for `iso-8859-1`, windows-1252 for `latin1` (inconsistent) | windows-1252 | raw bytes plus a warning; **chardet overrides labels** | raw |
| Python `email` | strict | U+FFFD | **raises `LookupError`** | U+FFFD |
| MimeKit | strict | replacement character | UTF-8 if valid, else Latin-1 | UTF-8 if valid, else Latin-1 |
| Go stdlib | strict | U+FFFD | error without a `CharsetReader` | n/a |
| Dovecot | strict (glibc iconv) | read as UTF-8 | lossy UTF-8 | lossy UTF-8 |

**Standards.**

- **WHATWG** maps `iso-8859-1`, `latin1` and `us-ascii` to windows-1252, for
  web compatibility. `iso-8859-15` stays its own strict encoding.
- **RFCs.** No RFC permits a receiver to treat iso-8859-1 as windows-1252.
  IANA lists them as separate charsets. RFC 2046 and RFC 2049 say to treat an
  unknown charset as octet-stream, and RFC 6657 §5 warns that guessing a
  charset has security implications.

**Override on valid UTF-8.** Only enmime overrides a *declared* single-byte
label when the bytes are valid UTF-8, using chardet. The others try UTF-8 only
when the charset is absent or unknown.

**Why windows-1252 is safe.** Strict ISO-8859-1 and windows-1252 give the same
result except for bytes 0x80–0x9F. Strict decoding turns those into C1
control characters, which essentially never appear on purpose in text. So
windows-1252 is lossless for real Latin-1 and recovers €, ’, “, –, … in the
very common mislabelled case.

## 3. Decisions (2026-11-12)

See the decision record in [assumptions.md](assumptions.md) once it has been
revised.
