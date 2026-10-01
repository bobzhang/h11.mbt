// Port of h11/tests/test_headers.py.

///|
fn nv(items : Array[(Bytes, Bytes)]) -> Array[(Bytes, Bytes)] raise {
  @h11.Headers::new(items).to_array()
}

///|
fn nv_error(items : Array[(Bytes, Bytes)]) -> @h11.ProtocolError raise {
  expect_local_error(() => ignore(@h11.Headers::new(items)))
}

///|
test "normalize_and_validate" {
  assert_eq(nv([(b"foo", b"bar")]), [(b"foo", b"bar")])

  // no leading/trailing whitespace in names
  ignore(nv_error([(b"foo ", b"bar")]))
  ignore(nv_error([(b" foo", b"bar")]))

  // no weird characters in names
  let e = nv_error([(b"foo bar", b"baz")])
  assert_true(e.message().contains("foo bar"))
  ignore(nv_error([(b"foo\x00bar", b"baz")]))
  // Not even 8-bit characters:
  ignore(nv_error([(b"foo\xffbar", b"baz")]))
  // And not even the control characters we allow in values:
  ignore(nv_error([(b"foo\x01bar", b"baz")]))

  // no return or NUL characters in values
  let e = nv_error([(b"foo", b"bar\rbaz")])
  assert_true(e.message().contains("bar\\rbaz"))
  ignore(nv_error([(b"foo", b"bar\nbaz")]))
  ignore(nv_error([(b"foo", b"bar\x00baz")]))
  // no leading/trailing whitespace
  ignore(nv_error([(b"foo", b"barbaz  ")]))
  ignore(nv_error([(b"foo", b"  barbaz")]))
  ignore(nv_error([(b"foo", b"barbaz\t")]))
  ignore(nv_error([(b"foo", b"\tbarbaz")]))

  // content-length
  assert_eq(nv([(b"Content-Length", b"1")]), [(b"content-length", b"1")])
  ignore(nv_error([(b"Content-Length", b"asdf")]))
  ignore(nv_error([(b"Content-Length", b"1x")]))
  ignore(nv_error([(b"Content-Length", b"1"), (b"Content-Length", b"2")]))
  assert_eq(nv([(b"Content-Length", b"0"), (b"Content-Length", b"0")]), [
    (b"content-length", b"0"),
  ])
  assert_eq(nv([(b"Content-Length", b"0 , 0")]), [(b"content-length", b"0")])
  ignore(
    nv_error([
      (b"Content-Length", b"1"),
      (b"Content-Length", b"1"),
      (b"Content-Length", b"2"),
    ]),
  )
  ignore(nv_error([(b"Content-Length", b"1 , 1,2")]))
  ignore(nv_error([(b"Content-Length", Bytes::make(21, b'1'))])) // 1 billion TB

  // transfer-encoding
  assert_eq(nv([(b"Transfer-Encoding", b"chunked")]), [
    (b"transfer-encoding", b"chunked"),
  ])
  assert_eq(nv([(b"Transfer-Encoding", b"cHuNkEd")]), [
    (b"transfer-encoding", b"chunked"),
  ])
  let e = nv_error([(b"Transfer-Encoding", b"gzip")])
  assert_eq(e.error_status_hint(), 501) // Not Implemented
  let e = nv_error([
    (b"Transfer-Encoding", b"chunked"),
    (b"Transfer-Encoding", b"gzip"),
  ])
  assert_eq(e.error_status_hint(), 501) // Not Implemented
}

///|
test "get/set comma header" {
  let headers = @h11.Headers::new([
    (b"Connection", b"close"),
    (b"whatever", b"something"),
    (b"connectiON", b"fOo,, , BAR"),
  ])
  assert_eq(@h11.get_comma_header(headers, b"connection"), [
    b"close", b"foo", b"bar",
  ])
  let headers = @h11.set_comma_header(headers, b"newthing", [b"a", b"b"])
  ignore(
    expect_local_error(() => {
      ignore(@h11.set_comma_header(headers, b"newthing", [b"  a", b"b"]))
    }),
  )
  assert_eq(headers.to_array(), [
    (b"connection", b"close"),
    (b"whatever", b"something"),
    (b"connection", b"fOo,, , BAR"),
    (b"newthing", b"a"),
    (b"newthing", b"b"),
  ])
  let headers = @h11.set_comma_header(headers, b"whatever", [b"different thing"])
  assert_eq(headers.to_array(), [
    (b"connection", b"close"),
    (b"connection", b"fOo,, , BAR"),
    (b"newthing", b"a"),
    (b"newthing", b"b"),
    (b"whatever", b"different thing"),
  ])
  // new headers get a title-cased name
  assert_eq(headers.raw_items()[4], (b"Whatever", b"different thing"))
}

///|
test "has_100_continue" {
  fn r(headers : Array[(Bytes, Bytes)], http_version : Bytes) raise {
    @h11.Request::new(method=b"GET", target=b"/", headers~, http_version~)
  }

  assert_true(
    @h11.has_expect_100_continue(
      r([(b"Host", b"example.com"), (b"Expect", b"100-continue")], b"1.1"),
    ),
  )
  assert_true(
    !@h11.has_expect_100_continue(r([(b"Host", b"example.com")], b"1.1")),
  )
  // Case insensitive
  assert_true(
    @h11.has_expect_100_continue(
      r([(b"Host", b"example.com"), (b"Expect", b"100-Continue")], b"1.1"),
    ),
  )
  // Doesn't work in HTTP/1.0
  assert_true(
    !@h11.has_expect_100_continue(
      r([(b"Host", b"example.com"), (b"Expect", b"100-continue")], b"1.0"),
    ),
  )
}

///|
test "headers equality ignores raw casing" {
  let a = @h11.Headers::new([(b"Host", b"a")])
  let b = @h11.Headers::new([(b"host", b"a")])
  assert_eq(a, b)
  assert_true(a.raw_items() != b.raw_items())
  debug_inspect(
    a,
    content=(
      #|[(b'host', b'a')]
    ),
  )
}
