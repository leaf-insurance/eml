"""Converts mime4j's expected parse trees (.xml) into eml's neutral rendering.

Usage: python3 -I dev/mime4j_expectations.py SOURCE_DIR DEST_DIR

For every NAME.msg with a NAME.xml in SOURCE_DIR, copies NAME.msg to
DEST_DIR and writes NAME.expected. The rendering is the one produced by
test/eml/corpus_mime4j_test.gleam:

    message
      header 3
      multipart
        preamble "text\r\n"
        part
          header 1
          body "Foo\r\n"
        epilogue "\r\nEpilogue\r\n"

Bodies are the raw (still transfer-encoded) bytes, escaped. Empty preambles
and epilogues are omitted. mime4j writes each text node as the opening tag,
a line break, then the exact content.
"""

import pathlib
import re
import shutil
import sys

TOKEN = re.compile(rb"<(/?)([a-z-]+)>")


def unescape(data):
    def char(match):
        ref = match.group(1)
        if ref.startswith(b"#x"):
            return bytes([int(ref[2:], 16)])
        if ref.startswith(b"#"):
            return bytes([int(ref[1:])])
        return {b"lt": b"<", b"gt": b">", b"amp": b"&", b"quot": b'"', b"apos": b"'"}[ref]

    return re.sub(rb"&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);", char, data)


def parse(data):
    """Returns the tree as nested (tag, children, text) tuples."""
    stack = [("root", [], b"")]
    pos = 0
    for match in TOKEN.finditer(data):
        text = data[pos : match.start()]
        pos = match.end()
        closing, tag = match.group(1), match.group(2).decode()
        if not closing:
            stack[-1][1].append(("#text", [], text))
            stack.append((tag, [], b""))
        else:
            node = stack.pop()
            assert node[0] == tag, (node[0], tag)
            content = b"".join(c[2] for c in node[1] if c[0] == "#text") + text
            children = [c for c in node[1] if c[0] != "#text"]
            stack[-1][1].append((tag, children, content))
    return [c for c in stack[0][1] if c[0] != "#text"][0]


def content(node):
    text = unescape(node[2])
    if text.startswith(b"\r\n"):
        return text[2:]
    if text.startswith(b"\n"):
        return text[1:]
    return text


def escape(data):
    out = []
    for byte in data:
        if byte == 0x5C:
            out.append("\\\\")
        elif byte == 0x22:
            out.append('\\"')
        elif byte == 0x0D:
            out.append("\\r")
        elif byte == 0x0A:
            out.append("\\n")
        elif byte == 0x09:
            out.append("\\t")
        elif 0x20 <= byte < 0x7F:
            out.append(chr(byte))
        else:
            out.append("\\x%02x" % byte)
    return '"' + "".join(out) + '"'


def render(node, indent, lines):
    pad = "  " * indent
    tag, children, _ = node
    if tag in ("message", "body-part"):
        lines.append(pad + ("message" if tag == "message" else "part"))
        for child in children:
            if child[0] == "header":
                fields = [c for c in child[1] if c[0] == "field"]
                lines.append(pad + "  header %d" % len(fields))
            else:
                render(child, indent + 1, lines)
    elif tag == "multipart":
        lines.append(pad + "multipart")
        for child in children:
            render(child, indent + 1, lines)
    elif tag in ("preamble", "epilogue"):
        data = content(node)
        if data:
            lines.append(pad + tag + " " + escape(data))
    elif tag == "body":
        lines.append(pad + "body " + escape(content(node)))
    else:
        raise ValueError(tag)


def main(source, dest):
    source, dest = pathlib.Path(source), pathlib.Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    for msg in sorted(source.glob("*.msg")):
        xml = msg.with_suffix(".xml")
        if not xml.exists():
            continue
        lines = []
        render(parse(xml.read_bytes()), 0, lines)
        shutil.copyfile(msg, dest / msg.name)
        (dest / (msg.stem + ".expected")).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
