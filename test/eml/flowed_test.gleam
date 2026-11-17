//// format=flowed (RFC 3676).

import eml
import eml/flowed

pub fn soft_breaks_test() {
  assert flowed.decode("Hello \r\nworld.\r\nNext\r\n", False)
    == "Hello world.\r\nNext\r\n"
  assert flowed.decode("a \nb \nc\n", False) == "a b c\n"
  // No final line break.
  assert flowed.decode("a \nb", False) == "a b"
  // A soft line at the end ends its paragraph.
  assert flowed.decode("a \n", False) == "a \n"
}

pub fn delete_space_test() {
  // RFC 3676 §4.2: with delsp=yes the space is not part of the text.
  assert flowed.decode("Ver \r\nyes.\r\n", True) == "Veryes.\r\n"
}

pub fn space_stuffing_test() {
  assert flowed.decode(" From here\r\n  two\r\n", False)
    == "From here\r\n two\r\n"
}

pub fn quotes_test() {
  assert flowed.decode(">> a \r\n>> b\r\n> c \r\n> d\r\n", False)
    == ">> a b\r\n> c d\r\n"
  // A change of quote depth ends a paragraph.
  assert flowed.decode("> a \r\nb\r\n", False) == "> a \r\nb\r\n"
  assert flowed.decode(">\r\n", False) == ">\r\n"
}

pub fn signature_separator_test() {
  assert flowed.decode("a \r\n-- \r\nsig\r\n", False) == "a \r\n-- \r\nsig\r\n"
}

pub fn unflow_test() {
  let text = fn(content_type) {
    let assert Ok(message) =
      eml.parse(<<
        "Content-Type: ",
        content_type:utf8,
        "\r\n\r\nVer \r\nyes\r\n",
      >>)
    let root = eml.root(message)
    let assert #(Ok(text), _) = eml.decode_text(root)
    eml.unflow(root, text)
  }
  assert text("text/plain; format=flowed") == "Ver yes\r\n"
  assert text("text/plain; format=Flowed; delsp=YES") == "Veryes\r\n"
  assert text("text/plain") == "Ver \r\nyes\r\n"
  assert text("text/html; format=flowed") == "Ver \r\nyes\r\n"
}
