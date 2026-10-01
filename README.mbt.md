# h11 for MoonBit

A MoonBit port of [h11](https://github.com/python-hyper/h11), a pure,
bring-your-own-I/O implementation of HTTP/1.1.

h11 contains no networking code at all. You feed it the bytes you receive and
it gives you back high-level events (`Request`, `Response`, `Data`,
`EndOfMessage`, ...). You hand it events and it gives you back the bytes to
send. It tracks the HTTP/1.1 state machine for both peers, handles framing
(`Content-Length`, chunked encoding, HTTP/1.0 read-until-close), keep-alive,
pipelining, `Expect: 100-continue`, and protocol switching (`Upgrade`,
`CONNECT`).

## Quick example

A client and a server talking to each other in memory:

```mbt check
///|
test "client and server" {
  let client = @h11.Connection::new(Client)
  let server = @h11.Connection::new(Server)

  // The client sends a request...
  let request = @h11.Request::new(method=b"GET", target=b"/", headers=[
    (b"Host", b"example.com"),
  ])
  let wire = client.send(Request(request)).unwrap()
  let wire = wire + client.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()

  // ...and the server parses it.
  server.receive_data(wire)
  guard server.next_event() is Event(Request(req)) else { fail("no request") }
  assert_eq(req.target, b"/")
  guard server.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }
  assert_eq(server.next_event(), NeedData) // nothing more buffered yet

  // The server responds with a body of unknown length, so h11 picks
  // chunked encoding for us.
  let response = @h11.Response::new(status_code=200, headers=[
    (b"Content-Type", b"text/plain"),
  ])
  let wire = server.send(Response(response)).unwrap()
  inspect(
    @utf8.decode(wire),
    content="HTTP/1.1 200 \r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n",
  )
  let wire = wire + server.send(Data(@h11.Data::new(b"hello"))).unwrap()
  let wire = wire + server.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()

  // The client reads the response.
  client.receive_data(wire)
  guard client.next_event() is Event(Response(resp)) else {
    fail("no response")
  }
  assert_eq(resp.status_code, 200)
  guard client.next_event() is Event(Data(d)) else { fail("no data") }
  assert_eq(d.data, b"hello")
  guard client.next_event() is Event(EndOfMessage(_)) else { fail("no EOM") }

  // Both sides are done; the connection can be reused.
  assert_eq(client.states(), { client: Done, server: Done, })
  client.start_next_cycle()
  server.start_next_cycle()
  assert_eq(server.our_state(), Idle)
}
```

## API overview

| Python h11 | MoonBit |
| --- | --- |
| `h11.Connection(our_role=h11.CLIENT)` | `@h11.Connection::new(Client)` |
| `conn.receive_data(data)` (`b""` = EOF) | `conn.receive_data(data)` (`b""` = EOF) |
| `conn.next_event()` → event / `NEED_DATA` / `PAUSED` | `conn.next_event()` → `Event(event)` / `NeedData` / `Paused` |
| `conn.send(event)` → `bytes` / `None` | `conn.send(event)` → `Some(bytes)` / `None` (for `ConnectionClosed`) |
| `conn.send_with_data_passthrough(event)` | `conn.send_with_data_passthrough(event)` |
| `conn.send_failed()` | `conn.send_failed()` |
| `conn.start_next_cycle()` | `conn.start_next_cycle()` |
| `conn.states`, `conn.our_state`, `conn.their_state` | `conn.states()`, `conn.our_state()`, `conn.their_state()` |
| `conn.their_http_version` | `conn.their_http_version()` |
| `conn.trailing_data` | `conn.trailing_data()` |
| `conn.client_is_waiting_for_100_continue` | `conn.client_is_waiting_for_100_continue()` |
| `h11.Request(method=..., target=..., headers=[...])` | `@h11.Request::new(method=..., target=..., headers=[...])` |
| `h11.Response`, `h11.InformationalResponse` | `@h11.Response::new(...)`, `@h11.InformationalResponse::new(...)` |
| `h11.Data(data=...)`, `h11.EndOfMessage(headers=...)` | `@h11.Data::new(...)`, `@h11.EndOfMessage::new(headers=...)` |
| `h11.ConnectionClosed()` | `ConnectionClosed` |
| `h11.CLIENT`, `h11.IDLE`, `h11.SEND_BODY`, ... | `Client`, `Idle`, `SendBody`, ... |
| `h11.LocalProtocolError`, `h11.RemoteProtocolError` | `@h11.LocalProtocolError(msg, error_status_hint~)`, `@h11.RemoteProtocolError(...)` (constructors of `ProtocolError`) |

Events are values of the `Event` enum wrapping validated structs; the
constructors (`Request::new` etc.) raise `LocalProtocolError` on invalid
input, exactly like their Python counterparts. Header names and values,
methods, targets, and versions are `Bytes`.

## Differences from Python h11

- Header values and other wire fields are `Bytes` only; Python's automatic
  conversion of ASCII `str` is not needed.
- `Data.data` is always `Bytes` (Python allows arbitrary objects for
  `sendfile`-style passthrough). `send_with_data_passthrough` still
  guarantees the exact `Bytes` you passed appear in the returned list.
- `Content-Length` values and chunk sizes are tracked as `Int64`. The same
  inputs as Python are accepted (up to 20 digits); values beyond 2^63 - 1
  saturate, which is unobservable in practice.
- `receive_data` after EOF raises `RuntimeError` (a MoonBit `suberror`).
- Python's `ValueError` for an invalid role and `TypeError`s for wrongly
  typed arguments are impossible in MoonBit and have no counterpart.

## Development

The original Python repository is cloned in `.repos/h11` for reference. The
test suite is a port of h11's own tests:

```bash
moon test
```
