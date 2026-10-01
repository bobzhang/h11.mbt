// High level events that make up HTTP/1.1 conversations. Loosely inspired by
// the corresponding events in hyper-h2.

///|
/// The beginning of an HTTP request.
///
/// - `method`: an HTTP method, e.g. `b"GET"` or `b"POST"`.
/// - `target`: the target of the request, e.g. `b"/index.html"`, or one of
///   the more exotic formats described in RFC 7230 section 5.3.
/// - `headers`: request headers, see `Headers`.
/// - `http_version`: the protocol version, e.g. `b"1.1"`.
pub struct Request {
  method : Bytes
  target : Bytes
  headers : Headers
  http_version : Bytes
} derive(Eq)

///|
/// Construct and validate a `Request`.
///
/// Raises `LocalProtocolError` if the method or target contain illegal
/// characters, if the headers are invalid, if an HTTP/1.1 request lacks a
/// `Host` header, or if there are multiple `Host` headers.
///
/// ```mbt check
/// test {
///   let req = @h11.Request::new(method=b"GET", target=b"/", headers=[
///     (b"Host", b"example.com"),
///   ])
///   inspect(req.headers.length(), content="1")
/// }
/// ```
pub fn Request::new(
  method~ : Bytes,
  target~ : Bytes,
  headers~ : ArrayView[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
) -> Request raise ProtocolError {
  Request::make(
    method,
    target,
    normalize_and_validate(headers, parsed=false),
    http_version,
  )
}

///|
fn Request::make(
  method : Bytes,
  target : Bytes,
  headers : Headers,
  http_version : Bytes,
) -> Request raise ProtocolError {
  // "A server MUST respond with a 400 (Bad Request) status code to any
  // HTTP/1.1 request message that lacks a Host header field and to any
  // request message that contains more than one Host header field or a
  // Host header field with an invalid field-value."
  // -- https://tools.ietf.org/html/rfc7230#section-5.4
  let mut host_count = 0
  for header in headers {
    if header.0 == b"host" {
      host_count += 1
    }
  }
  if http_version == b"1.1" && host_count == 0 {
    raise local_error("Missing mandatory Host: header")
  }
  if host_count > 1 {
    raise local_error("Found multiple Host: headers")
  }
  if !match_token(method) {
    raise local_error("Illegal method characters")
  }
  if target.is_empty() || !target.iter().all(is_vchar) {
    raise local_error("Illegal target characters")
  }
  { method, target, headers, http_version, }
}

///|
pub impl Debug for Request with fn to_repr(self) {
  Repr::ctor("Request", [
    (Some("method"), bytes_debug(self.method)),
    (Some("target"), bytes_debug(self.target)),
    (Some("headers"), Repr(self.headers)),
    (Some("http_version"), bytes_debug(self.http_version)),
  ])
}

///|
/// An HTTP informational response; `status_code` is always in the range
/// [100, 200).
pub struct InformationalResponse {
  status_code : Int
  headers : Headers
  http_version : Bytes
  reason : Bytes
} derive(Eq)

///|
/// Construct and validate an `InformationalResponse`.
pub fn InformationalResponse::new(
  status_code~ : Int,
  headers~ : ArrayView[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
  reason? : Bytes = b"",
) -> InformationalResponse raise ProtocolError {
  InformationalResponse::make(
    status_code,
    normalize_and_validate(headers, parsed=false),
    http_version,
    reason,
  )
}

///|
fn InformationalResponse::make(
  status_code : Int,
  headers : Headers,
  http_version : Bytes,
  reason : Bytes,
) -> InformationalResponse raise ProtocolError {
  if !(status_code >= 100 && status_code < 200) {
    raise local_error(
      "InformationalResponse status_code should be in range [100, 200), not \{status_code}",
    )
  }
  { status_code, headers, http_version, reason, }
}

///|
pub impl Debug for InformationalResponse with fn to_repr(self) {
  Repr::ctor("InformationalResponse", [
    (Some("status_code"), Repr(self.status_code)),
    (Some("headers"), Repr(self.headers)),
    (Some("http_version"), bytes_debug(self.http_version)),
    (Some("reason"), bytes_debug(self.reason)),
  ])
}

///|
/// The beginning of an HTTP response; `status_code` is always in the range
/// [200, 1000).
pub struct Response {
  status_code : Int
  headers : Headers
  http_version : Bytes
  reason : Bytes
} derive(Eq)

///|
/// Construct and validate a `Response`.
///
/// ```mbt check
/// test {
///   let resp = @h11.Response::new(status_code=200, headers=[], reason=b"OK")
///   inspect(resp.status_code, content="200")
/// }
/// ```
pub fn Response::new(
  status_code~ : Int,
  headers~ : ArrayView[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
  reason? : Bytes = b"",
) -> Response raise ProtocolError {
  Response::make(
    status_code,
    normalize_and_validate(headers, parsed=false),
    http_version,
    reason,
  )
}

///|
fn Response::make(
  status_code : Int,
  headers : Headers,
  http_version : Bytes,
  reason : Bytes,
) -> Response raise ProtocolError {
  if !(status_code >= 200 && status_code < 1000) {
    raise local_error(
      "Response status_code should be in range [200, 1000), not \{status_code}",
    )
  }
  { status_code, headers, http_version, reason, }
}

///|
pub impl Debug for Response with fn to_repr(self) {
  Repr::ctor("Response", [
    (Some("status_code"), Repr(self.status_code)),
    (Some("headers"), Repr(self.headers)),
    (Some("http_version"), bytes_debug(self.http_version)),
    (Some("reason"), bytes_debug(self.reason)),
  ])
}

///|
/// Part of an HTTP message body.
///
/// `chunk_start` and `chunk_end` mark whether this data is from the start /
/// the end of a chunk in chunked transfer encoding. They are only meaningful
/// on events returned by `Connection::next_event` and are ignored by
/// `Connection::send`. You probably shouldn't rely on them at all.
pub struct Data {
  data : Bytes
  chunk_start : Bool
  chunk_end : Bool
} derive(Eq)

///|
pub fn Data::new(
  data : Bytes,
  chunk_start? : Bool = false,
  chunk_end? : Bool = false,
) -> Data {
  { data, chunk_start, chunk_end, }
}

///|
pub impl Debug for Data with fn to_repr(self) {
  Repr::ctor("Data", [
    (Some("data"), bytes_debug(self.data)),
    (Some("chunk_start"), Repr(self.chunk_start)),
    (Some("chunk_end"), Repr(self.chunk_end)),
  ])
}

///|
/// The end of an HTTP message. `headers` holds any trailing headers, which
/// must be empty unless `Transfer-Encoding: chunked` is in use.
pub struct EndOfMessage {
  headers : Headers
} derive(Eq)

///|
pub fn EndOfMessage::new(
  headers? : ArrayView[(Bytes, Bytes)] = [],
) -> EndOfMessage raise ProtocolError {
  { headers: normalize_and_validate(headers, parsed=false), }
}

///|
pub impl Debug for EndOfMessage with fn to_repr(self) {
  Repr::ctor("EndOfMessage", [(Some("headers"), Repr(self.headers))])
}

///|
/// An h11 event. `ConnectionClosed` indicates that the sender has closed
/// their outgoing connection (which does not necessarily mean that they
/// can't receive further data).
pub(all) enum Event {
  Request(Request)
  InformationalResponse(InformationalResponse)
  Response(Response)
  Data(Data)
  EndOfMessage(EndOfMessage)
  ConnectionClosed
} derive(Eq, Debug)

///|
/// The kind of an event, without its payload. Used by the state machine.
priv enum EventType {
  Request
  InformationalResponse
  Response
  Data
  EndOfMessage
  ConnectionClosed
}

///|
impl Show for EventType with fn output(self, logger) {
  logger.write_string(
    match self {
      Request => "Request"
      InformationalResponse => "InformationalResponse"
      Response => "Response"
      Data => "Data"
      EndOfMessage => "EndOfMessage"
      ConnectionClosed => "ConnectionClosed"
    },
  )
}

///|
fn Event::event_type(self : Event) -> EventType {
  match self {
    Request(_) => Request
    InformationalResponse(_) => InformationalResponse
    Response(_) => Response
    Data(_) => Data
    EndOfMessage(_) => EndOfMessage
    ConnectionClosed => ConnectionClosed
  }
}
