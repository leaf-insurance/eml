//// Framing, header blocks and the MIME tree (assumptions.md §B–§E).
////
//// Every loop over input bytes or lines is a single self-recursive function,
//// so that it compiles to a loop on the JavaScript target too (§J.2).

import eml/diagnostic.{type Diagnostic, type Kind, type Span, Span}
import eml/internal/structured.{slice}
import eml/mime.{type ContentType, type ParseError, type TransferEncoding}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Limits {
  Limits(
    max_depth: Int,
    max_parts: Int,
    max_header_bytes: Int,
    max_header_lines: Int,
    max_diagnostics: Int,
  )
}

pub type HeaderLine {
  FieldLine(name: String, name_span: Span, value_span: Span, span: Span)
  AnomalyLine(span: Span)
}

pub type Node {
  Node(
    path: List(Int),
    span: Span,
    lines: List(HeaderLine),
    separator: Option(Span),
    body_span: Span,
    content_type: ContentType,
    encoding: TransferEncoding,
    body: NodeBody,
  )
}

pub type NodeBody {
  NodeLeaf
  /// `delimiters` interleave with `parts`: the delimiter opening part i is
  /// at index i, and a close delimiter, if present, comes last.
  NodeMultipart(
    boundary: BitArray,
    preamble: Span,
    delimiters: List(Span),
    parts: List(Node),
    closed: Bool,
    epilogue: Span,
  )
  NodeEmbedded(Node)
  NodeOpaque(mime.OpaqueReason)
}

pub type Parsed {
  Parsed(
    bom: Option(Span),
    envelope: Option(Span),
    root: Node,
    diagnostics: List(Diagnostic),
  )
}

type State {
  State(
    limits: Limits,
    parts: Int,
    // Reversed.
    diagnostics: List(Diagnostic),
    count: Int,
    /// The worst severity among the diagnostics dropped after
    /// `max_diagnostics` was reached.
    dropped: Option(diagnostic.Severity),
  )
}

type Context {
  Root
  Child
  Embedded
}

/// A physical line: content is `[start, content_end)` and its terminator is
/// `[content_end, end)`.
type Line {
  Line(start: Int, content_end: Int, end: Int)
}

type Delimiter {
  /// `owner` indexes the boundary stack, innermost first.
  Delimiter(line: Line, owner: Int, close: Bool, trailing: Bool)
}

type Stop {
  AtEof
  AtDelimiter(Delimiter)
}

pub fn parse(source: BitArray, limits: Limits) -> Result(Parsed, ParseError) {
  let size = bit_array.byte_size(source)
  use <- guard(bit_array.bit_size(source) != size * 8, mime.NotByteAligned)
  let state = State(limits:, parts: 0, diagnostics: [], count: 0, dropped: None)
  let #(bom, pos, state) = case source {
    <<0xEF, 0xBB, 0xBF, _:bytes>> -> #(
      Some(Span(0, 3)),
      3,
      push(state, diagnostic.ByteOrderMark, [], Some(Span(0, 3))),
    )
    _ -> #(None, 0, state)
  }
  use <- guard(
    structured.skip_whitespace(slice(source, pos, -1)) == <<>>,
    mime.EmptyInput,
  )
  let #(envelope, pos) = envelope(source, size, pos)
  use #(root, _end, _stop, state) <- result.try(parse_entity(
    source,
    size,
    pos,
    [],
    0,
    [],
    default_content_type(False),
    Root,
    state,
  ))
  // The truncation diagnostic is the last one recorded: it gets the worst
  // dropped severity.
  let diagnostics = case state.dropped, state.diagnostics {
    Some(worst), [last, ..rest] -> [
      diagnostic.new(diagnostic.DiagnosticsTruncated(worst), last.path, None),
      ..rest
    ]
    _, diagnostics -> diagnostics
  }
  Ok(Parsed(bom:, envelope:, root:, diagnostics: list.reverse(diagnostics)))
}

fn guard(
  condition: Bool,
  error: ParseError,
  continue: fn() -> Result(a, ParseError),
) -> Result(a, ParseError) {
  case condition {
    True -> Error(error)
    False -> continue()
  }
}

/// An mbox `From ` line is recognised only on the first line, and only when
/// the following line is a header field (§D.2).
fn envelope(source: BitArray, size: Int, pos: Int) -> #(Option(Span), Int) {
  case slice(source, pos, pos + 5) {
    <<"From ">> -> {
      let line = read_line(source, size, pos)
      case line.end > line.content_end && line.end < size {
        False -> #(None, pos)
        True -> {
          let next = read_line(source, size, line.end)
          case is_field(source, next) {
            Ok(_) -> #(Some(Span(pos, line.end)), line.end)
            Error(_) -> #(None, pos)
          }
        }
      }
    }
    _ -> #(None, pos)
  }
}

fn worse(
  current: Option(diagnostic.Severity),
  new: diagnostic.Severity,
) -> diagnostic.Severity {
  case current, new {
    Some(diagnostic.DataLoss), _ | _, diagnostic.DataLoss -> diagnostic.DataLoss
    Some(diagnostic.Warning), _ | _, diagnostic.Warning -> diagnostic.Warning
    _, _ -> diagnostic.Info
  }
}

fn push(
  state: State,
  kind: Kind,
  path: List(Int),
  span: Option(Span),
) -> State {
  let max = state.limits.max_diagnostics
  case state.count {
    count if count < max ->
      State(
        ..state,
        diagnostics: [diagnostic.new(kind, path, span), ..state.diagnostics],
        count: count + 1,
      )
    count if count == max ->
      State(
        ..state,
        diagnostics: [
          diagnostic.new(
            diagnostic.DiagnosticsTruncated(diagnostic.Info),
            path,
            None,
          ),
          ..state.diagnostics
        ],
        count: count + 1,
        dropped: Some(worse(state.dropped, diagnostic.severity(kind))),
      )
    _ ->
      State(
        ..state,
        dropped: Some(worse(state.dropped, diagnostic.severity(kind))),
      )
  }
}

fn push_all(
  state: State,
  kinds: List(#(Kind, Option(Span))),
  path: List(Int),
) -> State {
  list.fold(kinds, state, fn(state, entry) {
    push(state, entry.0, path, entry.1)
  })
}

// ---------------------------------------------------------------------------
// Lines

fn read_line(source: BitArray, size: Int, pos: Int) -> Line {
  scan_line(slice(source, pos, size), pos, pos)
}

fn scan_line(rest: BitArray, start: Int, pos: Int) -> Line {
  case rest {
    <<"\r\n", _:bytes>> -> Line(start, pos, pos + 2)
    <<"\r", _:bytes>> | <<"\n", _:bytes>> -> Line(start, pos, pos + 1)
    <<_, rest:bytes>> -> scan_line(rest, start, pos + 1)
    _ -> Line(start, pos, pos)
  }
}

fn content(source: BitArray, line: Line) -> BitArray {
  slice(source, line.start, line.content_end)
}

/// Returns the end of the field name and the position of the colon when the
/// line is a header field: one or more ftext bytes, optional SP/TAB, then `:`.
fn is_field(source: BitArray, line: Line) -> Result(#(Int, Int), Nil) {
  field_name(content(source, line), 0, line.start)
}

fn field_name(
  rest: BitArray,
  length: Int,
  start: Int,
) -> Result(#(Int, Int), Nil) {
  case rest {
    <<":", _:bytes>> if length > 0 -> Ok(#(start + length, start + length))
    <<c, _:bytes>> if { c == 32 || c == 9 } && length > 0 ->
      field_after_name(rest, length, start, length)
    <<c, rest:bytes>> if c >= 33 && c <= 126 && c != 58 ->
      field_name(rest, length + 1, start)
    _ -> Error(Nil)
  }
}

fn field_after_name(
  rest: BitArray,
  name_length: Int,
  start: Int,
  offset: Int,
) -> Result(#(Int, Int), Nil) {
  case rest {
    <<c, rest:bytes>> if c == 32 || c == 9 ->
      field_after_name(rest, name_length, start, offset + 1)
    <<":", _:bytes>> -> Ok(#(start + name_length, start + offset))
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Delimiters

/// Finds the owner of a delimiter line among the open boundaries (§E.4).
fn delimiter(
  source: BitArray,
  line: Line,
  stack: List(BitArray),
) -> Option(Delimiter) {
  case stack {
    [] -> None
    _ ->
      case content(source, line) {
        <<"--", rest:bytes>> ->
          case find_owner(rest, stack, 0, True) {
            Some(#(owner, close)) -> Some(Delimiter(line, owner, close, False))
            None ->
              case find_owner(rest, stack, 0, False) {
                Some(#(owner, close)) ->
                  Some(Delimiter(line, owner, close, True))
                None -> None
              }
          }
        _ -> None
      }
  }
}

fn find_owner(
  rest: BitArray,
  stack: List(BitArray),
  index: Int,
  exact: Bool,
) -> Option(#(Int, Bool)) {
  case stack {
    [] -> None
    [boundary, ..stack] ->
      case bit_array.starts_with(rest, boundary) {
        False -> find_owner(rest, stack, index + 1, exact)
        True -> {
          let after = slice(rest, bit_array.byte_size(boundary), -1)
          let #(close, is_exact) = classify(after)
          case is_exact == exact {
            True -> Some(#(index, close))
            False -> find_owner(rest, stack, index + 1, exact)
          }
        }
      }
  }
}

/// Returns whether the rest of a delimiter line closes the multipart, and
/// whether it is an exact match (only whitespace follows).
fn classify(after: BitArray) -> #(Bool, Bool) {
  case after {
    <<"--", rest:bytes>> -> #(True, is_lwsp(rest))
    _ -> #(False, is_lwsp(after))
  }
}

fn is_lwsp(bits: BitArray) -> Bool {
  case bits {
    <<c, rest:bytes>> if c == 32 || c == 9 -> is_lwsp(rest)
    <<>> -> True
    _ -> False
  }
}

// ---------------------------------------------------------------------------
// Header blocks (§D.3)

type Record {
  FieldRecord(name: String, name_end: Int, colon: Int, start: Int, line: Line)
  AnomalyRecord(start: Int, line: Line)
}

type HeaderBlock {
  HeaderBlock(
    lines: List(HeaderLine),
    fields: Int,
    separator: Option(Span),
    body_start: Int,
    kinds: List(#(Kind, Option(Span))),
  )
}

fn header_block(
  source: BitArray,
  size: Int,
  start: Int,
  stack: List(BitArray),
  limits: Limits,
) -> Result(HeaderBlock, ParseError) {
  header_loop(source, size, start, start, stack, limits, None, [], 0, 0, [])
}

/// One step of the header block algorithm.
type Step {
  Continue(
    current: Option(Record),
    lines: List(HeaderLine),
    fields: Int,
    kinds: List(#(Kind, Option(Span))),
  )
  Finish(
    separator: Option(Span),
    body_start: Int,
    kinds: List(#(Kind, Option(Span))),
  )
}

fn header_loop(
  source: BitArray,
  size: Int,
  block_start: Int,
  pos: Int,
  stack: List(BitArray),
  limits: Limits,
  current: Option(Record),
  lines: List(HeaderLine),
  fields: Int,
  count: Int,
  kinds: List(#(Kind, Option(Span))),
) -> Result(HeaderBlock, ParseError) {
  let #(step, next) = case pos >= size {
    True -> #(
      Finish(None, size, [
        #(diagnostic.NoBlankLineAfterHeaders, Some(Span(size, size))),
        ..kinds
      ]),
      size,
    )
    False -> {
      let line = read_line(source, size, pos)
      let step =
        classify_header_line(
          source,
          size,
          line,
          stack,
          current,
          lines,
          fields,
          kinds,
        )
      #(step, line.end)
    }
  }
  // Only lines that join the header block (fields, anomalies and
  // continuations) count towards the limits; the separator and the line
  // that starts the body do not.
  case step {
    Continue(..) if next - block_start > limits.max_header_bytes ->
      Error(mime.LimitExceeded(mime.MaxHeaderBytes))
    Continue(..) if count + 1 > limits.max_header_lines ->
      Error(mime.LimitExceeded(mime.MaxHeaderLines))
    Continue(current:, lines:, fields:, kinds:) ->
      header_loop(
        source,
        size,
        block_start,
        next,
        stack,
        limits,
        current,
        lines,
        fields,
        count + 1,
        kinds,
      )
    Finish(separator:, body_start:, kinds:) ->
      Ok(HeaderBlock(
        lines: list.reverse(close_record(current, lines)),
        fields:,
        separator:,
        body_start:,
        kinds: list.reverse(kinds),
      ))
  }
}

fn classify_header_line(
  source: BitArray,
  size: Int,
  line: Line,
  stack: List(BitArray),
  current: Option(Record),
  lines: List(HeaderLine),
  fields: Int,
  kinds: List(#(Kind, Option(Span))),
) -> Step {
  case delimiter(source, line, stack) {
    Some(_) ->
      Finish(None, line.start, [
        #(
          diagnostic.NoBlankLineAfterHeaders,
          Some(Span(line.start, line.start)),
        ),
        ..kinds
      ])
    None ->
      case line.content_end == line.start, content(source, line) {
        // An empty line is the separator.
        True, _ -> Finish(Some(Span(line.start, line.end)), line.end, kinds)
        False, <<c, _:bytes>> if c == 32 || c == 9 ->
          case current {
            Some(record) ->
              Continue(Some(extend(record, line)), lines, fields, kinds)
            None ->
              Continue(Some(AnomalyRecord(line.start, line)), lines, fields, [
                #(
                  diagnostic.FirstLineIsContinuation,
                  Some(Span(line.start, line.end)),
                ),
                ..kinds
              ])
          }
        False, _ ->
          case is_field(source, line) {
            Ok(#(name_end, colon)) -> {
              let lines = close_record(current, lines)
              let name =
                result.unwrap(
                  bit_array.to_string(slice(source, line.start, name_end)),
                  "",
                )
              let kinds = case colon > name_end {
                True -> [
                  #(diagnostic.SpaceBeforeColon, Some(Span(name_end, colon))),
                  ..kinds
                ]
                False -> kinds
              }
              let record = FieldRecord(name, name_end, colon, line.start, line)
              Continue(Some(record), lines, fields + 1, kinds)
            }
            Error(_) ->
              case next_is_field(source, size, line.end, stack) {
                True ->
                  Continue(
                    Some(AnomalyRecord(line.start, line)),
                    close_record(current, lines),
                    fields,
                    [
                      #(
                        diagnostic.NonHeaderLine,
                        Some(Span(line.start, line.end)),
                      ),
                      ..kinds
                    ],
                  )
                False ->
                  Finish(None, line.start, [
                    #(
                      diagnostic.MissingHeaderBodySeparator,
                      Some(Span(line.start, line.start)),
                    ),
                    ..kinds
                  ])
              }
          }
      }
  }
}

/// Looks past continuation lines for the next line, and reports whether it is
/// a header field. Delimiter lines are never fields.
fn next_is_field(
  source: BitArray,
  size: Int,
  pos: Int,
  stack: List(BitArray),
) -> Bool {
  case pos >= size {
    True -> False
    False -> {
      let line = read_line(source, size, pos)
      case content(source, line) {
        <<c, _:bytes>> if c == 32 || c == 9 ->
          next_is_field(source, size, line.end, stack)
        _ ->
          case delimiter(source, line, stack) {
            Some(_) -> False
            None -> result.is_ok(is_field(source, line))
          }
      }
    }
  }
}

fn extend(record: Record, line: Line) -> Record {
  case record {
    FieldRecord(..) -> FieldRecord(..record, line:)
    AnomalyRecord(..) -> AnomalyRecord(..record, line:)
  }
}

fn close_record(
  record: Option(Record),
  lines: List(HeaderLine),
) -> List(HeaderLine) {
  case record {
    None -> lines
    Some(FieldRecord(name, name_end, colon, start, last)) -> [
      FieldLine(
        name:,
        name_span: Span(start, name_end),
        value_span: Span(colon + 1, last.content_end),
        span: Span(start, last.end),
      ),
      ..lines
    ]
    Some(AnomalyRecord(start, last)) -> [
      AnomalyLine(Span(start, last.end)),
      ..lines
    ]
  }
}

// ---------------------------------------------------------------------------
// Entities

fn default_content_type(digest: Bool) -> ContentType {
  case digest {
    True -> mime.ContentType("message", "rfc822", [])
    False -> mime.ContentType("text", "plain", [#("charset", <<"us-ascii">>)])
  }
}

/// The value of the first field with the given lowercase name, unfolded,
/// and its span. More than one such field is reported.
fn first_field(
  source: BitArray,
  block: HeaderBlock,
  name: String,
  path: List(Int),
  state: State,
) -> #(Option(#(BitArray, Span)), State) {
  let #(first, count) =
    list.fold(block.lines, #(None, 0), fn(acc, line) {
      case line {
        FieldLine(name: field_name, value_span:, span:, ..) ->
          case string.lowercase(field_name) == name {
            False -> acc
            True ->
              case acc.0 {
                None -> #(
                  Some(#(
                    structured.unfold(slice(
                      source,
                      value_span.start,
                      value_span.end,
                    )),
                    span,
                  )),
                  1,
                )
                Some(_) -> #(acc.0, acc.1 + 1)
              }
          }
        AnomalyLine(_) -> acc
      }
    })
  case first, count > 1 {
    Some(#(_, span)), True -> #(
      first,
      push(state, diagnostic.DuplicateField(name), path, Some(span)),
    )
    _, _ -> #(first, state)
  }
}

fn parse_entity(
  source: BitArray,
  size: Int,
  start: Int,
  path: List(Int),
  depth: Int,
  stack: List(BitArray),
  default: ContentType,
  context: Context,
  state: State,
) -> Result(#(Node, Int, Stop, State), ParseError) {
  let limits = state.limits
  use <- guard(depth > limits.max_depth, mime.LimitExceeded(mime.MaxDepth))
  use <- guard(
    state.parts + 1 > limits.max_parts,
    mime.LimitExceeded(mime.MaxParts),
  )
  let state = State(..state, parts: state.parts + 1)
  use block <- result.try(header_block(source, size, start, stack, limits))
  case block.fields, context {
    0, Root -> Error(mime.NoHeaderBlock)
    0, Embedded -> {
      // Not a message: the whole region is opaque. Diagnostics from the
      // failed header block are not reported.
      let #(end, stop) = scan_body(source, size, start, stack)
      let node =
        Node(
          path:,
          span: Span(start, end),
          lines: [],
          separator: None,
          body_span: Span(start, end),
          content_type: default,
          encoding: mime.SevenBit,
          body: NodeOpaque(mime.NotMessage),
        )
      Ok(#(node, end, stop, state))
    }
    _, _ -> {
      let state = push_all(state, block.kinds, path)
      let #(content_type, state) =
        content_type(source, block, default, path, state)
      let #(encoding, state) = transfer_encoding(source, block, path, state)
      let body_start = block.body_start
      use #(body, encoding, end, stop, state) <- result.try(body(
        source,
        size,
        body_start,
        path,
        depth,
        stack,
        content_type,
        encoding,
        state,
      ))
      let body_span = Span(body_start, int_max(end, body_start))
      let node =
        Node(
          path:,
          span: Span(start, int_max(end, body_start)),
          lines: block.lines,
          separator: block.separator,
          body_span:,
          content_type:,
          encoding:,
          body:,
        )
      Ok(#(node, int_max(end, body_start), stop, state))
    }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn content_type(
  source: BitArray,
  block: HeaderBlock,
  default: ContentType,
  path: List(Int),
  state: State,
) -> #(ContentType, State) {
  case first_field(source, block, "content-type", path, state) {
    #(None, state) -> #(default, state)
    #(Some(#(value, span)), state) -> {
      case structured.skip_cfws(value) {
        // An empty value counts as absent.
        <<>> -> #(default, state)
        _ -> {
          let #(parsed, kinds) = structured.parse_content_type(value)
          let state =
            push_all(
              state,
              list.map(kinds, fn(kind) { #(kind, Some(span)) }),
              path,
            )
          case parsed {
            Some(content_type) -> #(content_type, state)
            // An invalid type falls back to the default for this
            // context, `message/rfc822` inside a digest.
            None -> #(default, state)
          }
        }
      }
    }
  }
}

fn transfer_encoding(
  source: BitArray,
  block: HeaderBlock,
  path: List(Int),
  state: State,
) -> #(TransferEncoding, State) {
  case first_field(source, block, "content-transfer-encoding", path, state) {
    #(None, state) -> #(mime.SevenBit, state)
    #(Some(#(value, span)), state) -> {
      let #(encoding, kinds) = structured.parse_transfer_encoding(value)
      let state =
        push_all(state, list.map(kinds, fn(kind) { #(kind, Some(span)) }), path)
      #(encoding, state)
    }
  }
}

fn is_identity(encoding: TransferEncoding) -> Bool {
  case encoding {
    mime.SevenBit | mime.EightBit | mime.Binary -> True
    _ -> False
  }
}

/// Classifies and parses a body (§E.3). Returns the body, the effective
/// transfer encoding, the trimmed end of the entity, and why it stopped.
fn body(
  source: BitArray,
  size: Int,
  body_start: Int,
  path: List(Int),
  depth: Int,
  stack: List(BitArray),
  content_type: ContentType,
  encoding: TransferEncoding,
  state: State,
) -> Result(#(NodeBody, TransferEncoding, Int, Stop, State), ParseError) {
  let here = Some(Span(body_start, body_start))
  let identity = is_identity(encoding)
  case content_type.type_, content_type.subtype {
    "multipart", subtype -> {
      let state = case identity {
        True -> state
        False -> push(state, diagnostic.EncodedMultipart, path, here)
      }
      let #(boundary, state) = boundary(content_type, path, here, state)
      case boundary {
        None -> {
          let #(end, stop) = scan_body(source, size, body_start, stack)
          let reason = case list.key_find(content_type.parameters, "boundary") {
            Ok(_) -> mime.BadBoundary
            Error(_) -> mime.NoBoundary
          }
          Ok(#(NodeOpaque(reason), mime.SevenBit, end, stop, state))
        }
        Some(boundary) -> {
          use #(body, end, stop, state) <- result.try(multipart(
            source,
            size,
            body_start,
            path,
            depth,
            stack,
            boundary,
            subtype == "digest",
            state,
          ))
          Ok(#(body, mime.SevenBit, end, stop, state))
        }
      }
    }
    "message", "rfc822" | "message", "global" if identity -> {
      use #(child, end, stop, child_state) <- result.try(parse_entity(
        source,
        size,
        body_start,
        list.append(path, [0]),
        depth + 1,
        stack,
        default_content_type(False),
        Embedded,
        state,
      ))
      case child.body {
        NodeOpaque(mime.NotMessage) -> {
          let state = push(state, diagnostic.NotAMessage, path, here)
          Ok(#(NodeOpaque(mime.NotMessage), encoding, end, stop, state))
        }
        _ -> Ok(#(NodeEmbedded(child), encoding, end, stop, child_state))
      }
    }
    type_, subtype -> {
      let state = case encoding, type_, subtype {
        mime.Unknown(label), _, _ ->
          push(state, diagnostic.UnknownTransferEncoding(label), path, here)
        // An encoded message is not parsed (§C.2).
        _, "message", "rfc822" | _, "message", "global" ->
          push(state, diagnostic.EncodedMessage, path, here)
        _, _, _ -> state
      }
      let #(end, stop) = scan_body(source, size, body_start, stack)
      Ok(#(NodeLeaf, encoding, end, stop, state))
    }
  }
}

fn boundary(
  content_type: ContentType,
  path: List(Int),
  here: Option(Span),
  state: State,
) -> #(Option(BitArray), State) {
  case list.key_find(content_type.parameters, "boundary") {
    Error(_) -> {
      let extended =
        list.any(content_type.parameters, fn(parameter) {
          string.starts_with(parameter.0, "boundary*")
        })
      let state = case extended {
        True -> push(state, diagnostic.IgnoredExtendedBoundary, path, here)
        False -> state
      }
      #(None, push(state, diagnostic.MissingBoundary, path, here))
    }
    Ok(boundary) ->
      case structured.boundary_status(boundary) {
        structured.ValidBoundary -> #(Some(boundary), state)
        structured.NonstandardBoundary -> #(
          Some(boundary),
          push(state, diagnostic.NonstandardBoundary, path, here),
        )
        structured.UnusableBoundary -> #(
          None,
          push(state, diagnostic.UnusableBoundary, path, here),
        )
      }
  }
}

/// Scans body lines until a delimiter owned by any open boundary, or EOF.
/// Returns the trimmed end of the region: the terminator of the last body
/// line belongs to the delimiter that follows it (§E.4).
fn scan_body(
  source: BitArray,
  size: Int,
  start: Int,
  stack: List(BitArray),
) -> #(Int, Stop) {
  scan_loop(source, size, start, start, start, stack)
}

fn scan_loop(
  source: BitArray,
  size: Int,
  region_start: Int,
  pos: Int,
  previous_content_end: Int,
  stack: List(BitArray),
) -> #(Int, Stop) {
  case stack, pos >= size {
    [], _ | _, True -> #(size, AtEof)
    _, False -> {
      let line = read_line(source, size, pos)
      case delimiter(source, line, stack) {
        Some(found) ->
          case pos > region_start {
            True -> #(previous_content_end, AtDelimiter(found))
            False -> #(pos, AtDelimiter(found))
          }
        None ->
          scan_loop(
            source,
            size,
            region_start,
            line.end,
            line.content_end,
            stack,
          )
      }
    }
  }
}

/// Lifts a stop from a nested stack to its parent's stack.
fn lift(stop: Stop) -> Stop {
  case stop {
    AtEof -> AtEof
    AtDelimiter(found) ->
      AtDelimiter(Delimiter(..found, owner: found.owner - 1))
  }
}

fn collides(boundary: BitArray, stack: List(BitArray)) -> Bool {
  list.any(stack, fn(other) {
    bit_array.starts_with(boundary, other)
    || bit_array.starts_with(other, boundary)
  })
}

fn multipart(
  source: BitArray,
  size: Int,
  body_start: Int,
  path: List(Int),
  depth: Int,
  stack: List(BitArray),
  boundary: BitArray,
  digest: Bool,
  state: State,
) -> Result(#(NodeBody, Int, Stop, State), ParseError) {
  let here = Some(Span(body_start, body_start))
  let state = case collides(boundary, stack) {
    True -> push(state, diagnostic.BoundaryCollision, path, here)
    False -> state
  }
  let inner = [boundary, ..stack]
  let #(preamble_end, stop) = scan_body(source, size, body_start, inner)
  case stop {
    AtDelimiter(Delimiter(owner: 0, ..) as found) -> {
      let state = trailing(state, found, path)
      let delimiter = Span(preamble_end, found.line.end)
      let state = case found.close {
        True -> push(state, diagnostic.CloseWithoutOpen, path, Some(delimiter))
        False -> state
      }
      parts(
        source,
        size,
        found,
        path,
        depth,
        stack,
        inner,
        boundary,
        digest,
        Span(body_start, preamble_end),
        [delimiter],
        [],
        0,
        state,
      )
    }
    _ -> {
      // No delimiter of our own before the entity ends.
      let state = push(state, diagnostic.StartDelimiterNotFound, path, here)
      Ok(#(NodeOpaque(mime.NoStartDelimiter), preamble_end, lift(stop), state))
    }
  }
}

fn trailing(state: State, found: Delimiter, path: List(Int)) -> State {
  case found.trailing {
    True ->
      push(
        state,
        diagnostic.DelimiterTrailingText,
        path,
        Some(Span(found.line.start, found.line.end)),
      )
    False -> state
  }
}

/// Parses the part after the delimiter `found`, which is owned by this
/// multipart, and the parts after it.
fn parts(
  source: BitArray,
  size: Int,
  found: Delimiter,
  path: List(Int),
  depth: Int,
  stack: List(BitArray),
  inner: List(BitArray),
  boundary: BitArray,
  digest: Bool,
  preamble: Span,
  delimiters: List(Span),
  nodes: List(Node),
  index: Int,
  state: State,
) -> Result(#(NodeBody, Int, Stop, State), ParseError) {
  case found.close {
    True -> {
      // The epilogue runs until an ancestor's delimiter or EOF. The closed
      // multipart's own boundary is no longer on the stack.
      let #(end, stop) = scan_body(source, size, found.line.end, stack)
      Ok(#(
        NodeMultipart(
          boundary:,
          preamble:,
          delimiters: list.reverse(delimiters),
          parts: list.reverse(nodes),
          closed: True,
          epilogue: Span(found.line.end, end),
        ),
        end,
        stop,
        state,
      ))
    }
    // A direct self-call (not through `result.try`), so that this loop over
    // parts compiles to a loop on JavaScript.
    False ->
      case
        parse_entity(
          source,
          size,
          found.line.end,
          list.append(path, [index]),
          depth + 1,
          inner,
          default_content_type(digest),
          Child,
          state,
        )
      {
        Error(error) -> Error(error)
        Ok(#(node, end, AtDelimiter(Delimiter(owner: 0, ..) as found), state)) -> {
          let state = trailing(state, found, path)
          parts(
            source,
            size,
            found,
            path,
            depth,
            stack,
            inner,
            boundary,
            digest,
            preamble,
            [Span(end, found.line.end), ..delimiters],
            [node, ..nodes],
            index + 1,
            state,
          )
        }
        Ok(#(node, end, stop, state)) -> {
          let state =
            push(
              state,
              diagnostic.MissingCloseDelimiter,
              path,
              Some(Span(end, end)),
            )
          Ok(#(
            NodeMultipart(
              boundary:,
              preamble:,
              delimiters: list.reverse(delimiters),
              parts: list.reverse([node, ..nodes]),
              closed: False,
              epilogue: Span(end, end),
            ),
            end,
            lift(stop),
            state,
          ))
        }
      }
  }
}
