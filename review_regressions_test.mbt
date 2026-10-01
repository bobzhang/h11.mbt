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
