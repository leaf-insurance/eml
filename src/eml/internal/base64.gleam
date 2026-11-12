//// Lenient MIME base64 decoding: the state machine in assumptions.md §F.1.

import eml/diagnostic.{type Kind, type Span, Span}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}

// Decoder states: the number of symbols held, then P1 (one `=` seen after
// two symbols) and Done (padding complete).
const p1 = 4

const done = 5

/// Output is gathered in a small accumulator that is flushed to a list of
/// chunks, so building it is linear on both targets.
const chunk_limit = 96

type Counters {
  Counters(
    stray: Int,
    stray_at: Int,
    invalid: Int,
    invalid_at: Int,
    excess: Int,
    excess_at: Int,
    after_padding: Option(#(Int, Int)),
    nonzero_pad_at: Int,
  )
}

/// Decodes `input`, whose first byte is at `offset` in the source. Returns
/// the bytes and the diagnostics with their first span.
pub fn decode(
  input: BitArray,
  offset: Int,
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  let counters =
    Counters(
      stray: 0,
      stray_at: 0,
      invalid: 0,
      invalid_at: 0,
      excess: 0,
      excess_at: 0,
      after_padding: None,
      nonzero_pad_at: -1,
    )
  loop(input, offset, 0, 0, <<>>, [], 0, counters)
}

fn loop(
  rest: BitArray,
  pos: Int,
  state: Int,
  held: Int,
  chunk: BitArray,
  chunks: List(BitArray),
  length: Int,
  counters: Counters,
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  case rest {
    <<c, rest:bytes>> -> {
      let value = symbol(c)
      case value >= 0, c {
        // Alphabet.
        True, _ ->
          case state {
            0 -> loop(rest, pos + 1, 1, value, chunk, chunks, length, counters)
            1 | 2 ->
              loop(
                rest,
                pos + 1,
                state + 1,
                held * 64 + value,
                chunk,
                chunks,
                length,
                counters,
              )
            3 -> {
              let n = held * 64 + value
              let #(chunk, chunks) = emit(chunk, chunks, <<n:size(24)>>)
              loop(rest, pos + 1, 0, 0, chunk, chunks, length + 3, counters)
            }
            _ -> {
              // Data after padding: decoding continues with a new quantum.
              let counters = case counters.after_padding {
                None ->
                  Counters(..counters, after_padding: Some(#(length, pos)))
                Some(_) -> counters
              }
              loop(rest, pos + 1, 1, value, chunk, chunks, length, counters)
            }
          }
        // Padding.
        False, 61 ->
          case state {
            0 | 1 -> {
              let counters = case counters.stray {
                0 -> Counters(..counters, stray: 1, stray_at: pos)
                n -> Counters(..counters, stray: n + 1)
              }
              loop(rest, pos + 1, state, held, chunk, chunks, length, counters)
            }
            2 -> {
              let counters = pad_bits(counters, held % 16, pos)
              let #(chunk, chunks) = emit(chunk, chunks, <<{ held / 16 }>>)
              loop(rest, pos + 1, p1, 0, chunk, chunks, length + 1, counters)
            }
            3 -> {
              let counters = pad_bits(counters, held % 4, pos)
              let #(chunk, chunks) =
                emit(chunk, chunks, <<{ held / 4 }:size(16)>>)
              loop(rest, pos + 1, done, 0, chunk, chunks, length + 2, counters)
            }
            4 -> loop(rest, pos + 1, done, 0, chunk, chunks, length, counters)
            _ -> {
              let counters = case counters.excess {
                0 -> Counters(..counters, excess: 1, excess_at: pos)
                n -> Counters(..counters, excess: n + 1)
              }
              loop(rest, pos + 1, done, 0, chunk, chunks, length, counters)
            }
          }
        // Whitespace is skipped silently.
        False, 32 | False, 9 | False, 13 | False, 10 ->
          loop(rest, pos + 1, state, held, chunk, chunks, length, counters)
        // Any other byte is skipped and counted.
        False, _ -> {
          let counters = case counters.invalid {
            0 -> Counters(..counters, invalid: 1, invalid_at: pos)
            n -> Counters(..counters, invalid: n + 1)
          }
          loop(rest, pos + 1, state, held, chunk, chunks, length, counters)
        }
      }
    }
    _ -> finish(pos, state, held, chunk, chunks, length, counters)
  }
}

fn finish(
  pos: Int,
  state: Int,
  held: Int,
  chunk: BitArray,
  chunks: List(BitArray),
  length: Int,
  counters: Counters,
) -> #(BitArray, List(#(Kind, Option(Span)))) {
  let eof = Some(Span(pos, pos))
  let #(chunk, chunks, counters, final) = case state {
    1 -> #(chunk, chunks, counters, [#(diagnostic.InvalidBase64Length, eof)])
    2 -> {
      let counters = pad_bits(counters, held % 16, pos)
      let #(chunk, chunks) = emit(chunk, chunks, <<{ held / 16 }>>)
      #(chunk, chunks, counters, [#(diagnostic.MissingBase64Padding, eof)])
    }
    3 -> {
      let counters = pad_bits(counters, held % 4, pos)
      let #(chunk, chunks) = emit(chunk, chunks, <<{ held / 4 }:size(16)>>)
      #(chunk, chunks, counters, [#(diagnostic.MissingBase64Padding, eof)])
    }
    4 -> #(chunk, chunks, counters, [#(diagnostic.MissingBase64Padding, eof)])
    _ -> #(chunk, chunks, counters, [])
  }
  let _ = length
  let bytes = bit_array.concat(list.reverse([chunk, ..chunks]))
  #(bytes, list.append(diagnostics(counters), final))
}

fn diagnostics(counters: Counters) -> List(#(Kind, Option(Span))) {
  let at = fn(pos) { Some(Span(pos, pos + 1)) }
  []
  |> prepend(counters.stray > 0, #(
    diagnostic.StrayPadding(counters.stray),
    at(counters.stray_at),
  ))
  |> prepend(counters.invalid > 0, #(
    diagnostic.InvalidBase64Characters(counters.invalid),
    at(counters.invalid_at),
  ))
  |> prepend(counters.excess > 0, #(
    diagnostic.ExcessBase64Padding(counters.excess),
    at(counters.excess_at),
  ))
  |> prepend(counters.nonzero_pad_at >= 0, #(
    diagnostic.NonZeroPadBits,
    at(counters.nonzero_pad_at),
  ))
  |> fn(kinds) {
    case counters.after_padding {
      Some(#(length, pos)) -> [
        #(diagnostic.Base64DataAfterPadding(length), at(pos)),
        ..kinds
      ]
      None -> kinds
    }
  }
  |> list.reverse
}

fn prepend(list: List(a), condition: Bool, item: a) -> List(a) {
  case condition {
    True -> [item, ..list]
    False -> list
  }
}

fn pad_bits(counters: Counters, bits: Int, pos: Int) -> Counters {
  case bits != 0 && counters.nonzero_pad_at < 0 {
    True -> Counters(..counters, nonzero_pad_at: pos)
    False -> counters
  }
}

fn emit(
  chunk: BitArray,
  chunks: List(BitArray),
  bytes: BitArray,
) -> #(BitArray, List(BitArray)) {
  case bit_array.byte_size(chunk) >= chunk_limit {
    True -> #(bytes, [chunk, ..chunks])
    False -> #(bit_array.append(chunk, bytes), chunks)
  }
}

fn symbol(c: Int) -> Int {
  case c {
    _ if c >= 65 && c <= 90 -> c - 65
    _ if c >= 97 && c <= 122 -> c - 71
    _ if c >= 48 && c <= 57 -> c + 4
    43 -> 62
    47 -> 63
    _ -> -1
  }
}
