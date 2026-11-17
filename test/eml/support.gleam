//// Helpers shared by the parser tests.

import eml.{type Entity, type Message}
import eml/address
import eml/charset
import eml/date
import eml/diagnostic.{type Kind}
import eml/encoded_word
import eml/filename
import eml/flowed
import eml/internal/structured
import eml/message_id
import eml/mime
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}

/// Parses a message that must succeed, and checks the tiling invariant
/// (assumptions.md §C.1) on every parse.
pub fn parse(input: String) -> Message {
  let assert Ok(message) = eml.parse(<<input:utf8>>)
  assert_tiles(message)
  message
}

pub fn parse_bytes(input: BitArray) -> Result(Message, mime.ParseError) {
  case eml.parse(input) {
    Ok(message) -> {
      assert_tiles(message)
      Ok(message)
    }
    Error(error) -> Error(error)
  }
}

/// The segments are contiguous, start at 0, end at the source size, and
/// their bytes reproduce the source.
pub fn assert_tiles(message: Message) -> Nil {
  let source = eml.source(message)
  let end =
    list.fold(eml.segments(message), 0, fn(pos, segment) {
      assert segment.span.start == pos
      assert segment.span.end > segment.span.start
      segment.span.end
    })
  assert end == bit_array.byte_size(source)
  Nil
}

pub fn kinds(message: Message) -> List(Kind) {
  eml.diagnostics(message) |> list.map(fn(diagnostic) { diagnostic.kind })
}

pub fn root(input: String) -> Entity {
  eml.root(parse(input))
}

pub fn parts(entity: Entity) -> List(Entity) {
  let assert eml.Multipart(parts:, ..) = eml.body(entity)
  parts
}

pub fn decoded(entity: Entity) -> BitArray {
  eml.decode_body(entity).0
}

pub fn content_type(entity: Entity) -> String {
  let content_type = eml.content_type(entity)
  content_type.type_ <> "/" <> content_type.subtype
}

pub fn header_names(entity: Entity) -> List(String) {
  eml.headers(entity) |> list.map(fn(header) { header.name })
}

/// Parses arbitrary input and calls every accessor on the result, checking
/// the tiling invariant. The fuzz target (`dev/fuzz`) and the property tests
/// use it: it must not crash for any input.
pub fn exercise(input: BitArray) -> Nil {
  case parse_bytes(input) {
    Ok(message) -> {
      let _ = eml.diagnose(message)
      let _ = eml.bodies(message)
      walk_depth(eml.root(message), 3)
    }
    Error(_) -> Nil
  }
}

/// Visits every entity, decoding each body and header.
pub fn walk(entity: Entity) -> Nil {
  walk_depth(entity, 0)
}

/// `walk`, also parsing up to `embedded` levels of encoded `message/*`
/// parts with `eml.parse_embedded`. Only leaves are decoded, so that each
/// byte is decoded once however deeply it is nested.
fn walk_depth(entity: Entity, embedded: Int) -> Nil {
  let options = charset.default_options()
  let override = charset.with_utf8_override(options, True)
  list.each(eml.headers(entity), fn(header) {
    let value = structured.unfold(header.value)
    let _ = encoded_word.decode(value, options)
    let _ = encoded_word.decode(value, override)
    let _ = address.parse(value, options)
    let _ = message_id.parse(value)
    case date.parse(value) {
      Ok(date) -> {
        let _ = date.to_unix_seconds(date)
        Nil
      }
      Error(_) -> Nil
    }
  })
  case eml.filename(entity) {
    Some(name) -> {
      let _ = filename.safe(name)
      Nil
    }
    None -> Nil
  }
  case eml.body(entity) {
    eml.Multipart(parts:, ..) ->
      list.each(parts, fn(part) { walk_depth(part, embedded) })
    eml.Embedded(child) -> walk_depth(child, embedded)
    eml.Leaf | eml.Opaque(_) -> {
      decode_leaf(entity)
      case eml.content_type(entity).type_, embedded > 0 {
        "message", True ->
          case eml.parse_embedded(entity, eml.default_options()) {
            Ok(message) -> {
              assert_tiles(message)
              walk_depth(eml.root(message), embedded - 1)
            }
            Error(_) -> Nil
          }
        _, _ -> Nil
      }
    }
  }
}

fn decode_leaf(entity: Entity) -> Nil {
  let _ = eml.decode_body(entity)
  case eml.decode_text(entity) {
    #(Ok(text), _) -> {
      let _ = eml.unflow(entity, text)
      let _ = flowed.decode(text, False)
      let _ = flowed.decode(text, True)
      Nil
    }
    #(Error(_), _) -> Nil
  }
}
