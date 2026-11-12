# Calls eml from Elixir through the compiled Erlang modules, and walks the
# tree. Run after `gleam build` with:
#
#     elixir -pa "build/dev/erlang/*/ebin" test/elixir_smoke/smoke.exs

input = """
From: Alice <alice@example.com>\r
Subject: Smoke test\r
Content-Type: multipart/mixed; boundary=b\r
\r
--b\r
Content-Type: text/plain; charset=utf-8\r
\r
Hej verden\r
--b\r
Content-Type: application/pdf\r
Content-Transfer-Encoding: base64\r
\r
JVBERi0=\r
--b--\r
"""

{:ok, message} = :eml.parse(input)
root = :eml.root(message)

# Records are tagged tuples.
{:content_type, "multipart", "mixed", [{"boundary", "b"}]} = :eml.content_type(root)
{:multipart, "b", _preamble, [text, pdf], _epilogue} = :eml.body(root)

{"Hej verden", []} = :eml.decode_body(text)
{"%PDF-", []} = :eml.decode_body(pdf)
:base64 = :eml.transfer_encoding(pdf)
{:single, " Smoke test"} = :eml.header(root, "subject")

# Errors are atoms or tagged tuples.
{:error, :empty_input} = :eml.parse("")
{:error, :no_header_block} = :eml.parse("garbage\nmore")

options = :eml.default_options() |> :eml.with_max_parts(1)
{:error, {:limit_exceeded, :max_parts}} = :eml.parse_with(input, options)

IO.puts("elixir smoke test passed")
