# Calls eml from Elixir through the compiled Erlang modules, and walks the
# tree. Run after `gleam build` with:
#
#     elixir -pa "build/dev/erlang/*/ebin" test/elixir_smoke/smoke.exs

input = """
From: =?UTF-8?Q?J=C3=B8rgen?= <jorgen@example.com>\r
Subject: =?UTF-8?Q?Bl=C3=A5b=C3=A6r?= smoke test\r
Content-Type: multipart/mixed; boundary=b\r
\r
--b\r
Content-Type: text/plain; charset=utf-8\r
\r
Hej verden\r
--b\r
Content-Type: application/pdf\r
Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r
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
{:single, " =?UTF-8?Q?Bl=C3=A5b=C3=A6r?= smoke test"} = :eml.header(root, "subject")

# Milestone 2: decoded text, addresses, filenames and body roles.
{:single, "Blåbær smoke test"} = :eml.subject(root)
{:single, [{:individual, {:mailbox, {:some, "Jørgen"}, "jorgen", {:some, "example.com"}}}]} =
  :eml.from(root)
{{:ok, "Hej verden"}, []} = :eml.decode_text(text)
{:some, "résumé.pdf"} = :eml.filename(pdf)
"résumé.pdf" = :"eml@filename".safe("../résumé.pdf")
{:bodies, [^text], [^text], [^pdf]} = :eml.bodies(message)
{:ok, _} = :eml.validate(message, :data_loss)

# Errors are atoms or tagged tuples.
{:error, :empty_input} = :eml.parse("")
{:error, :no_header_block} = :eml.parse("garbage\nmore")

options = :eml.default_options() |> :eml.with_max_parts(1)
{:error, {:limit_exceeded, :max_parts}} = :eml.parse_with(input, options)

IO.puts("elixir smoke test passed")
