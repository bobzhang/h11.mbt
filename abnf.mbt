// Hand-written matchers for the RFC 7230 grammar fragments that h11 uses.
// Each function corresponds to a `regex.fullmatch` in the Python version
// (see `h11/_abnf.py`).

///|
/// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
///         "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
fn is_tchar(b : Byte) -> Bool {
  is_digit(b) ||
  is_ascii_lower(b) ||
  is_ascii_upper(b) ||
  b
  is (b'!'
  | b'#'
  | b'$'
  | b'%'
  | b'&'
  | b'\''
  | b'*'
  | b'+'
  | b'-'
  | b'.'
  | b'^'
  | b'_'
  | b'`'
  | b'|'
  | b'~')
}

///|
/// VCHAR = %x21-7E
fn is_vchar(b : Byte) -> Bool {
  b >= b'\x21' && b <= b'\x7e'
}

///|
/// Our relaxed field-vchar: anything except NUL and whitespace (this
/// includes obs-text and most control characters, see h11 issue #57).
fn is_field_vchar(b : Byte) -> Bool {
  b != b'\x00' && !is_ascii_whitespace(b)
}

///|
fn is_ows(b : Byte) -> Bool {
  b is (b' ' | b'\t')
}

///|
/// token = 1*tchar
fn match_token(s : BytesView) -> Bool {
  !s.is_empty() && s.iter().all(is_tchar)
}

///|
/// field-value = [ field-vchar *( *( SP / HTAB ) field-vchar ) ]
fn match_field_value(s : BytesView) -> Bool {
  if s.is_empty() {
    return true
  }
  is_field_vchar(s[0]) &&
  is_field_vchar(s[s.length() - 1]) &&
  s.iter().all(b => is_field_vchar(b) || is_ows(b))
}

///|
/// header-field = field-name ":" OWS field-value OWS
///
/// Returns the `(field_name, field_value)` groups on success.
fn match_header_field(line : BytesView) -> (BytesView, BytesView)? {
  let mut i = 0
  while i < line.length() && is_tchar(line[i]) {
    i += 1
  }
  if i == 0 || i >= line.length() || line[i] != b':' {
    return None
  }
  let name = line[:i]
  let mut start = i + 1
  let mut end = line.length()
  while start < end && is_ows(line[start]) {
    start += 1
  }
  while end > start && is_ows(line[end - 1]) {
    end -= 1
  }
  let value = line[start:end]
  if match_field_value(value) {
    Some((name, value))
  } else {
    None
  }
}

///|
/// HTTP-version = "HTTP/" DIGIT "." DIGIT, returning the "d.d" part.
fn match_http_version(s : BytesView) -> BytesView? {
  if s is [b'H', b'T', b'T', b'P', b'/', d1, b'.', d2] &&
    is_digit(d1) &&
    is_digit(d2) {
    Some(s[5:])
  } else {
    None
  }
}

///|
/// request-line = method SP request-target SP HTTP-version
///
/// Returns `(method, target, http_version)`.
fn match_request_line(line : BytesView) -> (BytesView, BytesView, BytesView)? {
  let n = line.length()
  let mut i = 0
  while i < n && is_tchar(line[i]) {
    i += 1
  }
  if i == 0 || i >= n || line[i] != b' ' {
    return None
  }
  let meth = line[:i]
  let target_start = i + 1
  let mut j = target_start
  while j < n && is_vchar(line[j]) {
    j += 1
  }
  if j == target_start || j >= n || line[j] != b' ' {
    return None
  }
  let target = line[target_start:j]
  guard match_http_version(line[j + 1:]) is Some(version) else { return None }
  Some((meth, target, version))
}

///|
/// reason-phrase = *( HTAB / SP / VCHAR / obs-text ), relaxed like
/// field-vchar.
fn is_reason_byte(b : Byte) -> Bool {
  is_ows(b) || is_field_vchar(b)
}

///|
/// status-line = HTTP-version SP status-code [ SP reason-phrase ]
///
/// (The reason phrase is optional because many servers omit it.)
/// Returns `(http_version, status_code, reason)`.
fn match_status_line(line : BytesView) -> (BytesView, Int, BytesView?)? {
  if line.length() < 12 {
    return None
  }
  guard match_http_version(line[:8]) is Some(version) else { return None }
  guard line[8] == b' ' else { return None }
  let code = line[9:12]
  guard code.iter().all(is_digit) else { return None }
  let status_code = (code[0] - b'0').to_int() * 100 +
    (code[1] - b'0').to_int() * 10 +
    (code[2] - b'0').to_int()
  if line.length() == 12 {
    return Some((version, status_code, None))
  }
  guard line[12] == b' ' else { return None }
  let reason = line[13:]
  guard reason.iter().all(is_reason_byte) else { return None }
  Some((version, status_code, Some(reason)))
}

///|
/// chunk-header = 1*20HEXDIG [ ";" chunk-ext ] OWS CRLF
///
/// Chunk extensions are accepted and discarded. Returns the chunk size.
/// Sizes that do not fit in an `Int64` are rejected.
fn match_chunk_header(line : BytesView) -> Int64? {
  guard line.length() >= 2 &&
    line[line.length() - 2] == b'\r' &&
    line[line.length() - 1] == b'\n' else {
    return None
  }
  let body = line[:line.length() - 2]
  let mut i = 0
  while i < body.length() && hex_value(body[i]) is Some(_) {
    i += 1
  }
  if i == 0 || i > 20 {
    return None
  }
  let rest = body[i:]
  let ok = if rest is [b';', .. ext] {
    // `;.*` followed by OWS: `.` matches anything except \n
    ext.iter().all(b => b != b'\n')
  } else {
    rest.iter().all(is_ows)
  }
  if ok {
    parse_hex(body[:i])
  } else {
    None
  }
}
