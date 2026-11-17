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

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/string

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

  // Charset decoding (§G).
  NonAsciiInAscii
  C1ReinterpretedAsWindows1252
  MalformedCharsetData(count: Int)
  UnsupportedCharset(label: String)
  UnknownCharset(label: String)
  DeclaredCharsetOverridden(label: String)
  NulInText(count: Int)
  EightBitHeader

  // Header text, parameters and addresses (§H).
  InvalidEncodedWord(count: Int)
  /// A character, or an ISO-2022-JP shift state or UTF-16 byte order, was
  /// split between adjacent encoded-words, and carried across them.
  EncodedWordSplitCharacter
  AmbiguousParameter(name: String)
  MalformedParameter(name: String)
  InvalidAddress
  /// A Date or Resent-Date field that is not a date, or names no actual
  /// time.
  InvalidDate
  /// A message ID field needed one of the recoveries in `eml/message_id`.
  InvalidMessageId

  /// Recorded once when `max_diagnostics` is reached. Its severity is the
  /// worst severity among the diagnostics that were dropped.
  DiagnosticsTruncated(worst: Severity)
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
    DiagnosticsTruncated(worst) -> worst

    ByteOrderMark
    | NoBlankLineAfterHeaders
    | SpaceBeforeColon
    | NonstandardTransferEncoding(_)
    | MissingBase64Padding
    | ExcessBase64Padding(_)
    | NonZeroPadBits
    | TrailingSoftBreak
    | UnencodedOctets(_)
    | C1ReinterpretedAsWindows1252
    | NulInText(_)
    | EncodedWordSplitCharacter -> Info

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
    | InvalidQuotedPrintable(_)
    | NonAsciiInAscii
    | MalformedCharsetData(_)
    | UnknownCharset(_)
    | DeclaredCharsetOverridden(_)
    | EightBitHeader
    | InvalidEncodedWord(_)
    | AmbiguousParameter(_)
    | MalformedParameter(_)
    | InvalidAddress
    | InvalidDate
    | InvalidMessageId -> Warning

    MissingBoundary
    | UnusableBoundary
    | StartDelimiterNotFound
    | NotAMessage
    | UnknownTransferEncoding(_)
    | InvalidBase64Length
    | UnsupportedCharset(_) -> DataLoss
  }
}

pub fn new(kind: Kind, path: List(Int), span: Option(Span)) -> Diagnostic {
  Diagnostic(kind:, severity: severity(kind), path:, span:)
}

/// Combines diagnostics: counts are added up, and other kinds are kept
/// once, in order of first occurrence. Sorting rather than hashing keeps
/// this O(n log n) for any labels: on JavaScript, distinct labels can be
/// chosen to have equal hashes.
@internal
pub fn merge(kinds: List(Kind)) -> List(Kind) {
  kinds
  |> list.index_map(fn(kind, index) {
    let #(make, count) = split_count(kind)
    #(string.inspect(make(0)), index, make, count)
  })
  |> list.sort(fn(a, b) {
    order.break_tie(string.compare(a.0, b.0), int.compare(a.1, b.1))
  })
  |> group([])
  |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
  |> list.map(fn(entry) { entry.2(entry.3) })
}

/// Sums the counts of adjacent entries with the same key, keeping the
/// first entry's position.
fn group(
  sorted: List(#(String, Int, fn(Int) -> Kind, Int)),
  acc: List(#(String, Int, fn(Int) -> Kind, Int)),
) -> List(#(String, Int, fn(Int) -> Kind, Int)) {
  case sorted, acc {
    [], _ -> acc
    [entry, ..rest], [first, ..others] if entry.0 == first.0 ->
      group(rest, [#(first.0, first.1, first.2, first.3 + entry.3), ..others])
    [entry, ..rest], _ -> group(rest, [entry, ..acc])
  }
}

/// A kind as its constructor and its count. A kind without a count ignores
/// the count it is given. Every kind with a count must be listed here.
fn split_count(kind: Kind) -> #(fn(Int) -> Kind, Int) {
  case kind {
    MalformedCharsetData(n) -> #(MalformedCharsetData, n)
    NulInText(n) -> #(NulInText, n)
    InvalidQuotedPrintable(n) -> #(InvalidQuotedPrintable, n)
    InvalidEncodedWord(n) -> #(InvalidEncodedWord, n)
    StrayPadding(n) -> #(StrayPadding, n)
    InvalidBase64Characters(n) -> #(InvalidBase64Characters, n)
    ExcessBase64Padding(n) -> #(ExcessBase64Padding, n)
    UnencodedOctets(n) -> #(UnencodedOctets, n)
    _ -> #(fn(_) { kind }, 0)
  }
}
