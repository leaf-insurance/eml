# eml

A robust, pure Gleam parser for MIME email (`.eml`) messages. It runs on
Erlang and JavaScript, and has no native dependencies.

```gleam
import eml
import gleam/list

pub fn attachments(bytes: BitArray) {
  let assert Ok(message) = eml.parse(bytes)
  case eml.body(eml.root(message)) {
    eml.Multipart(parts:, ..) ->
      list.map(parts, fn(part) {
        let #(content, _diagnostics) = eml.decode_body(part)
        #(eml.content_type(part), content)
      })
    _ -> []
  }
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

Milestone 1 is done:

- framing (CRLF, LF and CR line endings, BOM, mbox `From ` line);
- header blocks, kept losslessly;
- Content-Type and Content-Transfer-Encoding;
- the MIME tree;
- base64 and quoted-printable decoding.

Milestone 2 adds:

- decoded header text (RFC 2047);
- filenames (RFC 2231);
- charset decoding;
- addresses;
- helpers for choosing the text and HTML bodies and the attachments.

Until then, header values and decoded bodies are bytes.

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
