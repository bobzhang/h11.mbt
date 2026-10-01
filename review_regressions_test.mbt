// Regression tests for issues found while reviewing the port.

///|
test "huge Content-Length and chunk sizes are accepted like in Python" {
  // 2^63 does not fit in an Int64, but Python accepts it (up to 20 digits).
  let c = @h11.Connection::new(Server)
  let events = receive_and_get(
    c, b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9223372036854775808\r\n\r\nx",
  )
  assert_eq(events.length(), 2)
  assert_eq(events[1], data(b"x"))
  assert_eq(c.next_event(), NeedData)

  // Chunk size 2^63 in hex.
  let c = @h11.Connection::new(Server)
  let events = receive_and_get(
    c, b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8000000000000000\r\nx",
  )
  assert_eq(events.length(), 2)
  assert_eq(events[1], data(b"x", chunk_start=true))

  // More than 20 digits is still rejected.
  ignore(
    expect_local_error(() => {
      ignore(@h11.Headers::new([(b"Content-Length", Bytes::make(21, b'9'))]))
    }),
  )
}

///|
test "many pipelined request refills stay fast" {
  // Used to reallocate the whole buffer on every refill (quadratic).
  let request = b"GET /12345 HTTP/1.1\r\nHost: x\r\n\r\n"
  let n = 4096
  let c = @h11.Connection::new(Server, max_incomplete_event_size=1 << 30)
  c.receive_data(request.repeat(n))
  for _ in 0..<(4 * n) {
    let events = get_all_events(c)
    assert_eq(events.length(), 2)
    ignore(c.send(resp(200, [(b"Content-Length", b"0")])))
    ignore(c.send(eom()))
    c.start_next_cycle()
    c.receive_data(request)
  }
}

///|
test "many Content-Length duplicates are rejected" {
  let values = Array::makei(10000, i => i.to_string()).join(",")
  let e = expect_local_error(() => {
    ignore(@h11.Headers::new([(b"Content-Length", @utf8.encode(values))]))
  })
  inspect(e.message(), content="conflicting Content-Length headers")
}

///|
test "Headers::get is safe out of range" {
  let h = @h11.Headers::new([(b"Host", b"a")])
  assert_eq(h.get(0), Some((b"host", b"a")))
  assert_eq(h.get(1), None)
  assert_eq(h.get(-1), None)
}

///|
test "EOF error quotes the declared Content-Length even beyond Int64" {
  // Found by differential fuzzing against Python h11.
  let c = @h11.Connection::new(Server)
  c.receive_data(
    b"PUT / HTTP/1.0\r\nContent-Length: 99999999999999999999\r\n\r\n",
  )
  ignore(c.next_event())
  c.receive_data(b"")
  let e = expect_remote_error(() => ignore(c.next_event()))
  inspect(
    e.message(),
    content="peer closed connection without sending complete message body (received 0 bytes, expected 99999999999999999999)",
  )
}

///|
test "chunk_start survives a chunk header arriving without its data" {
  // Python h11 reports chunk_start=False here (upstream bug).
  let c = @h11.Connection::new(Server)
  c.receive_data(
    b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
  )
  ignore(c.next_event())
  c.receive_data(b"3\r\n")
  assert_eq(c.next_event(), NeedData)
  c.receive_data(b"ab")
  assert_eq(c.next_event(), Event(data(b"ab", chunk_start=true)))
  c.receive_data(b"c\r\n")
  assert_eq(c.next_event(), Event(data(b"c", chunk_end=true)))
}

///|
test "EOF error formats the Content-Length like Python (no leading zeros)" {
  for
    case in [
      (b"0005", "expected 5"),
      (b"0", "expected 0"),
      (b"000", "expected 0"),
    ] {
    let (declared, expected) = case
    let c = @h11.Connection::new(Server)
    c.receive_data(
      b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: " +
      declared +
      b"\r\n\r\na",
    )
    let events = get_all_events(c)
    if declared == b"0005" {
      c.receive_data(b"")
      let e = expect_remote_error(() => ignore(c.next_event()))
      assert_true(e.message().has_suffix(expected + ")"), msg=e.message())
    } else {
      // Content-Length 0: the body is complete, trailing data is the next
      // request (which is garbage here).
      assert_true(events is [Request(_), EndOfMessage(_)])
    }
  }
}
