// Small ASCII byte-string helpers mirroring the Python `bytes` methods that
// h11 relies on (`lower`, `strip`, `split`, `title`, `repr`, ...).

///|
/// Python's `bytes.isspace` set: space, \t, \n, \r, \x0b, \x0c.
fn is_ascii_whitespace(b : Byte) -> Bool {
  b is (b' ' | b'\t' | b'\n' | b'\r' | b'\x0b' | b'\x0c')
}

///|
fn is_ascii_upper(b : Byte) -> Bool {
  b >= b'A' && b <= b'Z'
}

///|
fn is_ascii_lower(b : Byte) -> Bool {
  b >= b'a' && b <= b'z'
}

///|
fn is_digit(b : Byte) -> Bool {
  b >= b'0' && b <= b'9'
}

///|
fn hex_value(b : Byte) -> Int? {
  if is_digit(b) {
    Some((b - b'0').to_int())
  } else if b >= b'a' && b <= b'f' {
    Some((b - b'a').to_int() + 10)
  } else if b >= b'A' && b <= b'F' {
    Some((b - b'A').to_int() + 10)
  } else {
    None
  }
}

///|
fn ascii_lower(s : BytesView) -> Bytes {
  Bytes::makei(s.length(), i => {
    let b = s[i]
    if is_ascii_upper(b) {
      b + 32
    } else {
      b
    }
  })
}

///|
/// Python's `bytes.title()` restricted to ASCII: the first letter of every
/// run of letters is upper-cased, the rest lower-cased.
fn ascii_title(s : BytesView) -> Bytes {
  let out = Array(capacity=s.length())
  let mut prev_is_letter = false
  for b in s {
    let is_letter = is_ascii_upper(b) || is_ascii_lower(b)
    if is_letter && !prev_is_letter && is_ascii_lower(b) {
      out.push(b - 32)
    } else if is_letter && prev_is_letter && is_ascii_upper(b) {
      out.push(b + 32)
    } else {
      out.push(b)
    }
    prev_is_letter = is_letter
  }
  Bytes::from_array(out)
}

///|
/// Python's `bytes.strip()` with no arguments.
fn ascii_strip(s : BytesView) -> BytesView {
  let mut start = 0
  let mut end = s.length()
  while start < end && is_ascii_whitespace(s[start]) {
    start += 1
  }
  while end > start && is_ascii_whitespace(s[end - 1]) {
    end -= 1
  }
  s[start:end]
}

///|
/// Python's `bytes.split(sep)` for a single-byte separator.
fn split_on(s : BytesView, sep : Byte) -> Array[BytesView] {
  let out = []
  let mut start = 0
  for i in 0..<s.length() {
    if s[i] == sep {
      out.push(s[start:i])
      start = i + 1
    }
  }
  out.push(s[start:])
  out
}

///|
/// Lexicographic comparison, as done by Python for `bytes < bytes`.
fn bytes_lt(a : Bytes, b : Bytes) -> Bool {
  a.lexical_compare(b) < 0
}

///|
fn bytes_concat(parts : Array[Bytes]) -> Bytes {
  let buf = @buffer.Buffer()
  for p in parts {
    buf.write_bytes(p)
  }
  buf.to_bytes()
}

///|
/// Parse a non-empty run of digits in `radix` (10 or 16). Returns `None` on
/// an empty input or an invalid digit. Values that do not fit in an `Int64`
/// saturate at `Int64` max: Python accepts arbitrarily large integers here,
/// and no real stream can ever get close to 2^63 bytes, so saturating keeps
/// the observable behavior identical.
fn parse_digits(s : BytesView, radix~ : Int) -> Int64? {
  if s.is_empty() {
    return None
  }
  let r = radix.to_int64()
  let mut acc = 0L
  for b in s {
    let d = match hex_value(b) {
      Some(d) if d < radix => d.to_int64()
      _ => return None
    }
    acc = if acc > (@int64.MAX_VALUE - d) / r {
      @int64.MAX_VALUE
    } else {
      acc * r + d
    }
  }
  Some(acc)
}

///|
fn parse_decimal(s : BytesView) -> Int64? {
  parse_digits(s, radix=10)
}

///|
fn parse_hex(s : BytesView) -> Int64? {
  parse_digits(s, radix=16)
}

///|
/// Render a byte string the way Python's `repr(bytes)` does, e.g.
/// `b'foo\r\n'`. Used for error messages.
fn bytes_repr(s : BytesView) -> String {
  let mut has_single = false
  let mut has_double = false
  for b in s {
    if b == b'\'' {
      has_single = true
    } else if b == b'"' {
      has_double = true
    }
  }
  let quote : Byte = if has_single && !has_double { b'"' } else { b'\'' }
  let sb = StringBuilder()
  sb.write_char('b')
  sb.write_char(quote.to_char())
  for b in s {
    match b {
      b'\\' => sb.write_string("\\\\")
      b'\t' => sb.write_string("\\t")
      b'\n' => sb.write_string("\\n")
      b'\r' => sb.write_string("\\r")
      _ if b == quote => {
        sb.write_char('\\')
        sb.write_char(b.to_char())
      }
      _ if b < b' ' || b >= b'\x7f' => {
        sb.write_string("\\x")
        sb.write_string(b.to_hex())
      }
      _ => sb.write_char(b.to_char())
    }
  }
  sb.write_char(quote.to_char())
  sb.to_string()
}

///|
fn bytes_debug(s : BytesView) -> Repr {
  Repr::literal(bytes_repr(s))
}
