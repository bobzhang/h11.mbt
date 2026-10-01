// Port of h11/tests/test_events.py and the relevant parts of test_util.py.

///|
test "events" {
  // Missing Host:
  ignore(
    expect_local_error(() => {
      ignore(req(b"GET", b"/", [(b"a", b"b")], http_version=b"1.1"))
    }),
  )
  // But this is okay (HTTP/1.0)
  let r = @h11.Request::new(
    method=b"GET",
    target=b"/",
    headers=[(b"a", b"b")],
    http_version=b"1.0",
  )
  // fields are normalized
  assert_eq(r.method, b"GET")
  assert_eq(r.target, b"/")
  assert_eq(r.headers.to_array(), [(b"a", b"b")])
  assert_eq(r.http_version, b"1.0")

  // This is also okay -- has a Host (with weird capitalization, which is ok)
  let r = @h11.Request::new(
    method=b"GET",
    target=b"/",
    headers=[(b"a", b"b"), (b"hOSt", b"example.com")],
    http_version=b"1.1",
  )
  // we normalize header capitalization
  assert_eq(r.headers.to_array(), [(b"a", b"b"), (b"host", b"example.com")])

  // Multiple host is bad too
  ignore(
    expect_local_error(() => {
      ignore(req(b"GET", b"/", [(b"Host", b"a"), (b"Host", b"a")]))
    }),
  )
  // Even for HTTP/1.0
  ignore(
    expect_local_error(() => {
      ignore(
        req(b"GET", b"/", [(b"Host", b"a"), (b"Host", b"a")], http_version=b"1.0"),
      )
    }),
  )

  // Header values are validated
  for bad_char in [b'\x00', b'\r', b'\n', b'\x0c', b'\x0b'] {
    ignore(
      expect_local_error(() => {
        ignore(
          req(
            b"GET",
            b"/",
            [(b"Host", b"a"), (b"Foo", b"asd" + Bytes::make(1, bad_char))],
            http_version=b"1.0",
          ),
        )
      }),
    )
  }

  // But for compatibility we allow non-whitespace control characters, even
  // though they're forbidden by the spec.
  ignore(
    req(
      b"GET",
      b"/",
      [(b"Host", b"a"), (b"Foo", b"asd\x01\x02\x7f")],
      http_version=b"1.0",
    ),
  )

  // Request target is validated
  for bad_byte in [b'\x00', b'\x20', b'\x7f', b'\xee'] {
    let target = b"/" + Bytes::make(1, bad_byte)
    ignore(
      expect_local_error(() => {
        ignore(req(b"GET", target, [(b"Host", b"a")]))
      }),
    )
  }

  // Request method is validated
  ignore(
    expect_local_error(() => {
      ignore(req(b"GET / HTTP/1.1", b"/", [(b"Host", b"a")]))
    }),
  )
  let ir = @h11.InformationalResponse::new(
    status_code=100,
    headers=[(b"Host", b"a")],
  )
  assert_eq(ir.status_code, 100)
  assert_eq(ir.headers.to_array(), [(b"host", b"a")])
  assert_eq(ir.http_version, b"1.1")
  ignore(expect_local_error(() => ignore(info_resp(200, [(b"Host", b"a")]))))
  let r = @h11.Response::new(status_code=204, headers=[], http_version=b"1.0")
  assert_eq(r.status_code, 204)
  assert_eq(r.headers.to_array(), [])
  assert_eq(r.http_version, b"1.0")
  ignore(
    expect_local_error(() => ignore(resp(100, [], http_version=b"1.0"))),
  )
  // (Python also checks that a non-int status_code is rejected; the MoonBit
  // type system makes that impossible.)
  let d = @h11.Data::new(b"asdf")
  assert_eq(d.data, b"asdf")
  let e = @h11.EndOfMessage::new()
  assert_true(e.headers.is_empty())
  debug_inspect(@h11.Event::ConnectionClosed, content=(
    #|ConnectionClosed
  ))
}

///|
test "header casing" {
  let r = @h11.Request::new(
    method=b"GET",
    target=b"/",
    headers=[(b"Host", b"example.org"), (b"Connection", b"keep-alive")],
    http_version=b"1.1",
  )
  assert_eq(r.headers.length(), 2)
  assert_eq(r.headers[0], (b"host", b"example.org"))
  assert_eq(r.headers.to_array(), [
    (b"host", b"example.org"),
    (b"connection", b"keep-alive"),
  ])
  assert_eq(r.headers.raw_items(), [
    (b"Host", b"example.org"),
    (b"Connection", b"keep-alive"),
  ])
}

///|
test "event debug output" {
  debug_inspect(
    req(b"GET", b"/", [(b"Host", b"example.org"), (b"X-Thing", b"it's")]),
    content=(
      #|Request(
      #|  Request(
      #|    method=b'GET',
      #|    target=b'/',
      #|    headers=[(b'host', b'example.org'), (b'x-thing', b"it's")],
      #|    http_version=b'1.1',
      #|  ),
      #|)
    ),
  )
  debug_inspect(resp(200, [], reason=b"OK"), content=(
    #|Response(
    #|  Response(
    #|    status_code=200,
    #|    headers=[],
    #|    http_version=b'1.1',
    #|    reason=b'OK',
    #|  ),
    #|)
  ))
  debug_inspect(data(b"\x00\r\n", chunk_start=true), content=(
    #|Data(Data(data=b'\x00\r\n', chunk_start=true, chunk_end=false))
  ))
}

// --- test_util.py ---

///|
test "LocalProtocolError" {
  let e : @h11.ProtocolError = @h11.LocalProtocolError(
    "foo",
    error_status_hint=400,
  )
  assert_eq(e.message(), "foo")
  assert_eq(e.error_status_hint(), 400)
  assert_true(e.is_local())
  let e : @h11.ProtocolError = @h11.LocalProtocolError(
    "foo",
    error_status_hint=418,
  )
  assert_eq(e.error_status_hint(), 418)
  inspect(e, content=(
    #|LocalProtocolError("foo", error_status_hint=418)
  ))
}

///|
test "local errors are reraised as remote errors with the same hint" {
  // Python's test_LocalProtocolError checks _reraise_as_remote_protocol_error;
  // in MoonBit that conversion happens inside Connection::next_event.
  let c = @h11.Connection::new(Server)
  c.receive_data(b"GET / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n")
  let e = expect_remote_error(() => ignore(c.next_event()))
  assert_true(e.is_remote())
  assert_eq(e.error_status_hint(), 501)
  inspect(e.message(), content=(
    #|Only Transfer-Encoding: chunked is supported
  ))
}
