//// Helpers shared by the parser tests.

import eml.{type Entity, type Message}
import eml/diagnostic.{type Kind}
import eml/mime
import gleam/bit_array
import gleam/list

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

/// Visits every entity, decoding each body.
pub fn walk(entity: Entity) -> Nil {
  let _ = eml.decode_body(entity)
  let _ = eml.headers(entity)
  case eml.body(entity) {
    eml.Multipart(parts:, ..) -> list.each(parts, walk)
    eml.Embedded(child) -> walk(child)
    eml.Leaf | eml.Opaque(_) -> Nil
  }
}
