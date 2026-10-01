// Property-based tests (QuickCheck).
//
// The properties:
// - round trip: whatever a client/server sends, the peer parses back the
//   same events, regardless of how the bytes are fragmented in transit;
// - fragmentation invariance: for any input (valid, mutated or garbage)
//   smaller than the incomplete-event limit (16 KiB), feeding it in one piece
//   or in random fragments yields the same events and success/failure;
// - exact chunk boundaries: chunk_start/chunk_end delimit exactly the chunks
//   that were sent, however the bytes are fragmented;
// - robustness: no input makes the parser panic, and after an error the
//   connection stays in the ERROR state;
// - header normalization is idempotent.

///|
let tchars : Array[Byte] = b"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".to_array()

///|
let vchars : Array[Byte] = Array::makei(0x7e - 0x21 + 1, i => {
  (i + 0x21).to_byte()
})

///|
fn gen_bytes(alphabet : Array[Byte], lo : Int, hi : Int) -> @gen.Gen[Bytes] {
  @gen.int_range(lo, hi + 1).bind(n => {
    @gen.one_of_array(alphabet)
    .array_with_size(n)
    .fmap(a => Bytes::from_array(a))
  })
}

///|
fn gen_any_bytes(lo : Int, hi : Int) -> @gen.Gen[Bytes] {
  gen_bytes(Array::makei(256, i => i.to_byte()), lo, hi)
}

///|
fn[T] gen_array(g : @gen.Gen[T], lo : Int, hi : Int) -> @gen.Gen[Array[T]] {
  @gen.int_range(lo, hi + 1).bind(n => g.array_with_size(n))
}

///|
/// A header value: field-vchars (including obs-text and the control
/// characters h11 tolerates) with single internal spaces/tabs.
fn gen_header_value() -> @gen.Gen[Bytes] {
  let field_vchars = Array::makei(256, i => i.to_byte()).filter(b => {
    b != b'\x00' && !(b is (b' ' | b'\t' | b'\n' | b'\r' | b'\x0b' | b'\x0c'))
  })
  gen_array(gen_bytes(field_vchars, 1, 6), 0, 4).bind(words => {
    @gen.one_of_array([b" ", b"\t", b" \t "]).fmap(sep => {
      let buf = @buffer.Buffer()
      for i, w in words {
        if i > 0 {
          buf.write_bytes(sep)
        }
        buf.write_bytes(w)
      }
      buf.to_bytes()
    })
  })
}

///|
/// Header names that have special meaning to h11; random headers avoid them
/// so the generated messages have predictable framing.
let special_headers : Array[Bytes] = [
  b"host", b"content-length", b"transfer-encoding", b"connection", b"upgrade", b"expect",
]

///|
fn gen_plain_header() -> @gen.Gen[(Bytes, Bytes)] {
  @gen.tuple(gen_bytes(tchars, 1, 10), gen_header_value()).such_that(h => {
    !special_headers.contains(ascii_lower_test(h.0))
  })
}

///|
fn ascii_lower_test(b : Bytes) -> Bytes {
  Bytes::makei(b.length(), i => {
    let c = b[i]
    if c >= b'A' && c <= b'Z' {
      c + 32
    } else {
      c
    }
  })
}

///|
/// Split `data` at the given (unsorted, possibly out of range) points.
fn fragment(data : Bytes, points : Array[Int]) -> Array[Bytes] {
  let cuts = points
    .map(p => if data.length() == 0 { 0 } else { p.abs() % data.length() })
    .filter(p => p > 0)
  cuts.sort()
  let out = []
  let mut start = 0
  for c in cuts {
    if c > start {
      out.push(data[start:c].to_owned())
      start = c
    }
  }
  out.push(data[start:].to_owned())
  out
}

///|
/// Run a property body, turning failures into a counterexample message.
fn check(body : () -> Unit raise) -> Result[Bool, String] {
  try body() catch {
    e => Err(e.to_string())
  } noraise {
    _ => Ok(true)
  }
}

///|
fn merge_data(in_events : Array[@h11.Event]) -> Array[@h11.Event] {
  let out : Array[@h11.Event] = []
  for event in in_events {
    let event = match event {
      Data(d) => @h11.Event::Data(@h11.Data::new(d.data))
      e => e
    }
    match (out.last(), event) {
      (Some(Data(prev)), Data(d)) =>
        out[out.length() - 1] = Data(@h11.Data::new(prev.data + d.data))
      _ => out.push(event)
    }
  }
  out
}

///|
/// The observable result of feeding `chunks` to a fresh connection.
struct Outcome {
  events : Array[@h11.Event]
  error : Bool
  their_state : @h11.State
} derive(Eq, Debug)

///|
/// Feed `chunks` (then EOF) to a fresh `role` connection, pulling events
/// until it pauses, closes, or fails. Returns the raw events.
fn drive_raw(role : @h11.Role, chunks : Array[Bytes]) -> Outcome raise {
  let conn = @h11.Connection::new(role)
  if role is Client {
    // A client must have sent a request before it can read a response.
    ignore(
      conn.send(
        Request(
          @h11.Request::new(method_=b"GET", target=b"/", headers=[
            (b"Host", b"x"),
          ]),
        ),
      ),
    )
  }
  let events = []
  let mut next = 0
  let mut eof = false
  let mut error = false
  for ;; {
    let event = conn.next_event() catch {
      @h11.RemoteProtocolError(_, ..) => {
        error = true
        break
      }
      e => raise e
    }
    match event {
      NeedData =>
        if next < chunks.length() {
          conn.receive_data(chunks[next])
          next += 1
        } else if !eof {
          conn.receive_data(b"")
          eof = true
        } else {
          fail("NeedData after EOF without an error")
        }
      Paused => break
      Event(e) => {
        events.push(e)
        if e is ConnectionClosed {
          break
        }
      }
    }
  }
  if error {
    // After an error, the peer is in ERROR and stays there.
    assert_eq(conn.their_state(), Error)
    let failed_again = try conn.next_event() catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(failed_again)
  }
  { events, error, their_state: conn.their_state(), }
}

///|
/// Like `drive_raw`, but with Data events merged, since their boundaries
/// legitimately depend on fragmentation.
fn drive(role : @h11.Role, chunks : Array[Bytes]) -> Outcome raise {
  let outcome = drive_raw(role, chunks)
  { ..outcome, events: merge_data(outcome.events), }
}

///|
/// A randomly generated, valid request message.
struct ReqCase {
  meth : Bytes
  target : Bytes
  headers : Array[(Bytes, Bytes)]
  body : Array[Bytes]
  chunked : Bool
  trailers : Array[(Bytes, Bytes)]
  splits : Array[Int]
} derive(Debug)

///|
fn gen_req_case() -> @gen.Gen[ReqCase] {
  @gen.quad(
    @gen.tuple(
      @gen.frequency([
        (3, gen_bytes(tchars, 1, 8)),
        (1, @gen.one_of_array([b"GET", b"POST", b"HEAD", b"PUT", b"CONNECT"])),
      ]),
      gen_bytes(vchars, 0, 20),
    ),
    gen_array(gen_plain_header(), 0, 5),
    @gen.tuple(gen_array(gen_any_bytes(0, 30), 0, 4), @gen.Gen::spawn()),
    @gen.tuple(
      gen_array(gen_plain_header(), 0, 2),
      gen_array(@gen.int_range(0, 100000), 0, 8),
    ),
  ).fmap(t => {
    let ((meth, target), headers, (body, chunked), (trailers, splits)) = t
    {
      meth,
      target: b"/" + target,
      headers,
      body,
      chunked,
      trailers: if chunked {
        trailers
      } else {
        []
      },
      splits,
    }
  })
}

///|
fn ReqCase::events(self : ReqCase) -> Array[@h11.Event] raise {
  let headers = [(b"Host", b"example.com")]
  let total = self.body.fold(init=0, (acc, b) => acc + b.length())
  if self.chunked {
    headers.push((b"Transfer-Encoding", b"chunked"))
  } else {
    headers.push((b"Content-Length", @utf8.encode(total.to_string())))
  }
  headers.append(self.headers)
  let events : Array[@h11.Event] = [
    Request(@h11.Request::new(method_=self.meth, target=self.target, headers~)),
  ]
  for b in self.body {
    events.push(Data(@h11.Data::new(b)))
  }
  events.push(EndOfMessage(@h11.EndOfMessage::new(headers=self.trailers)))
  events
}

///|
test "property: requests round trip through any fragmentation" {
  @qc.quick_check(
    @qc.forall(gen_req_case(), (c : ReqCase) => {
      check(() => {
        let client = @h11.Connection::new(Client)
        let wire = @buffer.Buffer()
        let sent = c.events()
        for e in sent {
          wire.write_bytes(client.send(e).unwrap())
        }
        let expected_state : @h11.State = if c.meth == b"CONNECT" {
          MightSwitchProtocol
        } else {
          Done
        }
        assert_eq(client.our_state(), expected_state)
        let outcome = drive(Server, fragment(wire.to_bytes(), c.splits))
        let expected = merge_data(
          sent.filter(e => !(e is Data(d) && d.data.is_empty())),
        )
        assert_eq(outcome.error, false)
        if c.meth == b"CONNECT" {
          // A CONNECT request proposes a protocol switch: the server pauses
          // until it decides.
          assert_eq(outcome.events, expected)
          assert_eq(outcome.their_state, MightSwitchProtocol)
        } else {
          // drive() signals EOF after the data, so the peer then closes.
          assert_eq(outcome.events, expected + [ConnectionClosed])
          assert_eq(outcome.their_state, Closed)
        }
      })
    }),
    max_success=300,
  )
}

///|
/// A randomly generated, valid response, sent to an HTTP/1.0 or HTTP/1.1
/// client, with or without an explicit Content-Length.
struct RespCase {
  status_code : Int
  reason : Bytes
  headers : Array[(Bytes, Bytes)]
  body : Array[Bytes]
  use_content_length : Bool
  client_http10 : Bool
  head_request : Bool
  splits : Array[Int]
} derive(Debug)

///|
fn gen_resp_case() -> @gen.Gen[RespCase] {
  @gen.quad(
    @gen.tuple(
      @gen.int_range(200, 1000),
      gen_bytes(vchars + [b' ', b'\t'], 0, 12),
    ),
    gen_array(gen_plain_header(), 0, 5),
    gen_array(gen_any_bytes(0, 30), 0, 4),
    @gen.quad(
      @gen.Gen::spawn(),
      @gen.Gen::spawn(),
      @gen.frequency([(1, @gen.pure(true)), (4, @gen.pure(false))]),
      gen_array(@gen.int_range(0, 100000), 0, 8),
    ),
  ).fmap(t => {
    let ((status_code, reason), headers, body, (use_cl, http10, head, splits)) = t
    {
      status_code,
      reason,
      headers,
      body,
      use_content_length: use_cl,
      client_http10: http10,
      head_request: head,
      splits,
    }
  })
}

///|
fn RespCase::run(self : RespCase) -> Unit raise {
  let version = if self.client_http10 { b"1.0" } else { b"1.1" }
  let meth = if self.head_request { b"HEAD" } else { b"GET" }
  // The server reads the request...
  let server = @h11.Connection::new(Server)
  server.receive_data(
    meth + b" / HTTP/" + version + b"\r\nHost: example.com\r\n\r\n",
  )
  guard server.next_event() is Event(Request(_)) else { fail("no request") }
  guard server.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }
  // ...and responds.
  let no_body = self.head_request || self.status_code is (204 | 304)
  let body = if no_body { [] } else { self.body }
  let total = body.fold(init=0, (acc, b) => acc + b.length())
  let headers = if self.use_content_length {
    [(b"Content-Length", @utf8.encode(total.to_string()))]
  } else {
    []
  }
  headers.append(self.headers)
  let response = @h11.Response::new(
    status_code=self.status_code,
    headers~,
    reason=self.reason,
  )
  let wire = @buffer.Buffer()
  wire.write_bytes(server.send(Response(response)).unwrap())
  for b in body {
    wire.write_bytes(server.send(Data(@h11.Data::new(b))).unwrap())
  }
  wire.write_bytes(server.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap())
  // HTTP/1.0 clients never get keep-alive.
  if self.client_http10 {
    assert_eq(server.our_state(), MustClose)
  }
  // A client receives it (we replay the handshake on a client connection).
  let client = @h11.Connection::new(Client)
  ignore(
    client.send(
      Request(
        @h11.Request::new(method_=meth, target=b"/", headers=[
          (b"Host", b"example.com"),
        ]),
      ),
    ),
  )
  ignore(client.send(EndOfMessage(@h11.EndOfMessage::new())))
  // Parse after every fragment, so suspended readers are exercised.
  let events = []
  for chunk in fragment(wire.to_bytes(), self.splits) {
    client.receive_data(chunk)
    events.append(get_all_events(client))
  }
  // Close-delimited bodies need EOF to finish.
  if server.our_state() is MustClose {
    client.receive_data(b"")
    events.append(get_all_events(client))
  }
  let events = merge_data(events)
  guard events is [Response(got), .. rest] else { fail("no response") }
  assert_eq(got.status_code, self.status_code)
  assert_eq(got.reason, self.reason)
  for h in self.headers {
    assert_true(got.headers.raw_items().contains(h))
  }
  let expected_body = body.fold(init=b"", (acc, b) => acc + b)
  match rest {
    [Data(d), EndOfMessage(_), ..] => assert_eq(d.data, expected_body)
    [EndOfMessage(_), ..] => assert_eq(expected_body, b"")
    _ => fail("unexpected events \{Repr(rest)}")
  }
}

///|
test "property: responses round trip for HTTP/1.0 and HTTP/1.1 peers" {
  @qc.quick_check(
    @qc.forall(gen_resp_case(), (c : RespCase) => check(() => c.run())),
    max_success=300,
  )
}

///|
/// A valid response on the wire, with Content-Length, chunked, or
/// close-delimited framing.
fn gen_response_wire() -> @gen.Gen[Bytes] {
  @gen.quad(
    @gen.tuple(
      @gen.int_range(100, 1000),
      gen_bytes(vchars + [b' ', b'\t'], 0, 12),
    ),
    gen_array(gen_plain_header(), 0, 4),
    gen_array(gen_any_bytes(1, 20), 0, 3),
    @gen.int_range(0, 3),
  ).fmap(t => {
    let ((status, reason), headers, chunks, framing) = t
    let buf = @buffer.Buffer()
    buf.write_bytes(
      b"HTTP/1.1 " + @utf8.encode(status.to_string()) + b" " + reason + b"\r\n",
    )
    for h in headers {
      buf.write_bytes(h.0 + b": " + h.1 + b"\r\n")
    }
    let body = chunks.fold(init=b"", (acc, b) => acc + b)
    match framing {
      0 => {
        buf.write_bytes(
          b"Content-Length: " +
          @utf8.encode(body.length().to_string()) +
          b"\r\n\r\n",
        )
        buf.write_bytes(body)
      }
      1 => {
        buf.write_bytes(b"Transfer-Encoding: chunked\r\n\r\n")
        for c in chunks {
          buf.write_bytes(
            @utf8.encode(c.length().to_string(radix=16)) +
            b";ext\r\n" +
            c +
            b"\r\n",
          )
        }
        buf.write_bytes(b"0\r\n\r\n")
      }
      _ => {
        buf.write_bytes(b"\r\n")
        buf.write_bytes(body)
      }
    }
    buf.to_bytes()
  })
}

///|
/// Inputs for the robustness properties: valid messages, mutated valid
/// messages, and HTTP-flavoured garbage. Requests for a server, responses
/// for a client.
fn gen_wire_input(role : @h11.Role) -> @gen.Gen[Bytes] {
  let tokens : Array[Bytes] = [
    b"GET ", b"POST ", b"/", b" HTTP/1.1", b" HTTP/1.0", b"HTTP/1.1 ", b"200", b" OK",
    b"101", b"\r\n", b"\n", b"\r", b": ", b":", b" ", b"\t", b"Host", b"Content-Length",
    b"Transfer-Encoding", b"chunked", b"Connection", b"close", b"Upgrade", b"Expect",
    b"100-continue", b"0", b"5", b"a", b"ffffffff", b";ext", b"\x00", b"\x16\x03",
    b"\xff", b"12345", b"x",
  ]
  let valid = match role {
    Server =>
      gen_req_case().fmap(c => {
        let client = @h11.Connection::new(Client)
        let wire = @buffer.Buffer()
        for e in (try! c.events()) {
          wire.write_bytes(try! client.send(e).unwrap())
        }
        wire.to_bytes()
      })
    Client => gen_response_wire()
  }
  let mutated = @gen.tuple(
    valid,
    gen_array(@gen.tuple(@gen.int_range(0, 1 << 20), gen_any_bytes(0, 3)), 1, 4),
  ).fmap(t => {
    let (base, edits) = t
    let mut b = base
    for edit in edits {
      let (pos, ins) = edit
      let p = if b.length() == 0 { 0 } else { pos % b.length() }
      // replace one byte at `p` with `ins` (deletion when `ins` is empty)
      let end = if p < b.length() { p + 1 } else { p }
      b = b[:p].to_owned() + ins + b[end:].to_owned()
    }
    b
  })
  let garbage = gen_array(@gen.one_of_array(tokens), 0, 30).fmap(parts => {
    let g = parts.fold(init=b"", (acc, p) => acc + p)
    if role is Client {
      b"HTTP/1.1 200 OK\r\n" + g
    } else {
      g
    }
  })
  @gen.frequency([(2, valid), (5, mutated), (3, garbage)])
}

///|
test "property: fragmentation never changes the outcome" {
  @qc.quick_check(
    @qc.forall(
      @gen.one_of_array([@h11.Role::Client, Server]).bind(role => {
        @gen.tuple(
          gen_wire_input(role),
          gen_array(@gen.int_range(0, 100000), 0, 10),
        ).fmap(t => (role, t.0, t.1))
      }),
      (t : (@h11.Role, Bytes, Array[Int])) => {
        let (role, input, splits) = t
        check(() => {
          let whole = drive(role, [input])
          let pieces = drive(role, fragment(input, splits))
          assert_eq(whole, pieces)
        })
      },
    ),
    max_success=1000,
  )
}

///|
/// Content-Length / Transfer-Encoding header lists: several spellings of the
/// same length (repeated headers, comma lists), optionally a chunked
/// Transfer-Encoding in any case, mixed with plain headers.
fn gen_framing_headers() -> @gen.Gen[(Int, Array[(Bytes, Bytes)], Bool)] {
  @gen.quad(
    @gen.int_range(0, 50),
    gen_array(@gen.int_range(0, 3), 1, 4),
    @gen.one_of_array([
      None,
      Some(b"chunked"),
      Some(b"Chunked"),
      Some(b"CHUNKED"),
    ]),
    gen_array(gen_plain_header(), 0, 3),
  ).fmap(t => {
    let (n, forms, te, plain) = t
    let d = @utf8.encode(n.to_string())
    let headers = []
    for f in forms {
      let value = match f {
        1 => d + b", " + d
        2 => d + b"," + d + b" ,  " + d
        _ => d
      }
      headers.push((b"Content-Length", value))
    }
    if te is Some(v) {
      headers.push((b"Transfer-Encoding", v))
    }
    headers.append(plain)
    (n, headers, te is Some(_))
  })
}

///|
test "property: Content-Length and Transfer-Encoding normalization" {
  @qc.quick_check(
    @qc.forall(gen_framing_headers(), (t : (Int, Array[(Bytes, Bytes)], Bool)) => {
      let (n, raw, chunked) = t
      check(() => {
        let d = @utf8.encode(n.to_string())
        let headers = @h11.Headers::new(raw)
        // Exactly one, deduplicated, content-length entry survives...
        let cls = headers
          .iter()
          .filter(h => h.0 == b"content-length")
          .to_array()
        assert_eq(cls, [(b"content-length", d)])
        // ...and Transfer-Encoding is lowercased.
        let tes = headers
          .iter()
          .filter(h => h.0 == b"transfer-encoding")
          .to_array()
        let expected_te : Array[(Bytes, Bytes)] = if chunked {
          [(b"transfer-encoding", b"chunked")]
        } else {
          []
        }
        assert_eq(tes, expected_te)
        assert_eq(@h11.Headers::new(headers.raw_items()), headers)
        // A second, different length always conflicts.
        let other = @utf8.encode((n + 1).to_string())
        let conflict = try
          @h11.Headers::new(raw + [(b"Content-Length", other)])
        catch {
          @h11.LocalProtocolError(msg, ..) => msg
          e => raise e
        } noraise {
          _ => "no error"
        }
        assert_eq(conflict, "conflicting Content-Length headers")
        // The framing recorded in the headers is the one actually used:
        // exactly n body bytes go through, chunked if T-E is present.
        let client = @h11.Connection::new(Client)
        let req_headers = headers.raw_items() + [(b"Host", b"x")]
        let body = Bytes::make(n, b'z')
        let wire = client
          .send(
            Request(
              @h11.Request::new(
                method_=b"POST",
                target=b"/",
                headers=req_headers,
              ),
            ),
          )
          .unwrap() +
          client.send(Data(@h11.Data::new(body))).unwrap() +
          client.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()
        let encoded_body = if !chunked {
          body
        } else if n == 0 {
          b"0\r\n\r\n"
        } else {
          @utf8.encode(n.to_string(radix=16)) +
          b"\r\n" +
          body +
          b"\r\n0\r\n\r\n"
        }
        assert_true(wire.has_suffix(b"\r\n\r\n" + encoded_body))
        let outcome = drive(Server, [wire])
        assert_eq(outcome.error, false)
        let expected_data : Array[@h11.Event] = if n == 0 {
          []
        } else {
          [Data(@h11.Data::new(body))]
        }
        assert_eq(
          outcome.events[1:].to_owned(),
          expected_data +
          [EndOfMessage(@h11.EndOfMessage::new()), ConnectionClosed],
        )
      })
    }),
    max_success=500,
  )
}

///|
test "property: header normalization is idempotent" {
  @qc.quick_check(
    @qc.forall(gen_array(gen_plain_header(), 0, 8), (
      raw : Array[(Bytes, Bytes)],
    ) => {
      check(() => {
        let h = @h11.Headers::new(raw)
        let again = @h11.Headers::new(h.raw_items())
        assert_eq(h, again)
        assert_eq(h.raw_items(), again.raw_items())
        for item in h {
          assert_eq(item.0, ascii_lower_test(item.0))
        }
      })
    }),
    max_success=300,
  )
}

///|
test "property: chunked bodies keep exact chunk boundaries under any fragmentation" {
  @qc.quick_check(
    @qc.forall(
      @gen.tuple(
        gen_array(gen_any_bytes(0, 40), 0, 8),
        gen_array(@gen.int_range(0, 100000), 0, 8),
      ),
      (t : (Array[Bytes], Array[Int])) => {
        let (chunks, splits) = t
        check(() => {
          let client = @h11.Connection::new(Client)
          let wire = @buffer.Buffer()
          wire.write_bytes(
            client
            .send(
              Request(
                @h11.Request::new(method_=b"POST", target=b"/", headers=[
                  (b"Host", b"x"),
                  (b"Transfer-Encoding", b"chunked"),
                ]),
              ),
            )
            .unwrap(),
          )
          for c in chunks {
            wire.write_bytes(client.send(Data(@h11.Data::new(c))).unwrap())
          }
          wire.write_bytes(
            client.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap(),
          )
          let pieces = fragment(wire.to_bytes(), splits)
          // Exact chunk boundaries: data between chunk_start and chunk_end
          // reassembles every non-empty chunk that was sent.
          let raw = drive_raw(Server, pieces)
          let got : Array[Bytes] = []
          let mut current : @buffer.Buffer? = None
          for e in raw.events {
            guard e is Data(d) else { continue }
            if d.chunk_start {
              assert_true(current is None, msg="chunk started twice")
              current = Some(@buffer.Buffer())
            }
            guard current is Some(buf) else { fail("data outside a chunk") }
            buf.write_bytes(d.data)
            if d.chunk_end {
              got.push(buf.to_bytes())
              current = None
            }
          }
          assert_true(current is None, msg="unterminated chunk")
          assert_eq(got, chunks.filter(c => !c.is_empty()))
          let outcome = drive(Server, pieces)
          let body = chunks.fold(init=b"", (acc, b) => acc + b)
          let expected_data : Array[@h11.Event] = if body.is_empty() {
            []
          } else {
            [Data(@h11.Data::new(body))]
          }
          assert_eq(
            outcome.events[1:].to_owned(),
            expected_data +
            [EndOfMessage(@h11.EndOfMessage::new()), ConnectionClosed],
          )
        })
      },
    ),
    max_success=300,
  )
}
