// Code to write HTTP data (port of h11/_writers.py).
//
// Each writer takes an event and appends the bytes to send to `out`.

///|
priv struct ContentLengthWriter {
  mut length : Int64
}

///|
priv enum Writer {
  WriteRequest
  WriteAnyResponse
  ContentLength(ContentLengthWriter)
  Chunked
  Http10
}

///|
/// WRITERS[(role, state)] for the non-body states.
fn writer_for_state(role : Role, state : State) -> Writer? {
  match (role, state) {
    (Client, Idle) => Some(WriteRequest)
    (Server, Idle | SendResponse) => Some(WriteAnyResponse)
    _ => None
  }
}

///|
/// WRITERS[SEND_BODY][framing](*args)
fn writer_for_framing(framing : Framing) -> Writer {
  match framing {
    ContentLength(length) => ContentLength({ length, })
    Chunked => Chunked
    Http10 => Http10
  }
}

///|
fn write_headers(headers : Headers, out : Array[Bytes]) -> Unit {
  // "Since the Host field-value is critical information for handling a
  // request, a user agent SHOULD generate Host as the first header field
  // following the request-line." - RFC 7230
  for item in headers.full_items {
    let (raw_name, name, value) = item
    if name == b"host" {
      out.push(bytes_concat([raw_name, b": ", value, b"\r\n"]))
    }
  }
  for item in headers.full_items {
    let (raw_name, name, value) = item
    if name != b"host" {
      out.push(bytes_concat([raw_name, b": ", value, b"\r\n"]))
    }
  }
  out.push(b"\r\n")
}

///|
fn write_request(
  request : Request,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  if request.http_version != b"1.1" {
    raise local_error("I only send HTTP/1.1")
  }
  out.push(
    bytes_concat([request.method, b" ", request.target, b" HTTP/1.1\r\n"]),
  )
  write_headers(request.headers, out)
}

///|
/// Shared between InformationalResponse and Response.
fn write_any_response(
  status_code : Int,
  headers : Headers,
  http_version : Bytes,
  reason : Bytes,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  if http_version != b"1.1" {
    raise local_error("I only send HTTP/1.1")
  }
  let status_bytes = @utf8.encode(status_code.to_string())
  // We don't bother sending ascii status messages like "OK"; they're
  // optional and ignored by the protocol. (But the space after the numeric
  // status code is mandatory.)
  out.push(bytes_concat([b"HTTP/1.1 ", status_bytes, b" ", reason, b"\r\n"]))
  write_headers(headers, out)
}

///|
fn Writer::write(
  self : Writer,
  event : Event,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  match (self, event) {
    (WriteRequest, Request(r)) => write_request(r, out)
    (WriteAnyResponse, InformationalResponse(r)) =>
      write_any_response(
        r.status_code,
        r.headers,
        r.http_version,
        r.reason,
        out,
      )
    (WriteAnyResponse, Response(r)) =>
      write_any_response(
        r.status_code,
        r.headers,
        r.http_version,
        r.reason,
        out,
      )
    (ContentLength(w), Data(d)) => {
      w.length -= d.data.length().to_int64()
      if w.length < 0L {
        raise local_error("Too much data for declared Content-Length")
      }
      out.push(d.data)
    }
    (ContentLength(w), EndOfMessage(eom)) => {
      if w.length != 0L {
        raise local_error("Too little data for declared Content-Length")
      }
      if !eom.headers.is_empty() {
        raise local_error("Content-Length and trailers don't mix")
      }
    }
    (Chunked, Data(d)) =>
      // if we encoded 0-length data in the naive way, it would look like an
      // end-of-message.
      if !d.data.is_empty() {
        out.push(
          bytes_concat([
            @utf8.encode(d.data.length().to_string(radix=16)),
            b"\r\n",
          ]),
        )
        out.push(d.data)
        out.push(b"\r\n")
      }
    (Chunked, EndOfMessage(eom)) => {
      out.push(b"0\r\n")
      write_headers(eom.headers, out)
    }
    (Http10, Data(d)) => out.push(d.data)
    (Http10, EndOfMessage(eom)) =>
      if !eom.headers.is_empty() {
        raise local_error("can't send trailers to HTTP/1.0 client")
      }
    // no need to close the socket ourselves, that will be taken care of by
    // Connection: close machinery
    _ => abort("writer \{self} can't handle event \{event.event_type()}")
  }
}

///|
impl Show for Writer with fn output(self, logger) {
  logger.write_string(
    match self {
      WriteRequest => "write_request"
      WriteAnyResponse => "write_any_response"
      ContentLength(_) => "ContentLengthWriter"
      Chunked => "ChunkedWriter"
      Http10 => "Http10Writer"
    },
  )
}
