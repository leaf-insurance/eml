//// Dates (RFC 5322 §3.3 and §4.3): assumptions.md §H.5.

import eml
import eml/date.{Date}
import eml/mime
import gleam/option.{None, Some}

fn parse(value: String) {
  date.parse(<<value:utf8>>)
}

/// The components as a tuple: year, month, day, hour, minute, second,
/// offset, valid.
fn parts(value: String) {
  case parse(value) {
    Ok(date) ->
      Ok(#(
        date.year,
        date.month,
        date.day,
        date.hour,
        date.minute,
        date.second,
        date.offset,
        date.valid,
      ))
    Error(Nil) -> Error(Nil)
  }
}

pub fn rfc_5322_test() {
  assert parse(" Fri, 21 Nov 1997 09:55:06 -0600 ")
    == Ok(Date(
      year: 1997,
      month: 11,
      day: 21,
      hour: 9,
      minute: 55,
      second: 6,
      offset: -360,
      day_of_week: Some(5),
      valid: True,
      raw: "Fri, 21 Nov 1997 09:55:06 -0600",
    ))
  // RFC 5322 appendix A.5: comments and folding everywhere.
  assert parts(
      "Thu,\n      13\n        Feb\n          1969\n      23:32\n               -0330 (Newfoundland Time)",
    )
    == Ok(#(1969, 2, 13, 23, 32, 0, -210, True))
}

/// Cases from Stalwart mail-parser's `resources/date.json` (Apache-2.0 or
/// MIT) whose expected results follow RFC 5322.
pub fn stalwart_vectors_test() {
  assert parts("Tue, 1 Jul 2003 10:52:37 +0200")
    == Ok(#(2003, 7, 1, 10, 52, 37, 120, True))
  assert parts("Tue, 30 Dec 1969 23:32:54 -0330")
    == Ok(#(1969, 12, 30, 23, 32, 54, -210, True))
  assert parts(" 1 Jul 2003 (comment about date) 10:52:37 +0200")
    == Ok(#(2003, 7, 1, 10, 52, 37, 120, True))
  assert parts("Tue, 1 Jul 2003 ((tricky)\n comment) 10:52:37 +0200")
    == Ok(#(2003, 7, 1, 10, 52, 37, 120, True))
  assert parts("21 Nov 97 09:55:06 GMT")
    == Ok(#(1997, 11, 21, 9, 55, 6, 0, True))
  assert parts(" Wed, 27 Jun 99 04:11 +0900 ")
    == Ok(#(1999, 6, 27, 4, 11, 0, 540, True))
  assert parts("12 dec 2021 09:55:06 +0200")
    == Ok(#(2021, 12, 12, 9, 55, 6, 120, True))
  assert parts("Sun, 27 Oct 2002 23:57:07 EST")
    == Ok(#(2002, 10, 27, 23, 57, 7, -300, True))
  assert parts("Tue, 1 Jul 2003 10:52:37 PDT (Pacific)")
    == Ok(#(2003, 7, 1, 10, 52, 37, -420, True))
  assert parts("Thu, 10 Jul 1997 14:53:31 A")
    == Ok(#(1997, 7, 10, 14, 53, 31, 0, True))
  assert parts("17 May 2026 22:15:15 +1345")
    == Ok(#(2026, 5, 17, 22, 15, 15, 825, True))
  assert parts("Mon, 5 Jan 2004 10:00:00 +0100 (GMT+01:00)")
    == Ok(#(2004, 1, 5, 10, 0, 0, 60, True))
  assert parts("1 Jul 49 10:52:37 +0200")
    == Ok(#(2049, 7, 1, 10, 52, 37, 120, True))
  assert parts("1 Jul 50 10:52:37 +0200")
    == Ok(#(1950, 7, 1, 10, 52, 37, 120, True))
  assert parts("Tue, 1 Jul 2003 10:52:37 (UTC)")
    == Ok(#(2003, 7, 1, 10, 52, 37, 0, True))
  assert parts(" some numbers 0 1 2 but invalid ") == Error(Nil)
  assert parts("13 zzz 2021 09:55:06 +0200") == Error(Nil)
  assert parts("Tue, 7 00 2026 19:14:51 +0000") == Error(Nil)
  assert parts("01-Jan-2021 10:52:37 +0200") == Error(Nil)
  assert parts("Tue, 1 Jul 2003 10:52:37 +0200; x") == Error(Nil)
}

pub fn obsolete_years_test() {
  // Three digits: years since 1900.
  assert parts("1 Jul 103 10:52:37 +0200")
    == Ok(#(2003, 7, 1, 10, 52, 37, 120, True))
}

/// A zone whose meaning is not known, or no zone, counts as -0000.
pub fn unknown_zones_test() {
  assert parts("Tue, 1 Jul 2003 10:52:37 CEST")
    == Ok(#(2003, 7, 1, 10, 52, 37, 0, True))
  assert parts("Tue, 1 Jul 2003 10:52:37")
    == Ok(#(2003, 7, 1, 10, 52, 37, 0, True))
  // A zone name after a numeric zone is ignored.
  assert parts("Tue, 1 Jul 2003 10:52:37 +0200 CEST")
    == Ok(#(2003, 7, 1, 10, 52, 37, 120, True))
  assert parts("Tue, 1 Jul 2003 10:52:37 +0200 CEST x") == Error(Nil)
  assert parts("Tue, 1 Jul 2003 10:52:37 +5") == Error(Nil)
}

/// Components out of range are parsed, but not valid.
pub fn validity_test() {
  assert parts("Tue, 32 Jul 2003 25:61:61 +0200")
    == Ok(#(2003, 7, 32, 25, 61, 61, 120, False))
  assert parts("31 Apr 2003 10:00 +0000")
    == Ok(#(2003, 4, 31, 10, 0, 0, 0, False))
  assert parts("29 Feb 2001 10:00 +0000")
    == Ok(#(2001, 2, 29, 10, 0, 0, 0, False))
  assert parts("29 Feb 2000 10:00 +0000")
    == Ok(#(2000, 2, 29, 10, 0, 0, 0, True))
  assert parts("29 Feb 1900 10:00 +0000")
    == Ok(#(1900, 2, 29, 10, 0, 0, 0, False))
  assert parts("1 Jan 2000 10:00 +0060")
    == Ok(#(2000, 1, 1, 10, 0, 0, 60, False))
  // A leap second is valid.
  assert parts("31 Dec 2016 23:59:60 +0000")
    == Ok(#(2016, 12, 31, 23, 59, 60, 0, True))
}

pub fn day_of_week_test() {
  let assert Ok(d) = parse("Sunday, 1 Jan 2006 10:00 +0000")
  assert d.day_of_week == Some(7)
  let assert Ok(d) = parse("1 Jan 2006 10:00 +0000")
  assert d.day_of_week == None
  // Not checked against the date.
  let assert Ok(d) = parse("Mon, 1 Jan 2006 10:00 +0000")
  assert d.valid
  assert parse("Xyz, 1 Jan 2006 10:00 +0000") == Error(Nil)
}

pub fn to_unix_seconds_test() {
  let seconds = fn(value) {
    let assert Ok(d) = parse(value)
    date.to_unix_seconds(d)
  }
  assert seconds("Thu, 1 Jan 1970 00:00:00 +0000") == Ok(0)
  assert seconds("Fri, 21 Nov 1997 09:55:06 -0600") == Ok(880_127_706)
  assert seconds("Tue, 1 Jul 2003 10:52:37 +0200") == Ok(1_057_049_557)
  assert seconds("1 Mar 2000 00:00 +0000") == Ok(951_868_800)
  assert seconds("31 Dec 1969 23:59:59 +0000") == Ok(-1)
  assert seconds("1 Jan 1600 00:00 +0000") == Ok(-11_676_096_000)
  assert seconds("31 Dec 2016 23:59:60 +0000") == Ok(1_483_228_800)
  assert seconds("31 Apr 2003 10:00 +0000") == Error(Nil)
}

pub fn accessor_test() {
  let assert Ok(message) =
    eml.parse(<<
      "Date: Tue, 1 Jul 2003 10:52:37 +0200\r\nDate: nonsense\r\n\r\n",
    >>)
  let assert mime.Multiple([Ok(first), Error(Nil)]) =
    eml.date(eml.root(message))
  assert date.to_unix_seconds(first) == Ok(1_057_049_557)
}
