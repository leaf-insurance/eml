//// Data types describing the MIME structure of a parsed message.

import eml/diagnostic.{type Span}

/// An effective content type. `type_` and `subtype` are lowercase ASCII.
/// Parameter names are lowercase ASCII; values are the raw bytes after
/// unquoting.
pub type ContentType {
  ContentType(
    type_: String,
    subtype: String,
    parameters: List(#(String, BitArray)),
  )
}

/// A parsed Content-Disposition field (RFC 2183). `type_` and parameter
/// names are lowercase ASCII.
pub type Disposition {
  Disposition(type_: String, parameters: List(#(String, BitArray)))
}

pub type TransferEncoding {
  SevenBit
  EightBit
  Binary
  QuotedPrintable
  Base64
  Unknown(label: String)
}

/// Why a body could not be interpreted as its declared type. Its raw bytes
/// are still available through `eml.raw_body`.
pub type OpaqueReason {
  NoBoundary
  BadBoundary
  NoStartDelimiter
  NotMessage
}

pub type Limit {
  MaxDepth
  MaxParts
  MaxHeaderBytes
  MaxHeaderLines
}

pub type ParseError {
  /// The input is not a whole number of bytes.
  NotByteAligned
  /// The input is empty, or contains only SP, TAB, CR and LF (after an
  /// optional byte order mark).
  EmptyInput
  /// The input does not start with a header block containing at least one
  /// valid field.
  NoHeaderBlock
  LimitExceeded(limit: Limit)
}

/// A header field as it appears in the source. `value` is the raw value
/// after the colon, including any folding line breaks.
pub type Header {
  Header(name: String, value: BitArray, span: Span)
}

/// The result of looking up a field that should occur at most once.
pub type Lookup(a) {
  Missing
  Single(a)
  Multiple(List(a))
}

/// The segments of a message tile its source: they are ordered, do not
/// overlap, and together cover every byte.
pub type Segment {
  Segment(kind: SegmentKind, span: Span, path: List(Int))
}

pub type SegmentKind {
  BomSegment
  EnvelopeSegment
  FieldSegment
  AnomalySegment
  SeparatorSegment
  PreambleSegment
  DelimiterSegment
  BodySegment
  EpilogueSegment
}
