//// Decoding `text/plain; format=flowed` (RFC 3676, assumptions.md §I).
////
//// A line that ends in a space is soft: the next line, at the same quote
//// depth, continues it. Space-stuffing is removed, the signature separator
//// `-- ` is never soft, and with `delsp=yes` the trailing space of a soft
//// line is deleted. A soft line followed by a line of another quote depth,
//// or by the signature separator, or by nothing, ends its paragraph. Quoted
//// lines are written with `>` for each level and one space before the
//// text. Line breaks keep their style (CRLF or LF).

import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/string

/// Joins the soft line breaks of decoded format=flowed text.
pub fn decode(text: String, delete_space: Bool) -> String {
  string.split(text, "\n")
  |> lines([])
  |> paragraphs(delete_space, Closed, [])
}

type Line {
  Line(depth: Int, content: String, break: String)
}

type Open {
  Closed
  /// A paragraph so far: its depth, its parts reversed, and the line break
  /// of its last line.
  Open(depth: Int, parts: List(String), break: String)
}

fn lines(raw: List(String), acc: List(Line)) -> List(Line) {
  case raw {
    [] -> list.reverse(acc)
    [last] ->
      case last {
        "" -> list.reverse(acc)
        _ -> list.reverse([line(last, ""), ..acc])
      }
    [first, ..rest] ->
      case string.ends_with(first, "\r") {
        True -> lines(rest, [line(drop_last(first), "\r\n"), ..acc])
        False -> lines(rest, [line(first, "\n"), ..acc])
      }
  }
}

fn line(text: String, break: String) -> Line {
  let #(depth, content) = quotes(text, 0)
  let content = case content {
    " " <> content -> content
    _ -> content
  }
  Line(depth:, content:, break:)
}

fn quotes(text: String, depth: Int) -> #(Int, String) {
  case text {
    ">" <> rest -> quotes(rest, depth + 1)
    _ -> #(depth, text)
  }
}

fn paragraphs(
  lines: List(Line),
  delete_space: Bool,
  open: Open,
  out: List(String),
) -> String {
  case lines, open {
    [], _ -> string.concat(list.reverse(close(open, out)))
    [line, ..], Open(depth:, ..)
      if depth != line.depth || line.content == "-- "
    -> paragraphs(lines, delete_space, Closed, close(open, out))
    [line, ..rest], _ -> {
      let parts = case open {
        Open(parts:, ..) -> parts
        Closed -> []
      }
      case string.ends_with(line.content, " ") && line.content != "-- " {
        True -> {
          let content = case delete_space {
            True -> drop_last(line.content)
            False -> line.content
          }
          let open = Open(line.depth, [content, ..parts], line.break)
          paragraphs(rest, delete_space, open, out)
        }
        False -> {
          let open = Open(line.depth, [line.content, ..parts], line.break)
          paragraphs(rest, delete_space, Closed, close(open, out))
        }
      }
    }
  }
}

fn close(open: Open, out: List(String)) -> List(String) {
  case open {
    Closed -> out
    Open(depth:, parts:, break:) -> {
      let text = string.concat(list.reverse(parts))
      let prefix = case depth, text {
        0, _ -> ""
        _, "" -> string.repeat(">", depth)
        _, _ -> string.repeat(">", depth) <> " "
      }
      [break, text, prefix, ..out]
    }
  }
}

/// Drops the last byte of text that ends in an ASCII character.
/// `string.drop_end` would drop a whole grapheme cluster.
fn drop_last(text: String) -> String {
  let bits = <<text:utf8>>
  let assert Ok(bits) = bit_array.slice(bits, 0, bit_array.byte_size(bits) - 1)
  let assert Ok(text) = utf8.to_string(bits)
  text
}
