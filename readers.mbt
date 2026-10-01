// Code to read HTTP data (port of h11/_readers.py).
//
// Each reader takes a ReceiveBuffer and either:
// 1) consumes some of it and returns an Event
// 2) raises a LocalProtocolError
// 3) returns None, meaning "I need more data"
//
// Body readers additionally know what to do on EOF (`read_eof`); for the
// other readers EOF simply produces a ConnectionClosed event.

///|
priv struct ContentLengthReader {
  length : Int64
  /// The Content-Length as written by the peer, for error messages.
  declared : String
  mut remaining : Int64
}

///|
priv struct ChunkedReader {
  mut bytes_in_chunk : Int64
  /// After reading a chunk, we have to throw away the trailing \r\n. This
  /// tracks the bytes that we still need to match and throw away.
  mut bytes_to_discard : Bytes
  mut reading_trailer : Bool
}

///|
priv enum Reader {
  IdleClient
  SendResponseServer
  ExpectNothing
  ContentLength(ContentLengthReader)
  Chunked(ChunkedReader)
  Http10
}

///|
/// READERS[(role, state)] for the non-body states.
fn reader_for_state(role : Role, state : State) -> Reader? {
  match (role, state) {
    (Client, Idle) => Some(IdleClient)
    (Server, Idle | SendResponse) => Some(SendResponseServer)
    (_, Done | MustClose | Closed) => Some(ExpectNothing)
    _ => None
  }
}

///|
/// READERS[SEND_BODY][framing](*args)
fn reader_for_framing(framing : Framing) -> Reader {
  match framing {
    ContentLength(length, declared~) => {
      let declared = match declared {
        Some(d) => @utf8.decode_lossy(d)
        None => length.to_string()
      }
      ContentLength({ length, declared, remaining: length, })
    }
    Chunked => Chunked(ChunkedReader::new())
    Http10 => Http10
  }
}

///|
fn ChunkedReader::new() -> ChunkedReader {
  { bytes_in_chunk: 0L, bytes_to_discard: b"", reading_trailer: false, }
}

///|
fn Reader::read(
  self : Reader,
  buf : ReceiveBuffer,
) -> Event? raise ProtocolError {
  match self {
    IdleClient => maybe_read_from_idle_client(buf)
    SendResponseServer => maybe_read_from_send_response_server(buf)
    ExpectNothing => {
      if !buf.is_empty() {
        raise local_error("Got data when expecting EOF")
      }
      None
    }
    ContentLength(r) => r.read(buf)
    Chunked(r) => r.read(buf)
    Http10 =>
      match buf.maybe_extract_at_most(999999999L) {
        None => None
        Some(data) => Some(Data(Data::new(data)))
      }
  }
}

///|
/// What to do when EOF arrives with an empty buffer. `None` means the reader
/// has no special EOF handling and a `ConnectionClosed` should be produced.
fn Reader::read_eof(self : Reader) -> Event? raise ProtocolError {
  match self {
    ContentLength(r) =>
      raise RemoteProtocolError(
        "peer closed connection without sending complete message body " +
        "(received \{r.length - r.remaining} bytes, expected \{r.declared})",
        error_status_hint=400,
      )
    Chunked(_) =>
      raise RemoteProtocolError(
        "peer closed connection without sending complete message body " +
        "(incomplete chunked read)",
        error_status_hint=400,
      )
    Http10 => Some(EndOfMessage({ headers: Headers::empty(), }))
    IdleClient | SendResponseServer | ExpectNothing => None
  }
}

///|
/// Handle obsolete line folding: lines starting with whitespace are
/// continuations of the previous line.
fn obsolete_line_fold(
  lines : ArrayView[Bytes],
) -> Array[Bytes] raise ProtocolError {
  let out : Array[Bytes] = []
  let mut last : @buffer.Buffer? = None
  for line in lines {
    let mut ws = 0
    while ws < line.length() && is_ows(line[ws]) {
      ws += 1
    }
    if ws > 0 {
      guard last is Some(buf) else {
        raise local_error("continuation line at start of headers")
      }
      buf.write_byte(b' ')
      buf.write_bytesview(line[ws:])
    } else {
      if last is Some(buf) {
        out.push(buf.to_bytes())
      }
      let buf = @buffer.Buffer(size_hint=line.length())
      buf.write_bytes(line)
      last = Some(buf)
    }
  }
  if last is Some(buf) {
    out.push(buf.to_bytes())
  }
  out
}

///|
fn decode_header_lines(
  lines : ArrayView[Bytes],
) -> Array[(Bytes, Bytes)] raise ProtocolError {
  obsolete_line_fold(lines).map(line => {
    guard match_header_field(line) is Some((name, value)) else {
      raise local_error("illegal header line: \{bytes_repr(line)}")
    }
    (name.to_owned(), value.to_owned())
  })
}

///|
fn maybe_read_from_idle_client(
  buf : ReceiveBuffer,
) -> Event? raise ProtocolError {
  guard buf.maybe_extract_lines() is Some(lines) else {
    if buf.is_next_line_obviously_invalid_request_line() {
      raise local_error("illegal request line")
    }
    return None
  }
  if lines.is_empty() {
    raise local_error("no request line received")
  }
  guard match_request_line(lines[0]) is Some((meth, target, http_version)) else {
    raise local_error("illegal request line: \{bytes_repr(lines[0])}")
  }
  let headers = normalize_and_validate(
    decode_header_lines(lines[1:]),
    parsed=true,
  )
  Some(
    Request(
      Request::make(
        meth.to_owned(),
        target.to_owned(),
        headers,
        http_version.to_owned(),
      ),
    ),
  )
}

///|
fn maybe_read_from_send_response_server(
  buf : ReceiveBuffer,
) -> Event? raise ProtocolError {
  guard buf.maybe_extract_lines() is Some(lines) else {
    if buf.is_next_line_obviously_invalid_request_line() {
      raise local_error("illegal request line")
    }
    return None
  }
  if lines.is_empty() {
    raise local_error("no response line received")
  }
  guard match_status_line(lines[0]) is Some((http_version, status_code, reason)) else {
    raise local_error("illegal status line: \{bytes_repr(lines[0])}")
  }
  let reason = match reason {
    None => b""
    Some(r) => r.to_owned()
  }
  let headers = normalize_and_validate(
    decode_header_lines(lines[1:]),
    parsed=true,
  )
  let http_version = http_version.to_owned()
  if status_code < 200 {
    Some(
      InformationalResponse(
        InformationalResponse::make(status_code, headers, http_version, reason),
      ),
    )
  } else {
    Some(Response(Response::make(status_code, headers, http_version, reason)))
  }
}

///|
fn ContentLengthReader::read(
  self : ContentLengthReader,
  buf : ReceiveBuffer,
) -> Event? {
  if self.remaining == 0L {
    return Some(EndOfMessage({ headers: Headers::empty(), }))
  }
  guard buf.maybe_extract_at_most(self.remaining) is Some(data) else {
    return None
  }
  self.remaining -= data.length().to_int64()
  Some(Data(Data::new(data)))
}

///|
fn ChunkedReader::read(
  self : ChunkedReader,
  buf : ReceiveBuffer,
) -> Event? raise ProtocolError {
  if self.reading_trailer {
    guard buf.maybe_extract_lines() is Some(lines) else { return None }
    return Some(
      EndOfMessage({
        headers: normalize_and_validate(decode_header_lines(lines), parsed=true),
      }),
    )
  }
  if !self.bytes_to_discard.is_empty() {
    guard buf.maybe_extract_at_most(self.bytes_to_discard.length().to_int64())
      is Some(data) else {
      return None
    }
    if data[:] != self.bytes_to_discard[:data.length()] {
      raise local_error(
        "malformed chunk footer: \{bytes_repr(data)} (expected \{bytes_repr(self.bytes_to_discard)})",
      )
    }
    self.bytes_to_discard = self.bytes_to_discard[data.length():].to_owned()
    if !self.bytes_to_discard.is_empty() {
      return None
    }
    // else, fall through and read some more
  }
  let chunk_start = if self.bytes_in_chunk == 0L {
    // We need to refill our chunk count
    guard buf.maybe_extract_next_line() is Some(chunk_header) else {
      return None
    }
    guard match_chunk_header(chunk_header) is Some(size) else {
      raise local_error("illegal chunk header: \{bytes_repr(chunk_header)}")
    }
    // XX FIXME: we discard chunk extensions. Does anyone care?
    self.bytes_in_chunk = size
    if size == 0L {
      self.reading_trailer = true
      return self.read(buf)
    }
    true
  } else {
    false
  }
  guard! self.bytes_in_chunk > 0L
  guard buf.maybe_extract_at_most(self.bytes_in_chunk) is Some(data) else {
    return None
  }
  self.bytes_in_chunk -= data.length().to_int64()
  let chunk_end = if self.bytes_in_chunk == 0L {
    self.bytes_to_discard = b"\r\n"
    true
  } else {
    false
  }
  Some(Data(Data::new(data, chunk_start~, chunk_end~)))
}
