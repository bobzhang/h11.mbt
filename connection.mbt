// The main Connection type (port of h11/_connection.py). Everything in h11
// revolves around this.

///|
/// If we ever have this much buffered without it making a complete parseable
/// event, we error out. The only time we really buffer is when reading the
/// request/response line + headers together, so this is effectively the
/// limit on the size of that.
pub const DEFAULT_MAX_INCOMPLETE_EVENT_SIZE : Int = 16 * 1024

///|
/// The result of `Connection::next_event`.
pub(all) enum NextEvent {
  /// A parsed event.
  Event(Event)
  /// You need to read more data from your socket and pass it to
  /// `receive_data` before more events can be returned.
  NeedData
  /// We are not in a state where we can process incoming data (usually
  /// because the peer has finished their part of the current
  /// request/response cycle, and you have not yet called
  /// `start_next_cycle`).
  Paused
} derive(Eq, Debug)

///|
/// How a message body is framed.
priv enum Framing {
  ContentLength(Int64)
  Chunked
  Http10
}

///|
/// RFC 7230's rules for connection lifecycles, simplified: if someone says
/// `Connection: close` we will close, and if someone uses HTTP/1.0 we will
/// close (we don't support keep-alive with HTTP/1.0 peers).
fn keep_alive(headers : Headers, http_version : Bytes) -> Bool {
  let connection = get_comma_header(headers, b"connection")
  if connection.contains(b"close") {
    return false
  }
  if bytes_lt(http_version, b"1.1") {
    return false
  }
  true
}

///|
/// Figure out the framing of the body that follows `event`, which must be a
/// `Request` or a `Response`. Reference: RFC 7230 section 3.3.3.
fn body_framing(request_method : Bytes?, event : Event) -> Framing {
  let headers = match event {
    Response(resp) => {
      // Step 1: some responses always have an empty body, regardless of what
      // the headers say.
      if resp.status_code is (204 | 304) ||
        request_method is Some(b"HEAD") ||
        (
          request_method is Some(b"CONNECT") &&
          resp.status_code >= 200 &&
          resp.status_code < 300
        ) {
        return ContentLength(0L)
      }
      // Section 3.3.3 also lists another case -- responses with status_code
      // < 200. For us these are InformationalResponses, not Responses, so
      // they can't get into this function in the first place.
      guard! resp.status_code >= 200
      resp.headers
    }
    Request(req) => req.headers
    _ => abort("body_framing called with \{event.event_type()}")
  }
  // Step 2: check for Transfer-Encoding (T-E beats C-L):
  let transfer_encodings = get_comma_header(headers, b"transfer-encoding")
  if !transfer_encodings.is_empty() {
    guard! transfer_encodings == [b"chunked"]
    return Chunked
  }
  // Step 3: check for Content-Length
  let content_lengths = get_comma_header(headers, b"content-length")
  if !content_lengths.is_empty() {
    guard! parse_decimal(content_lengths[0]) is Some(n)
    return ContentLength(n)
  }
  // Step 4: no applicable headers; fallback/default depends on type
  match event {
    Request(_) => ContentLength(0L)
    _ => Http10
  }
}

///|
/// An object encapsulating the state of an HTTP connection.
///
/// It performs no I/O: feed received bytes with `receive_data`, pull parsed
/// events with `next_event`, and turn your own events into bytes with
/// `send`.
pub struct Connection {
  priv our_role : Role
  priv their_role : Role
  priv max_incomplete_event_size : Int
  priv cstate : ConnectionState
  // Readers/writers for converting data <-> events given the current state
  priv mut writer : Writer?
  priv mut reader : Reader?
  // Holds any unprocessed received data
  priv receive_buffer : ReceiveBuffer
  // If this is true, then it indicates that the incoming connection was
  // closed *after* the end of whatever's in receive_buffer
  priv mut receive_buffer_closed : Bool
  // Only used to interpret framing headers for figuring out how to
  // read/write response bodies. their_http_version is also public.
  priv mut their_http_version : Bytes?
  priv mut request_method : Bytes?
  // This is pure flow-control and doesn't at all affect the set of legal
  // transitions, so no need to bother ConnectionState with it
  priv mut client_is_waiting_for_100_continue : Bool
}

///|
/// Create a connection playing `our_role`.
///
/// `max_incomplete_event_size` is the maximum number of bytes we're willing
/// to buffer of an incomplete event. In practice this mostly sets a limit on
/// the maximum size of the request/response line + headers. If this is
/// exceeded, then `next_event` will raise `RemoteProtocolError`.
pub fn Connection::new(
  our_role : Role,
  max_incomplete_event_size? : Int = DEFAULT_MAX_INCOMPLETE_EVENT_SIZE,
) -> Connection {
  let their_role = our_role.other()
  {
    our_role,
    their_role,
    max_incomplete_event_size,
    cstate: ConnectionState::new(),
    writer: writer_for_state(our_role, Idle),
    reader: reader_for_state(their_role, Idle),
    receive_buffer: ReceiveBuffer::new(),
    receive_buffer_closed: false,
    their_http_version: None,
    request_method: None,
    client_is_waiting_for_100_continue: false,
  }
}

///|
/// The role we are playing.
pub fn Connection::our_role(self : Connection) -> Role {
  self.our_role
}

///|
/// The role our peer is playing.
pub fn Connection::their_role(self : Connection) -> Role {
  self.their_role
}

///|
/// The current state of both the client and the server.
pub fn Connection::states(self : Connection) -> States {
  self.cstate.states
}

///|
/// The current state of whichever role we are playing.
pub fn Connection::our_state(self : Connection) -> State {
  self.cstate.states.get(self.our_role)
}

///|
/// The current state of whichever role we are NOT playing.
pub fn Connection::their_state(self : Connection) -> State {
  self.cstate.states.get(self.their_role)
}

///|
/// The HTTP version our peer used in their last request or response, if
/// any has been received.
pub fn Connection::their_http_version(self : Connection) -> Bytes? {
  self.their_http_version
}

///|
/// Whether the client has sent `Expect: 100-continue` and is still waiting
/// for a response.
pub fn Connection::client_is_waiting_for_100_continue(
  self : Connection,
) -> Bool {
  self.client_is_waiting_for_100_continue
}

///|
/// Whether our peer is a client waiting for a `100 Continue`.
pub fn Connection::they_are_waiting_for_100_continue(self : Connection) -> Bool {
  self.their_role is Client && self.client_is_waiting_for_100_continue
}

///|
/// Attempt to reset our connection state for a new request/response cycle.
///
/// If both client and server are in `Done` state, then resets them both to
/// `Idle` in preparation for a new request/response cycle on this same
/// connection. Otherwise, raises a `LocalProtocolError`.
pub fn Connection::start_next_cycle(
  self : Connection,
) -> Unit raise ProtocolError {
  let old_states = self.cstate.states
  self.cstate.start_next_cycle()
  self.request_method = None
  // their_http_version gets left alone, since it presumably lasts beyond a
  // single request/response cycle
  guard! !self.client_is_waiting_for_100_continue
  self.respond_to_state_changes(old_states, None)
}

///|
fn Connection::process_error(self : Connection, role : Role) -> Unit {
  let old_states = self.cstate.states
  self.cstate.process_error(role)
  self.respond_to_state_changes(old_states, None)
}

///|
fn Connection::server_switch_event(
  self : Connection,
  event : Event,
) -> SwitchType? {
  match event {
    InformationalResponse(r) if r.status_code == 101 => Some(SwitchUpgrade)
    Response(r) if self.cstate.pending_switch_proposals.contains(SwitchConnect) &&
      r.status_code >= 200 &&
      r.status_code < 300 => Some(SwitchConnect)
    _ => None
  }
}

///|
/// All events go through here.
fn Connection::process_event(
  self : Connection,
  role : Role,
  event : Event,
) -> Unit raise ProtocolError {
  // First, pass the event through the state machine to make sure it
  // succeeds.
  let old_states = self.cstate.states
  if role is Client && event is Request(req) {
    if req.method == b"CONNECT" {
      self.cstate.process_client_switch_proposal(SwitchConnect)
    }
    if !get_comma_header(req.headers, b"upgrade").is_empty() {
      self.cstate.process_client_switch_proposal(SwitchUpgrade)
    }
  }
  let server_switch_event = if role is Server {
    self.server_switch_event(event)
  } else {
    None
  }
  self.cstate.process_event(role, event.event_type(), server_switch_event?)
  // Then perform the updates triggered by it.
  if event is Request(req) {
    self.request_method = Some(req.method)
  }
  if role == self.their_role {
    match event {
      Request(r) => self.their_http_version = Some(r.http_version)
      Response(r) => self.their_http_version = Some(r.http_version)
      InformationalResponse(r) => self.their_http_version = Some(r.http_version)
      _ => ()
    }
  }
  // Keep alive handling
  //
  // RFC 7230 doesn't really say what one should do if Connection: close
  // shows up on a 1xx InformationalResponse. I think the idea is that this
  // is not supposed to happen. In any case, if it does happen, we ignore it.
  match event {
    Request(r) if !keep_alive(r.headers, r.http_version) =>
      self.cstate.process_keep_alive_disabled()
    Response(r) if !keep_alive(r.headers, r.http_version) =>
      self.cstate.process_keep_alive_disabled()
    _ => ()
  }
  // 100-continue
  if event is Request(req) && has_expect_100_continue(req) {
    self.client_is_waiting_for_100_continue = true
  }
  if event is (InformationalResponse(_) | Response(_)) {
    self.client_is_waiting_for_100_continue = false
  }
  if role is Client && event is (Data(_) | EndOfMessage(_)) {
    self.client_is_waiting_for_100_continue = false
  }
  self.respond_to_state_changes(old_states, Some(event))
}

///|
/// This must be called after any action that might have caused the states
/// to change. `event` is only used when entering SEND_BODY.
fn Connection::respond_to_state_changes(
  self : Connection,
  old_states : States,
  event : Event?,
) -> Unit {
  // Update reader/writer
  if self.our_state() != old_states.get(self.our_role) {
    self.writer = match self.our_state() {
      SendBody => Some(writer_for_framing(self.framing_for(event)))
      state => writer_for_state(self.our_role, state)
    }
  }
  if self.their_state() != old_states.get(self.their_role) {
    self.reader = match self.their_state() {
      SendBody => Some(reader_for_framing(self.framing_for(event)))
      state => reader_for_state(self.their_role, state)
    }
  }
}

///|
fn Connection::framing_for(self : Connection, event : Event?) -> Framing {
  guard! event is Some(event)
  body_framing(self.request_method, event)
}

///|
/// Data that has been received, but not yet processed, together with a flag
/// that is true if the receive connection was closed.
///
/// See the h11 docs on switching protocols for why you'd want this.
pub fn Connection::trailing_data(self : Connection) -> (Bytes, Bool) {
  (self.receive_buffer.to_bytes(), self.receive_buffer_closed)
}

///|
/// Add data to our internal receive buffer.
///
/// This does not actually do any processing on the data, just stores it. To
/// trigger processing, you have to call `next_event`.
///
/// Special case: if `data` is empty, then this indicates that the remote
/// side has closed the connection (end of file). Calling
/// `receive_data(b"")` multiple times is fine, and equivalent to calling it
/// once.
///
/// Raises `RuntimeError` if you pass an empty `data`, indicating EOF, and
/// then pass a non-empty `data`, indicating more data that somehow arrived
/// after the EOF.
pub fn Connection::receive_data(
  self : Connection,
  data : BytesView,
) -> Unit raise RuntimeError {
  if !data.is_empty() {
    if self.receive_buffer_closed {
      raise RuntimeError("received close, then received more data?")
    }
    self.receive_buffer.append(data)
  } else {
    self.receive_buffer_closed = true
  }
}

///|
fn Connection::extract_next_receive_event(
  self : Connection,
) -> NextEvent raise ProtocolError {
  let state = self.their_state()
  // We don't pause immediately when they enter DONE, because even in DONE
  // state we can still process a ConnectionClosed() event. But if we have
  // data in our buffer, then we definitely aren't getting a
  // ConnectionClosed() immediately and we need to pause.
  if state is Done && !self.receive_buffer.is_empty() {
    return Paused
  }
  if state is (MightSwitchProtocol | SwitchedProtocol) {
    return Paused
  }
  guard! self.reader is Some(reader)
  let mut event = reader.read(self.receive_buffer)
  if event is None {
    if self.receive_buffer.is_empty() && self.receive_buffer_closed {
      // In some unusual cases (basically just HTTP/1.0 bodies), EOF
      // triggers an actual protocol event; in that case, we want to return
      // that event, and then the state will change and we'll get called
      // again to generate the actual ConnectionClosed().
      event = match reader.read_eof() {
        Some(e) => Some(e)
        None => Some(ConnectionClosed)
      }
    }
  }
  match event {
    Some(e) => Event(e)
    None => NeedData
  }
}

///|
/// Parse the next event out of our receive buffer, update our internal
/// state, and return it.
///
/// This is a mutating operation -- think of it like calling `next` on an
/// iterator. Returns one of:
///
/// 1. `Event(event)`: an event object.
/// 2. `NeedData`: you need to read more data from your socket and pass it to
///    `receive_data` before this method will be able to return any more
///    events.
/// 3. `Paused`: we are not in a state where we can process incoming data
///    (usually because the peer has finished their part of the current
///    request/response cycle, and you have not yet called
///    `start_next_cycle`).
///
/// Raises `RemoteProtocolError` if the peer has misbehaved. You should close
/// the connection (possibly after sending some kind of 4xx response).
///
/// Once this method returns `ConnectionClosed` once, then all subsequent
/// calls will also return `ConnectionClosed`.
///
/// If this method raises then it also sets `their_state` to `Error`.
pub fn Connection::next_event(
  self : Connection,
) -> NextEvent raise ProtocolError {
  if self.their_state() is Error {
    raise RemoteProtocolError(
      "Can't receive data when peer state is ERROR",
      error_status_hint=400,
    )
  }
  try {
    let event = self.extract_next_receive_event()
    if event is Event(e) {
      self.process_event(self.their_role, e)
    }
    if event is NeedData {
      if self.receive_buffer.length() > self.max_incomplete_event_size {
        // 431 is "Request header fields too large" which is pretty much the
        // only situation where we can get here
        raise RemoteProtocolError(
          "Receive buffer too long",
          error_status_hint=431,
        )
      }
      if self.receive_buffer_closed {
        // We're still trying to complete some event, but that's never going
        // to happen because no more data is coming
        raise RemoteProtocolError(
          "peer unexpectedly closed connection",
          error_status_hint=400,
        )
      }
    }
    event
  } catch {
    exc => {
      self.process_error(self.their_role)
      match exc {
        LocalProtocolError(msg, error_status_hint~) =>
          raise RemoteProtocolError(msg, error_status_hint~)
        exc => raise exc
      }
    }
  }
}

///|
/// Convert a high-level event into bytes that can be sent to the peer, while
/// updating our internal state machine.
///
/// Returns `None` if `event` is `ConnectionClosed`, and the bytes to send
/// otherwise.
///
/// Raises `LocalProtocolError` if sending this event at this time would
/// violate our understanding of the HTTP/1.1 protocol. If this method
/// raises then it also sets `our_state` to `Error`.
pub fn Connection::send(
  self : Connection,
  event : Event,
) -> Bytes? raise ProtocolError {
  match self.send_with_data_passthrough(event) {
    None => None
    Some(data_list) => Some(bytes_concat(data_list))
  }
}

///|
/// Identical to `send`, except that in situations where `send` returns a
/// single byte string, this instead returns a list of them -- and when
/// sending a `Data` event, this list is guaranteed to contain the exact
/// `Bytes` object you passed in as `Data.data`.
pub fn Connection::send_with_data_passthrough(
  self : Connection,
  event : Event,
) -> Array[Bytes]? raise ProtocolError {
  if self.our_state() is Error {
    raise local_error("Can't send data when our state is ERROR")
  }
  errdefer self.process_error(self.our_role)
  let event = match event {
    Response(resp) =>
      Event::Response(self.clean_up_response_headers_for_sending(resp))
    e => e
  }
  // We want to call process_event before calling the writer, because if
  // someone tries to do something invalid then this will give a sensible
  // error message, while our writers all just assume they will only receive
  // valid events. But, process_event might change self.writer. So we have
  // to do a little dance:
  let writer = self.writer
  self.process_event(self.our_role, event)
  if event is ConnectionClosed {
    None
  } else {
    // In any situation where writer is None, process_event should have
    // raised ProtocolError
    guard! writer is Some(writer)
    let data_list = []
    writer.write(event, data_list)
    Some(data_list)
  }
}

///|
/// Notify the state machine that we failed to send the data it gave us.
///
/// This causes `our_state` to immediately become `Error`.
pub fn Connection::send_failed(self : Connection) -> Unit {
  self.process_error(self.our_role)
}

///|
/// When sending a Response, we take responsibility for a few things:
///
/// - Sometimes you MUST set Connection: close. We take care of those times.
///   (You can also set it yourself if you want, and if you do then we'll
///   respect that and close the connection at the right time.)
///
/// - The user has to set Content-Length if they want it. Otherwise, for
///   responses that have bodies (e.g. not HEAD), we will automatically
///   select the right mechanism for streaming a body of unknown length,
///   which depends on the peer's HTTP version.
///
/// This function's *only* responsibility is making sure headers are set up
/// right -- everything downstream just looks at the headers.
fn Connection::clean_up_response_headers_for_sending(
  self : Connection,
  response : Response,
) -> Response raise ProtocolError {
  let mut headers = response.headers
  let mut need_close = false
  // HEAD requests need some special handling: they always act like they
  // have Content-Length: 0, and that's how body_framing treats them. But
  // their headers are supposed to match what we would send if the request
  // was a GET.
  let method_for_choosing_headers = match self.request_method {
    Some(b"HEAD") => Some(b"GET")
    m => m
  }
  let framing = body_framing(method_for_choosing_headers, Response(response))
  if framing is (Chunked | Http10) {
    // This response has a body of unknown length.
    // If our peer is HTTP/1.1, we use Transfer-Encoding: chunked
    // If our peer is HTTP/1.0, we use no framing headers, and close the
    // connection afterwards.
    //
    // Make sure to clear Content-Length (in principle user could have set
    // both and then we ignored Content-Length b/c Transfer-Encoding
    // overwrote it -- this would be naughty of them, but the HTTP spec says
    // that if our peer does this then we have to fix it instead of erroring
    // out, so we'll accord the user the same respect).
    headers = set_comma_header(headers, b"content-length", [])
    let peer_is_http10 = match self.their_http_version {
      None => true
      Some(v) => bytes_lt(v, b"1.1")
    }
    if peer_is_http10 {
      // Either we never got a valid request and are sending back an error
      // (their_http_version is None), so we assume the worst; or else we did
      // get a valid HTTP/1.0 request, so we know that they don't understand
      // chunked encoding.
      headers = set_comma_header(headers, b"transfer-encoding", [])
      // This is actually redundant ATM, since currently we unconditionally
      // disable keep-alive when talking to HTTP/1.0 peers. But let's be
      // defensive just in case we add Connection: keep-alive support later:
      if !(self.request_method is Some(b"HEAD")) {
        need_close = true
      }
    } else {
      headers = set_comma_header(headers, b"transfer-encoding", [b"chunked"])
    }
  }
  if !self.cstate.keep_alive || need_close {
    // Make sure Connection: close is set
    let connection_set : Map[Bytes, Unit] = Map([])
    for v in get_comma_header(headers, b"connection") {
      connection_set[v] = ()
    }
    connection_set.remove(b"keep-alive")
    connection_set[b"close"] = ()
    let connection = connection_set.keys().to_array()
    connection.sort_by((a, b) => a.lexical_compare(b))
    headers = set_comma_header(headers, b"connection", connection)
  }
  Response::make(
    response.status_code,
    headers,
    response.http_version,
    response.reason,
  )
}
