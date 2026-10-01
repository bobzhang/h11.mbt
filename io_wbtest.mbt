// Port of h11/tests/test_io.py (white-box: readers, writers and the
// receive buffer are package-private).

///|
/// Merges adjacent Data events and removes chunk boundaries
/// (port of `normalize_data_events` from h11/tests/helpers.py).
fn normalize_data_events(in_events : Array[Event]) -> Array[Event] {
  let out_events : Array[Event] = []
  for event in in_events {
    let event = match event {
      Data(d) => Event::Data(Data::new(d.data))
      e => e
    }
    match (out_events.last(), event) {
      (Some(Data(prev)), Data(d)) =>
        out_events[out_events.length() - 1] = Event::Data(
          Data::new(prev.data + d.data),
        )
      _ => out_events.push(event)
    }
  }
  out_events
}

///|
/// Runs `f` and checks that it raises a `LocalProtocolError`
/// (equivalent of `with pytest.raises(LocalProtocolError): ...`).
fn expect_local_error(f : () -> Unit raise) -> Unit raise {
  try f() catch {
    ProtocolError::LocalProtocolError(_, ..) => ()
    e => raise e
  } noraise {
    _ => fail("expected LocalProtocolError to be raised")
  }
}

///|
fn simple_cases() -> Array[(Role, State, Event, Bytes)] raise {
  [
    (
      Client,
      Idle,
      Event::Request(
        Request::new(method=b"GET", target=b"/a", headers=[
          (b"Host", b"foo"),
          (b"Connection", b"close"),
        ]),
      ),
      b"GET /a HTTP/1.1\r\nHost: foo\r\nConnection: close\r\n\r\n",
    ),
    (
      Server,
      SendResponse,
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Connection", b"close")],
          reason=b"OK",
        ),
      ),
      b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n",
    ),
    (
      Server,
      SendResponse,
      Event::Response(Response::new(status_code=200, headers=[], reason=b"OK")),
      b"HTTP/1.1 200 OK\r\n\r\n",
    ),
    (
      Server,
      SendResponse,
      Event::InformationalResponse(
        InformationalResponse::new(
          status_code=101,
          headers=[(b"Upgrade", b"websocket")],
          reason=b"Upgrade",
        ),
      ),
      b"HTTP/1.1 101 Upgrade\r\nUpgrade: websocket\r\n\r\n",
    ),
    (
      Server,
      SendResponse,
      Event::InformationalResponse(
        InformationalResponse::new(
          status_code=101,
          headers=[],
          reason=b"Upgrade",
        ),
      ),
      b"HTTP/1.1 101 Upgrade\r\n\r\n",
    ),
  ]
}

///|
fn[T] dowrite(writer : (T, Array[Bytes]) -> Unit raise, obj : T) -> Bytes raise {
  let got_list : Array[Bytes] = []
  writer(obj, got_list)
  bytes_concat(got_list)
}

///|
fn[T] tw(
  writer : (T, Array[Bytes]) -> Unit raise,
  obj : T,
  expected : Bytes,
) -> Unit raise {
  let got = dowrite(writer, obj)
  assert_eq(got, expected)
}

///|
/// Adapts a `Writer` to the callable shape used by `dowrite`/`tw`.
fn writer_fn(w : Writer) -> (Event, Array[Bytes]) -> Unit raise {
  (event, out) => w.write(event, out)
}

///|
/// `write_any_response` as called with a response object, like in Python.
fn write_any_response_event(
  response : Response,
  out : Array[Bytes],
) -> Unit raise ProtocolError {
  write_any_response(
    response.status_code,
    response.headers,
    response.http_version,
    response.reason,
    out,
  )
}

///|
fn makebuf(data : BytesView) -> ReceiveBuffer {
  let buf = ReceiveBuffer::new()
  buf.append(data)
  buf
}

///|
fn tr(reader : Reader, data : Bytes, expected : Event?) -> Unit raise {
  // Simple: consume whole thing
  let buf = makebuf(data)
  assert_eq(reader.read(buf), expected)
  assert_true(buf.is_empty())
  // Incrementally growing buffer
  let buf = ReceiveBuffer::new()
  for i in 0..<data.length() {
    assert_eq(reader.read(buf), None)
    buf.append(data[i:i + 1])
  }
  assert_eq(reader.read(buf), expected)
  // Trailing data
  let buf = makebuf(data)
  buf.append(b"trailing")
  assert_eq(reader.read(buf), expected)
  assert_eq(buf.to_bytes(), b"trailing")
}

///|
fn client_idle_reader() -> Reader {
  reader_for_state(Client, Idle).unwrap()
}

///|
fn server_send_response_reader() -> Reader {
  reader_for_state(Server, SendResponse).unwrap()
}

///|
test "writers_simple" {
  for case in simple_cases() {
    let (role, state, event, binary) = case
    tw(writer_fn(writer_for_state(role, state).unwrap()), event, binary)
  }
}

///|
test "readers_simple" {
  for case in simple_cases() {
    let (role, state, event, binary) = case
    tr(reader_for_state(role, state).unwrap(), binary, Some(event))
  }
}

///|
test "writers_unusual" {
  // Simple test of the write_headers utility routine
  tw(
    (headers, out) => write_headers(headers, out),
    normalize_and_validate([(b"foo", b"bar"), (b"baz", b"quux")], parsed=false),
    b"foo: bar\r\nbaz: quux\r\n\r\n",
  )
  tw((headers, out) => write_headers(headers, out), Headers::empty(), b"\r\n")

  // We understand HTTP/1.0, but we don't speak it
  expect_local_error(() => {
    dowrite(
      (request, out) => write_request(request, out),
      Request::new(
        method=b"GET",
        target=b"/",
        headers=[(b"Host", b"foo"), (b"Connection", b"close")],
        http_version=b"1.0",
      ),
    )
    |> ignore
  })
  expect_local_error(() => {
    dowrite(
      (response, out) => write_any_response_event(response, out),
      Response::new(
        status_code=200,
        headers=[(b"Connection", b"close")],
        http_version=b"1.0",
      ),
    )
    |> ignore
  })
}

///|
test "readers_unusual" {
  // Reading HTTP/1.0
  tr(
    client_idle_reader(),
    b"HEAD /foo HTTP/1.0\r\nSome: header\r\n\r\n",
    Some(
      Event::Request(
        Request::new(
          method=b"HEAD",
          target=b"/foo",
          headers=[(b"Some", b"header")],
          http_version=b"1.0",
        ),
      ),
    ),
  )

  // check no-headers, since it's only legal with HTTP/1.0
  tr(
    client_idle_reader(),
    b"HEAD /foo HTTP/1.0\r\n\r\n",
    Some(
      Event::Request(
        Request::new(
          method=b"HEAD",
          target=b"/foo",
          headers=[],
          http_version=b"1.0",
        ),
      ),
    ),
  )
  tr(
    server_send_response_reader(),
    b"HTTP/1.0 200 OK\r\nSome: header\r\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Some", b"header")],
          http_version=b"1.0",
          reason=b"OK",
        ),
      ),
    ),
  )

  // single-character header values (actually disallowed by the ABNF in RFC
  // 7230 -- this is a bug in the standard that we originally copied...)
  tr(
    server_send_response_reader(),
    b"HTTP/1.0 200 OK\r\nFoo: a a a a a \r\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Foo", b"a a a a a")],
          http_version=b"1.0",
          reason=b"OK",
        ),
      ),
    ),
  )

  // Empty headers -- also legal
  tr(
    server_send_response_reader(),
    b"HTTP/1.0 200 OK\r\nFoo:\r\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Foo", b"")],
          http_version=b"1.0",
          reason=b"OK",
        ),
      ),
    ),
  )
  tr(
    server_send_response_reader(),
    b"HTTP/1.0 200 OK\r\nFoo: \t \t \r\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Foo", b"")],
          http_version=b"1.0",
          reason=b"OK",
        ),
      ),
    ),
  )

  // Tolerate broken servers that leave off the response code
  tr(
    server_send_response_reader(),
    b"HTTP/1.0 200\r\nFoo: bar\r\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"Foo", b"bar")],
          http_version=b"1.0",
          reason=b"",
        ),
      ),
    ),
  )

  // Tolerate headers line endings (\r\n and \n)
  //    \n\r\b between headers and body
  tr(
    server_send_response_reader(),
    b"HTTP/1.1 200 OK\r\nSomeHeader: val\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"SomeHeader", b"val")],
          http_version=b"1.1",
          reason=b"OK",
        ),
      ),
    ),
  )

  //   delimited only with \n
  tr(
    server_send_response_reader(),
    b"HTTP/1.1 200 OK\nSomeHeader1: val1\nSomeHeader2: val2\n\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"SomeHeader1", b"val1"), (b"SomeHeader2", b"val2")],
          http_version=b"1.1",
          reason=b"OK",
        ),
      ),
    ),
  )

  //   mixed \r\n and \n
  tr(
    server_send_response_reader(),
    b"HTTP/1.1 200 OK\r\nSomeHeader1: val1\nSomeHeader2: val2\n\r\n",
    Some(
      Event::Response(
        Response::new(
          status_code=200,
          headers=[(b"SomeHeader1", b"val1"), (b"SomeHeader2", b"val2")],
          http_version=b"1.1",
          reason=b"OK",
        ),
      ),
    ),
  )

  // obsolete line folding
  tr(
    client_idle_reader(),
    b"HEAD /foo HTTP/1.1\r\n" +
    b"Host: example.com\r\n" +
    b"Some: multi-line\r\n" +
    b" header\r\n" +
    b"\tnonsense\r\n" +
    b"    \t   \t\tI guess\r\n" +
    b"Connection: close\r\n" +
    b"More-nonsense: in the\r\n" +
    b"    last header  \r\n\r\n",
    Some(
      Event::Request(
        Request::new(method=b"HEAD", target=b"/foo", headers=[
          (b"Host", b"example.com"),
          (b"Some", b"multi-line header nonsense I guess"),
          (b"Connection", b"close"),
          (b"More-nonsense", b"in the last header"),
        ]),
      ),
    ),
  )
  expect_local_error(() => {
    tr(
      client_idle_reader(),
      b"HEAD /foo HTTP/1.1\r\n  folded: line\r\n\r\n",
      None,
    )
  })
  expect_local_error(() => {
    tr(client_idle_reader(), b"HEAD /foo HTTP/1.1\r\nfoo  : line\r\n\r\n", None)
  })
  expect_local_error(() => {
    tr(client_idle_reader(), b"HEAD /foo HTTP/1.1\r\nfoo\t: line\r\n\r\n", None)
  })
  expect_local_error(() => {
    tr(client_idle_reader(), b"HEAD /foo HTTP/1.1\r\nfoo\t: line\r\n\r\n", None)
  })
  expect_local_error(() => {
    tr(client_idle_reader(), b"HEAD /foo HTTP/1.1\r\n: line\r\n\r\n", None)
  })
}

///|
test "_obsolete_line_fold_bytes" {
  assert_eq(obsolete_line_fold([b"aaa", b"bbb", b"  ccc", b"ddd"]), [
    b"aaa", b"bbb ccc", b"ddd",
  ])
}

///|
fn run_reader_iter(
  reader : Reader,
  buf : ReceiveBuffer,
  do_eof : Bool,
) -> Array[Event] raise {
  let events = []
  for ;; {
    guard reader.read(buf) is Some(event) else { break }
    events.push(event)
    // body readers have undefined behavior after returning EndOfMessage,
    // because this changes the state so they don't get called again
    if event is EndOfMessage(_) {
      break
    }
  }
  if do_eof {
    assert_true(buf.is_empty())
    guard reader.read_eof() is Some(event) else {
      fail("reader has no read_eof handling")
    }
    events.push(event)
  }
  events
}

///|
fn run_reader(
  reader : Reader,
  buf : ReceiveBuffer,
  do_eof : Bool,
) -> Array[Event] raise {
  normalize_data_events(run_reader_iter(reader, buf, do_eof))
}

///|
/// The `expected` argument of `t_body_reader`: either a list of events, or
/// `[LocalProtocolError]` meaning the reader must raise.
priv enum BodyExpected {
  Events(Array[Event])
  RaisesLocalProtocolError
}

///|
fn check_body_result(
  expected : BodyExpected,
  f : () -> Array[Event] raise,
) -> Unit raise {
  match expected {
    Events(events) => assert_eq(f(), events)
    RaisesLocalProtocolError =>
      try f() catch {
        ProtocolError::LocalProtocolError(_, ..) => ()
        e => raise e
      } noraise {
        got =>
          fail("expected [LocalProtocolError], got \{Repr(got)} without error")
      }
  }
}

///|
fn t_body_reader(
  thunk : () -> Reader,
  data : Bytes,
  expected : BodyExpected,
  do_eof? : Bool = false,
) -> Unit raise {
  // Simple: consume whole thing
  check_body_result(expected, () => run_reader(thunk(), makebuf(data), do_eof))

  // Incrementally growing buffer
  let reader = thunk()
  check_body_result(expected, () => {
    let buf = ReceiveBuffer::new()
    let events = []
    for i in 0..<data.length() {
      events.append(run_reader(reader, buf, false))
      buf.append(data[i:i + 1])
    }
    events.append(run_reader(reader, buf, do_eof))
    normalize_data_events(events)
  })
  // is_complete = any(type(event) is EndOfMessage for event in expected)
  if expected is Events(evs) &&
    evs.iter().any(event => event is EndOfMessage(_)) &&
    !do_eof {
    let buf = makebuf(data + b"trailing")
    assert_eq(run_reader(thunk(), buf, false), evs)
  }
}

///|
fn eom(headers? : ArrayView[(Bytes, Bytes)] = []) -> Event raise {
  Event::EndOfMessage(EndOfMessage::new(headers~))
}

///|
fn data_event(data : Bytes) -> Event {
  Event::Data(Data::new(data))
}

///|
fn chunked_reader() -> Reader {
  reader_for_framing(Chunked)
}

///|
fn http10_reader() -> Reader {
  reader_for_framing(Http10)
}

///|
test "ContentLengthReader" {
  t_body_reader(
    () => reader_for_framing(ContentLength(0L)),
    b"",
    Events([eom()]),
  )
  t_body_reader(
    () => reader_for_framing(ContentLength(10L)),
    b"0123456789",
    Events([data_event(b"0123456789"), eom()]),
  )
}

///|
test "Http10Reader" {
  t_body_reader(http10_reader, b"", Events([eom()]), do_eof=true)
  t_body_reader(
    http10_reader,
    b"asdf",
    Events([data_event(b"asdf")]),
    do_eof=false,
  )
  t_body_reader(
    http10_reader,
    b"asdf",
    Events([data_event(b"asdf"), eom()]),
    do_eof=true,
  )
}

///|
test "ChunkedReader" {
  t_body_reader(chunked_reader, b"0\r\n\r\n", Events([eom()]))
  t_body_reader(
    chunked_reader,
    b"0\r\nSome: header\r\n\r\n",
    Events([eom(headers=[(b"Some", b"header")])]),
  )
  t_body_reader(
    chunked_reader,
    b"5\r\n01234\r\n" +
    b"10\r\n0123456789abcdef\r\n" +
    b"0\r\n" +
    b"Some: header\r\n\r\n",
    Events([
      data_event(b"012340123456789abcdef"),
      eom(headers=[(b"Some", b"header")]),
    ]),
  )
  t_body_reader(
    chunked_reader,
    b"5\r\n01234\r\n" + b"10\r\n0123456789abcdef\r\n" + b"0\r\n\r\n",
    Events([data_event(b"012340123456789abcdef"), eom()]),
  )

  // handles upper and lowercase hex
  t_body_reader(
    chunked_reader,
    b"aA\r\n" + Bytes::make(0xAA, b'x') + b"\r\n" + b"0\r\n\r\n",
    Events([data_event(Bytes::make(0xAA, b'x')), eom()]),
  )

  // refuses arbitrarily long chunk integers
  // Technically this is legal HTTP/1.1, but we refuse to process chunk
  // sizes that don't fit into 20 characters of hex
  t_body_reader(
    chunked_reader,
    Bytes::make(100, b'9') + b"\r\nxxx",
    RaisesLocalProtocolError,
  )

  // refuses garbage in the chunk count
  t_body_reader(chunked_reader, b"10\x00\r\nxxx", RaisesLocalProtocolError)

  // handles (and discards) "chunk extensions" omg wtf
  t_body_reader(
    chunked_reader,
    b"5; hello=there\r\n" +
    b"xxxxx" +
    b"\r\n" +
    b"0; random=\"junk\"; some=more; canbe=lonnnnngg\r\n\r\n",
    Events([data_event(b"xxxxx"), eom()]),
  )
  t_body_reader(
    chunked_reader,
    b"5   \t \r\n01234\r\n" + b"0\r\n\r\n",
    Events([data_event(b"01234"), eom()]),
  )

  // Chunked encoding with bad chunk termination characters are refused.
  // Originally we simply dropped the 2 bytes after a chunk, instead of
  // validating that the bytes were \r\n -- so we would successfully decode
  // the data below as b"xxxa". And apparently there are other HTTP
  // processors that ignore the chunk length and just keep reading until
  // they see \r\n, so they would decode it as b"xxx__1a". Any time two HTTP
  // processors accept the same input but interpret it differently, there's
  // a possibility of request smuggling shenanigans. So we now reject this.
  t_body_reader(chunked_reader, b"3\r\nxxx__1a\r\n", RaisesLocalProtocolError)

  // Confirm we check both bytes individually
  t_body_reader(chunked_reader, b"3\r\nxxx\r_1a\r\n", RaisesLocalProtocolError)
  t_body_reader(chunked_reader, b"3\r\nxxx_\n1a\r\n", RaisesLocalProtocolError)
}

///|
test "ContentLengthWriter" {
  let w = writer_fn(writer_for_framing(ContentLength(5L)))
  assert_eq(dowrite(w, data_event(b"123")), b"123")
  assert_eq(dowrite(w, data_event(b"45")), b"45")
  assert_eq(dowrite(w, eom()), b"")
  let w = writer_fn(writer_for_framing(ContentLength(5L)))
  expect_local_error(() => dowrite(w, data_event(b"123456")) |> ignore)
  let w = writer_fn(writer_for_framing(ContentLength(5L)))
  dowrite(w, data_event(b"123")) |> ignore
  expect_local_error(() => dowrite(w, data_event(b"456")) |> ignore)
  let w = writer_fn(writer_for_framing(ContentLength(5L)))
  dowrite(w, data_event(b"123")) |> ignore
  expect_local_error(() => dowrite(w, eom()) |> ignore)
  let w = writer_fn(writer_for_framing(ContentLength(5L)))
  assert_eq(dowrite(w, data_event(b"123")), b"123")
  assert_eq(dowrite(w, data_event(b"45")), b"45")
  expect_local_error(() => {
    dowrite(w, eom(headers=[(b"Etag", b"asdf")])) |> ignore
  })
}

///|
test "ChunkedWriter" {
  let w = writer_fn(writer_for_framing(Chunked))
  assert_eq(dowrite(w, data_event(b"aaa")), b"3\r\naaa\r\n")
  assert_eq(
    dowrite(w, data_event(Bytes::make(20, b'a'))),
    b"14\r\n" + Bytes::make(20, b'a') + b"\r\n",
  )
  assert_eq(dowrite(w, data_event(b"")), b"")
  assert_eq(dowrite(w, eom()), b"0\r\n\r\n")
  assert_eq(
    dowrite(w, eom(headers=[(b"Etag", b"asdf"), (b"a", b"b")])),
    b"0\r\nEtag: asdf\r\na: b\r\n\r\n",
  )
}

///|
test "Http10Writer" {
  let w = writer_fn(writer_for_framing(Http10))
  assert_eq(dowrite(w, data_event(b"1234")), b"1234")
  assert_eq(dowrite(w, eom()), b"")
  expect_local_error(() => {
    dowrite(w, eom(headers=[(b"Etag", b"asdf")])) |> ignore
  })
}

///|
test "reject_garbage_after_request_line" {
  expect_local_error(() => {
    tr(server_send_response_reader(), b"HTTP/1.0 200 OK\x00xxxx\r\n\r\n", None)
  })
}

///|
test "reject_garbage_after_response_line" {
  expect_local_error(() => {
    tr(
      client_idle_reader(),
      b"HEAD /foo HTTP/1.1 xxxxxx\r\nHost: a\r\n\r\n",
      None,
    )
  })
}

///|
test "reject_garbage_in_header_line" {
  expect_local_error(() => {
    tr(
      client_idle_reader(),
      b"HEAD /foo HTTP/1.1\r\nHost: foo\x00bar\r\n\r\n",
      None,
    )
  })
}

///|
test "reject_non_vchar_in_path" {
  for bad_char in [b'\x00', b'\x20', b'\x7f', b'\xee'] {
    let message = b"HEAD /" +
      Bytes::make(1, bad_char) +
      b" HTTP/1.1\r\nHost: foobar\r\n\r\n"
    expect_local_error(() => tr(client_idle_reader(), message, None))
  }
}

///|
/// https://github.com/python-hyper/h11/issues/57
test "allow_some_garbage_in_cookies" {
  tr(
    client_idle_reader(),
    b"HEAD /foo HTTP/1.1\r\n" +
    b"Host: foo\r\n" +
    b"Set-Cookie: ___utmvafIumyLc=kUd\x01UpAt; path=/; Max-Age=900\r\n" +
    b"\r\n",
    Some(
      Event::Request(
        Request::new(method=b"HEAD", target=b"/foo", headers=[
          (b"Host", b"foo"),
          (b"Set-Cookie", b"___utmvafIumyLc=kUd\x01UpAt; path=/; Max-Age=900"),
        ]),
      ),
    ),
  )
}

///|
test "host_comes_first" {
  tw(
    (headers, out) => write_headers(headers, out),
    normalize_and_validate(
      [(b"foo", b"bar"), (b"Host", b"example.com")],
      parsed=false,
    ),
    b"Host: example.com\r\nfoo: bar\r\n\r\n",
  )
}
