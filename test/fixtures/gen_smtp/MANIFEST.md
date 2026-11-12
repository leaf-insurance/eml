# gen_smtp fixtures

Imported 2026-11-12 for the M1 corpus tests (assumptions.md §K.1, §L).

| | |
|---|---|
| Source | https://github.com/gen-smtp/gen_smtp |
| Version | tag `1.3.0`, commit `68ab11101a0710a13d39d73ff780dc9d76ffa15f` |
| Path | `test/fixtures/` (message files only; keys and certificates are not imported) |
| Licence | BSD-2-Clause, see [LICENSE](LICENSE) |
| Modifications | none |

These files are test data. No gen_smtp code is used (assumptions.md §K.7).

## What is asserted

`test/eml/corpus_gen_smtp_test.gleam` ports the structural assertions of
gen_smtp's `parse_example_mails_test_` (in `src/mimemail.erl`): part
counts, effective content types, and exact decoded bytes. Every file is
also checked for the tiling invariant.

Deliberate deviations from gen_smtp, where gen_smtp raised an error:

| File | gen_smtp | eml |
|---|---|---|
| `Plain-text-only-with-boundary-header.eml` | `missing_boundary` error | `Opaque(NoStartDelimiter)`, raw text kept |
| `rich-text-no-boundary.eml` | `no_boundary` error | `Opaque(NoBoundary)` |
| `rich-text-missing-last-boundary.eml` | `missing_last_boundary` error | two parts, `MissingCloseDelimiter` |
| `rich-text-broken-last-boundary.eml` | `missing_last_boundary` error | three parts (the final opening delimiter opens an empty part), `MissingCloseDelimiter` |

Since M2, the decoded Subject of `malformed-folded-multibyte-header.eml`,
the filenames in `utf-attachment-name.eml`, and the text of
`unicode-subject.eml` and `unicode-body.eml` are asserted too. `chinesemail`
(GB2312) and `shift-jismail` (Shift_JIS, ISO-2022-JP) use charsets that are
not built in: their text is reported as `UnsupportedCharset`, and the tests
check that a caller-supplied decoder is used instead.

## Files (SHA-256)

```
79d75239fa5ee37b8289d15a77680aa1a9b526f22d00aa47a62300c47a871594  chinesemail
aab6b126b826172cafffb813cbf58ee977933b030b4951296b7dbe60ff241072  html.eml
d33aa7c1585d7232207bc61cdf342c5ed4e8e52db59da746260aad4f0792f76c  image-and-text-attachments.eml
e629214bafe755df09326454c3e9df9fd2bb773d973ce2eb4477061432a9c4d0  image-attachment-only.eml
453da48564047d8c2db7db86c3b67dbee3c5b9123a929082624b07c5bba1e826  malformed-folded-multibyte-header.eml
8ee03180c2fcddb5ae612feb48eeb7b52397f339c5422b81b741b57ccf8258a2  message-as-attachment.eml
36ecc6735a5d143afee8ffc00573b4949094a1a0de3b61798b6ecf177bc66410  message-image-text-attachments.eml
ee4c6080580d0ec9079b4369e1fe140cedffeb0005e40dc5b63e313d81c7c515  message-text-html-attachment.eml
be0eb7c1ba8e1ab66ff8c77a6f23dfef74d6eb68040f0ed7ad36b354c5b62ea8  outlook-2007.eml
f84ac57bcba8952f51c36deb82676c7207cf4aba08f89d2d15af795e90711075  plain-text-and-two-identical-attachments.eml
b6cf96fa7347737e47b36bf4e0a5866b7a49a0d9e31f02238732ff44f5c93495  Plain-text-only.eml
77e9f0e740a906bb0ae189d6b0e5ec27dbad9be36e4f2cadda06490ffd988061  Plain-text-only-no-content-type.eml
890e21f060a3f5fefa3c30a8d31666eca6214adebda39ec4f951718ae1fcaae7  Plain-text-only-no-MIME.eml
3b266517ce0fe68d0649afb38b247ff838172778db3dc4779083b7774b384e84  Plain-text-only-with-boundary-header.eml
1c5d48dcf1447fe94b2143751ff30c21ecde7a82d4e2045f04d8f286129a7aa4  python-smtp-lib.eml
5ec1dea5cd6b90b9e95079bd9294db9335b0fe7600e708907620a385dc07489b  rich-text-bad-boundary.eml
2998a22ccced4f5452848a988a34de6edf5203447f23f4bf48ab54e9a864fca8  rich-text-broken-last-boundary.eml
ab75ec0bbe4feef082f00b411cd84229ff100cc073a4daf899e74ea99092d717  rich-text.eml
698a79036d1c79e904073c6f8d30862a9ad4183b0081cea354f0ceb8c2e2165b  rich-text-missing-first-boundary.eml
4053e0da0bdf1cd61f259848a1892380e03c34c6bdf3091bf8a8b969e14f7db1  rich-text-missing-last-boundary.eml
756f5334d8f987cfbee140b198baf8e77eeecbe891ed178fad7a7a86571da6e1  rich-text-no-boundary.eml
75f6eff4e2ca6c89afc208a9276c1178adea275f9cc18c5cef27a113bf7146c6  rich-text-no-MIME.eml
54950b8348ffc5080734ef51acb442f68deeee77c659a75dae8abafffcef390d  rich-text-no-text-contenttype.eml
e87788546a16e815fb5788aa3b63de34e0c9baea8c2ac0d51fb46ba3966dcd09  shift-jismail
2cb91b5de7369353b853d18e8d361512bcc1506187fc98805f7acff642a96b6a  testcase1
3a98ea3e74e829c3a35dd05a24eb59b84c0e0c3abf0f5125574dde739987b6fb  testcase2
43d823247975d2ac59b26aa007e592dfb4f2f6d023a5af897176c0010a126919  text-attachment-only.eml
90952cfd21d5fd9c0124e66e787259ca23beac937b2942ac8bbfa8ec67fe2ba3  the-gamut.eml
74f864fdfb6138bf3b1a7c619a1f07e03dce096751095cadafaf7ff9fc64bd09  unicode-body.eml
fcb5b3409e48d49b432121b9b7463f59824ae5844888fa4646fa736b48be1525  unicode-subject.eml
c3c55b2236bb1a4f956fc3345e4caa0c988ffc869f1d999836a4125fbf694d4f  utf-attachment-name.eml
```
