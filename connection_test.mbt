// Port of h11/tests/test_connection.py (black-box tests).
//
// test__keep_alive and test__body_framing exercise private functions and live
// in connection_wbtest.mbt.

///|
fn states(client : @h11.State, server : @h11.State) -> @h11.States {
  { client, server, }
}

///|
/// Run `f`, expecting it to raise a `RuntimeError`.
#callsite(autofill(loc))
fn expect_runtime_error(f : () -> Unit raise, loc~ : SourceLoc) -> Unit raise {
  try f() catch {
    @h11.RuntimeError(_) => ()
    e => fail("expected RuntimeError, got \{e}", loc~)
  } noraise {
    _ => fail("expected RuntimeError, but nothing was raised", loc~)
  }
}

///|
test "Connection basics and content length" {
  // Python: `Connection("CLIENT")` raises ValueError. Not applicable here:
  // the role is a typed enum, so an invalid role cannot be constructed.
  let p = ConnectionPair::new()
  assert_eq(p.conn(Client).our_role(), Client)
  assert_eq(p.conn(Client).their_role(), Server)
  assert_eq(p.conn(Server).our_role(), Server)
  assert_eq(p.conn(Server).their_role(), Client)
  let wire = p.send(Client, [
    req(b"GET", b"/", [(b"Host", b"example.com"), (b"Content-Length", b"10")]),
  ])
  assert_eq(
    wire,
    b"GET / HTTP/1.1\r\n" +
    b"Host: example.com\r\n" +
    b"Content-Length: 10\r\n\r\n",
  )
  for conn in p.conns() {
    assert_eq(conn.states(), states(SendBody, SendResponse))
  }
  assert_eq(p.conn(Client).our_state(), SendBody)
  assert_eq(p.conn(Client).their_state(), SendResponse)
  assert_eq(p.conn(Server).our_state(), SendResponse)
  assert_eq(p.conn(Server).their_state(), SendBody)
  assert_eq(p.conn(Client).their_http_version(), None)
  assert_eq(p.conn(Server).their_http_version(), Some(b"1.1"))
  let wire = p.send(Server, [info_resp(100, [])])
  assert_eq(wire, b"HTTP/1.1 100 \r\n\r\n")
  let wire = p.send(Server, [resp(200, [(b"Content-Length", b"11")])])
  assert_eq(wire, b"HTTP/1.1 200 \r\nContent-Length: 11\r\n\r\n")
  for conn in p.conns() {
    assert_eq(conn.states(), states(SendBody, SendBody))
  }
  assert_eq(p.conn(Client).their_http_version(), Some(b"1.1"))
  assert_eq(p.conn(Server).their_http_version(), Some(b"1.1"))
  let wire = p.send(Client, [@h11.Event::Data(@h11.Data::new(b"12345"))])
  assert_eq(wire, b"12345")
  let wire = p.send(Client, [data(b"67890")], expect=[data(b"67890"), eom()])
  assert_eq(wire, b"67890")
  let wire = p.send(Client, [eom()], expect=[])
  assert_eq(wire, b"")
  for conn in p.conns() {
    assert_eq(conn.states(), states(Done, SendBody))
  }
  let wire = p.send(Server, [data(b"1234567890")])
  assert_eq(wire, b"1234567890")
  let wire = p.send(Server, [data(b"1")], expect=[data(b"1"), eom()])
  assert_eq(wire, b"1")
  let wire = p.send(Server, [eom()], expect=[])
  assert_eq(wire, b"")
  for conn in p.conns() {
    assert_eq(conn.states(), states(Done, Done))
  }
}

///|
test "chunked" {
  let p = ConnectionPair::new()
  p.send(Client, [
    req(b"GET", b"/", [
      (b"Host", b"example.com"),
      (b"Transfer-Encoding", b"chunked"),
    ]),
  ])
  |> ignore
  let wire = p.send(Client, [
    data(b"1234567890", chunk_start=true, chunk_end=true),
  ])
  assert_eq(wire, b"a\r\n1234567890\r\n")
  let wire = p.send(Client, [data(b"abcde", chunk_start=true, chunk_end=true)])
  assert_eq(wire, b"5\r\nabcde\r\n")
  let wire = p.send(Client, [data(b"")], expect=[])
  assert_eq(wire, b"")
  let wire = p.send(Client, [eom(headers=[(b"hello", b"there")])])
  assert_eq(wire, b"0\r\nhello: there\r\n\r\n")
  p.send(Server, [resp(200, [(b"Transfer-Encoding", b"chunked")])]) |> ignore
  p.send(Server, [data(b"54321", chunk_start=true, chunk_end=true)]) |> ignore
  p.send(Server, [data(b"12345", chunk_start=true, chunk_end=true)]) |> ignore
  p.send(Server, [eom()]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(Done, Done))
  }
}

///|
test "chunk boundaries" {
  let conn = @h11.Connection::new(Server)
  let request = b"POST / HTTP/1.1\r\n" +
    b"Host: example.com\r\n" +
    b"Transfer-Encoding: chunked\r\n" +
    b"\r\n"
  conn.receive_data(request)
  assert_eq(
    conn.next_event(),
    Event(
      req(b"POST", b"/", [
        (b"Host", b"example.com"),
        (b"Transfer-Encoding", b"chunked"),
      ]),
    ),
  )
  assert_eq(conn.next_event(), NeedData)
  conn.receive_data(b"5\r\nhello\r\n")
  assert_eq(
    conn.next_event(),
    Event(data(b"hello", chunk_start=true, chunk_end=true)),
  )
  conn.receive_data(b"5\r\nhel")
  assert_eq(
    conn.next_event(),
    Event(data(b"hel", chunk_start=true, chunk_end=false)),
  )
  conn.receive_data(b"l")
  assert_eq(
    conn.next_event(),
    Event(data(b"l", chunk_start=false, chunk_end=false)),
  )
  conn.receive_data(b"o\r\n")
  assert_eq(
    conn.next_event(),
    Event(data(b"o", chunk_start=false, chunk_end=true)),
  )
  conn.receive_data(b"5\r\nhello")
  assert_eq(
    conn.next_event(),
    Event(data(b"hello", chunk_start=true, chunk_end=true)),
  )
  conn.receive_data(b"\r\n")
  assert_eq(conn.next_event(), NeedData)
  conn.receive_data(b"0\r\n\r\n")
  assert_eq(conn.next_event(), Event(eom()))
}

///|
test "client talking to http10 server" {
  let c = @h11.Connection::new(Client)
  c.send(req(b"GET", b"/", [(b"Host", b"example.com")])) |> ignore
  c.send(eom()) |> ignore
  assert_eq(c.our_state(), Done)
  // No content-length, so Http10 framing for body
  assert_eq(receive_and_get(c, b"HTTP/1.0 200 OK\r\n\r\n"), [
    resp(200, [], http_version=b"1.0", reason=b"OK"),
  ])
  assert_eq(c.our_state(), MustClose)
  assert_eq(receive_and_get(c, b"12345"), [data(b"12345")])
  assert_eq(receive_and_get(c, b"67890"), [data(b"67890")])
  assert_eq(receive_and_get(c, b""), [eom(), ConnectionClosed])
  assert_eq(c.their_state(), Closed)
}

///|
test "server talking to http10 client" {
  let c = @h11.Connection::new(Server)
  // No content-length, so no body
  // NB: no host header
  assert_eq(receive_and_get(c, b"GET / HTTP/1.0\r\n\r\n"), [
    req(b"GET", b"/", [], http_version=b"1.0"),
    eom(),
  ])
  assert_eq(c.their_state(), MustClose)
  // We automatically Connection: close back at them
  assert_eq(
    c.send(resp(200, [])),
    Some(b"HTTP/1.1 200 \r\nConnection: close\r\n\r\n"),
  )
  assert_eq(c.send(data(b"12345")), Some(b"12345"))
  assert_eq(c.send(eom()), Some(b""))
  assert_eq(c.our_state(), MustClose)
  // Check that it works if they do send Content-Length
  let c = @h11.Connection::new(Server)
  // NB: no host header
  assert_eq(
    receive_and_get(c, b"POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\n1"),
    [
      req(b"POST", b"/", [(b"Content-Length", b"10")], http_version=b"1.0"),
      data(b"1"),
    ],
  )
  assert_eq(receive_and_get(c, b"234567890"), [data(b"234567890"), eom()])
  assert_eq(c.their_state(), MustClose)
  assert_eq(receive_and_get(c, b""), [ConnectionClosed])
}

///|
test "automatic transfer encoding in response" {
  // Check that in responses, the user can specify either Transfer-Encoding:
  // chunked or no framing at all, and in both cases we automatically select
  // the right option depending on whether the peer speaks HTTP/1.0 or
  // HTTP/1.1
  let cases : Array[Array[(Bytes, Bytes)]] = [
    [(b"Transfer-Encoding", b"chunked")],
    [],
    // In fact, this even works if Content-Length is set,
    // because if both are set then Transfer-Encoding wins
    [(b"Transfer-Encoding", b"chunked"), (b"Content-Length", b"100")],
  ]
  for user_headers in cases {
    let p = ConnectionPair::new()
    p.send(Client, [req(b"GET", b"/", [(b"Host", b"example.com")]), eom()])
    |> ignore
    // When speaking to HTTP/1.1 client, all of the above cases get
    // normalized to Transfer-Encoding: chunked
    p.send(Server, [resp(200, user_headers)], expect=[
      resp(200, [(b"Transfer-Encoding", b"chunked")]),
    ])
    |> ignore
    // When speaking to HTTP/1.0 client, all of the above cases get
    // normalized to no-framing-headers
    let c = @h11.Connection::new(Server)
    receive_and_get(c, b"GET / HTTP/1.0\r\n\r\n") |> ignore
    assert_eq(
      c.send(resp(200, user_headers)),
      Some(b"HTTP/1.1 200 \r\nConnection: close\r\n\r\n"),
    )
    assert_eq(c.send(data(b"12345")), Some(b"12345"))
  }
}

///|
test "automagic connection close handling" {
  let p = ConnectionPair::new()
  // If the user explicitly sets Connection: close, then we notice and
  // respect it
  p.send(Client, [
    req(b"GET", b"/", [(b"Host", b"example.com"), (b"Connection", b"close")]),
    eom(),
  ])
  |> ignore
  for conn in p.conns() {
    assert_eq(conn.states()[Client], MustClose)
  }
  // And if the client sets it, the server automatically echoes it back
  p.send(
    Server,
    // no header here...
    [resp(204, []), eom()],
    // ...but oh look, it arrived anyway
    expect=[resp(204, [(b"connection", b"close")]), eom()],
  )
  |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(MustClose, MustClose))
  }
}

///|
fn setup_100_continue() -> ConnectionPair raise {
  let p = ConnectionPair::new()
  p.send(Client, [
    req(b"GET", b"/", [
      (b"Host", b"example.com"),
      (b"Content-Length", b"100"),
      (b"Expect", b"100-continue"),
    ]),
  ])
  |> ignore
  for conn in p.conns() {
    assert_true(conn.client_is_waiting_for_100_continue())
  }
  assert_true(!p.conn(Client).they_are_waiting_for_100_continue())
  assert_true(p.conn(Server).they_are_waiting_for_100_continue())
  p
}

///|
test "100 continue" {
  // Disabled by 100 Continue
  let p = setup_100_continue()
  p.send(Server, [info_resp(100, [])]) |> ignore
  for conn in p.conns() {
    assert_true(!conn.client_is_waiting_for_100_continue())
    assert_true(!conn.they_are_waiting_for_100_continue())
  }
  // Disabled by a real response
  let p = setup_100_continue()
  p.send(Server, [resp(200, [(b"Transfer-Encoding", b"chunked")])]) |> ignore
  for conn in p.conns() {
    assert_true(!conn.client_is_waiting_for_100_continue())
    assert_true(!conn.they_are_waiting_for_100_continue())
  }
  // Disabled by the client going ahead and sending stuff anyway
  let p = setup_100_continue()
  p.send(Client, [data(b"12345")]) |> ignore
  for conn in p.conns() {
    assert_true(!conn.client_is_waiting_for_100_continue())
    assert_true(!conn.they_are_waiting_for_100_continue())
  }
}

///|
test "max incomplete event size countermeasure" {
  // Infinitely long headers are definitely not okay
  let c = @h11.Connection::new(Server)
  c.receive_data(b"GET / HTTP/1.0\r\nEndless: ")
  assert_eq(c.next_event(), NeedData)
  expect_remote_error(() => {
    // Python loops forever; bound it so a missing error fails instead of
    // hanging (1000 KiB is far beyond the 16 KiB default limit).
    for _ in 0..<1000 {
      c.receive_data(Bytes::make(1024, b'a'))
      c.next_event() |> ignore
    }
  })
  |> ignore
  // Checking that the same header is accepted / rejected depending on the
  // max_incomplete_event_size setting:
  let c = @h11.Connection::new(Server, max_incomplete_event_size=5000)
  c.receive_data(b"GET / HTTP/1.0\r\nBig: ")
  c.receive_data(Bytes::make(4000, b'a'))
  c.receive_data(b"\r\n\r\n")
  assert_eq(get_all_events(c), [
    req(b"GET", b"/", [(b"big", Bytes::make(4000, b'a'))], http_version=b"1.0"),
    eom(),
  ])
  let c = @h11.Connection::new(Server, max_incomplete_event_size=4000)
  c.receive_data(b"GET / HTTP/1.0\r\nBig: ")
  c.receive_data(Bytes::make(4000, b'a'))
  expect_remote_error(() => c.next_event() |> ignore) |> ignore
  // Temporarily exceeding the size limit is fine, as long as its done with
  // complete events:
  let c = @h11.Connection::new(Server, max_incomplete_event_size=5000)
  c.receive_data(b"GET / HTTP/1.0\r\nContent-Length: 10000")
  c.receive_data(b"\r\n\r\n" + Bytes::make(10000, b'a'))
  assert_eq(get_all_events(c), [
    req(b"GET", b"/", [(b"Content-Length", b"10000")], http_version=b"1.0"),
    data(Bytes::make(10000, b'a')),
    eom(),
  ])
  let c = @h11.Connection::new(Server, max_incomplete_event_size=100)
  // Two pipelined requests to create a way-too-big receive buffer... but
  // it's fine because we're not checking
  c.receive_data(
    b"GET /1 HTTP/1.1\r\nHost: a\r\n\r\n" +
    b"GET /2 HTTP/1.1\r\nHost: b\r\n\r\n" +
    Bytes::make(1000, b'X'),
  )
  assert_eq(get_all_events(c), [req(b"GET", b"/1", [(b"host", b"a")]), eom()])
  // Even more data comes in, still no problem
  c.receive_data(Bytes::make(1000, b'X'))
  // We can respond and reuse to get the second pipelined request
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  c.start_next_cycle()
  assert_eq(get_all_events(c), [req(b"GET", b"/2", [(b"host", b"b")]), eom()])
  // But once we unpause and try to read the next message, and find that it's
  // incomplete and the buffer is *still* way too large, then *that's* a
  // problem:
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  c.start_next_cycle()
  expect_remote_error(() => c.next_event() |> ignore) |> ignore
}

///|
test "reuse simple" {
  let p = ConnectionPair::new()
  p.send(Client, [req(b"GET", b"/", [(b"Host", b"a")]), eom()]) |> ignore
  p.send(Server, [resp(200, [(b"transfer-encoding", b"chunked")]), eom()])
  |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(Done, Done))
    conn.start_next_cycle()
  }
  p.send(Client, [req(b"DELETE", b"/foo", [(b"Host", b"a")]), eom()]) |> ignore
  p.send(Server, [resp(404, [(b"transfer-encoding", b"chunked")]), eom()])
  |> ignore
}

///|
test "pipelining" {
  // Client doesn't support pipelining, so we have to do this by hand
  let c = @h11.Connection::new(Server)
  assert_eq(c.next_event(), NeedData)
  // 3 requests all bunched up
  c.receive_data(
    b"GET /1 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n" +
    b"12345" +
    b"GET /2 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n" +
    b"67890" +
    b"GET /3 HTTP/1.1\r\nHost: a.com\r\n\r\n",
  )
  assert_eq(get_all_events(c), [
    req(b"GET", b"/1", [(b"Host", b"a.com"), (b"Content-Length", b"5")]),
    data(b"12345"),
    eom(),
  ])
  assert_eq(c.their_state(), Done)
  assert_eq(c.our_state(), SendResponse)
  assert_eq(c.next_event(), Paused)
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  assert_eq(c.their_state(), Done)
  assert_eq(c.our_state(), Done)
  c.start_next_cycle()
  assert_eq(get_all_events(c), [
    req(b"GET", b"/2", [(b"Host", b"a.com"), (b"Content-Length", b"5")]),
    data(b"67890"),
    eom(),
  ])
  assert_eq(c.next_event(), Paused)
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  c.start_next_cycle()
  assert_eq(get_all_events(c), [
    req(b"GET", b"/3", [(b"Host", b"a.com")]),
    eom(),
  ])
  // Doesn't pause this time, no trailing data
  assert_eq(c.next_event(), NeedData)
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  // Arrival of more data triggers pause
  assert_eq(c.next_event(), NeedData)
  c.receive_data(b"SADF")
  assert_eq(c.next_event(), Paused)
  assert_eq(c.trailing_data(), (b"SADF", false))
  // If EOF arrives while paused, we don't see that either:
  c.receive_data(b"")
  assert_eq(c.trailing_data(), (b"SADF", true))
  assert_eq(c.next_event(), Paused)
  c.receive_data(b"")
  assert_eq(c.next_event(), Paused)
  // Can't call receive_data with non-empty buf after closing it
  expect_runtime_error(() => c.receive_data(b"FDSA"))
}

///|
fn setup_protocol_switch(request : @h11.Event) -> ConnectionPair raise {
  let p = ConnectionPair::new()
  p.send(Client, [request]) |> ignore
  // No switch-related state change stuff yet; the client has to
  // finish the request before that kicks in
  for conn in p.conns() {
    assert_eq(conn.states()[Client], SendBody)
  }
  p.send(Client, [data(b"1"), eom()]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states()[Client], MightSwitchProtocol)
  }
  assert_eq(p.conn(Server).next_event(), Paused)
  p
}

///|
test "protocol switch" {
  let cases = [
    (
      req(b"CONNECT", b"example.com:443", [
        (b"Host", b"foo"),
        (b"Content-Length", b"1"),
      ]),
      resp(404, [(b"transfer-encoding", b"chunked")]),
      resp(200, [(b"transfer-encoding", b"chunked")]),
    ),
    (
      req(b"GET", b"/", [
        (b"Host", b"foo"),
        (b"Content-Length", b"1"),
        (b"Upgrade", b"a, b"),
      ]),
      resp(200, [(b"transfer-encoding", b"chunked")]),
      info_resp(101, [(b"Upgrade", b"a")]),
    ),
    (
      req(b"CONNECT", b"example.com:443", [
        (b"Host", b"foo"),
        (b"Content-Length", b"1"),
        (b"Upgrade", b"a, b"),
      ]),
      resp(404, [(b"transfer-encoding", b"chunked")]),
      // Accept CONNECT, not upgrade
      resp(200, [(b"transfer-encoding", b"chunked")]),
    ),
    (
      req(b"CONNECT", b"example.com:443", [
        (b"Host", b"foo"),
        (b"Content-Length", b"1"),
        (b"Upgrade", b"a, b"),
      ]),
      resp(404, [(b"transfer-encoding", b"chunked")]),
      // Accept Upgrade, not CONNECT
      info_resp(101, [(b"Upgrade", b"b")]),
    ),
  ]
  for case in cases {
    let (request, deny, accept) = case
    // Test deny case
    let p = setup_protocol_switch(request)
    p.send(Server, [deny]) |> ignore
    for conn in p.conns() {
      assert_eq(conn.states(), states(Done, SendBody))
    }
    p.send(Server, [eom()]) |> ignore
    // Check that re-use is still allowed after a denial
    for conn in p.conns() {
      conn.start_next_cycle()
    }
    // Test accept case
    let p = setup_protocol_switch(request)
    p.send(Server, [accept]) |> ignore
    for conn in p.conns() {
      assert_eq(conn.states(), states(SwitchedProtocol, SwitchedProtocol))
      conn.receive_data(b"123")
      assert_eq(conn.next_event(), Paused)
      conn.receive_data(b"456")
      assert_eq(conn.next_event(), Paused)
      assert_eq(conn.trailing_data(), (b"123456", false))
    }
    // Pausing in might-switch, then recovery
    // (weird artificial case where the trailing data actually is valid
    // HTTP for some reason, because this makes it easier to test the state
    // logic)
    let p = setup_protocol_switch(request)
    let sc = p.conn(Server)
    sc.receive_data(b"GET / HTTP/1.0\r\n\r\n")
    assert_eq(sc.next_event(), Paused)
    assert_eq(sc.trailing_data(), (b"GET / HTTP/1.0\r\n\r\n", false))
    sc.send(deny) |> ignore
    assert_eq(sc.next_event(), Paused)
    sc.send(eom()) |> ignore
    sc.start_next_cycle()
    assert_eq(get_all_events(sc), [
      req(b"GET", b"/", [], http_version=b"1.0"),
      eom(),
    ])
    // When we're DONE, have no trailing data, and the connection gets
    // closed, we report ConnectionClosed(). When we're in might-switch or
    // switched, we don't.
    let p = setup_protocol_switch(request)
    let sc = p.conn(Server)
    sc.receive_data(b"")
    assert_eq(sc.next_event(), Paused)
    assert_eq(sc.trailing_data(), (b"", true))
    p.send(Server, [accept]) |> ignore
    assert_eq(sc.next_event(), Paused)
    let p = setup_protocol_switch(request)
    let sc = p.conn(Server)
    sc.receive_data(b"")
    assert_eq(sc.next_event(), Paused)
    sc.send(deny) |> ignore
    assert_eq(sc.next_event(), Event(ConnectionClosed))
    // You can't send after switching protocols, or while waiting for a
    // protocol switch
    let p = setup_protocol_switch(request)
    expect_local_error(() => {
      p.conn(Client).send(req(b"GET", b"/", [(b"Host", b"a")])) |> ignore
    })
    |> ignore
    let p = setup_protocol_switch(request)
    p.send(Server, [accept]) |> ignore
    expect_local_error(() => p.conn(Server).send(data(b"123")) |> ignore)
    |> ignore
  }
}

///|
fn setup_close_simple(
  who_shot_first : @h11.Role,
  who_shot_second : @h11.Role,
) -> ConnectionPair raise {
  let p = ConnectionPair::new()
  p.send(who_shot_first, [ConnectionClosed]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states()[who_shot_first], Closed)
    assert_eq(conn.states()[who_shot_second], MustClose)
  }
  p
}

///|
test "close simple" {
  // Just immediately closing a new connection without anything having
  // happened yet.
  for roles in [(@h11.Role::Client, @h11.Role::Server), (Server, Client)] {
    let (who_shot_first, who_shot_second) = roles
    // You can keep putting b"" into a closed connection, and you keep
    // getting ConnectionClosed() out:
    let p = setup_close_simple(who_shot_first, who_shot_second)
    assert_eq(p.conn(who_shot_second).next_event(), Event(ConnectionClosed))
    assert_eq(p.conn(who_shot_second).next_event(), Event(ConnectionClosed))
    p.conn(who_shot_second).receive_data(b"")
    assert_eq(p.conn(who_shot_second).next_event(), Event(ConnectionClosed))
    // Second party can close...
    let p = setup_close_simple(who_shot_first, who_shot_second)
    p.send(who_shot_second, [ConnectionClosed]) |> ignore
    for conn in p.conns() {
      assert_eq(conn.our_state(), Closed)
      assert_eq(conn.their_state(), Closed)
    }
    // But trying to receive new data on a closed connection is a
    // RuntimeError (not ProtocolError, because the problem here isn't
    // violation of HTTP, it's violation of physics)
    let p = setup_close_simple(who_shot_first, who_shot_second)
    expect_runtime_error(() => p.conn(who_shot_second).receive_data(b"123"))
    // And receiving new data on a MUST_CLOSE connection is a ProtocolError
    let p = setup_close_simple(who_shot_first, who_shot_second)
    p.conn(who_shot_first).receive_data(b"GET")
    expect_remote_error(() => p.conn(who_shot_first).next_event() |> ignore)
    |> ignore
  }
}

///|
test "close different states" {
  let req_events = [req(b"GET", b"/foo", [(b"Host", b"a")]), eom()]
  let resp_events = [resp(200, [(b"transfer-encoding", b"chunked")]), eom()]
  // Client before request
  let p = ConnectionPair::new()
  p.send(Client, [ConnectionClosed]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(Closed, MustClose))
  }
  // Client after request
  let p = ConnectionPair::new()
  p.send(Client, req_events) |> ignore
  p.send(Client, [ConnectionClosed]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(Closed, SendResponse))
  }
  // Server after request -> not allowed
  let p = ConnectionPair::new()
  p.send(Client, req_events) |> ignore
  expect_local_error(() => p.conn(Server).send(ConnectionClosed) |> ignore)
  |> ignore
  p.conn(Client).receive_data(b"")
  expect_remote_error(() => p.conn(Client).next_event() |> ignore) |> ignore
  // Server after response
  let p = ConnectionPair::new()
  p.send(Client, req_events) |> ignore
  p.send(Server, resp_events) |> ignore
  p.send(Server, [ConnectionClosed]) |> ignore
  for conn in p.conns() {
    assert_eq(conn.states(), states(MustClose, Closed))
  }
  // Both after closing (ConnectionClosed() is idempotent)
  let p = ConnectionPair::new()
  p.send(Client, req_events) |> ignore
  p.send(Server, resp_events) |> ignore
  p.send(Client, [ConnectionClosed]) |> ignore
  p.send(Server, [ConnectionClosed]) |> ignore
  p.send(Client, [ConnectionClosed]) |> ignore
  p.send(Server, [ConnectionClosed]) |> ignore
  // In the middle of sending -> not allowed
  let p = ConnectionPair::new()
  p.send(Client, [
    req(b"GET", b"/", [(b"Host", b"a"), (b"Content-Length", b"10")]),
  ])
  |> ignore
  expect_local_error(() => p.conn(Client).send(ConnectionClosed) |> ignore)
  |> ignore
  p.conn(Server).receive_data(b"")
  expect_remote_error(() => p.conn(Server).next_event() |> ignore) |> ignore
}

///|
/// Receive several requests and then client shuts down their side of the
/// connection; we can respond to each
test "pipelined close" {
  let c = @h11.Connection::new(Server)
  // 2 requests then a close
  c.receive_data(
    b"GET /1 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n" +
    b"12345" +
    b"GET /2 HTTP/1.1\r\nHost: a.com\r\nContent-Length: 5\r\n\r\n" +
    b"67890",
  )
  c.receive_data(b"")
  assert_eq(get_all_events(c), [
    req(b"GET", b"/1", [(b"host", b"a.com"), (b"content-length", b"5")]),
    data(b"12345"),
    eom(),
  ])
  assert_eq(c.states()[Client], Done)
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  assert_eq(c.states()[Server], Done)
  c.start_next_cycle()
  assert_eq(get_all_events(c), [
    req(b"GET", b"/2", [(b"host", b"a.com"), (b"content-length", b"5")]),
    data(b"67890"),
    eom(),
    ConnectionClosed,
  ])
  assert_eq(c.states(), states(Closed, SendResponse))
  c.send(resp(200, [])) |> ignore
  c.send(eom()) |> ignore
  assert_eq(c.states(), states(Closed, MustClose))
  c.send(ConnectionClosed) |> ignore
  assert_eq(c.states(), states(Closed, Closed))
}

///|
/// Python uses a placeholder object with `__len__` for `Data.data`; in
/// MoonBit `Data.data` is always `Bytes`, so we use a 10-byte value and check
/// that the very same `Bytes` object is passed through.
fn setup_sendfile(
  header : (Bytes, Bytes)?,
  http_version : Bytes,
  placeholder : Bytes,
) -> (@h11.Connection, Array[Bytes]?) raise {
  let c = @h11.Connection::new(Server)
  receive_and_get(c, b"GET / HTTP/" + http_version + b"\r\nHost: a\r\n\r\n")
  |> ignore
  let headers = []
  if header is Some(h) {
    headers.push(h)
  }
  c.send(resp(200, headers)) |> ignore
  (c, c.send_with_data_passthrough(data(placeholder)))
}

///|
test "sendfile" {
  let placeholder = Bytes::make(10, b'x')
  let (c, data) = setup_sendfile(
    Some((b"Content-Length", b"10")),
    b"1.1",
    placeholder,
  )
  guard data is Some([only]) else {
    fail("expected [placeholder], got \{Repr(data)}")
  }
  assert_true(physical_equal(only, placeholder))
  // Raises an error if the connection object doesn't think we've sent
  // exactly 10 bytes
  c.send(eom()) |> ignore
  let (_, data) = setup_sendfile(
    Some((b"Transfer-Encoding", b"chunked")),
    b"1.1",
    placeholder,
  )
  guard data is Some(data) else { fail("expected Some(_)") }
  assert_true(data.iter().any(d => physical_equal(d, placeholder)))
  let joined = @buffer.Buffer()
  for d in data {
    joined.write_bytes(d)
  }
  assert_eq(joined.to_bytes(), b"a\r\nxxxxxxxxxx\r\n")
  let (c, data) = setup_sendfile(None, b"1.0", placeholder)
  guard data is Some([only]) else {
    fail("expected [placeholder], got \{Repr(data)}")
  }
  assert_true(physical_equal(only, placeholder))
  assert_eq(c.our_state(), SendBody)
}

///|
fn errors_conn(role : @h11.Role) -> @h11.Connection raise {
  let c = @h11.Connection::new(role)
  if role is Server {
    // Put it into the state where it *could* send a response...
    receive_and_get(c, b"GET / HTTP/1.0\r\n\r\n") |> ignore
    assert_eq(c.our_state(), SendResponse)
  }
  c
}

///|
test "errors" {
  // After a receive error, you can't receive
  for role in [@h11.Role::Client, Server] {
    let c = @h11.Connection::new(role)
    c.receive_data(b"gibberish\r\n\r\n")
    expect_remote_error(() => c.next_event() |> ignore) |> ignore
    // Now any attempt to receive continues to raise
    assert_eq(c.their_state(), Error)
    assert_true(c.our_state() != Error)
    expect_remote_error(() => c.next_event() |> ignore) |> ignore
    // But we can still yell at the client for sending us gibberish
    if role is Server {
      assert_eq(
        c.send(resp(400, [])),
        Some(b"HTTP/1.1 400 \r\nConnection: close\r\n\r\n"),
      )
    }
  }
  // After an error sending, you can no longer send
  // (This is especially important for things like content-length errors,
  // where there's complex internal state being modified)
  for role in [@h11.Role::Client, Server] {
    let (good, bad) = match role {
      // This HTTP/1.0 request won't be detected as bad until after we go
      // through the state machine and hit the writing code
      Client =>
        (
          req(b"GET", b"/", [(b"Host", b"example.com")]),
          req(b"GET", b"/", [(b"Host", b"example.com")], http_version=b"1.0"),
        )
      Server => (resp(200, []), resp(200, [], http_version=b"1.0"))
    }
    // Make sure 'good' actually is good
    let c = errors_conn(role)
    c.send(good) |> ignore
    assert_true(c.our_state() != Error)
    // Do that again, but this time sending 'bad' first
    let c = errors_conn(role)
    expect_local_error(() => c.send(bad) |> ignore) |> ignore
    assert_eq(c.our_state(), Error)
    assert_true(c.their_state() != Error)
    // Now 'good' is not so good
    expect_local_error(() => c.send(good) |> ignore) |> ignore
    // And check send_failed() too
    let c = errors_conn(role)
    c.send_failed()
    assert_eq(c.our_state(), Error)
    assert_true(c.their_state() != Error)
    // This is idempotent
    c.send_failed()
    assert_eq(c.our_state(), Error)
    assert_true(c.their_state() != Error)
  }
}

///|
test "idle receive nothing" {
  // At one point this incorrectly raised an error
  for role in [@h11.Role::Client, Server] {
    let c = @h11.Connection::new(role)
    assert_eq(c.next_event(), NeedData)
  }
}

///|
test "connection drop" {
  let c = @h11.Connection::new(Server)
  c.receive_data(b"GET /")
  assert_eq(c.next_event(), NeedData)
  c.receive_data(b"")
  expect_remote_error(() => c.next_event() |> ignore) |> ignore
}

///|
test "408 request timeout" {
  // Should be able to send this spontaneously as a server without seeing
  // anything from client
  let p = ConnectionPair::new()
  p.send(Server, [resp(408, [(b"connection", b"close")])]) |> ignore
}

///|
/// This used to raise IndexError
test "empty request" {
  let c = @h11.Connection::new(Server)
  c.receive_data(b"\r\n")
  expect_remote_error(() => c.next_event() |> ignore) |> ignore
}

///|
/// This used to raise IndexError
test "empty response" {
  let c = @h11.Connection::new(Client)
  c.send(req(b"GET", b"/", [(b"Host", b"a")])) |> ignore
  c.receive_data(b"\r\n")
  expect_remote_error(() => c.next_event() |> ignore) |> ignore
}

///|
test "early detection of invalid request" {
  for
    data in [
      b"\x00", b"\x20", b"\x16\x03\x01\x00\xa5", // Typical start of a TLS Client Hello
    ] {
    let c = @h11.Connection::new(Server)
    // Early detection should occur before even receiving a `\r\n`
    c.receive_data(data)
    expect_remote_error(() => c.next_event() |> ignore) |> ignore
  }
}

///|
test "early detection of invalid response" {
  for
    data in [
      b"\x00", b"\x20", b"\x16\x03\x03\x00\x31", // Typical start of a TLS Server Hello
    ] {
    let c = @h11.Connection::new(Client)
    // Early detection should occur before even receiving a `\r\n`
    c.receive_data(data)
    expect_remote_error(() => c.next_event() |> ignore) |> ignore
  }
}

///|
fn setup_head_framing(
  method : Bytes,
  http_version : Bytes,
) -> @h11.Connection raise {
  let c = @h11.Connection::new(Server)
  c.receive_data(
    method + b" / HTTP/" + http_version + b"\r\n" + b"Host: example.com\r\n\r\n",
  )
  assert_true(c.next_event() is Event(Request(_)))
  assert_true(c.next_event() is Event(EndOfMessage(_)))
  c
}

///|
/// This used to give different headers for HEAD and GET.
/// The correct way to handle HEAD is to put whatever headers we *would* have
/// put if it were a GET -- even though we know that for HEAD, those headers
/// will be ignored.
test "HEAD framing headers" {
  for method in [b"GET", b"HEAD"] {
    // No Content-Length, HTTP/1.1 peer, should use chunked
    let c = setup_head_framing(method, b"1.1")
    assert_eq(
      c.send(resp(200, [])),
      Some(b"HTTP/1.1 200 \r\n" + b"Transfer-Encoding: chunked\r\n\r\n"),
    )
    // No Content-Length, HTTP/1.0 peer, frame with connection: close
    let c = setup_head_framing(method, b"1.0")
    assert_eq(
      c.send(resp(200, [])),
      Some(b"HTTP/1.1 200 \r\n" + b"Connection: close\r\n\r\n"),
    )
    // Content-Length + Transfer-Encoding, TE wins
    let c = setup_head_framing(method, b"1.1")
    assert_eq(
      c.send(
        resp(200, [
          (b"Content-Length", b"100"),
          (b"Transfer-Encoding", b"chunked"),
        ]),
      ),
      Some(b"HTTP/1.1 200 \r\n" + b"Transfer-Encoding: chunked\r\n\r\n"),
    )
  }
}

///|
test "special exceptions for lost connection in message body" {
  let c = @h11.Connection::new(Server)
  c.receive_data(
    b"POST / HTTP/1.1\r\n" +
    b"Host: example.com\r\n" +
    b"Content-Length: 100\r\n\r\n",
  )
  assert_true(c.next_event() is Event(Request(_)))
  assert_eq(c.next_event(), NeedData)
  c.receive_data(b"12345")
  assert_eq(c.next_event(), Event(data(b"12345")))
  c.receive_data(b"")
  let err = expect_remote_error(() => c.next_event() |> ignore)
  assert_true(err.to_string().contains("received 5 bytes"))
  assert_true(err.to_string().contains("expected 100"))
  let c = @h11.Connection::new(Server)
  c.receive_data(
    b"POST / HTTP/1.1\r\n" +
    b"Host: example.com\r\n" +
    b"Transfer-Encoding: chunked\r\n\r\n",
  )
  assert_true(c.next_event() is Event(Request(_)))
  assert_eq(c.next_event(), NeedData)
  c.receive_data(b"8\r\n012345")
  guard c.next_event() is Event(Data(d)) else { fail("expected Data") }
  assert_eq(d.data, b"012345")
  c.receive_data(b"")
  let err = expect_remote_error(() => c.next_event() |> ignore)
  assert_true(err.to_string().contains("incomplete chunked read"))
}
