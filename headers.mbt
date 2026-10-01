// Headers are a list of (name, value) pairs where names are compared
// case-insensitively, duplicates are allowed and order matters. We store the
// original casing (to preserve it over the wire) together with the
// lowercased name (for comparisons).

///|
/// Maximum number of digits accepted in a Content-Length value (allows up to
/// 1 billion TB - 1).
let content_length_max_digits = 20

///|
/// A list-like collection of headers. Iterating yields
/// `(lowercased_name, value)` pairs; `raw_items` yields the names with their
/// original casing.
pub struct Headers {
  priv full_items : Array[(Bytes, Bytes, Bytes)]
}

///|
/// Normalize and validate a list of `(name, value)` pairs.
///
/// Header names must be tokens and values must be valid field values (no
/// leading/trailing whitespace, NUL, CR or LF). `Content-Length` and
/// `Transfer-Encoding` receive extra checks.
pub fn Headers::new(
  items : ArrayView[(Bytes, Bytes)],
) -> Headers raise ProtocolError {
  normalize_and_validate(items, parsed=false)
}

///|
/// An empty header list.
pub fn Headers::empty() -> Headers {
  { full_items: [], }
}

///|
pub fn Headers::length(self : Headers) -> Int {
  self.full_items.length()
}

///|
pub fn Headers::is_empty(self : Headers) -> Bool {
  self.full_items.is_empty()
}

///|
/// The `idx`-th header as a `(lowercased_name, value)` pair.
#alias("_[_]")
pub fn Headers::at(self : Headers, idx : Int) -> (Bytes, Bytes) {
  let (_, name, value) = self.full_items[idx]
  (name, value)
}

///|
/// The `idx`-th header as a `(lowercased_name, value)` pair, or `None` if
/// `idx` is out of range.
pub fn Headers::get(self : Headers, idx : Int) -> (Bytes, Bytes)? {
  match self.full_items.get(idx) {
    Some((_, name, value)) => Some((name, value))
    None => None
  }
}

///|
/// Iterate over `(lowercased_name, value)` pairs.
pub fn Headers::iter(self : Headers) -> Iter[(Bytes, Bytes)] {
  self.full_items.iter().map(item => (item.1, item.2))
}

///|
/// All headers as `(lowercased_name, value)` pairs.
pub fn Headers::to_array(self : Headers) -> Array[(Bytes, Bytes)] {
  self.full_items.map(item => (item.1, item.2))
}

///|
/// All headers as `(raw_name, value)` pairs, preserving the original casing
/// of the names.
pub fn Headers::raw_items(self : Headers) -> Array[(Bytes, Bytes)] {
  self.full_items.map(item => (item.0, item.2))
}

///|
/// Two header lists are equal when their `(lowercased_name, value)` pairs
/// are equal; the original casing is ignored.
pub impl Eq for Headers with fn equal(self, other) {
  let n = self.full_items.length()
  if n != other.full_items.length() {
    return false
  }
  for i in 0..<n {
    let (_, n1, v1) = self.full_items[i]
    let (_, n2, v2) = other.full_items[i]
    if n1 != n2 || v1 != v2 {
      return false
    }
  }
  true
}

///|
pub impl Debug for Headers with fn to_repr(self) {
  Repr::array(
    self.full_items.map(item => {
      Repr::tuple([bytes_debug(item.1), bytes_debug(item.2)])
    }),
  )
}

///|
/// Shared implementation of header normalization. When `parsed` is true the
/// data came out of our own parser, which already validated names and
/// values, so those checks are skipped.
fn normalize_and_validate(
  headers : ArrayView[(Bytes, Bytes)],
  parsed~ : Bool,
) -> Headers raise ProtocolError {
  let new_headers = []
  let mut seen_content_length : Bytes? = None
  let mut saw_transfer_encoding = false
  for header in headers {
    let (raw_name, value) = header
    if !parsed {
      if !match_token(raw_name) {
        raise local_error("Illegal header name \{bytes_repr(raw_name)}")
      }
      if !match_field_value(value) {
        raise local_error("Illegal header value \{bytes_repr(value)}")
      }
    }
    let name = ascii_lower(raw_name)
    if name == b"content-length" {
      let lengths : Map[Bytes, Unit] = Map([])
      for length in split_on(value, b',') {
        lengths[ascii_strip(length).to_owned()] = ()
      }
      if lengths.length() != 1 {
        raise local_error("conflicting Content-Length headers")
      }
      guard lengths.keys().head() is Some(value) else {
        raise local_error("conflicting Content-Length headers")
      }
      if value.is_empty() || !value.iter().all(is_digit) {
        raise local_error("bad Content-Length")
      }
      if value.length() > content_length_max_digits {
        raise local_error("bad Content-Length")
      }
      match seen_content_length {
        None => {
          seen_content_length = Some(value)
          new_headers.push((raw_name, name, value))
        }
        Some(seen) =>
          if seen != value {
            raise local_error("conflicting Content-Length headers")
          }
      }
    } else if name == b"transfer-encoding" {
      // "A server that receives a request message with a transfer coding it
      // does not understand SHOULD respond with 501 (Not Implemented)."
      // https://tools.ietf.org/html/rfc7230#section-3.3.1
      if saw_transfer_encoding {
        raise local_error(
          "multiple Transfer-Encoding headers",
          error_status_hint=501,
        )
      }
      // "All transfer-coding names are case-insensitive"
      // -- https://tools.ietf.org/html/rfc7230#section-4
      let value = ascii_lower(value)
      if value != b"chunked" {
        raise local_error(
          "Only Transfer-Encoding: chunked is supported",
          error_status_hint=501,
        )
      }
      saw_transfer_encoding = true
      new_headers.push((raw_name, name, value))
    } else {
      new_headers.push((raw_name, name, value))
    }
  }
  { full_items: new_headers, }
}

///|
/// Collect the comma-separated, case-insensitive values of every header
/// named `name` (which must be lowercase).
///
/// This naive splitting is wrong for headers that allow quoted strings, but
/// fine for the headers we use it on: Connection, Content-Length,
/// Transfer-Encoding (we reject anything but "chunked" anyway) and Expect.
pub fn get_comma_header(headers : Headers, name : Bytes) -> Array[Bytes] {
  let out = []
  for item in headers.full_items {
    let (_, found_name, found_raw_value) = item
    if found_name == name {
      let lowered = ascii_lower(found_raw_value)
      for found_split_value in split_on(lowered, b',') {
        let v = ascii_strip(found_split_value)
        if !v.is_empty() {
          out.push(v.to_owned())
        }
      }
    }
  }
  out
}

///|
/// Return a copy of `headers` where every header named `name` (lowercase) is
/// replaced by one header per entry of `new_values`, appended at the end with
/// a title-cased name.
pub fn set_comma_header(
  headers : Headers,
  name : Bytes,
  new_values : ArrayView[Bytes],
) -> Headers raise ProtocolError {
  let new_headers = []
  for item in headers.full_items {
    let (found_raw_name, found_name, found_raw_value) = item
    if found_name != name {
      new_headers.push((found_raw_name, found_raw_value))
    }
  }
  let title = ascii_title(name)
  for new_value in new_values {
    new_headers.push((title, new_value))
  }
  normalize_and_validate(new_headers, parsed=false)
}

///|
/// Whether a request carries `Expect: 100-continue` (ignored for HTTP/1.0,
/// as required by RFC 7231 section 5.1.1).
pub fn has_expect_100_continue(request : Request) -> Bool {
  if bytes_lt(request.http_version, b"1.1") {
    return false
  }
  get_comma_header(request.headers, b"expect").contains(b"100-continue")
}
