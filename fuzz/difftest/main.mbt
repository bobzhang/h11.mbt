// Differential-testing driver: runs the same deterministic script as
// fuzz/difftest.py's `run_case` over a batch of inputs and prints a trace
// per case, so the two implementations can be compared line by line.
//
// Input: one case per line, `<C|S> <hex>,<hex>,...` (role, then the chunks
// to feed to receive_data). Output: trace lines per case, then `END`.

///|
fn hex(b : BytesView) -> String {
  let sb = StringBuilder()
  for x in b {
    sb.write_string(x.to_hex())
  }
  sb.to_string()
}

///|
fn unhex(s : StringView) -> Bytes {
  let digit = (c : UInt16) => {
    let c = c.to_int()
    if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else {
      c - 'a'.to_int() + 10
    }
  }
  Bytes::makei(s.length() / 2, i => {
    (digit(s[2 * i]) * 16 + digit(s[2 * i + 1])).to_byte()
  })
}

///|
fn fmt_headers(h : @h11.Headers) -> String {
  h.raw_items().map(item => "\{hex(item.0)}=\{hex(item.1)}").join(" ")
}

///|
fn fmt_bool(b : Bool) -> String {
  if b {
    "1"
  } else {
    "0"
  }
}

///|
fn fmt_event(e : @h11.Event) -> String {
  match e {
    Request(r) =>
      "REQ \{hex(r.method_)} \{hex(r.target)} \{hex(r.http_version)} \{fmt_headers(r.headers)}"
    InformationalResponse(r) =>
      "INFO \{r.status_code} \{hex(r.http_version)} \{hex(r.reason)} \{fmt_headers(r.headers)}"
    Response(r) =>
      "RESP \{r.status_code} \{hex(r.http_version)} \{hex(r.reason)} \{fmt_headers(r.headers)}"
    Data(d) =>
      "DATA \{hex(d.data)} \{fmt_bool(d.chunk_start)}\{fmt_bool(d.chunk_end)}"
    EndOfMessage(m) => "EOM \{fmt_headers(m.headers)}"
    ConnectionClosed => "CLOSED"
  }
}

///|
/// Events the client sends before reading, per variant (see client_script
/// in difftest.py).
fn client_script(variant : Int) -> Array[@h11.Event] raise {
  let host = (b"Host", b"x")
  match variant {
    1 =>
      [
        Request(@h11.Request::new(method_=b"HEAD", target=b"/", headers=[host])),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    2 =>
      [
        Request(
          @h11.Request::new(method_=b"CONNECT", target=b"x:443", headers=[host]),
        ),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    3 =>
      [
        Request(
          @h11.Request::new(method_=b"GET", target=b"/", headers=[
            host,
            (b"Upgrade", b"websocket"),
            (b"Connection", b"Upgrade"),
          ]),
        ),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    4 =>
      [
        Request(
          @h11.Request::new(method_=b"POST", target=b"/", headers=[
            host,
            (b"Content-Length", b"5"),
          ]),
        ),
        Data(@h11.Data::new(b"hello")),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    5 =>
      // an upload still in progress when the response arrives
      [
        Request(
          @h11.Request::new(method_=b"POST", target=b"/", headers=[
            host,
            (b"Transfer-Encoding", b"chunked"),
            (b"Expect", b"100-continue"),
          ]),
        ),
        Data(@h11.Data::new(b"abc")),
      ]
    _ =>
      [
        Request(@h11.Request::new(method_=b"GET", target=b"/", headers=[host])),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
  }
}

///|
/// Events the server sends in response to a finished request (see
/// server_script in difftest.py).
fn server_script(variant : Int) -> Array[@h11.Event] raise {
  match variant {
    1 =>
      [
        Response(@h11.Response::new(status_code=200, headers=[])),
        Data(@h11.Data::new(b"hi")),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    2 =>
      [
        InformationalResponse(
          @h11.InformationalResponse::new(status_code=101, headers=[
            (b"Upgrade", b"websocket"),
          ]),
        ),
      ]
    3 =>
      [
        InformationalResponse(
          @h11.InformationalResponse::new(status_code=100, headers=[]),
        ),
        Response(
          @h11.Response::new(status_code=200, headers=[
            (b"Content-Length", b"2"),
          ]),
        ),
        Data(@h11.Data::new(b"ok")),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    4 =>
      [
        Response(@h11.Response::new(status_code=204, headers=[])),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    5 =>
      [
        Response(
          @h11.Response::new(status_code=404, headers=[
            (b"Connection", b"close"),
            (b"Content-Length", b"0"),
          ]),
        ),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
    _ =>
      [
        Response(
          @h11.Response::new(status_code=200, headers=[
            (b"Content-Length", b"0"),
          ]),
        ),
        EndOfMessage(@h11.EndOfMessage::new()),
      ]
  }
}

///|
/// Send events one by one, recording each; stop at the first failure.
fn send_all(
  conn : @h11.Connection,
  events : Array[@h11.Event],
  out : Array[String],
) -> Bool {
  for ev in events {
    let data = conn.send(ev) catch {
      e => {
        out.push("SENDERR \{protocol_message(e)}")
        return false
      }
    }
    out.push(
      match data {
        None => "SENT CLOSE"
        Some(d) => "SENT \{hex(d)}"
      },
    )
  }
  true
}

///|
fn run_case(
  role : @h11.Role,
  variant : Int,
  chunks : Array[Bytes],
  out : Array[String],
) -> Unit {
  let conn = @h11.Connection::new(role)
  if role is Client {
    ignore(send_all(conn, try! client_script(variant), out))
  }
  // Server only: answer a finished request and start the next cycle.
  let respond = () => {
    if !(role is Server) {
      return false
    }
    let mut progressed = false
    if conn.our_state() is SendResponse &&
      conn.their_state() is (Done | MustClose | Closed | MightSwitchProtocol) {
      if !send_all(conn, try! server_script(variant), out) {
        return false
      }
      progressed = true
    }
    if conn.our_state() is Done && conn.their_state() is Done {
      try! conn.start_next_cycle()
      out.push("CYCLE")
      progressed = true
    }
    progressed
  }
  let mut i = 0
  let mut eof = false
  for _ in 0..<200 {
    let event = conn.next_event() catch {
      e => {
        out.push("ERR \{protocol_message(e)}")
        break
      }
    }
    match event {
      NeedData => {
        if i < chunks.length() {
          try! conn.receive_data(chunks[i])
          i += 1
        } else if !eof {
          try! conn.receive_data(b"")
          eof = true
        } else {
          out.push("STUCK")
          break
        }
        continue
      }
      Paused => {
        out.push("PAUSED")
        if !respond() {
          // Deliver what's left (e.g. tunnelled bytes after a protocol
          // switch) so trailing_data gets compared too.
          while i < chunks.length() {
            try! conn.receive_data(chunks[i])
            i += 1
          }
          break
        }
        continue
      }
      Event(e) => {
        out.push(fmt_event(e))
        if e is ConnectionClosed {
          break
        }
        ignore(respond())
      }
    }
  }
  let states = conn.states()
  let (trail, closed) = conn.trailing_data()
  out.push(
    "STATES \{states.client} \{states.server} TRAIL \{hex(trail)} \{fmt_bool(closed)}",
  )
}

///|
fn protocol_message(e : Error) -> String {
  match e {
    @h11.LocalProtocolError(msg, error_status_hint~) =>
      "Local \{error_status_hint} \{msg}"
    @h11.RemoteProtocolError(msg, error_status_hint~) =>
      "Remote \{error_status_hint} \{msg}"
    e => "Other \{e}"
  }
}

///|
fn main {
  let args = @env.args()
  let path = args[args.length() - 1]
  let text = @fs.read_file_to_string(path) catch {
    e => abort("cannot read \{path}: \{Repr(e)}")
  }
  for line in text.split("\n") {
    if line.is_empty() {
      continue
    }
    let role : @h11.Role = if line.has_prefix("C") { Client } else { Server }
    let variant = line.code_unit_at(1).to_int() - '0'.to_int()
    let rest = line[3:]
    let chunks = if rest.is_empty() {
      []
    } else {
      rest.split(",").map(unhex).to_array()
    }
    let out = []
    run_case(role, variant, chunks, out)
    for o in out {
      println(o)
    }
    println("END")
  }
}
