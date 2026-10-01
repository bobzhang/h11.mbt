// Port of h11/tests/test_receivebuffer.py.

///|
fn opt_bytes(b : Bytes?) -> String {
  match b {
    None => "None"
    Some(b) => bytes_repr(b)
  }
}

///|
fn opt_lines(lines : Array[Bytes]?) -> String {
  match lines {
    None => "None"
    Some(lines) => "[" + lines.map(l => bytes_repr(l)).join(", ") + "]"
  }
}

///|
test "receivebuffer" {
  let b = ReceiveBuffer::new()
  assert_true(b.is_empty())
  assert_eq(b.length(), 0)
  assert_eq(b.to_bytes(), b"")
  b.append(b"123")
  assert_true(!b.is_empty())
  assert_eq(b.length(), 3)
  assert_eq(b.to_bytes(), b"123")
  assert_eq(b.maybe_extract_at_most(2L), Some(b"12"))
  assert_true(!b.is_empty())
  assert_eq(b.length(), 1)
  assert_eq(b.to_bytes(), b"3")
  assert_eq(b.maybe_extract_at_most(10L), Some(b"3"))
  assert_eq(b.to_bytes(), b"")
  assert_eq(b.maybe_extract_at_most(10L), None)
  assert_true(b.is_empty())

  // maybe_extract_next_line
  b.append(b"123\n456\r\n789\r\n")
  assert_eq(b.maybe_extract_next_line(), Some(b"123\n456\r\n"))
  assert_eq(b.to_bytes(), b"789\r\n")
  assert_eq(b.maybe_extract_next_line(), Some(b"789\r\n"))
  assert_eq(b.to_bytes(), b"")
  b.append(b"12\r")
  assert_eq(b.maybe_extract_next_line(), None)
  assert_eq(b.to_bytes(), b"12\r")
  b.append(b"345\n\r")
  assert_eq(b.maybe_extract_next_line(), None)
  assert_eq(b.to_bytes(), b"12\r345\n\r")

  // here we stopped at the middle of b"\r\n" delimiter
  b.append(b"\n6789aaa123\r\n")
  assert_eq(b.maybe_extract_next_line(), Some(b"12\r345\n\r\n"))
  assert_eq(b.maybe_extract_next_line(), Some(b"6789aaa123\r\n"))
  assert_eq(b.maybe_extract_next_line(), None)
  assert_eq(b.to_bytes(), b"")

  // maybe_extract_lines
  b.append(b"123\r\na: b\r\nfoo:bar\r\n\r\ntrailing")
  inspect(
    opt_lines(b.maybe_extract_lines()),
    content=(
      #|[b'123', b'a: b', b'foo:bar']
    ),
  )
  assert_eq(b.to_bytes(), b"trailing")
  assert_eq(b.maybe_extract_lines(), None)
  b.append(b"\r\n\r")
  assert_eq(b.maybe_extract_lines(), None)
  inspect(
    opt_bytes(b.maybe_extract_at_most(100L)),
    content=(
      #|b'trailing\r\n\r'
    ),
  )
  assert_true(b.is_empty())

  // Empty body case (as happens at the end of chunked encoding if there are
  // no trailing headers, e.g.)
  b.append(b"\r\ntrailing")
  assert_eq(b.maybe_extract_lines(), Some([]))
  assert_eq(b.to_bytes(), b"trailing")
}

///|
test "receivebuffer for invalid delimiter" {
  let cases : Array[Array[Bytes]] = [
    // with_crlf_delimiter
    [
      b"HTTP/1.1 200 OK\r\n", b"Content-type: text/plain\r\n", b"Connection: close\r\n",
      b"\r\n", b"Some body",
    ],
    // with_lf_only_delimiter
    [
      b"HTTP/1.1 200 OK\n", b"Content-type: text/plain\n", b"Connection: close\n",
      b"\n", b"Some body",
    ],
    // with_mixed_crlf_and_lf
    [
      b"HTTP/1.1 200 OK\n", b"Content-type: text/plain\r\n", b"Connection: close\n",
      b"\n", b"Some body",
    ],
  ]
  for data in cases {
    let b = ReceiveBuffer::new()
    for line in data {
      b.append(line)
    }
    let lines = b.maybe_extract_lines()
    assert_eq(
      lines,
      Some([
        b"HTTP/1.1 200 OK", b"Content-type: text/plain", b"Connection: close",
      ]),
    )
    assert_eq(b.to_bytes(), b"Some body")
  }
}

///|
test "receivebuffer large incremental growth stays consistent" {
  // Exercise the compaction / growth paths of the ring buffer.
  let b = ReceiveBuffer::new()
  let expected = @buffer.Buffer()
  for i in 0..<1000 {
    let chunk = Bytes::make(i % 37 + 1, (i % 251).to_byte())
    b.append(chunk)
    expected.write_bytes(chunk)
    if i % 3 == 0 {
      let n = (i % 50 + 1).to_int64()
      ignore(b.maybe_extract_at_most(n))
      let all = expected.to_bytes()
      let taken = if n.to_int() < all.length() {
        n.to_int()
      } else {
        all.length()
      }
      expected.reset()
      expected.write_bytesview(all[taken:])
    }
  }
  assert_eq(b.to_bytes(), expected.to_bytes())
}
