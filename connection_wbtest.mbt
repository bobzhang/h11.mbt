// White-box port of test__keep_alive and test__body_framing from
// h11/tests/test_connection.py. `keep_alive` and `body_framing` are private
// in the MoonBit port, so they can only be tested from inside the package.

///|
fn keep_alive_req(
  headers : Array[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
) -> Bool raise {
  let r = Request::new(method_=b"GET", target=b"/", headers~, http_version~)
  keep_alive(r.headers, r.http_version)
}

///|
fn keep_alive_resp(
  headers : Array[(Bytes, Bytes)],
  http_version? : Bytes = b"1.1",
) -> Bool raise {
  let r = Response::new(status_code=200, headers~, http_version~)
  keep_alive(r.headers, r.http_version)
}

///|
test "_keep_alive" {
  assert_true(keep_alive_req([(b"Host", b"Example.com")]))
  assert_true(
    !keep_alive_req([(b"Host", b"Example.com"), (b"Connection", b"close")]),
  )
  assert_true(
    !keep_alive_req([
      (b"Host", b"Example.com"),
      (b"Connection", b"a, b, cLOse, foo"),
    ]),
  )
  assert_true(!keep_alive_req([], http_version=b"1.0"))
  assert_true(keep_alive_resp([]))
  assert_true(!keep_alive_resp([(b"Connection", b"close")]))
  assert_true(!keep_alive_resp([(b"Connection", b"a, b, cLOse, foo")]))
  assert_true(!keep_alive_resp([], http_version=b"1.0"))
}

///|
fn framing_headers(cl : Int?, te : Bool) -> Array[(Bytes, Bytes)] {
  let headers = []
  if cl is Some(cl) {
    headers.push((b"Content-Length", @utf8.encode(cl.to_string())))
  }
  if te {
    headers.push((b"Transfer-Encoding", b"chunked"))
  }
  headers
}

///|
fn framing_resp(
  status_code? : Int = 200,
  cl? : Int,
  te? : Bool = false,
) -> Event raise {
  Response(Response::new(status_code~, headers=framing_headers(cl, te)))
}

///|
fn framing_req(cl? : Int, te? : Bool = false) -> Event raise {
  let h = framing_headers(cl, te)
  h.push((b"Host", b"example.com"))
  Request(Request::new(method_=b"GET", target=b"/", headers=h))
}

///|
test "_body_framing" {
  // Special cases where the headers are ignored:
  for
    kwargs in [
      (None, false),
      (Some(100), false),
      (None, true),
      (Some(100), true),
    ] {
    let (cl, te) = kwargs
    for
      case in [
        (b"HEAD", framing_resp(cl?, te~)),
        (b"GET", framing_resp(status_code=204, cl?, te~)),
        (b"GET", framing_resp(status_code=304, cl?, te~)),
      ] {
      let (meth, r) = case
      assert_true(body_framing(Some(meth), r) is ContentLength(0L, ..))
    }
  }
  // Transfer-encoding
  for kwargs in [(None, true), (Some(100), true)] {
    let (cl, te) = kwargs
    assert_true(body_framing(None, framing_req(cl?, te~)) is Chunked)
    assert_true(body_framing(Some(b"GET"), framing_resp(cl?, te~)) is Chunked)
  }
  // Content-Length
  assert_true(
    body_framing(None, framing_req(cl=100)) is ContentLength(100L, ..),
  )
  assert_true(
    body_framing(Some(b"GET"), framing_resp(cl=100)) is ContentLength(100L, ..),
  )
  // No headers
  assert_true(body_framing(None, framing_req()) is ContentLength(0L, ..))
  assert_true(body_framing(Some(b"GET"), framing_resp()) is Http10)
}
