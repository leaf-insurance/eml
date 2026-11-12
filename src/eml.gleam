//// A robust, pure Gleam parser for MIME email (`.eml`) messages.
////
//// ```gleam
//// case eml.parse(bytes) {
////   Ok(message) -> eml.body(eml.root(message))
////   Error(error) -> ...
//// }
//// ```
////
//// Parsing succeeds for any input that starts with a header block, however
//// malformed it is. Every recovery is recorded as a diagnostic (see
//// `eml/diagnostic`). The original bytes are always available.

import eml/diagnostic.{type Diagnostic, type Span, Span}
import eml/internal/base64
import eml/internal/parser.{type Node}
import eml/internal/quoted_printable
import eml/internal/structured.{slice}
import eml/mime.{
  type ContentType, type Header, type Lookup, type OpaqueReason, type ParseError,
  type Segment, type TransferEncoding,
}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A parsed message. It keeps the original input, which every entity and
/// span refers to. Note that keeping any part of a message keeps the whole
/// input alive.
pub opaque type Message {
  Message(source: BitArray, parsed: parser.Parsed)
}

/// A MIME entity: the message itself, a part of a multipart, or an embedded
/// message.
pub opaque type Entity {
  Entity(source: BitArray, node: Node)
}

/// The structure of an entity's body.
pub type Body {
  /// A body that is not interpreted structurally. Use `decode_body` to get
  /// its content.
  Leaf
  Multipart(
    boundary: BitArray,
    preamble: Span,
    parts: List(Entity),
    epilogue: Span,
  )
  /// An identity-encoded `message/rfc822` or `message/global`.
  Embedded(Entity)
  /// A body that could not be interpreted as its declared type.
  Opaque(reason: OpaqueReason)
}

pub opaque type Options {
  Options(limits: parser.Limits)
}

pub fn default_options() -> Options {
  Options(parser.Limits(
    max_depth: 64,
    max_parts: 10_000,
    max_header_bytes: 1_048_576,
    max_header_lines: 10_000,
    max_diagnostics: 1000,
  ))
}

/// The maximum nesting of multiparts and embedded messages. The root is at
/// depth 0. Negative values are treated as 0.
pub fn with_max_depth(options: Options, max: Int) -> Options {
  Options(parser.Limits(..options.limits, max_depth: non_negative(max)))
}

/// The maximum number of entities in a message, including the root.
pub fn with_max_parts(options: Options, max: Int) -> Options {
  Options(parser.Limits(..options.limits, max_parts: non_negative(max)))
}

/// The maximum size in bytes of one entity's header block.
pub fn with_max_header_bytes(options: Options, max: Int) -> Options {
  Options(parser.Limits(..options.limits, max_header_bytes: non_negative(max)))
}

/// The maximum number of lines in one entity's header block.
pub fn with_max_header_lines(options: Options, max: Int) -> Options {
  Options(parser.Limits(..options.limits, max_header_lines: non_negative(max)))
}

/// The maximum number of diagnostics recorded by `parse`. When it is
/// reached, a single `DiagnosticsTruncated` is recorded and the rest are
/// dropped. Exceeding it never fails a parse.
pub fn with_max_diagnostics(options: Options, max: Int) -> Options {
  Options(parser.Limits(..options.limits, max_diagnostics: non_negative(max)))
}

fn non_negative(n: Int) -> Int {
  case n < 0 {
    True -> 0
    False -> n
  }
}

pub fn parse(input: BitArray) -> Result(Message, ParseError) {
  parse_with(input, default_options())
}

pub fn parse_with(
  input: BitArray,
  options: Options,
) -> Result(Message, ParseError) {
  case parser.parse(input, options.limits) {
    Ok(parsed) -> Ok(Message(input, parsed))
    Error(error) -> Error(error)
  }
}

// ---------------------------------------------------------------------------
// Messages

/// The original input.
pub fn source(message: Message) -> BitArray {
  message.source
}

pub fn root(message: Message) -> Entity {
  Entity(message.source, message.parsed.root)
}

/// The diagnostics recorded while parsing, in source order. Diagnostics from
/// decoding are returned by `decode_body`.
pub fn diagnostics(message: Message) -> List(Diagnostic) {
  message.parsed.diagnostics
}

/// The mbox `From ` line that preceded the message, without its line break.
pub fn envelope_from(message: Message) -> Option(BitArray) {
  case message.parsed.envelope {
    Some(span) ->
      Some(trim_line_break(slice(message.source, span.start, span.end)))
    None -> None
  }
}

fn trim_line_break(line: BitArray) -> BitArray {
  let size = bit_array.byte_size(line)
  case slice(line, size - 2, size), slice(line, size - 1, size) {
    <<"\r\n">>, _ -> slice(line, 0, size - 2)
    _, <<"\n">> | _, <<"\r">> -> slice(line, 0, size - 1)
    _, _ -> line
  }
}

/// The entity at a path: the root is `[]`, the children of a multipart are
/// numbered from 0, and the child of an embedded message is 0.
pub fn part_at(message: Message, path: List(Int)) -> Result(Entity, Nil) {
  find(root(message), path)
}

fn find(entity: Entity, path: List(Int)) -> Result(Entity, Nil) {
  case path, body(entity) {
    [], _ -> Ok(entity)
    [index, ..path], Multipart(parts:, ..) ->
      case list.drop(parts, index) {
        [part, ..] if index >= 0 -> find(part, path)
        _ -> Error(Nil)
      }
    [0, ..path], Embedded(child) -> find(child, path)
    _, _ -> Error(Nil)
  }
}

/// The segments that tile the source, in order. Concatenating their bytes
/// reproduces the input exactly.
pub fn segments(message: Message) -> List(Segment) {
  let acc = case message.parsed.bom {
    Some(span) -> [mime.Segment(mime.BomSegment, span, [])]
    None -> []
  }
  let acc = case message.parsed.envelope {
    Some(span) -> [mime.Segment(mime.EnvelopeSegment, span, []), ..acc]
    None -> acc
  }
  node_segments(message.parsed.root, acc)
  |> list.filter(fn(segment) { segment.span.end > segment.span.start })
  |> list.reverse
}

fn node_segments(node: Node, acc: List(Segment)) -> List(Segment) {
  let path = node.path
  let segment = fn(acc, kind, span) { [mime.Segment(kind, span, path), ..acc] }
  let acc =
    list.fold(node.lines, acc, fn(acc, line) {
      case line {
        parser.FieldLine(span:, ..) -> segment(acc, mime.FieldSegment, span)
        parser.AnomalyLine(span) -> segment(acc, mime.AnomalySegment, span)
      }
    })
  let acc = case node.separator {
    Some(span) -> segment(acc, mime.SeparatorSegment, span)
    None -> acc
  }
  case node.body {
    parser.NodeLeaf | parser.NodeOpaque(_) ->
      segment(acc, mime.BodySegment, node.body_span)
    parser.NodeEmbedded(child) -> node_segments(child, acc)
    parser.NodeMultipart(preamble:, delimiters:, parts:, epilogue:, ..) -> {
      let acc = segment(acc, mime.PreambleSegment, preamble)
      let #(acc, delimiters) =
        list.fold(parts, #(acc, delimiters), fn(state, part) {
          let #(acc, delimiters) = state
          case delimiters {
            [delimiter, ..delimiters] -> #(
              node_segments(
                part,
                segment(acc, mime.DelimiterSegment, delimiter),
              ),
              delimiters,
            )
            [] -> #(node_segments(part, acc), [])
          }
        })
      let acc =
        list.fold(delimiters, acc, fn(acc, delimiter) {
          segment(acc, mime.DelimiterSegment, delimiter)
        })
      segment(acc, mime.EpilogueSegment, epilogue)
    }
  }
}

// ---------------------------------------------------------------------------
// Entities

pub fn path(entity: Entity) -> List(Int) {
  entity.node.path
}

/// The byte range of the whole entity in the source.
pub fn span(entity: Entity) -> Span {
  entity.node.span
}

/// The header fields in order, with their raw values.
pub fn headers(entity: Entity) -> List(Header) {
  list.filter_map(entity.node.lines, fn(line) {
    case line {
      parser.FieldLine(name:, value_span:, span:, ..) ->
        Ok(mime.Header(
          name:,
          value: slice(entity.source, value_span.start, value_span.end),
          span:,
        ))
      parser.AnomalyLine(_) -> Error(Nil)
    }
  })
}

/// Lines in the header block that are not header fields (§D.3), as raw bytes.
pub fn anomalies(entity: Entity) -> List(BitArray) {
  list.filter_map(entity.node.lines, fn(line) {
    case line {
      parser.AnomalyLine(span) -> Ok(slice(entity.source, span.start, span.end))
      parser.FieldLine(..) -> Error(Nil)
    }
  })
}

/// The unfolded values of every field with this name (compared without
/// regard to ASCII case).
pub fn header_values(entity: Entity, name: String) -> List(BitArray) {
  let name = string.lowercase(name)
  headers(entity)
  |> list.filter(fn(header) { string.lowercase(header.name) == name })
  |> list.map(fn(header) { structured.unfold(header.value) })
}

/// Looks up a field that should occur at most once.
pub fn header(entity: Entity, name: String) -> Lookup(BitArray) {
  case header_values(entity, name) {
    [] -> mime.Missing
    [value] -> mime.Single(value)
    values -> mime.Multiple(values)
  }
}

/// The effective content type: the parsed first Content-Type field, or the
/// RFC default when it is absent or invalid.
pub fn content_type(entity: Entity) -> ContentType {
  entity.node.content_type
}

/// The effective transfer encoding. It is always identity for multiparts.
pub fn transfer_encoding(entity: Entity) -> TransferEncoding {
  entity.node.encoding
}

pub fn body(entity: Entity) -> Body {
  let wrap = fn(node) { Entity(entity.source, node) }
  case entity.node.body {
    parser.NodeLeaf -> Leaf
    parser.NodeMultipart(boundary:, preamble:, parts:, epilogue:, ..) ->
      Multipart(boundary:, preamble:, parts: list.map(parts, wrap), epilogue:)
    parser.NodeEmbedded(child) -> Embedded(wrap(child))
    parser.NodeOpaque(reason) -> Opaque(reason)
  }
}

/// The preamble of a multipart: the bytes before its first delimiter. It is
/// empty for other bodies.
pub fn preamble(entity: Entity) -> BitArray {
  case entity.node.body {
    parser.NodeMultipart(preamble:, ..) ->
      slice(entity.source, preamble.start, preamble.end)
    _ -> <<>>
  }
}

/// The epilogue of a multipart: the bytes after its close delimiter. It is
/// empty for other bodies.
pub fn epilogue(entity: Entity) -> BitArray {
  case entity.node.body {
    parser.NodeMultipart(epilogue:, ..) ->
      slice(entity.source, epilogue.start, epilogue.end)
    _ -> <<>>
  }
}

/// The raw, still encoded, bytes of the body.
pub fn raw_body(entity: Entity) -> BitArray {
  let span = entity.node.body_span
  slice(entity.source, span.start, span.end)
}

/// The body with its transfer encoding removed, and the diagnostics found
/// while decoding. Identity and unknown encodings return the raw bytes.
pub fn decode_body(entity: Entity) -> #(BitArray, List(Diagnostic)) {
  let raw = raw_body(entity)
  let offset = entity.node.body_span.start
  let path = entity.node.path
  let #(bytes, kinds) = case entity.node.encoding {
    mime.Base64 -> base64.decode(raw, offset)
    mime.QuotedPrintable -> quoted_printable.decode(raw, offset)
    mime.Unknown(label) -> #(raw, [
      #(diagnostic.UnknownTransferEncoding(label), Some(Span(offset, offset))),
    ])
    mime.SevenBit | mime.EightBit | mime.Binary -> #(raw, [])
  }
  #(bytes, list.map(kinds, fn(kind) { diagnostic.new(kind.0, path, kind.1) }))
}

/// Parses the decoded body of an entity as a message of its own. This is how
/// a base64 or quoted-printable encoded `message/rfc822` is read. The new
/// message's source is the decoded body.
pub fn parse_embedded(
  entity: Entity,
  options: Options,
) -> Result(Message, ParseError) {
  let #(bytes, _) = decode_body(entity)
  parse_with(bytes, options)
}
