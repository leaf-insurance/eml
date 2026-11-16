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

import eml/address.{type Address}
import eml/charset
import eml/diagnostic.{type Diagnostic, type Span}
import eml/encoded_word
import eml/internal/base64
import eml/internal/parser.{type Node}
import eml/internal/quoted_printable
import eml/internal/structured.{slice}
import eml/internal/utf8
import eml/mime.{
  type ContentType, type Header, type Lookup, type OpaqueReason, type ParseError,
  type Segment, type TransferEncoding,
}
import eml/parameter
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
// Validation

/// Every diagnostic for a message, with the default charset options: those
/// from parsing, then, for the message and each embedded message, those from
/// decoding Subject and the address fields, and for each part those from
/// decoding its body (text bodies with their charset) and its file name.
/// This decodes every body, so it costs as much as reading all of them.
pub fn diagnose(message: Message) -> List(Diagnostic) {
  let root = root(message)
  list.flatten([
    diagnostics(message),
    header_diagnostics(root),
    decode_diagnostics(root),
  ])
}

const address_fields = [
  "from", "sender", "reply-to", "to", "cc", "bcc", "resent-from",
  "resent-sender", "resent-to", "resent-cc", "resent-bcc",
]

/// Diagnostics from the decoded header fields of a message.
fn header_diagnostics(entity: Entity) -> List(Diagnostic) {
  let options = charset.default_options()
  list.flat_map(headers(entity), fn(header) {
    let name = string.lowercase(header.name)
    let value = structured.unfold(header.value)
    let kinds = case name == "subject", list.contains(address_fields, name) {
      True, _ -> encoded_word.decode(value, options).1
      _, True -> address.parse(value, options).1
      False, False -> []
    }
    list.map(kinds, fn(kind) {
      diagnostic.new(kind, entity.node.path, Some(header.span))
    })
  })
}

fn decode_diagnostics(entity: Entity) -> List(Diagnostic) {
  case body(entity) {
    Multipart(parts:, ..) -> list.flat_map(parts, decode_diagnostics)
    Embedded(child) ->
      list.append(header_diagnostics(child), decode_diagnostics(child))
    Opaque(_) -> []
    Leaf -> {
      let decoded = case entity.node.content_type.type_ {
        "text" -> decode_text(entity).1
        _ -> decode_body(entity).1
      }
      let span = Some(entity.node.span)
      let filename =
        resolve_filename(entity, charset.default_options()).1
        |> list.map(fn(kind) { diagnostic.new(kind, entity.node.path, span) })
      list.append(decoded, filename)
    }
  }
}

/// Fails with the diagnostics at or above a severity, from `diagnose`. For
/// example, `validate(message, diagnostic.DataLoss)` accepts a message only
/// if all of its bodies, Subject and address fields could be interpreted as
/// declared. When `parse` dropped diagnostics because of
/// `with_max_diagnostics`, the `DiagnosticsTruncated` diagnostic carries
/// the worst severity among those dropped, so validation still fails.
pub fn validate(
  message: Message,
  at_least: diagnostic.Severity,
) -> Result(Message, List(Diagnostic)) {
  let rank = severity_rank(at_least)
  case
    list.filter(diagnose(message), fn(d) { severity_rank(d.severity) >= rank })
  {
    [] -> Ok(message)
    found -> Error(found)
  }
}

fn severity_rank(severity: diagnostic.Severity) -> Int {
  case severity {
    diagnostic.Info -> 0
    diagnostic.Warning -> 1
    diagnostic.DataLoss -> 2
  }
}

// ---------------------------------------------------------------------------
// Body and attachment roles

/// The parts that make up a message's text and HTML bodies, and its
/// attachments, as chosen by RFC 8621 §4.1.4 (JMAP).
///
/// `text` and `html` are alternative renderings: each lists the parts to
/// show in order, and a part can be in both (for example an image between
/// two text parts). If a message has only one rendering, it is used for
/// both. Attached messages are attachments; their own bodies are not
/// searched.
pub type Bodies {
  Bodies(text: List(Entity), html: List(Entity), attachments: List(Entity))
}

pub fn bodies(message: Message) -> Bodies {
  let #(roles, _, _) =
    structure(
      [root(message)],
      "mixed",
      False,
      True,
      True,
      Roles([], 0, [], 0, []),
    )
  Bodies(
    text: list.reverse(roles.text),
    html: list.reverse(roles.html),
    attachments: list.reverse(roles.attachments),
  )
}

/// The lists are reversed, with their lengths.
type Roles {
  Roles(
    text: List(Entity),
    text_length: Int,
    html: List(Entity),
    html_length: Int,
    attachments: List(Entity),
  )
}

/// `parseStructure` from RFC 8621 §4.1.4. `text_on` and `html_on` are
/// false where the algorithm sets `textBody` or `htmlBody` to null; that
/// only affects the current call.
fn structure(
  parts: List(Entity),
  multipart_type: String,
  in_alternative: Bool,
  text_on: Bool,
  html_on: Bool,
  roles: Roles,
) -> #(Roles, Bool, Bool) {
  let text_start = case text_on {
    True -> roles.text_length
    False -> -1
  }
  let html_start = case html_on {
    True -> roles.html_length
    False -> -1
  }
  let #(roles, text_on, html_on) =
    structure_loop(
      parts,
      0,
      multipart_type,
      in_alternative,
      text_on,
      html_on,
      roles,
    )
  let roles = case multipart_type == "alternative" && text_on && html_on {
    False -> roles
    True ->
      case
        text_start == roles.text_length,
        html_start != roles.html_length,
        html_start == roles.html_length,
        text_start != roles.text_length
      {
        // Only an HTML part was found: use it for text too.
        True, True, _, _ -> {
          let found = list.take(roles.html, roles.html_length - html_start)
          Roles(
            ..roles,
            text: list.append(found, roles.text),
            text_length: roles.text_length + list.length(found),
          )
        }
        // Only a plain text part was found: use it for HTML too.
        _, _, True, True -> {
          let found = list.take(roles.text, roles.text_length - text_start)
          Roles(
            ..roles,
            html: list.append(found, roles.html),
            html_length: roles.html_length + list.length(found),
          )
        }
        _, _, _, _ -> roles
      }
  }
  #(roles, text_on, html_on)
}

fn structure_loop(
  parts: List(Entity),
  index: Int,
  multipart_type: String,
  in_alternative: Bool,
  text_on: Bool,
  html_on: Bool,
  roles: Roles,
) -> #(Roles, Bool, Bool) {
  case parts {
    [] -> #(roles, text_on, html_on)
    [part, ..rest] -> {
      let content_type = content_type(part)
      let type_ = content_type.type_ <> "/" <> content_type.subtype
      let media = is_inline_media(content_type.type_)
      let attachment = case disposition(part) {
        Some(mime.Disposition(type_: "attachment", ..)) -> True
        _ -> False
      }
      let inline =
        !attachment
        && { type_ == "text/plain" || type_ == "text/html" || media }
        && {
          index == 0
          || {
            multipart_type != "related" && { media || filename(part) == None }
          }
        }
      let #(roles, text_on, html_on) = case content_type.type_, body(part) {
        "multipart", Multipart(parts: children, ..) -> {
          let sub = content_type.subtype
          let #(roles, _, _) =
            structure(
              children,
              sub,
              in_alternative || sub == "alternative",
              text_on,
              html_on,
              roles,
            )
          #(roles, text_on, html_on)
        }
        _, _ if inline && multipart_type == "alternative" -> {
          let roles = case type_ {
            "text/plain" -> push_text(roles, part)
            "text/html" -> push_html(roles, part)
            _ -> Roles(..roles, attachments: [part, ..roles.attachments])
          }
          #(roles, text_on, html_on)
        }
        _, _ if inline -> {
          let html_on = html_on && !{ in_alternative && type_ == "text/plain" }
          let text_on = text_on && !{ in_alternative && type_ == "text/html" }
          let roles = case text_on {
            True -> push_text(roles, part)
            False -> roles
          }
          let roles = case html_on {
            True -> push_html(roles, part)
            False -> roles
          }
          let roles = case { !text_on || !html_on } && media {
            True -> Roles(..roles, attachments: [part, ..roles.attachments])
            False -> roles
          }
          #(roles, text_on, html_on)
        }
        _, _ -> #(
          Roles(..roles, attachments: [part, ..roles.attachments]),
          text_on,
          html_on,
        )
      }
      structure_loop(
        rest,
        index + 1,
        multipart_type,
        in_alternative,
        text_on,
        html_on,
        roles,
      )
    }
  }
}

fn push_text(roles: Roles, part: Entity) -> Roles {
  Roles(..roles, text: [part, ..roles.text], text_length: roles.text_length + 1)
}

fn push_html(roles: Roles, part: Entity) -> Roles {
  Roles(..roles, html: [part, ..roles.html], html_length: roles.html_length + 1)
}

fn is_inline_media(type_: String) -> Bool {
  type_ == "image" || type_ == "audio" || type_ == "video"
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

/// The decoded text of every field with this name: RFC 2047 encoded-words
/// are decoded, raw 8-bit bytes are read as UTF-8 (or windows-1252 when they
/// are not valid UTF-8), and surrounding whitespace is removed. `diagnose`
/// reports the problems found decoding Subject.
///
/// The text is not sanitised: encoded-words can produce line breaks and NUL.
/// Escape it before writing it into another header or a log.
pub fn header_text(entity: Entity, name: String) -> Lookup(String) {
  header_text_with(entity, name, charset.default_options())
}

/// `header_text` with charset options, for example a decoder for charsets
/// that are not built in.
pub fn header_text_with(
  entity: Entity,
  name: String,
  options: charset.Options,
) -> Lookup(String) {
  header_values(entity, name)
  |> list.map(fn(value) { encoded_word.decode(value, options).0 })
  |> lookup
}

fn lookup(values: List(a)) -> Lookup(a) {
  case values {
    [] -> mime.Missing
    [value] -> mime.Single(value)
    values -> mime.Multiple(values)
  }
}

/// The decoded Subject.
pub fn subject(entity: Entity) -> Lookup(String) {
  header_text(entity, "subject")
}

pub fn subject_with(
  entity: Entity,
  options: charset.Options,
) -> Lookup(String) {
  header_text_with(entity, "subject", options)
}

/// The addresses in every field with this name, one list per field (see
/// `eml/address`). `diagnose` reports the problems found in the address
/// fields.
pub fn addresses(entity: Entity, name: String) -> Lookup(List(Address)) {
  addresses_with(entity, name, charset.default_options())
}

pub fn addresses_with(
  entity: Entity,
  name: String,
  options: charset.Options,
) -> Lookup(List(Address)) {
  header_values(entity, name)
  |> list.map(fn(value) { address.parse(value, options).0 })
  |> lookup
}

/// The From addresses. More than one From field is `Multiple`: a sign of a
/// forged or broken message, so it is not merged.
pub fn from(entity: Entity) -> Lookup(List(Address)) {
  addresses(entity, "from")
}

/// The first Content-Disposition field, parsed. `None` when it is absent or
/// has no disposition type.
pub fn disposition(entity: Entity) -> Option(mime.Disposition) {
  case header_values(entity, "content-disposition") {
    [value, ..] ->
      case structured.parse_disposition(value) {
        #(Some(#(type_, parameters)), _) ->
          Some(mime.Disposition(type_:, parameters:))
        #(None, _) -> None
      }
    [] -> None
  }
}

/// The attachment's file name: Content-Disposition `filename`, falling back
/// to Content-Type `name`, with RFC 2231 and RFC 2047 encodings decoded (see
/// `eml/parameter`). An empty name counts as absent. The name is untrusted:
/// see `eml/filename.safe`. `diagnose` reports the problems found.
pub fn filename(entity: Entity) -> Option(String) {
  filename_with(entity, charset.default_options())
}

pub fn filename_with(
  entity: Entity,
  options: charset.Options,
) -> Option(String) {
  resolve_filename(entity, options).0
}

fn resolve_filename(
  entity: Entity,
  options: charset.Options,
) -> #(Option(String), List(diagnostic.Kind)) {
  let #(from_disposition, kinds) = case disposition(entity) {
    Some(disposition) ->
      parameter.resolve(disposition.parameters, "filename", options)
    None -> #(parameter.Absent, [])
  }
  case from_disposition {
    parameter.Resolved(name) if name != "" -> #(Some(name), kinds)
    _ ->
      case
        parameter.resolve(entity.node.content_type.parameters, "name", options)
      {
        #(parameter.Resolved(name), more) if name != "" -> #(
          Some(name),
          list.append(kinds, more),
        )
        #(_, more) -> #(None, list.append(kinds, more))
      }
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
/// while decoding. Identity and unknown encodings return the raw bytes; an
/// unknown encoding is already reported by `parse`.
pub fn decode_body(entity: Entity) -> #(BitArray, List(Diagnostic)) {
  let raw = raw_body(entity)
  let offset = entity.node.body_span.start
  let path = entity.node.path
  let #(bytes, kinds) = case entity.node.encoding {
    mime.Base64 -> base64.decode(raw, offset)
    mime.QuotedPrintable -> quoted_printable.decode(raw, offset)
    mime.Unknown(_) | mime.SevenBit | mime.EightBit | mime.Binary -> #(raw, [])
  }
  #(bytes, list.map(kinds, fn(kind) { diagnostic.new(kind.0, path, kind.1) }))
}

/// The body as text: its transfer encoding is removed, then it is decoded
/// with its declared charset (see `eml/charset`). Returns `Error(Nil)` when
/// the charset is not supported; the diagnostics say why.
pub fn decode_text(entity: Entity) -> #(Result(String, Nil), List(Diagnostic)) {
  decode_text_with(entity, charset.default_options())
}

pub fn decode_text_with(
  entity: Entity,
  options: charset.Options,
) -> #(Result(String, Nil), List(Diagnostic)) {
  let #(bytes, diagnostics) = decode_body(entity)
  let #(text, kinds) = charset.decode(bytes, charset_label(entity), options)
  let span = Some(entity.node.body_span)
  let path = entity.node.path
  #(
    text,
    list.append(
      diagnostics,
      list.map(kinds, fn(kind) { diagnostic.new(kind, path, span) }),
    ),
  )
}

/// The declared `charset` parameter of the content type, if any.
pub fn charset_label(entity: Entity) -> Option(String) {
  case list.key_find(entity.node.content_type.parameters, "charset") {
    Ok(label) ->
      case utf8.to_string(label) {
        Ok(label) -> Some(label)
        Error(_) -> Some(string.inspect(label))
      }
    Error(_) -> None
  }
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
