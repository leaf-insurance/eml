//// Dates: the Date and Resent-Date fields (RFC 5322 §3.3, assumptions.md
//// §H.5).
////
//// The obsolete syntax of RFC 5322 §4.3 is accepted: comments and
//// whitespace anywhere between the parts, two- and three-digit years, no
//// seconds, and alphabetic zones. As the RFC asks, a zone whose meaning is
//// not known (military letters, `CEST`, ...) counts as `-0000`, offset 0;
//// so does a missing zone. A numeric zone may be followed by a zone name
//// (`+0200 CEST`). Anything else is not a date.
////
//// Parsing checks only the syntax: `valid` says whether the components
//// name an actual time (no 31 April, no hour 24). The day of the week is
//// kept but not checked against the date.

import eml/encoded_word
import eml/internal/structured
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Date {
  Date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    /// Minutes east of UTC.
    offset: Int,
    /// 1 for Monday to 7 for Sunday, when the date names one.
    day_of_week: Option(Int),
    /// Whether the components name an actual time.
    valid: Bool,
    /// The field value, without surrounding whitespace.
    raw: String,
  )
}

/// Parses an unfolded Date field value. Returns `Error(Nil)` when it is
/// not a date.
pub fn parse(value: BitArray) -> Result(Date, Nil) {
  let rest = structured.skip_cfws(value)
  use #(day_of_week, rest) <- result.try(day_of_week(rest))
  use #(day, _, rest) <- result.try(number(rest, 1, 2))
  use #(month, rest) <- result.try(month(rest))
  use #(year, digits, rest) <- result.try(number(rest, 2, 9))
  use #(hour, _, rest) <- result.try(number(rest, 1, 2))
  use rest <- result.try(colon(rest))
  use #(minute, _, rest) <- result.try(number(rest, 2, 2))
  use #(second, rest) <- result.try(case colon(rest) {
    Ok(rest) ->
      number(rest, 2, 2)
      |> result.map(fn(second) { #(second.0, second.2) })
    Error(_) -> Ok(#(0, rest))
  })
  use #(offset, zone_valid) <- result.try(zone(rest))
  let year = case digits {
    2 if year < 50 -> 2000 + year
    2 | 3 -> 1900 + year
    _ -> year
  }
  let valid =
    zone_valid
    && day >= 1
    && day <= days_in_month(year, month)
    && hour <= 23
    && minute <= 59
    && second <= 60
  let raw = encoded_word.raw_text(structured.trim(value)).0
  Ok(Date(
    year:,
    month:,
    day:,
    hour:,
    minute:,
    second:,
    offset:,
    day_of_week:,
    valid:,
    raw:,
  ))
}

/// The date as seconds since 1970-01-01T00:00:00Z. A leap second counts as
/// the first second of the next minute. Returns `Error(Nil)` when the date
/// is not `valid`.
pub fn to_unix_seconds(date: Date) -> Result(Int, Nil) {
  case date.valid {
    False -> Error(Nil)
    True ->
      Ok(
        days_from_epoch(date.year, date.month, date.day)
        * 86_400
        + date.hour
        * 3600
        + date.minute
        * 60
        + date.second
        - date.offset
        * 60,
      )
  }
}

/// Days from 1970-01-01 to a date in the proleptic Gregorian calendar
/// (Howard Hinnant's `days_from_civil`).
fn days_from_epoch(year: Int, month: Int, day: Int) -> Int {
  let year = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = floor_divide(year, 400)
  let year_of_era = year - era * 400
  let day_of_year = { 153 * { { month + 9 } % 12 } + 2 } / 5 + day - 1
  let day_of_era =
    year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
  era * 146_097 + day_of_era - 719_468
}

fn floor_divide(a: Int, b: Int) -> Int {
  int.floor_divide(a, b) |> result.unwrap(0)
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    2 ->
      case year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 } {
        True -> 29
        False -> 28
      }
    4 | 6 | 9 | 11 -> 30
    _ -> 31
  }
}

const day_names = [
  #("mon", 1),
  #("tue", 2),
  #("wed", 3),
  #("thu", 4),
  #("fri", 5),
  #("sat", 6),
  #("sun", 7),
  #("monday", 1),
  #("tuesday", 2),
  #("wednesday", 3),
  #("thursday", 4),
  #("friday", 5),
  #("saturday", 6),
  #("sunday", 7),
]

const month_names = [
  "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov",
  "dec",
]

/// Zones that RFC 5322 §4.3 gives a meaning, and UTC. Any other alphabetic
/// zone is offset 0.
const zone_names = [
  #("ut", 0),
  #("utc", 0),
  #("gmt", 0),
  #("est", -300),
  #("edt", -240),
  #("cst", -360),
  #("cdt", -300),
  #("mst", -420),
  #("mdt", -360),
  #("pst", -480),
  #("pdt", -420),
]

/// An optional day of the week, and the comma after it.
fn day_of_week(rest: BitArray) -> Result(#(Option(Int), BitArray), Nil) {
  case word(rest) {
    #("", _) -> Ok(#(None, rest))
    #(name, rest) -> {
      use day <- result.try(list.key_find(day_names, name))
      case structured.skip_cfws(rest) {
        <<",", rest:bytes>> -> Ok(#(Some(day), structured.skip_cfws(rest)))
        rest -> Ok(#(Some(day), rest))
      }
    }
  }
}

fn month(rest: BitArray) -> Result(#(Int, BitArray), Nil) {
  let #(name, rest) = word(rest)
  use month <- result.try(index_of(month_names, name, 1))
  Ok(#(month, structured.skip_cfws(rest)))
}

fn index_of(names: List(String), name: String, index: Int) -> Result(Int, Nil) {
  case names {
    [] -> Error(Nil)
    [first, ..] if first == name -> Ok(index)
    [_, ..rest] -> index_of(rest, name, index + 1)
  }
}

fn colon(rest: BitArray) -> Result(BitArray, Nil) {
  case rest {
    <<":", rest:bytes>> -> Ok(structured.skip_cfws(rest))
    _ -> Error(Nil)
  }
}

/// The zone and whatever may follow it. Returns the offset, and whether its
/// minutes are in range.
fn zone(rest: BitArray) -> Result(#(Int, Bool), Nil) {
  case rest {
    <<sign, h1, h2, m1, m2, rest:bytes>>
      if { sign == 0x2B || sign == 0x2D }
      && h1 >= 0x30
      && h1 <= 0x39
      && h2 >= 0x30
      && h2 <= 0x39
      && m1 >= 0x30
      && m1 <= 0x39
      && m2 >= 0x30
      && m2 <= 0x39
    -> {
      let minutes = { m1 - 0x30 } * 10 + m2 - 0x30
      let offset = { { h1 - 0x30 } * 10 + h2 - 0x30 } * 60 + minutes
      let offset = case sign {
        0x2D -> -offset
        _ -> offset
      }
      // A zone name may follow: `+0200 CEST`.
      let rest = structured.skip_cfws(rest)
      let #(_, rest) = word(rest)
      use Nil <- result.try(end(rest))
      Ok(#(offset, minutes <= 59))
    }
    _ -> {
      let #(name, rest) = word(rest)
      use Nil <- result.try(end(rest))
      Ok(#(list.key_find(zone_names, name) |> result.unwrap(0), True))
    }
  }
}

fn end(rest: BitArray) -> Result(Nil, Nil) {
  case structured.skip_cfws(rest) {
    <<>> -> Ok(Nil)
    _ -> Error(Nil)
  }
}

/// A run of 1 to 9 ASCII digits, of at least `min` and at most `max`, and
/// the CFWS after it. Returns the value and the number of digits.
fn number(
  rest: BitArray,
  min: Int,
  max: Int,
) -> Result(#(Int, Int, BitArray), Nil) {
  let #(value, digits, rest) = digits(rest, 0, 0)
  case digits >= min && digits <= max {
    True -> Ok(#(value, digits, structured.skip_cfws(rest)))
    False -> Error(Nil)
  }
}

fn digits(rest: BitArray, value: Int, count: Int) -> #(Int, Int, BitArray) {
  case rest {
    <<c, rest:bytes>> if c >= 0x30 && c <= 0x39 && count < 10 ->
      digits(rest, value * 10 + c - 0x30, count + 1)
    _ -> #(value, count, rest)
  }
}

/// A run of ASCII letters, lowercased, and the CFWS after it.
fn word(rest: BitArray) -> #(String, BitArray) {
  word_loop(rest, [])
}

fn word_loop(rest: BitArray, acc: List(Int)) -> #(String, BitArray) {
  case rest {
    <<c, rest:bytes>> if c >= 0x41 && c <= 0x5A ->
      word_loop(rest, [c + 32, ..acc])
    <<c, rest:bytes>> if c >= 0x61 && c <= 0x7A -> word_loop(rest, [c, ..acc])
    _ -> {
      let name =
        list.reverse(acc)
        |> list.map(fn(c) { <<c>> })
        |> bit_array.concat
        |> bit_array.to_string
        |> result.unwrap("")
      #(name, structured.skip_cfws(rest))
    }
  }
}
