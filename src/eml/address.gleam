//// Address lists: From, To, Cc, Reply-To and the like (RFC 5322 §3.4,
//// RFC 6854, assumptions.md §H.2).
////
//// Parsing is lenient, following RFC 7103 §7.1:
////
//// - a source route `<@a,@b:x@y>` is dropped;
//// - extra angle brackets `<<x@y>>` are ignored;
//// - an unclosed `<x@y` is closed at a comma or the end;
//// - an unclosed comment or quoted string ends before a `<`;
//// - a lone local part (`To: Joe`) is a mailbox without a domain, with an
////   `InvalidAddress` diagnostic.
////
//// It is strict about identities. A local part must be words separated by
//// dots, and a domain atoms separated by dots (or a domain literal);
//// whitespace and comments may surround the dots. Anything else, including
//// control characters, makes the whole address `Invalid`. Local parts and
//// domains are never decoded or charset-guessed.
////
//// One further recovery: in `ceo@example.com <other@example.net>`, the
//// address is `other@example.net`, with `ceo@example.com` as its display
//// name, and an `InvalidAddress` diagnostic. Mail clients display it that
//// way.
////
//// Display names have RFC 2047 encoded-words decoded, also inside quoted
//// strings. Decoded text is not sanitised: it can contain line breaks and
//// NUL, so escape it before writing it into another header or a log.

import eml/charset
import eml/diagnostic.{type Kind}
import eml/encoded_word
import eml/internal/structured.{slice}
import eml/internal/utf8
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Mailbox {
  /// `domain` is `None` for a lone local part, and for the null path `<>`
  /// (an empty local part).
  Mailbox(name: Option(String), local_part: String, domain: Option(String))
}

pub type Address {
  Individual(Mailbox)
  /// A group; RFC 6854 allows them in From. Members are always mailboxes.
  Group(name: String, members: List(Mailbox))
  /// A part of the list that is not an address, kept as text.
  Invalid(raw: String)
}

/// The address of a mailbox, `local@domain`. A local part that needs quoting
/// is quoted.
pub fn to_string(mailbox: Mailbox) -> String {
  let local = case needs_quoting(mailbox.local_part) {
    True ->
      "\""
      <> mailbox.local_part
      |> string.replace("\\", "\\\\")
      |> string.replace("\"", "\\\"")
      <> "\""
    False -> mailbox.local_part
  }
  case mailbox.domain {
    Some(domain) -> local <> "@" <> domain
    None -> local
  }
}

fn needs_quoting(local: String) -> Bool {
  local == ""
  || string.starts_with(local, ".")
  || string.ends_with(local, ".")
  || string.contains(local, "..")
  || list.any(string.to_utf_codepoints(local), fn(c) {
    // ( ) < > [ ] : ; @ \ , " SP TAB
    case string.utf_codepoint_to_int(c) {
      40 | 41 | 60 | 62 | 91 | 93 | 58 | 59 | 64 | 92 | 44 | 34 | 32 | 9 -> True
      _ -> False
    }
  })
}

/// All mailboxes in a list, including group members. Lone local parts are
/// included, with no domain.
pub fn mailboxes(addresses: List(Address)) -> List(Mailbox) {
  list.flat_map(addresses, fn(address) {
    case address {
      Individual(mailbox) -> [mailbox]
      Group(members:, ..) -> members
      Invalid(_) -> []
    }
  })
}

// ---------------------------------------------------------------------------
// Tokens

type TokenKind {
  Atom(BitArray)
  Quoted(BitArray)
  Literal(BitArray)
  Comment(BitArray)
  Special(Int)
}

/// `space` records whether whitespace preceded the token. `start` is its
/// offset in the value.
type Token {
  Token(kind: TokenKind, space: Bool, start: Int)
}

const dot = 46

const at = 64

const comma = 44

const less = 60

const greater = 62

const colon = 58

const semicolon = 59

/// After the first unterminated comment or quoted string, later ones are
/// only searched for up to the next `<`. This keeps tokenising linear: the
/// first search reaches the end of the value, and later searches stop where
/// recovery would resume.
fn tokenise(input: BitArray) -> List(Token) {
  tokenise_loop(input, input, 0, False, False, [])
}

fn tokenise_loop(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  space: Bool,
  bounded: Bool,
  acc: List(Token),
) -> List(Token) {
  case rest {
    <<c, rest:bytes>> if c == 32 || c == 9 || c == 13 || c == 10 ->
      tokenise_loop(input, rest, pos + 1, True, bounded, acc)
    <<"\"", _:bytes>> -> {
      let #(content, end, found) = quoted(input, pos + 1, bounded)
      let acc = [Token(Quoted(content), space, pos), ..acc]
      let bounded = bounded || !found
      tokenise_loop(input, slice(input, end, -1), end, False, bounded, acc)
    }
    <<"(", _:bytes>> -> {
      let #(content, end, found) = comment(input, pos + 1, bounded)
      let acc = [Token(Comment(content), space, pos), ..acc]
      let bounded = bounded || !found
      tokenise_loop(input, slice(input, end, -1), end, True, bounded, acc)
    }
    <<"[", _:bytes>> -> {
      let end = literal_end(rest, pos)
      let acc = [Token(Literal(slice(input, pos, end)), space, pos), ..acc]
      tokenise_loop(input, slice(input, end, -1), end, False, bounded, acc)
    }
    <<"=?", _:bytes>> ->
      case encoded_word_length(rest) {
        Ok(length) -> {
          let end = pos + length
          let acc = [Token(Atom(slice(input, pos, end)), space, pos), ..acc]
          tokenise_loop(input, slice(input, end, -1), end, False, bounded, acc)
        }
        Error(_) -> {
          let #(token, end) = atom_token(input, rest, pos, space)
          tokenise_loop(input, slice(input, end, -1), end, False, bounded, [
            token,
            ..acc
          ])
        }
      }
    <<_, _:bytes>> -> {
      let #(token, end) = atom_token(input, rest, pos, space)
      tokenise_loop(input, slice(input, end, -1), end, False, bounded, [
        token,
        ..acc
      ])
    }
    _ -> list.reverse(acc)
  }
}

/// An atom, or a single special character, and its end. Always consumes
/// at least one byte. (Not recursive: `tokenise_loop` must be the only loop,
/// so that it compiles to one on JavaScript.)
fn atom_token(
  input: BitArray,
  rest: BitArray,
  pos: Int,
  space: Bool,
) -> #(Token, Int) {
  case atom_end(rest, pos), rest {
    end, _ if end > pos -> #(
      Token(Atom(slice(input, pos, end)), space, pos),
      end,
    )
    _, <<c, _:bytes>> -> #(Token(Special(c), space, pos), pos + 1)
    _, _ -> #(Token(Special(0), space, pos), pos + 1)
  }
}

fn atom_end(rest: BitArray, pos: Int) -> Int {
  case rest {
    <<c, _:bytes>>
      if c == 32
      || c == 9
      || c == 13
      || c == 10
      || c == 34
      || c == 40
      || c == 41
      || c == 91
      || c == 93
      || c == dot
      || c == at
      || c == comma
      || c == less
      || c == greater
      || c == colon
      || c == semicolon
    -> pos
    <<_, rest:bytes>> -> atom_end(rest, pos + 1)
    _ -> pos
  }
}

/// The length of an encoded-word `=?charset?X?text?=` at the start of
/// `bits`, without whitespace, at most 256 bytes.
fn encoded_word_length(bits: BitArray) -> Result(Int, Nil) {
  case bits {
    <<"=?", rest:bytes>> -> encoded_word_loop(rest, 2, 0)
    _ -> Error(Nil)
  }
}

/// `part` counts the `?` separators seen: charset, encoding, then text.
fn encoded_word_loop(
  rest: BitArray,
  length: Int,
  part: Int,
) -> Result(Int, Nil) {
  case rest {
    _ if length > 256 -> Error(Nil)
    <<"?=", _:bytes>> if part >= 2 -> Ok(length + 2)
    <<"?", rest:bytes>> -> encoded_word_loop(rest, length + 1, part + 1)
    <<c, _:bytes>> if c == 32 || c == 9 || c == 13 || c == 10 -> Error(Nil)
    <<_, rest:bytes>> -> encoded_word_loop(rest, length + 1, part)
    _ -> Error(Nil)
  }
}

fn literal_end(rest: BitArray, pos: Int) -> Int {
  case rest {
    <<"]", _:bytes>> -> pos + 1
    <<_, rest:bytes>> -> literal_end(rest, pos + 1)
    _ -> pos
  }
}

/// Reads a quoted string starting after its quote. Returns its content, the
/// end, and whether the closing quote was found. An unterminated quoted
/// string ends before the next `<` (RFC 7103 §7.1.6), or at the end. When
/// `bounded`, the search stops at the next `<`.
fn quoted(
  input: BitArray,
  start: Int,
  bounded: Bool,
) -> #(BitArray, Int, Bool) {
  case quoted_loop(slice(input, start, -1), start, bounded, []) {
    Ok(#(content, end)) -> #(content, end, True)
    Error(_) -> {
      let end = find(slice(input, start, -1), less, start)
      #(unescape(slice(input, start, end), []), end, False)
    }
  }
}

fn quoted_loop(
  rest: BitArray,
  pos: Int,
  bounded: Bool,
  acc: List(BitArray),
) -> Result(#(BitArray, Int), Nil) {
  case rest {
    <<"\"", _:bytes>> -> Ok(#(acc |> list.reverse |> bit_array.concat, pos + 1))
    <<"<", _:bytes>> if bounded -> Error(Nil)
    <<"\\", c, rest:bytes>> ->
      quoted_loop(rest, pos + 2, bounded, [<<c>>, ..acc])
    <<c, rest:bytes>> -> quoted_loop(rest, pos + 1, bounded, [<<c>>, ..acc])
    _ -> Error(Nil)
  }
}

fn unescape(bits: BitArray, acc: List(BitArray)) -> BitArray {
  case bits {
    <<"\\", c, rest:bytes>> -> unescape(rest, [<<c>>, ..acc])
    <<c, rest:bytes>> -> unescape(rest, [<<c>>, ..acc])
    _ -> acc |> list.reverse |> bit_array.concat
  }
}

/// Reads a comment starting after its `(`. Comments nest. An unterminated
/// comment ends before the next `<` (RFC 7103 §7.1.4), or at the end. When
/// `bounded`, the search stops at the next `<`.
fn comment(
  input: BitArray,
  start: Int,
  bounded: Bool,
) -> #(BitArray, Int, Bool) {
  case comment_loop(slice(input, start, -1), start, 1, bounded) {
    Ok(end) -> #(slice(input, start, end - 1), end, True)
    Error(_) -> {
      let end = find(slice(input, start, -1), less, start)
      #(slice(input, start, end), end, False)
    }
  }
}

fn comment_loop(
  rest: BitArray,
  pos: Int,
  depth: Int,
  bounded: Bool,
) -> Result(Int, Nil) {
  case rest {
    <<")", rest:bytes>> ->
      case depth {
        1 -> Ok(pos + 1)
        _ -> comment_loop(rest, pos + 1, depth - 1, bounded)
      }
    <<"<", _:bytes>> if bounded -> Error(Nil)
    <<"(", rest:bytes>> -> comment_loop(rest, pos + 1, depth + 1, bounded)
    <<"\\", _, rest:bytes>> -> comment_loop(rest, pos + 2, depth, bounded)
    <<_, rest:bytes>> -> comment_loop(rest, pos + 1, depth, bounded)
    _ -> Error(Nil)
  }
}

fn find(rest: BitArray, byte: Int, pos: Int) -> Int {
  case rest {
    <<c, _:bytes>> if c == byte -> pos
    <<_, rest:bytes>> -> find(rest, byte, pos + 1)
    _ -> pos
  }
}

// ---------------------------------------------------------------------------
// Parsing

type Context {
  Context(input: BitArray, options: charset.Options)
}

/// Parses an unfolded address list field value.
pub fn parse(
  value: BitArray,
  options: charset.Options,
) -> #(List(Address), List(Kind)) {
  list_loop(tokenise(value), Context(value, options), [], [])
}

fn list_loop(
  tokens: List(Token),
  context: Context,
  acc: List(Address),
  kinds: List(Kind),
) -> #(List(Address), List(Kind)) {
  case skip_specials(tokens, [comma, greater, semicolon]) {
    [] -> #(list.reverse(acc), list.reverse(kinds))
    tokens -> {
      let #(address, rest, address_kinds) = address(tokens, context, False)
      let kinds = list.append(list.reverse(address_kinds), kinds)
      list_loop(rest, context, [address, ..acc], kinds)
    }
  }
}

fn skip_specials(tokens: List(Token), specials: List(Int)) -> List(Token) {
  case tokens {
    [Token(Special(c), _, _), ..rest] ->
      case list.contains(specials, c) {
        True -> skip_specials(rest, specials)
        False -> tokens
      }
    [Token(Comment(_), _, _), ..rest] -> skip_specials(rest, specials)
    _ -> tokens
  }
}

fn skip_comments(tokens: List(Token)) -> List(Token) {
  case tokens {
    [Token(Comment(_), _, _), ..rest] -> skip_comments(rest)
    _ -> tokens
  }
}

/// Parses one address, and returns the tokens after it. Inside a group,
/// another group is invalid; it is never parsed recursively.
fn address(
  tokens: List(Token),
  context: Context,
  in_group: Bool,
) -> #(Address, List(Token), List(Kind)) {
  let #(phrase, rest) = list.split_while(tokens, is_phrase)
  case rest {
    [Token(Special(c), _, _), ..after] if c == less -> {
      let #(name, name_kinds) = display_name(phrase, context)
      angle_address(tokens, after, name, name_kinds, context)
    }
    [Token(Special(c), _, _), ..after] if c == colon && !in_group -> {
      let #(name, kinds) = display_name(phrase, context)
      let #(members, rest, member_kinds) = group_members(after, context, [], [])
      #(
        Group(option.unwrap(name, ""), members),
        rest,
        list.append(kinds, member_kinds),
      )
    }
    [Token(Special(c), _, _), ..after] if c == at -> {
      let #(domain, after_domain) = list.split_while(after, is_domain)
      let #(domain, comment) = trailing_comments(domain)
      case after_domain, spec(phrase, Some(domain)) {
        // `ceo@example.com <other@example.net>`: the bare address is the
        // display name of the angle address.
        [Token(Special(c), _, start), ..after], _ if c == less -> {
          let first = case tokens {
            [first, ..] -> first.start
            [] -> start
          }
          let #(name, name_kinds) =
            encoded_word.decode(
              slice(context.input, first, start),
              context.options,
            )
          let name = case name {
            "" -> None
            name -> Some(name)
          }
          let #(address, rest, kinds) =
            angle_address(tokens, after, name, name_kinds, context)
          #(address, rest, [diagnostic.InvalidAddress, ..kinds])
        }
        [], Ok(#(local, domain))
        | [Token(Special(44), _, _), ..], Ok(#(local, domain))
        | [Token(Special(59), _, _), ..], Ok(#(local, domain))
        | [Token(Special(62), _, _), ..], Ok(#(local, domain))
        -> {
          let #(name, kinds) = case comment {
            Some(text) -> comment_name(text, context)
            None -> #(None, [])
          }
          #(Individual(Mailbox(name, local, domain)), after_domain, kinds)
        }
        _, _ -> invalid(tokens, after_domain, context)
      }
    }
    _ ->
      case list.filter(phrase, not_comment), rest {
        // A lone local part (RFC 7103 §7.1.7).
        [Token(Atom(_), _, _) as word], _
        | [Token(Quoted(_), _, _) as word], _
        ->
          case spec([word], None) {
            Ok(#(local, None)) -> #(
              Individual(Mailbox(None, local, None)),
              rest,
              [diagnostic.InvalidAddress],
            )
            _ -> invalid(tokens, rest, context)
          }
        _, _ -> invalid(tokens, rest, context)
      }
  }
}

/// Parses an angle address after its `<`. `tokens` is where the address
/// started, for the raw text of an invalid address.
fn angle_address(
  tokens: List(Token),
  after: List(Token),
  name: Option(String),
  name_kinds: List(Kind),
  context: Context,
) -> #(Address, List(Token), List(Kind)) {
  let after = skip_specials(after, [less])
  case route(after) {
    Error(rest) -> invalid(tokens, rest, context)
    Ok(after) -> {
      let #(local, rest) = list.split_while(after, is_phrase)
      let #(domain, rest) = case rest {
        [Token(Special(c), _, _), ..rest] if c == at -> {
          let #(domain, rest) = list.split_while(rest, is_domain)
          #(Some(domain), rest)
        }
        _ -> #(None, rest)
      }
      let after_spec = skip_comments(rest)
      // A closed angle address, or one ended by a comma (RFC 7103 §7.1.5)
      // or the end of the value.
      let closed = case after_spec {
        [Token(Special(c), _, _), ..rest] if c == greater ->
          Ok(skip_specials(rest, [greater]))
        [Token(Special(c), _, _), ..] if c == comma -> Ok(after_spec)
        [] -> Ok([])
        _ -> Error(Nil)
      }
      case closed, local, domain {
        // Anything else inside the brackets: skip to the closing `>`.
        Error(_), _, _ -> invalid(tokens, to_closing(after_spec), context)
        // The null path `<>`.
        Ok(rest), [], None -> #(
          Individual(Mailbox(name, "", None)),
          rest,
          name_kinds,
        )
        Ok(rest), _, _ ->
          case spec(local, domain) {
            Ok(#(local, domain)) -> #(
              Individual(Mailbox(name, local, domain)),
              rest,
              name_kinds,
            )
            Error(_) -> invalid(tokens, rest, context)
          }
      }
    }
  }
}

/// Drops an obsolete source route `@a,@b:`. The route must end with a `:`
/// before the closing `>` or a comma.
fn route(tokens: List(Token)) -> Result(List(Token), List(Token)) {
  case tokens {
    [Token(Special(c), _, _), ..] if c == at -> route_loop(tokens)
    _ -> Ok(tokens)
  }
}

fn route_loop(tokens: List(Token)) -> Result(List(Token), List(Token)) {
  case tokens {
    [Token(Special(c), _, _), ..rest] if c == colon -> Ok(rest)
    [Token(Special(c), _, _), ..] if c == greater -> Error(to_closing(tokens))
    [Token(Special(c), _, _), ..rest] if c == comma ->
      case rest {
        [Token(Special(c), _, _), ..] if c == at -> route_loop(rest)
        _ -> Error(tokens)
      }
    [_, ..rest] -> route_loop(rest)
    [] -> Error([])
  }
}

/// Skips to just after the `>` that closes an angle address, stopping
/// before a comma.
fn to_closing(tokens: List(Token)) -> List(Token) {
  case tokens {
    [Token(Special(c), _, _), ..rest] if c == greater -> rest
    [Token(Special(c), _, _), ..] if c == comma -> tokens
    [_, ..rest] -> to_closing(rest)
    [] -> []
  }
}

/// Splits comments off the end of a domain. The first of them is the name
/// in the legacy form `user@host (Full Name)`.
fn trailing_comments(domain: List(Token)) -> #(List(Token), Option(BitArray)) {
  let #(comments, rest) =
    list.split_while(list.reverse(domain), fn(token) { !not_comment(token) })
  let name = case list.reverse(comments) {
    [Token(Comment(text), _, _), ..] -> Some(text)
    _ -> None
  }
  #(list.reverse(rest), name)
}

/// Group members: mailboxes, up to the `;` that ends the group. A nested
/// group is invalid and dropped.
fn group_members(
  tokens: List(Token),
  context: Context,
  acc: List(Mailbox),
  kinds: List(Kind),
) -> #(List(Mailbox), List(Token), List(Kind)) {
  case skip_specials(tokens, [comma]) {
    [] -> #(list.reverse(acc), [], list.reverse(kinds))
    [Token(Special(c), _, _), ..rest] if c == semicolon -> #(
      list.reverse(acc),
      rest,
      list.reverse(kinds),
    )
    tokens -> {
      let #(member, rest, member_kinds) = address(tokens, context, True)
      let kinds = list.append(list.reverse(member_kinds), kinds)
      case member {
        Individual(mailbox) ->
          group_members(rest, context, [mailbox, ..acc], kinds)
        _ -> group_members(rest, context, acc, kinds)
      }
    }
  }
}

/// An invalid address runs to the next comma, or the end of a group. Its
/// raw text is taken from the value.
fn invalid(
  tokens: List(Token),
  rest: List(Token),
  context: Context,
) -> #(Address, List(Token), List(Kind)) {
  // Always make progress. Lists are compared by their first token's
  // offset: structural equality on lists is linear, and on JavaScript it
  // walks the whole tail.
  let rest = case rest, tokens {
    [a, ..], [b, ..] if a.start == b.start -> list.drop(rest, 1)
    _, _ -> rest
  }
  let #(_, rest) =
    list.split_while(rest, fn(token) {
      token.kind != Special(comma) && token.kind != Special(semicolon)
    })
  let start = case tokens {
    [first, ..] -> first.start
    [] -> 0
  }
  let end = case rest {
    [next, ..] -> next.start
    [] -> bit_array.byte_size(context.input)
  }
  let raw =
    encoded_word.raw_text(structured.trim(slice(context.input, start, end))).0
  #(Invalid(raw), rest, [diagnostic.InvalidAddress])
}

fn is_phrase(token: Token) -> Bool {
  case token.kind {
    Atom(_) | Quoted(_) | Comment(_) -> True
    Special(c) -> c == dot
    Literal(_) -> False
  }
}

fn is_domain(token: Token) -> Bool {
  case token.kind {
    Atom(_) | Literal(_) | Comment(_) -> True
    Special(c) -> c == dot
    Quoted(_) -> False
  }
}

fn not_comment(token: Token) -> Bool {
  case token.kind {
    Comment(_) -> False
    _ -> True
  }
}

/// Validates and assembles a local part and an optional domain.
fn spec(
  local: List(Token),
  domain: Option(List(Token)),
) -> Result(#(String, Option(String)), Nil) {
  case dotted(list.filter(local, not_comment), True, []) {
    Ok(local) ->
      case domain {
        None -> Ok(#(local, None))
        Some(domain) ->
          case list.filter(domain, not_comment) {
            [Token(Literal(bytes), _, _)] ->
              identity(bytes) |> result_map(fn(d) { #(local, Some(d)) })
            domain ->
              case dotted(domain, False, []) {
                Ok(domain) -> Ok(#(local, Some(domain)))
                Error(_) -> Error(Nil)
              }
          }
      }
    Error(_) -> Error(Nil)
  }
}

fn result_map(result: Result(a, Nil), f: fn(a) -> b) -> Result(b, Nil) {
  case result {
    Ok(a) -> Ok(f(a))
    Error(_) -> Error(Nil)
  }
}

/// `word ("." word)*`. Local parts accept quoted strings as words.
fn dotted(
  tokens: List(Token),
  local: Bool,
  acc: List(BitArray),
) -> Result(String, Nil) {
  dotted_loop(tokens, local, True, acc)
}

/// `expect_word` alternates: a word, then a dot or the end.
fn dotted_loop(
  tokens: List(Token),
  local: Bool,
  expect_word: Bool,
  acc: List(BitArray),
) -> Result(String, Nil) {
  case expect_word, tokens {
    True, [Token(Atom(bytes), _, _), ..rest] ->
      dotted_loop(rest, local, False, [bytes, ..acc])
    True, [Token(Quoted(bytes), _, _), ..rest] if local ->
      dotted_loop(rest, local, False, [bytes, ..acc])
    False, [] -> identity(acc |> list.reverse |> bit_array.concat)
    False, [Token(Special(c), _, _), ..rest] if c == dot ->
      dotted_loop(rest, local, True, [<<".">>, ..acc])
    _, _ -> Error(Nil)
  }
}

/// Identity bytes must be UTF-8 without control characters.
fn identity(bytes: BitArray) -> Result(String, Nil) {
  case has_control(bytes) {
    True -> Error(Nil)
    False -> utf8.to_string(bytes)
  }
}

fn has_control(bytes: BitArray) -> Bool {
  case bytes {
    <<c, _:bytes>> if c < 0x20 || c == 0x7F -> True
    <<_, rest:bytes>> -> has_control(rest)
    _ -> False
  }
}

/// The display name: words joined by single spaces, with encoded-words
/// decoded. Comments are not part of it.
fn display_name(
  phrase: List(Token),
  context: Context,
) -> #(Option(String), List(Kind)) {
  case list.filter(phrase, not_comment) {
    [] -> #(None, [])
    [first, ..rest] -> {
      let bytes =
        list.fold(rest, [token_bytes(first)], fn(acc, token) {
          case token.space {
            True -> [token_bytes(token), <<" ">>, ..acc]
            False -> [token_bytes(token), ..acc]
          }
        })
        |> list.reverse
        |> bit_array.concat
      case encoded_word.decode(bytes, context.options) {
        #("", kinds) -> #(None, kinds)
        #(name, kinds) -> #(Some(name), kinds)
      }
    }
  }
}

fn comment_name(
  text: BitArray,
  context: Context,
) -> #(Option(String), List(Kind)) {
  case encoded_word.decode(text, context.options) {
    #("", kinds) -> #(None, kinds)
    #(name, kinds) -> #(Some(name), kinds)
  }
}

fn token_bytes(token: Token) -> BitArray {
  case token.kind {
    Atom(bytes) | Quoted(bytes) | Literal(bytes) -> bytes
    Special(c) -> <<c>>
    Comment(_) -> <<>>
  }
}
