//// The mime4j structural test messages (test/fixtures/mime4j/MANIFEST.md).
////
//// Each `NAME.msg` is parsed and rendered in the neutral format written by
//// `dev/mime4j_expectations.py`, and compared with `NAME.expected`, which
//// was converted from mime4j's own expected tree. Where eml deliberately
//// differs, `NAME.eml.expected` holds eml's expected rendering instead, and
//// the manifest says why.

import eml.{type Entity}
import eml/support
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import simplifile

const root_dir = "test/fixtures/mime4j/"

const actual_dir = "build/mime4j-actual/"

fn render_message(entity: Entity, indent: Int, lines: List(String)) {
  let lines = [pad(indent) <> "message", ..lines]
  render_entity(entity, indent, lines)
}

fn render_entity(
  entity: Entity,
  indent: Int,
  lines: List(String),
) -> List(String) {
  let lines = [
    pad(indent + 1)
      <> "header "
      <> int.to_string(list.length(eml.headers(entity))),
    ..lines
  ]
  case eml.body(entity) {
    eml.Multipart(parts:, ..) -> {
      let lines = [pad(indent + 1) <> "multipart", ..lines]
      let lines = optional(lines, indent + 2, "preamble", eml.preamble(entity))
      let lines =
        list.fold(parts, lines, fn(lines, part) {
          render_entity(part, indent + 2, [pad(indent + 2) <> "part", ..lines])
        })
      optional(lines, indent + 2, "epilogue", eml.epilogue(entity))
    }
    eml.Embedded(child) -> render_message(child, indent + 1, lines)
    eml.Leaf | eml.Opaque(_) ->
      case is_encoded_message(entity) {
        True ->
          case eml.parse_embedded(entity, eml.default_options()) {
            Ok(message) -> render_message(eml.root(message), indent + 1, lines)
            Error(_) -> body(lines, indent, entity)
          }
        False -> body(lines, indent, entity)
      }
  }
}

fn is_encoded_message(entity: Entity) -> Bool {
  let content_type = eml.content_type(entity)
  content_type.type_ == "message"
  && { content_type.subtype == "rfc822" || content_type.subtype == "global" }
  && eml.body(entity) == eml.Leaf
}

fn body(lines: List(String), indent: Int, entity: Entity) -> List(String) {
  [pad(indent + 1) <> "body " <> escape(eml.raw_body(entity)), ..lines]
}

fn optional(
  lines: List(String),
  indent: Int,
  name: String,
  bytes: BitArray,
) -> List(String) {
  case bytes {
    <<>> -> lines
    _ -> [pad(indent) <> name <> " " <> escape(bytes), ..lines]
  }
}

fn pad(indent: Int) -> String {
  string.repeat("  ", indent)
}

fn escape(bytes: BitArray) -> String {
  "\"" <> escape_loop(bytes, []) <> "\""
}

fn escape_loop(bytes: BitArray, acc: List(String)) -> String {
  case bytes {
    <<c, rest:bytes>> -> {
      let piece = case c {
        0x5C -> "\\\\"
        0x22 -> "\\\""
        0x0D -> "\\r"
        0x0A -> "\\n"
        0x09 -> "\\t"
        _ if c >= 0x20 && c < 0x7F -> {
          let assert Ok(s) = bit_array.to_string(<<c>>)
          s
        }
        _ ->
          "\\x" <> string.pad_start(string.lowercase(int.to_base16(c)), 2, "0")
      }
      escape_loop(rest, [piece, ..acc])
    }
    _ -> acc |> list.reverse |> string.concat
  }
}

fn render(input: BitArray) -> String {
  case support.parse_bytes(input) {
    Ok(message) ->
      render_message(eml.root(message), 0, [])
      |> list.reverse
      |> list.map(fn(line) { line <> "\n" })
      |> string.concat
    Error(error) -> "error " <> string.inspect(error) <> "\n"
  }
}

fn check_set(set: String) -> List(String) {
  let dir = root_dir <> set <> "/"
  let assert Ok(files) = simplifile.read_directory(dir)
  let _ = simplifile.create_directory_all(actual_dir <> set)
  files
  |> list.filter(fn(file) { string.ends_with(file, ".msg") })
  |> list.sort(string.compare)
  |> list.filter_map(fn(file) {
    let name = string.drop_end(file, 4)
    let assert Ok(input) = simplifile.read_bits(dir <> file)
    let expected = case simplifile.read(dir <> name <> ".eml.expected") {
      Ok(expected) -> expected
      Error(_) -> {
        let assert Ok(expected) = simplifile.read(dir <> name <> ".expected")
        expected
      }
    }
    let actual = render(input)
    case actual == expected {
      True -> Error(Nil)
      False -> {
        let _ = simplifile.write(actual_dir <> set <> "/" <> name, actual)
        Ok(set <> "/" <> name)
      }
    }
  })
}

pub fn testmsgs_test() {
  assert check_set("testmsgs") == []
}

pub fn mimetools_testmsgs_test() {
  assert check_set("mimetools-testmsgs") == []
}
