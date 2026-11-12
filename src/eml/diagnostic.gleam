//// Diagnostics describe every malformation the parser recovered from.
////
//// Parsing never fails because of malformed content. Instead, each recovery
//// is recorded as a `Diagnostic` with a `Severity`:
////
//// - `Info`: a nonconformance that does not change the interpreted result.
//// - `Warning`: a recovery was applied. No input bytes were dropped, but
////   another conforming parser may interpret the input differently.
//// - `DataLoss`: input bytes are not represented in the interpreted result,
////   or some content cannot be interpreted as declared. The raw bytes are
////   still reachable.

import gleam/option.{type Option}

/// A half-open byte range `[start, end)` in a message's source.
pub type Span {
  Span(start: Int, end: Int)
}

pub type Severity {
  Info
  Warning
  DataLoss
}

pub type Kind {
  // Framing and header blocks.
  ByteOrderMark
  FirstLineIsContinuation
  NonHeaderLine
  MissingHeaderBodySeparator
  NoBlankLineAfterHeaders
  SpaceBeforeColon
  DuplicateField(name: String)

  // Content-Type and Content-Transfer-Encoding.
  InvalidContentType
  InvalidParameter
  UnterminatedQuotedString
  DuplicateParameter(name: String)
  IgnoredExtendedBoundary
  NonstandardBoundary
  NonstandardTransferEncoding(label: String)

  // MIME structure.
  EncodedMultipart
  MissingBoundary
  UnusableBoundary
  StartDelimiterNotFound
  NotAMessage
  EncodedMessage
  UnknownTransferEncoding(label: String)
  DelimiterTrailingText
  BoundaryCollision
  CloseWithoutOpen
  MissingCloseDelimiter

  // Base64 decoding. Counts aggregate every occurrence in one decode call.
  StrayPadding(count: Int)
  InvalidBase64Characters(count: Int)
  InvalidBase64Length
  MissingBase64Padding
  Base64DataAfterPadding(decoded_length: Int)
  ExcessBase64Padding(count: Int)
  NonZeroPadBits

  // Quoted-printable decoding.
  TrailingSoftBreak
  InvalidQuotedPrintable(count: Int)
  UnencodedOctets(count: Int)

  // Recorded once when `max_diagnostics` is reached.
  DiagnosticsTruncated
}

/// `path` identifies the entity (see `eml.part_at`), and `span` is the first
/// byte range the diagnostic concerns, when there is one.
pub type Diagnostic {
  Diagnostic(
    kind: Kind,
    severity: Severity,
    path: List(Int),
    span: Option(Span),
  )
}

/// The severity of each kind is fixed, so it can be derived from the kind.
pub fn severity(kind: Kind) -> Severity {
  case kind {
    ByteOrderMark
    | NoBlankLineAfterHeaders
    | SpaceBeforeColon
    | NonstandardTransferEncoding(_)
    | MissingBase64Padding
    | ExcessBase64Padding(_)
    | NonZeroPadBits
    | TrailingSoftBreak
    | UnencodedOctets(_)
    | DiagnosticsTruncated -> Info

    FirstLineIsContinuation
    | NonHeaderLine
    | MissingHeaderBodySeparator
    | DuplicateField(_)
    | InvalidContentType
    | InvalidParameter
    | UnterminatedQuotedString
    | DuplicateParameter(_)
    | IgnoredExtendedBoundary
    | NonstandardBoundary
    | EncodedMultipart
    | EncodedMessage
    | DelimiterTrailingText
    | BoundaryCollision
    | CloseWithoutOpen
    | MissingCloseDelimiter
    | StrayPadding(_)
    | InvalidBase64Characters(_)
    | Base64DataAfterPadding(_)
    | InvalidQuotedPrintable(_) -> Warning

    MissingBoundary
    | UnusableBoundary
    | StartDelimiterNotFound
    | NotAMessage
    | UnknownTransferEncoding(_)
    | InvalidBase64Length -> DataLoss
  }
}

pub fn new(kind: Kind, path: List(Int), span: Option(Span)) -> Diagnostic {
  Diagnostic(kind:, severity: severity(kind), path:, span:)
}
