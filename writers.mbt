// Code to write HTTP data (port of h11/_writers.py).
//
// Each writer takes an event and appends the bytes to send to `out`.

///|
priv struct ContentLengthWriter {
  mut length : Int64
}

///|
/// Writers for message bodies (WRITERS[SEND_BODY] in Python). Message heads
/// need no writer state: `write_request` and `write_any_response` are
/// chosen directly from the event.
priv enum BodyWriter {
  ContentLength(ContentLengthWriter)
  Chunked
  Http10
}

///|
/// WRITERS[SEND_BODY][framing](*args)
fn writer_for_framing(framing : Framing) -> BodyWriter {
  match framing {
    ContentLength(length, ..) => ContentLength({ length, })
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
    bytes_concat([request.method_, b" ", request.target, b" HTTP/1.1\r\n"]),
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
// These are careful not to do anything to `data` except take its length and
// push it to `out`, so `send_with_data_passthrough` hands back the very same
// `Bytes` object.
fn BodyWriter::send_data(
  self : BodyWriter,
  data : Bytes,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  match self {
    ContentLength(w) => {
      w.length -= data.length().to_int64()
      if w.length < 0L {
        raise local_error("Too much data for declared Content-Length")
      }
      out.push(data)
    }
    Chunked =>
      // if we encoded 0-length data in the naive way, it would look like an
      // end-of-message.
      if !data.is_empty() {
        out.push(
          bytes_concat([
            @utf8.encode(data.length().to_string(radix=16)),
            b"\r\n",
          ]),
        )
        out.push(data)
        out.push(b"\r\n")
      }
    Http10 => out.push(data)
  }
}

///|
fn BodyWriter::send_eom(
  self : BodyWriter,
  headers : Headers,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  match self {
    ContentLength(w) => {
      if w.length != 0L {
        raise local_error("Too little data for declared Content-Length")
      }
      if !headers.is_empty() {
        raise local_error("Content-Length and trailers don't mix")
      }
    }
    Chunked => {
      out.push(b"0\r\n")
      write_headers(headers, out)
    }
    Http10 =>
      if !headers.is_empty() {
        raise local_error("can't send trailers to HTTP/1.0 client")
      }
    // no need to close the socket ourselves, that will be taken care of by
    // Connection: close machinery
  }
}
