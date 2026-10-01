// Port of h11/tests/helpers.py (black-box test helpers).

///|
/// Pull events out of `conn` until it needs data, pauses, or reports
/// `ConnectionClosed`.
fn get_all_events(conn : @h11.Connection) -> Array[@h11.Event] raise {
  let got_events = []
  for ;; {
    match conn.next_event() {
      NeedData | Paused => break
      Event(event) => {
        got_events.push(event)
        if event is ConnectionClosed {
          break
        }
      }
    }
  }
  got_events
}

///|
fn receive_and_get(
  conn : @h11.Connection,
  data : Bytes,
) -> Array[@h11.Event] raise {
  conn.receive_data(data)
  get_all_events(conn)
}

///|
/// Two connections with a fake network link in between.
struct ConnectionPair {
  client : @h11.Connection
  server : @h11.Connection
}

///|
fn ConnectionPair::new() -> ConnectionPair {
  {
    client: @h11.Connection::new(Client),
    server: @h11.Connection::new(Server),
  }
}

///|
fn ConnectionPair::conn(
  self : ConnectionPair,
  role : @h11.Role,
) -> @h11.Connection {
  match role {
    Client => self.client
    Server => self.server
  }
}

///|
fn ConnectionPair::conns(self : ConnectionPair) -> Array[@h11.Connection] {
  [self.client, self.server]
}

///|
/// Send `send_events` from `role`, deliver the bytes to the other side, and
/// check that the other side receives `expect` (defaults to `send_events`).
/// Returns the bytes that went over the wire.
#callsite(autofill(loc))
fn ConnectionPair::send(
  self : ConnectionPair,
  role : @h11.Role,
  send_events : Array[@h11.Event],
  expect? : Array[@h11.Event],
  loc~ : SourceLoc,
) -> Bytes raise {
  let data = @buffer.Buffer()
  let mut closed = false
  for send_event in send_events {
    match self.conn(role).send(send_event) {
      None => closed = true
      Some(new_data) => data.write_bytes(new_data)
    }
  }
  let data = data.to_bytes()
  // send uses b"" to mean b"", and None to mean closed
  // receive uses b"" to mean closed, and None to mean "try again"
  // so we have to translate between the two conventions
  let other = self.conn(role.other())
  if !data.is_empty() {
    other.receive_data(data)
  }
  if closed {
    other.receive_data(b"")
  }
  let got_events = get_all_events(other)
  let expect = match expect {
    Some(e) => e
    None => send_events
  }
  assert_eq(got_events, expect, loc~)
  data
}

///|
/// Shorthand constructors used throughout the tests.
fn req(
  meth : Bytes,
  target : Bytes,
  headers : Array[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
) -> @h11.Event raise {
  Request(@h11.Request::new(method_=meth, target~, headers~, http_version~))
}

///|
fn resp(
  status_code : Int,
  headers : Array[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
  reason? : Bytes = b"",
) -> @h11.Event raise {
  Response(@h11.Response::new(status_code~, headers~, http_version~, reason~))
}

///|
fn info_resp(
  status_code : Int,
  headers : Array[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
  reason? : Bytes = b"",
) -> @h11.Event raise {
  InformationalResponse(
    @h11.InformationalResponse::new(
      status_code~,
      headers~,
      http_version~,
      reason~,
    ),
  )
}

///|
fn data(
  bytes : Bytes,
  chunk_start? : Bool = false,
  chunk_end? : Bool = false,
) -> @h11.Event {
  Data(@h11.Data::new(bytes, chunk_start~, chunk_end~))
}

///|
fn eom(headers? : Array[(Bytes, Bytes)] = []) -> @h11.Event raise {
  EndOfMessage(@h11.EndOfMessage::new(headers~))
}

///|
/// Run `f`, expecting it to raise a `LocalProtocolError`.
#callsite(autofill(loc))
fn expect_local_error(
  f : () -> Unit raise,
  loc~ : SourceLoc,
) -> @h11.ProtocolError raise {
  try f() catch {
    @h11.LocalProtocolError(_, ..) as e => e
    e => fail("expected LocalProtocolError, got \{e}", loc~)
  } noraise {
    _ => fail("expected LocalProtocolError, but nothing was raised", loc~)
  }
}

///|
/// Run `f`, expecting it to raise a `RemoteProtocolError`.
#callsite(autofill(loc))
fn expect_remote_error(
  f : () -> Unit raise,
  loc~ : SourceLoc,
) -> @h11.ProtocolError raise {
  try f() catch {
    @h11.RemoteProtocolError(_, ..) as e => e
    e => fail("expected RemoteProtocolError, got \{e}", loc~)
  } noraise {
    _ => fail("expected RemoteProtocolError, but nothing was raised", loc~)
  }
}
