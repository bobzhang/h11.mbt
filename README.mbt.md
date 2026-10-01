# bobzhang/h11

A pure, bring-your-own-I/O implementation of HTTP/1.1 for MoonBit — a
faithful port of Python's [h11](https://github.com/python-hyper/h11).

- **Sans-I/O.** h11 never touches a socket. You feed it bytes, it gives you
  events; you give it events, it gives you bytes. Use it with any runtime:
  `moonbitlang/async`, a custom event loop, a test harness, or a fuzzer.
- **Complete HTTP/1.1 semantics.** Request/response framing
  (`Content-Length`, chunked encoding, HTTP/1.0 read-until-close),
  keep-alive and pipelining, `Expect: 100-continue`, `Upgrade` and `CONNECT`
  protocol switching, HEAD responses, trailers, and strict validation of
  everything that goes on or comes off the wire.
- **A real state machine.** Both peers' states are tracked explicitly, so
  protocol violations are caught as errors instead of silently producing
  garbage. Errors carry a suggested HTTP status code.
- **Thoroughly tested.** The whole h11 test suite is ported and passes.
- **No dependencies** beyond the MoonBit standard library; works on every
  backend.

## Installation

```bash
moon add bobzhang/h11
```

Then import it in your package's `moon.pkg`:

```
import {
  "bobzhang/h11",
}
```

## Quick start

A client and a server talking to each other entirely in memory:

```mbt check
///|
test "quick start: one request/response cycle" {
  let client = @h11.Connection::new(Client)
  let server = @h11.Connection::new(Server)

  // The client turns events into bytes...
  let request = @h11.Request::new(method_=b"GET", target=b"/hello", headers=[
    (b"Host", b"example.com"),
  ])
  let wire = client.send(Request(request)).unwrap() +
    client.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()
  inspect(
    @utf8.decode(wire),
    content="GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n",
  )

  // ...and the server turns bytes back into events.
  server.receive_data(wire)
  guard server.next_event() is Event(Request(req)) else { fail("no request") }
  assert_eq(req.target, b"/hello")
  guard server.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }
  assert_eq(server.next_event(), NeedData)

  // The server replies. No Content-Length was given, so h11 picks chunked
  // transfer encoding automatically because the client speaks HTTP/1.1.
  let response = @h11.Response::new(status_code=200, headers=[
    (b"Content-Type", b"text/plain"),
  ])
  let wire = server.send(Response(response)).unwrap() +
    server.send(Data(@h11.Data::new(b"hi!"))).unwrap() +
    server.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()
  inspect(
    @utf8.decode(wire),
    content="HTTP/1.1 200 \r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhi!\r\n0\r\n\r\n",
  )

  // The client parses the response.
  client.receive_data(wire)
  guard client.next_event() is Event(Response(resp)) else { fail("no resp") }
  assert_eq(resp.status_code, 200)
  guard client.next_event() is Event(Data(body)) else { fail("no data") }
  assert_eq(body.data, b"hi!")
  guard client.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }

  // Both sides are DONE, so the connection can be reused.
  assert_eq(client.states(), { client: Done, server: Done, })
  client.start_next_cycle()
  server.start_next_cycle()
}
```

## How it works

A `Connection` is created with the role you are playing (`Client` or
`Server`) and has three core operations:

| Operation | What it does |
| --- | --- |
| `conn.receive_data(bytes)` | Append bytes you read from the network to the internal buffer. Pass `b""` to signal end-of-file. |
| `conn.next_event()` | Parse the next event from the buffer. Returns `Event(event)`, `NeedData` (read more from the socket), or `Paused` (the peer is done for now; see *Keep-alive*). |
| `conn.send(event)` | Validate `event` against the state machine and return the bytes to write (`None` for `ConnectionClosed`). |

The events are:

| Event | Meaning |
| --- | --- |
| `Request(Request)` | Start of a request: `method_`, `target`, `headers`, `http_version` |
| `InformationalResponse(InformationalResponse)` | A `1xx` response |
| `Response(Response)` | Start of a final response: `status_code`, `headers`, `http_version`, `reason` |
| `Data(Data)` | A piece of a message body |
| `EndOfMessage(EndOfMessage)` | End of a message body, with optional trailers |
| `ConnectionClosed` | The peer closed their side of the connection |

Event payloads are built with validating constructors (`Request::new`,
`Response::new`, ...) that raise `LocalProtocolError` if you try to build
something illegal.

### A server loop

Here is the shape of a typical server, with the network abstracted as a
list of chunks that arrive one by one:

```mbt check
///|
/// Handle one connection whose incoming bytes arrive as `chunks`, returning
/// everything the server wrote.
fn serve(chunks : Array[Bytes]) -> Bytes raise {
  let conn = @h11.Connection::new(Server)
  let out = @buffer.Buffer()
  let mut next_chunk = 0
  for ;; {
    match conn.next_event() {
      NeedData =>
        // read from the socket; b"" means EOF
        if next_chunk < chunks.length() {
          conn.receive_data(chunks[next_chunk])
          next_chunk += 1
        } else {
          conn.receive_data(b"")
        }
      Event(Request(req)) => {
        let body = b"you asked for " + req.target
        let length = @utf8.encode(body.length().to_string())
        let resp = @h11.Response::new(status_code=200, headers=[
          (b"Content-Length", length),
        ])
        out.write_bytes(conn.send(Response(resp)).unwrap())
        out.write_bytes(conn.send(Data(@h11.Data::new(body))).unwrap())
        out.write_bytes(
          conn.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap(),
        )
      }
      Event(ConnectionClosed) => break
      Event(_) => () // request body chunks, end of request, ...
      Paused =>
        // Both sides finished one request/response cycle.
        if conn.our_state() is Done && conn.their_state() is Done {
          conn.start_next_cycle()
        } else {
          break // e.g. MUST_CLOSE: we should close the socket
        }
    }
  }
  out.to_bytes()
}

///|
test "server loop with a pipelined, fragmented request stream" {
  let replies = serve([
    b"GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HT", b"TP/1.1\r\nHost: x\r\n\r\n",
  ])
  inspect(
    @utf8.decode(replies),
    content="HTTP/1.1 200 \r\nContent-Length: 16\r\n\r\nyou asked for /aHTTP/1.1 200 \r\nContent-Length: 16\r\n\r\nyou asked for /b",
  )
}
```

### Keep-alive, pipelining, and `Paused`

After a peer finishes its part of a request/response cycle, `next_event`
returns `Paused` if more data is already buffered (a pipelined request).
Once both sides reach `Done`, call `start_next_cycle()` to reset to `Idle`
and continue reading. If either side sends `Connection: close` or speaks
HTTP/1.0, the states become `MustClose` instead and you should close the
socket after sending your response. h11 adds `Connection: close` to your
responses automatically when it is required.

### Body framing is handled for you

- A message with `Content-Length` is checked to contain exactly that many
  bytes (sending too much or too little is a `LocalProtocolError`).
- A response without `Content-Length` to an HTTP/1.1 client uses
  `Transfer-Encoding: chunked`; to an HTTP/1.0 client it falls back to
  "read until close" and forces `Connection: close`.
- Responses to `HEAD`, `204`, `304`, and successful `CONNECT` never have a
  body, regardless of headers.

```mbt check
///|
test "HTTP/1.0 peers get close-delimited bodies" {
  let server = @h11.Connection::new(Server)
  server.receive_data(b"GET / HTTP/1.0\r\n\r\n")
  guard server.next_event() is Event(Request(_)) else { fail("no request") }
  guard server.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }
  let wire = server.send(
    Response(@h11.Response::new(status_code=200, headers=[])),
  )
  inspect(
    @utf8.decode(wire.unwrap()),
    content="HTTP/1.1 200 \r\nConnection: close\r\n\r\n",
  )
  assert_eq(server.our_state(), SendBody)
}
```

### Headers

Headers are an ordered list of `(name, value)` byte-string pairs.
Iterating a `Headers` yields lowercased names; `raw_items()` preserves the
original casing, which is also what goes on the wire.

```mbt check
///|
test "headers keep their casing on the wire" {
  let headers = @h11.Headers::new([
    (b"Content-Type", b"text/html"),
    (b"X-Custom", b"1"),
  ])
  assert_eq(headers[0], (b"content-type", b"text/html"))
  assert_eq(headers.raw_items()[1], (b"X-Custom", b"1"))
  // Comma-separated headers can be read case-insensitively:
  let h = @h11.Headers::new([(b"Connection", b"Keep-Alive, Upgrade")])
  assert_eq(@h11.get_comma_header(h, b"connection"), [b"keep-alive", b"upgrade"])
}
```

### Expect: 100-continue

```mbt check
///|
test "100-continue" {
  let server = @h11.Connection::new(Server)
  server.receive_data(
    b"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n",
  )
  guard server.next_event() is Event(Request(_)) else { fail("no request") }
  assert_true(server.they_are_waiting_for_100_continue())
  let wire = server.send(
    InformationalResponse(
      @h11.InformationalResponse::new(status_code=100, headers=[]),
    ),
  )
  inspect(@utf8.decode(wire.unwrap()), content="HTTP/1.1 100 \r\n\r\n")
  assert_true(!server.they_are_waiting_for_100_continue())
}
```

### Protocol switching (`Upgrade` / `CONNECT`)

When the client proposes a switch, it enters `MightSwitchProtocol` after
its request and `next_event` returns `Paused` until the server answers. If
the server accepts (`101 Switching Protocols` for `Upgrade`, `2xx` for
`CONNECT`), both sides enter `SwitchedProtocol` and h11 steps aside: any
bytes after the handshake are available from `trailing_data()` for the new
protocol (e.g. WebSocket).

```mbt check
///|
test "upgrading to another protocol" {
  let server = @h11.Connection::new(Server)
  server.receive_data(
    b"GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\x81\x05hello",
  )
  guard server.next_event() is Event(Request(_)) else { fail("no request") }
  guard server.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }
  assert_eq(server.next_event(), Paused)
  assert_eq(server.their_state(), MightSwitchProtocol)
  let accept = @h11.InformationalResponse::new(status_code=101, headers=[
    (b"Upgrade", b"websocket"),
    (b"Connection", b"Upgrade"),
  ])
  ignore(server.send(InformationalResponse(accept)))
  assert_eq(server.states(), {
    client: SwitchedProtocol,
    server: SwitchedProtocol,
  })
  // The bytes that followed the handshake belong to the new protocol.
  assert_eq(server.trailing_data(), (b"\x81\x05hello", false))
}
```

### Error handling

- `next_event` raises `RemoteProtocolError` when the **peer** violates the
  protocol. The peer's state becomes `Error`; you should close the
  connection, optionally after sending an error response (the error's
  `error_status_hint()` suggests a status code).
- `send` and the event constructors raise `LocalProtocolError` when **you**
  try to do something illegal. After a failed `send`, our state becomes
  `Error`.
- Call `send_failed()` if writing to the socket fails, so the state machine
  knows the message was not delivered.

```mbt check
///|
test "errors carry a suggested status code" {
  let server = @h11.Connection::new(Server)
  server.receive_data(
    b"GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n",
  )
  try server.next_event() catch {
    RemoteProtocolError(msg, error_status_hint~) => {
      inspect(msg, content="Only Transfer-Encoding: chunked is supported")
      assert_eq(error_status_hint, 501)
    }
    e => fail("unexpected error \{e}")
  } noraise {
    _ => fail("expected an error")
  }
  assert_eq(server.their_state(), Error)

  // We can still tell the client what went wrong:
  let wire = server.send(
    Response(@h11.Response::new(status_code=501, headers=[])),
  )
  inspect(
    @utf8.decode(wire.unwrap()),
    content="HTTP/1.1 501 \r\nConnection: close\r\n\r\n",
  )
}
```

h11 also limits how many bytes it will buffer while waiting for a complete
request/response head (`max_incomplete_event_size`, default 16 KiB);
exceeding it raises `RemoteProtocolError` with a 431 hint.

## Coming from Python h11

| Python | MoonBit |
| --- | --- |
| `h11.Connection(our_role=h11.CLIENT)` | `@h11.Connection::new(Client)` |
| `conn.next_event()` → event, `h11.NEED_DATA`, `h11.PAUSED` | `conn.next_event()` → `Event(e)`, `NeedData`, `Paused` |
| `conn.send(event)` → `bytes` or `None` | `conn.send(event)` → `Some(bytes)` or `None` |
| `conn.states`, `conn.our_state`, `conn.their_state` | `conn.states()`, `conn.our_state()`, `conn.their_state()` |
| `conn.their_http_version`, `conn.trailing_data` | `conn.their_http_version()`, `conn.trailing_data()` |
| `h11.Request(method=..., target=..., headers=[...])` | `@h11.Request::new(method_=..., target=..., headers=[...])` |
| `h11.Data(data=b"...")`, `h11.EndOfMessage()` | `@h11.Data::new(b"...")`, `@h11.EndOfMessage::new()` |
| `h11.ConnectionClosed()` | `ConnectionClosed` |
| `h11.CLIENT`, `h11.SEND_BODY`, `h11.MUST_CLOSE`, ... | `Client`, `SendBody`, `MustClose`, ... |
| `except h11.RemoteProtocolError as e: e.error_status_hint` | `catch { RemoteProtocolError(msg, error_status_hint~) => ... }` |

Differences worth knowing:

- All wire values (methods, targets, header names and values, versions) are
  `Bytes`. The request method field is `method_` because `method` is a
  reserved word in MoonBit.
- `Data.data` is always `Bytes`. `send_with_data_passthrough` still
  guarantees that the exact `Bytes` you passed appears in the returned list,
  so you can swap in zero-copy writes.
- `Content-Length` values and chunk sizes are tracked as `Int64`. The same
  inputs as Python are accepted (up to 20 digits); values beyond 2^63 - 1
  saturate, which is unobservable in practice.
- `Data.chunk_start` is `true` on the first data of every chunk. Python h11
  reports `False` when a chunk header and its data arrive in separate reads.
- `receive_data` after EOF raises `RuntimeError` (a MoonBit `suberror`).
- Error messages quote received data as `b'...'` (Python shows
  `bytearray(b'...')`).

## Development

```bash
moon test
```

The test suite has three layers:

- a port of h11's own tests (`*_test.mbt` for the public API, `*_wbtest.mbt`
  for internals such as the state machine, readers, writers, and receive
  buffer);
- QuickCheck properties (`quickcheck_test.mbt`): round trips, fragmentation
  invariance on valid, mutated, and garbage input, and robustness;
- a differential fuzzer (`fuzz/`) that runs random and mutated byte streams
  through both this port and Python h11 and compares the resulting events,
  states, bytes sent, and error messages:

```bash
python3 fuzz/difftest.py --cases 100000 --seed 1
```

  Python h11 is patched in the harness with the same `chunk_start` fix, so
  the comparison is exact; `--unpatched` compares against upstream as is.

Every code block in this README also runs as a test.

## License and credits

MIT. Original h11 by Nathaniel J. Smith and contributors
([python-hyper/h11](https://github.com/python-hyper/h11)); this is an
independent MoonBit port.
