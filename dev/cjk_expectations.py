"""Writes the expected decoded text of the gen_smtp CJK fixtures, decoded
independently of eml: the transfer encoding with Python's email package, the
charset with encoding_rs (text_encoding's dev/oracle).

Usage: python3 -I dev/cjk_expectations.py ORACLE

Writes test/fixtures/gen_smtp/<name>.text.expected (the first text/plain
part) and <name>.subject.expected (the Subject's encoded-words).
"""

import email
import email.header
import pathlib
import subprocess
import sys

FIXTURES = {"chinesemail": "GBK", "shift-jismail": "Shift_JIS"}
WORD_CHARSETS = {"gb2312": "GBK", "iso-2022-jp": "ISO-2022-JP"}


def decode(oracle, name, data):
    result = subprocess.run(
        [oracle], input="%s %s\n" % (name, data.hex()), capture_output=True,
        text=True, check=True,
    )
    text, errors = result.stdout.split()
    assert errors == "0", (name, data)
    return bytes.fromhex(text)


def main():
    oracle = sys.argv[1]
    root = pathlib.Path("test/fixtures/gen_smtp")
    for fixture, encoding in FIXTURES.items():
        message = email.message_from_bytes((root / fixture).read_bytes())
        part = next(p for p in message.walk() if p.get_content_type() == "text/plain")
        text = decode(oracle, encoding, part.get_payload(decode=True))
        (root / (fixture + ".text.expected")).write_bytes(text)
        subject = b"".join(
            decode(oracle, WORD_CHARSETS[charset.lower()], data)
            for data, charset in email.header.decode_header(message["Subject"])
        )
        (root / (fixture + ".subject.expected")).write_bytes(subject)


main()
