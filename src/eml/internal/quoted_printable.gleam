//// Lenient quoted-printable decoding: the single pass in assumptions.md §F.2.
////
//// Literal runs are copied as slices of the input. Pending whitespace is
//// tracked by its start offset, so it is never rescanned. `loop` is the only
//// recursive function, so it compiles to a loop on JavaScript.

import eml/diagnostic.{type Kind, type Span, Span}
import eml/internal/structured.{slice}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, Some}

type Counters {
  Counters(invalid: Int, invalid_at: Int, unencoded: Int, unencoded_at: Int)
}

/// What follows a `=`.
type Equals {
  Escape(byte: Int)
  /// A soft line break; decoding resumes at `next`.
  SoftBreak(next: Int)
  /// `=` and optional whitespace at the end of the input.
  TrailingEquals(end: Int)
  /// Not an escape: the `=` is literal.
  LiteralEquals
}

/// Decodes `input`, whose first byte is at `offset` in the source.
pub fn decode(
  input: BitArray,
  offset: Int,
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  loop(input, input, 0, 0, -1, [], Counters(0, 0, 0, 0), offset)
}

fn loop(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  literal_start: Int,
  whitespace_start: Int,
  chunks: List(BitArray),
  counters: Counters,
  offset: Int,
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  case rest {
    <<c, rest:bytes>> if c == 32 || c == 9 -> {
      let whitespace_start = case whitespace_start < 0 {
        True -> pos
        False -> whitespace_start
      }
      loop(
        input,
        rest,
        pos + 1,
        literal_start,
        whitespace_start,
        chunks,
        counters,
        offset,
      )
    }

    // A hard line break: trailing whitespace before it is removed, and the
    // break itself is kept as it appears.
    <<c, _:bytes>> if c == 13 || c == 10 -> {
      let length = case rest {
        <<"\r\n", _:bytes>> -> 2
        _ -> 1
      }
      let next = slice(rest, length, -1)
      case whitespace_start < 0 {
        True ->
          loop(
            input,
            next,
            pos + length,
            literal_start,
            -1,
            chunks,
            counters,
            offset,
          )
        False ->
          loop(
            input,
            next,
            pos + length,
            pos,
            -1,
            emit(chunks, slice(input, literal_start, whitespace_start)),
            counters,
            offset,
          )
      }
    }

    <<"=", after:bytes>> -> {
      // Whitespace before `=` is significant, so it is flushed with the run.
      let flushed = emit(chunks, slice(input, literal_start, pos))
      case equals(after, pos) {
        Escape(byte) ->
          loop(
            input,
            slice(after, 2, -1),
            pos + 3,
            pos + 3,
            -1,
            emit(flushed, <<byte>>),
            counters,
            offset,
          )
        SoftBreak(next) ->
          loop(
            input,
            slice(input, next, -1),
            next,
            next,
            -1,
            flushed,
            counters,
            offset,
          )
        TrailingEquals(end) ->
          finish(flushed, counters, offset, [
            #(
              diagnostic.TrailingSoftBreak,
              Some(Span(offset + pos, offset + end)),
            ),
          ])
        LiteralEquals -> {
          // Keep the `=` in the literal run and continue at the next byte.
          let counters = case counters.invalid {
            0 -> Counters(..counters, invalid: 1, invalid_at: pos)
            n -> Counters(..counters, invalid: n + 1)
          }
          loop(
            input,
            after,
            pos + 1,
            literal_start,
            -1,
            chunks,
            counters,
            offset,
          )
        }
      }
    }

    <<c, rest:bytes>> -> {
      let counters = case c < 32 || c >= 127 {
        True ->
          case counters.unencoded {
            0 -> Counters(..counters, unencoded: 1, unencoded_at: pos)
            n -> Counters(..counters, unencoded: n + 1)
          }
        False -> counters
      }
      loop(input, rest, pos + 1, literal_start, -1, chunks, counters, offset)
    }

    _ -> {
      // EOF: pending trailing whitespace is dropped.
      let end = case whitespace_start < 0 {
        True -> pos
        False -> whitespace_start
      }
      finish(
        emit(chunks, slice(input, literal_start, end)),
        counters,
        offset,
        [],
      )
    }
  }
}

/// Classifies the bytes after a `=` at `pos`.
fn equals(after: BitArray, pos: Int) -> Equals {
  case after {
    <<h, l, _:bytes>> ->
      case hex(h), hex(l) {
        Ok(h), Ok(l) -> Escape(h * 16 + l)
        _, _ -> soft_break(after, pos + 1)
      }
    _ -> soft_break(after, pos + 1)
  }
}

fn soft_break(rest: BitArray, pos: Int) -> Equals {
  case rest {
    <<c, rest:bytes>> if c == 32 || c == 9 -> soft_break(rest, pos + 1)
    <<"\r\n", _:bytes>> -> SoftBreak(pos + 2)
    <<c, _:bytes>> if c == 13 || c == 10 -> SoftBreak(pos + 1)
    <<>> -> TrailingEquals(pos)
    _ -> LiteralEquals
  }
}

/// Adds output. Small pieces are appended to a bounded chunk at the head of
/// the list, so the list stays short and building it is linear on both
/// targets.
fn emit(chunks: List(BitArray), bits: BitArray) -> List(BitArray) {
  let size = bit_array.byte_size(bits)
  case size, chunks {
    0, _ -> chunks
    _, [chunk, ..rest] if size < 64 ->
      case bit_array.byte_size(chunk) < 64 {
        True -> [bit_array.append(chunk, bits), ..rest]
        False -> [bits, ..chunks]
      }
    _, _ -> [bits, ..chunks]
  }
}

fn finish(
  chunks: List(BitArray),
  counters: Counters,
  offset: Int,
  final: List(#(Kind, Option(Span))),
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  let at = fn(pos) { Some(Span(offset + pos, offset + pos + 1)) }
  let kinds = case counters.invalid {
    0 -> []
    n -> [#(diagnostic.InvalidQuotedPrintable(n), at(counters.invalid_at))]
  }
  let kinds = case counters.unencoded {
    0 -> kinds
    n ->
      list.append(kinds, [
        #(diagnostic.UnencodedOctets(n), at(counters.unencoded_at)),
      ])
  }
  #(bit_array.concat(list.reverse(chunks)), list.append(kinds, final))
}

/// The value of a hexadecimal digit.
pub fn hex(c: Int) -> Result(Int, Nil) {
  case c {
    _ if c >= 48 && c <= 57 -> Ok(c - 48)
    _ if c >= 65 && c <= 70 -> Ok(c - 55)
    _ if c >= 97 && c <= 102 -> Ok(c - 87)
    _ -> Error(Nil)
  }
}
