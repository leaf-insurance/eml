# eml

A robust, pure Gleam parser for MIME email (`.eml`) messages. It runs on
Erlang and JavaScript, and has no native dependencies.

```gleam
import eml
import eml/filename
import gleam/list
import gleam/option

pub fn summary(bytes: BitArray) {
  let assert Ok(message) = eml.parse(bytes)
  let root = eml.root(message)
  let subject = eml.subject(root)
  let bodies = eml.bodies(message)
  // The text body: decoded with its charset.
  let text = list.map(bodies.text, fn(part) { eml.decode_text(part).0 })
  // Attachments: a suggested file name and the decoded bytes.
  let attachments =
    list.map(bodies.attachments, fn(part) {
      let name = option.unwrap(eml.filename(part), "attachment")
      #(filename.safe(name), eml.decode_body(part).0)
    })
  #(subject, text, attachments)
}
```

## Principles

- **Malformed mail still parses.** `parse` only fails when the input is not
  a message at all (`EmptyInput`, `NoHeaderBlock`, `NotByteAligned`) or
  exceeds a configured limit (`LimitExceeded`). Every recovery from broken
  input is recorded as a diagnostic with a severity of `Info`, `Warning` or
  `DataLoss`.
- **No bytes are lost.** The parsed message keeps the original input. Its
  segments tile the input exactly, 8-bit bytes pass through untouched, and
  empty parts are kept.
- **One defined answer per input.** The recovery rules are written down as
  decision tables in [docs/assumptions.md](docs/assumptions.md), and tested
  case by case.
- **Linear time on both targets.** Every loop is self-recursive, so it
  compiles to a loop on JavaScript, and doubling tests check the growth.

## Status

Milestones 1 and 2 are done:

- framing (CRLF, LF and CR line endings, BOM, mbox `From ` line), header
  blocks kept losslessly, the MIME tree, and base64 and quoted-printable
  decoding;
- charsets: every encoding of the WHATWG Encoding Standard, through the
  pure Gleam `text_encoding` package: UTF-8, UTF-16, the
  28 single-byte encodings, and the Chinese, Japanese and Korean encodings;
  a caller-supplied decoder can handle others (UTF-7, EBCDIC, ...);
- header text with RFC 2047 encoded-words (`eml.subject`,
  `eml.header_text`);
- addresses (`eml.from`, `eml.addresses`, `eml/address`);
- filenames with RFC 2231 and RFC 2047 (`eml.filename`), and safe file
  names (`eml/filename`);
- body and attachment roles, as in JMAP (`eml.bodies`);
- dates (`eml.date`, `eml/date`), message IDs (`eml.message_id`,
  `eml.in_reply_to`, `eml.references`), and format=flowed text
  (`eml.unflow`);
- `eml.diagnose` and `eml.validate`.

Milestone 3 also adds coverage-guided fuzzing.

## Development

```sh
nix develop   # or direnv; provides Gleam, Erlang/OTP, Node and Elixir
gleam test
gleam test --target javascript
gleam build && elixir -pa "build/dev/erlang/*/ebin" test/elixir_smoke/smoke.exs
```

The tests include fixtures from gen_smtp and Apache mime4j, with their
licences and import manifests in `test/fixtures/`.

Design documents:

- [docs/research.md](docs/research.md): RFCs, corpora and tooling.
- [docs/research-error-model-and-charsets.md](docs/research-error-model-and-charsets.md):
  how other parsers handle errors and charsets.
- [docs/assumptions.md](docs/assumptions.md): the specification and
  decisions.
- [docs/reviews/](docs/reviews/): adversarial reviews of the design.
