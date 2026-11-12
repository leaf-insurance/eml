# mime4j fixtures

Imported 2026-11-12 for the M1 structural corpus tests (assumptions.md §K.1,
§L).

| | |
|---|---|
| Source | https://github.com/apache/james-mime4j |
| Commit | `a3a9ec2e578e5fd05bf4bbb58e904237f09e9cb5` |
| Paths | `core/src/test/resources/testmsgs/` (32 messages), `core/src/test/resources/mimetools-testmsgs/` (48 messages) |
| Licence | Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). The `mimetools-testmsgs` messages come from the MIME-tools Perl library (Eryq and ZeeGee Software Inc.) under the Artistic License, see [mimetools-testmsgs/ARTISTIC-LICENSE.txt](mimetools-testmsgs/ARTISTIC-LICENSE.txt). |
| Modifications | The `.msg` files are unmodified. mime4j's expected trees (`.xml`) are not copied; `NAME.expected` is generated from each by `dev/mime4j_expectations.py`. |

## What is asserted

`test/eml/corpus_mime4j_test.gleam` renders eml's tree for each message:
nesting, header field counts, and the exact raw bytes of every body,
preamble and epilogue. It compares the rendering with `NAME.expected`. A
base64 or quoted-printable `message/rfc822` is rendered through
`parse_embedded`, since mime4j decodes those and recurses.

72 of the 80 messages match mime4j exactly. For the other 8, eml deliberately
differs, and `NAME.eml.expected` holds eml's rendering:

| Message | mime4j | eml | Why |
|---|---|---|---|
| `testmsgs/basic-plain-with-bad-header-separator` | Drops the paragraph after a `SP CRLF` separator | Keeps it as body | A whitespace-only line is folding (RFC 7103 §7.3); the body starts at the first line that is not a header (§D.3) |
| `mimetools-testmsgs/hdr-fakeout` | Empty body | Keeps the text as body | Same rule |
| `testmsgs/malformedHeaderStartsBody-nocrlfcrlf` | The body starts at the invalid line (its `malformedHeaderStartsBody` mode) | The invalid line is an anomaly because a field follows (§D.3) | eml matches mime4j's default mode, `malformedHeader-nocrlfcrlf` |
| `testmsgs/malformedHeader-noheader`, `testmsgs/malformedHeaderStartsBody-noheader` | A message with no headers | `NoHeaderBlock` error | Owner decision (§B.1) |
| `testmsgs/missing-boundary`, `testmsgs/missing-inner-boundary`, `mimetools-testmsgs/badbound` | A multipart with only a preamble | `Opaque(NoStartDelimiter)` with the same bytes | §E.3 row 3 |

## Files (SHA-256)

```
b4f2d622324f8f8883e66642ed5f369ae770bd80293bfea99fa9e8a8321c4eae  testmsgs/bad-newlines-multiple-parts-base64.msg
7f5a045ad74e3720af250ff784d7a39e66b6d5cd7cac553baa36dc076218c4eb  testmsgs/bad-newlines-multiple-parts.msg
f720c483a05dc9237e0222f5203332dc016beb0601a97597504d8fac1dbc0f1d  testmsgs/base64encoded-rfc822message.msg
ece666871cd9ac00c897aaa396243af3ff9b4500fdabc2de4c9263a4152703f6  testmsgs/base64encoded-rfc822message-nested.msg
5e48e3b1dbd9955ce25483e28f299756fbdc5af9580102d7f2818a8cca7ab288  testmsgs/base64-encoded-text.msg
0a70fa67b87c1ecd228d6217504b8c9dc95360ebad5cf74f27bc00e37fc7a43d  testmsgs/basic-plain.msg
10df8e9b7d89fe529dff19495d35f13ab9a4e8515917f18c0138ee90bd356f3b  testmsgs/basic-plain-very-long-lines.msg
f600a3a872121568b3cd63766791505c2cd5ac9ba2c34a054a63fac8f9275539  testmsgs/basic-plain-with-bad-header-separator.msg
f672cc0a4628a69c21eef243e94c2a3ec4ea58eb1d3a87ca20b1fce56447fdda  testmsgs/boundary-name-clash.msg
8081bf7ec6e81ab7f5ac001e8430e539738aab9cd35392552044593e47c6b895  testmsgs/ending-boundaries.msg
f880bbcd8153b1cc2e9437137e19bf483a25d0eb85fef9aabc9c39c0016b55ed  testmsgs/example.msg
8b87c1d4e38af44ae155c66652e26aac8d220093ea8ce503aa102f60bbe2619f  testmsgs/intermediate-boundaries.msg
5398da5a1c16270e0293850e01d4da68a3caf47e4f494ba30cd74954ddfeed68  testmsgs/malformedHeader-nocrlfcrlf.msg
823e7dfc212abca9dbfab40eb2e632815cd80565c26b8a46cf07dc00fb304830  testmsgs/malformedHeader-noheader.msg
5398da5a1c16270e0293850e01d4da68a3caf47e4f494ba30cd74954ddfeed68  testmsgs/malformedHeaderStartsBody-nocrlfcrlf.msg
823e7dfc212abca9dbfab40eb2e632815cd80565c26b8a46cf07dc00fb304830  testmsgs/malformedHeaderStartsBody-noheader.msg
7ec45319b2baf77e586564a82c60dc7dceb66ec706406491015759e01f668da2  testmsgs/misplaced-boundary.msg
9a83ca6716c30a9b7eda935f0104e867c6b3a7f9f660b472f2a7d6accfbccaef  testmsgs/missing-boundary.msg
0a85a5d7b4225dad2313385a7b72b638fcff36aec6b02ad6165e93240e3da993  testmsgs/missing-inner-boundary.msg
2638e68d3ed27e5c04fce0f5b6c7cb575c04f04ef4ce1d9bf94199b1c5a250fb  testmsgs/missing-inner-start-boundary.msg
2d7f3c24656eb3b98ccc20643a52e883feee7e2bc34d3a1f913f75c3d2f6e82c  testmsgs/multipartdigestnestedemptyparts.msg
9f1d46c75e4083f8066c1e95ea8af7df9d3bf7ce8582d4bf5bf4f9bccb69ed3d  testmsgs/multipartemptypart.msg
9ac5b1a1a9203c8e2d87b5dbbcab9da824a2aee96bfb21cc23ac0b0a36f1a6d0  testmsgs/multipartnestedemptyparts.msg
860aaa3141a6653308694ded78686217d4f554e8c29b2868f99bfced82770468  testmsgs/multipartnestedemptypartsnorfc822.msg
80d33f6b106dbccc103ebeff21607b5345204863e0b54b9c7ff9343eeb1a4dbd  testmsgs/multipartnopart.msg
7f795531a26de68680c077f89d6bdc6cbb4797ee43d3fa5ca1ca86c152801a66  testmsgs/obsolete.msg
bcec0d1d4ebe0e1b596a1584b2d5da4890aca371f7ec33c5d0dd6c855baeed61  testmsgs/qp-body.msg
f5cf5892d63298864b1b2164bc6c90dcd8afba7aea3049dc19a2535d8b88c994  testmsgs/russian-headers.msg
46da0c106d2dd6bb9e4b63e079a367ddc1a2bd472869a662d86da24918e3499f  testmsgs/simple-attachment.msg
4577772774e40ad57078f363106e8c7f30c5be1f427403d8c855e9c0f2d911c4  testmsgs/very-long-boundary.msg
f915fe657d083d16f5d908a4e4a2acdafe3855249976becb10501786c3a3c17d  testmsgs/very-very-long-boundary.msg
55a7121527d0fb90daa41e7dd700e90697c6c500f71708c22fb22ab9fcf5951d  testmsgs/weird-boundary.msg
b14d5dbd9fb4a7cdd3e58a91a73f5e7e1fd9c267a182be27bc9c2b73a84f1d9a  mimetools-testmsgs/2002_06_12_doublebound.msg
f4ba0cb759f7460653ccda646f94f3171cddbdad4c86545f60bae30902b5400e  mimetools-testmsgs/ak-0696.msg
81e18d39f5e8bd8b1d3b65118dfbaf4440e10a78a81e712c69eace16bb7f6008  mimetools-testmsgs/attachment-filename-encoding-Latin1.msg
b8352f8ad84e7c090b4e1d42fc1f0012796653592c26c391887b09ac7af5b3b6  mimetools-testmsgs/attachment-filename-encoding-UTF8.msg
23b154e05e5c3ff0016d377123122db4db49341cb944de122c98eee483a41aa1  mimetools-testmsgs/badbound.msg
cc798266b0c5b0c7488aa3c9bb7ea3ed6f0b0aad7b21bf64796225fccfb55509  mimetools-testmsgs/badfile.msg
864312d205f7bef4e75c0831fea4961ecf4ab48b436d0f33202fd467843c2be6  mimetools-testmsgs/bluedot-postcard.msg
89cd117192754f5f6a0304d15f847713eebb4eaee3d238fb5a0eee4108380b37  mimetools-testmsgs/bluedot-simple.msg
ccd565f2880a65a78e546fbaf4385f0a80134fae2c9cf51c2e7b014f1d91d070  mimetools-testmsgs/double-bound.msg
163d356e57d6e30f6a11875b0f17f68621ff054bdf6a3dd70500211fdfe2fd32  mimetools-testmsgs/double-semicolon2.msg
0689af53870dc8bca8310ebab02b300c962bcdcfad2c609bd3180d5b39ba1381  mimetools-testmsgs/double-semicolon.msg
934a8d601889aa4cc5577494ae66b458435300737d715f10ac2eb15bfb3be560  mimetools-testmsgs/dup-names.msg
20e6784b3ff1861cb59abffc9f6b5171b8dd6f873ddbb5a8bd54a00feca6157b  mimetools-testmsgs/empty-preamble.msg
61d66d7f1eede81e365e84bec0942e9df985b34f0c37d651da3a5ba32adb8952  mimetools-testmsgs/frag.msg
205f674b26725f2156311f790545ea7b642512f016aa41b5e1eab91dc3105832  mimetools-testmsgs/german.msg
e064726482ec2306b2f2bc68f55b3250af11140333c1be7760c7454bbb29288a  mimetools-testmsgs/german-qp.msg
b593e372a4102b8c40a8cd80b25d62ffb65d44fd388df798fcea9829e46479c5  mimetools-testmsgs/hdr-fakeout.msg
ef8d6061a9b6ceecaa40f4b4c43ccc5d05461812567688bf838b6aa2deff6b6b  mimetools-testmsgs/infinite.msg
1bb0d03e94ae290f8724dec295ff15fbbd2dc06e8e7f6c1e71b7bb09baf9a6e1  mimetools-testmsgs/intl.msg
e7d1194f8dd3903c6e1969761f96453e880c6fdf36c95bddc5e331b48dc1986c  mimetools-testmsgs/jt-0498.msg
f6fd75111072684991e18dce2b302076c67c440273204a3efd204a17a7cddda7  mimetools-testmsgs/lennie.msg
24dd27cdc04c3ff7ee108be2b13aa8b256efe97b57effa1bfd9e64237d3676e8  mimetools-testmsgs/mp-msg-rfc822.msg
0d72744deeed6034c09726408a80866f5717139d679bb4f0b5f118bb5aee72a8  mimetools-testmsgs/multi-2evil.msg
e9327d8596ffe07c1f6dcb46f23b744ef451811e98dbbf4f53619080dd65febd  mimetools-testmsgs/multi-2gifs-base64.msg
66b07c90472b09f750a903efdba3e864c68cdc59277cc95d29ccb0dcbfced938  mimetools-testmsgs/multi-2gifs.msg
c8f7d2734daa81ce5dc7fad88a5e862fd88afdccb904aa8eff468ea38044bb7b  mimetools-testmsgs/multi-bad.msg
748e8f1be94aa30c91393f60f45482fc4cb01d006205ebabf2a7c0c2c66db4f4  mimetools-testmsgs/multi-badnames.msg
8af2ffc45f13338ac0da897ce175742b87d9eff968270e8fbe983134c06a52fb  mimetools-testmsgs/multi-clen.msg
4775a0c197b82f0a3062823c7364dce21fc7afb24675631bc8faba70b2b5e43f  mimetools-testmsgs/multi-digest.msg
aedc339c95ac204568896b547158b3b0629247c198815e118167a9a5fc2dd6d4  mimetools-testmsgs/multi-frag.msg
a4407c487a75cb7f7c5453b9060fb78e17272dcef9641f8adf88518256469aa4  mimetools-testmsgs/multi-igor2.msg
a4407c487a75cb7f7c5453b9060fb78e17272dcef9641f8adf88518256469aa4  mimetools-testmsgs/multi-igor.msg
2fd87bac32a2120e6071ce87594d41245bfa50c70a59178e6a9796cede7132b7  mimetools-testmsgs/multi-nested2.msg
f219cb7e86583ebcb1b721992c760d48acd9605df2b2e441cde73d08ab0bd4e8  mimetools-testmsgs/multi-nested3.msg
2fd87bac32a2120e6071ce87594d41245bfa50c70a59178e6a9796cede7132b7  mimetools-testmsgs/multi-nested.msg
224bda933003ed542d5166733f940d961b33ca53fc4d8e65849972cca2481963  mimetools-testmsgs/multi-simple.msg
27905c65071c0f7fdf21d19716dc49de54a5313a365f7d9f74c00569534d5045  mimetools-testmsgs/multi-weirdspace.msg
529461e57f41adc9012142983f90340c20d7ffcefc33eca1db8807cb9d0048e5  mimetools-testmsgs/not-mime.msg
bfb3f01907f176f922723bee161c76f1bf2bb40a4b33c65c11530dfddf20774a  mimetools-testmsgs/re-fwd.msg
13662648c3cc6a72b217b642e52e773bbbc3225ab5195878d889f2259a2645c1  mimetools-testmsgs/russian.msg
462bac47f449fc8860dc9192a9ba4b6dbb0b600563a274dc854d06ae40b1086d  mimetools-testmsgs/sig-uu.msg
11cdb687e9219f7e8d36ab79735466fbbc7e5ce449643f3846b5b3f2aafa898c  mimetools-testmsgs/simple.msg
1bae9714ec5c1339ef54a2ea7b3235759c6ca0c9517a5dadb16f97d937ff21c1  mimetools-testmsgs/ticket-60931.msg
cdfe4809041c1620ddf8574fa862841847ca2029efcb9e84bb5332c135065426  mimetools-testmsgs/twopart.msg
b650f2cd5e5115e6bf1b4b268c5f66e74a2bb25fe6320b2c229db161dcfdf863  mimetools-testmsgs/uu-junk.msg
96f65c60f684c71a20d9ad9e3d510cf50634ce029224335b801489c2cef4913a  mimetools-testmsgs/uu-junk-target.msg
0687259febf26f68e731aa6e9ec4f7839a6f5ad12dd39f8bb86fd9fb67977646  mimetools-testmsgs/uu-zeegee.msg
1f26a5026941e4388217dd45e72432ec5c6ab935436c176cdd91def8309d1f8b  mimetools-testmsgs/x-gzip64.msg
```
