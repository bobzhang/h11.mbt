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
fn state_name(s : @h11.State) -> String {
  s.to_string()
}

///|
fn run_case(role : @h11.Role, chunks : Array[Bytes], out : Array[String]) -> Unit {
  let conn = @h11.Connection::new(role)
  if role is Client {
    let req = try! @h11.Request::new(method_=b"GET", target=b"/", headers=[
      (b"Host", b"x"),
    ])
    ignore(try! conn.send(Request(req)))
    ignore(try! conn.send(EndOfMessage(try! @h11.EndOfMessage::new())))
  }
  // Server only: answer a finished request and start the next cycle.
  let respond = () => {
    if !(role is Server) {
      return false
    }
    let mut progressed = false
    if conn.our_state() is SendResponse &&
      conn.their_state() is (Done | MustClose | Closed | MightSwitchProtocol) {
      let sent = try {
        let resp = @h11.Response::new(status_code=200, headers=[
          (b"Content-Length", b"0"),
        ])
        let a = conn.send(Response(resp)).unwrap()
        a + conn.send(EndOfMessage(@h11.EndOfMessage::new())).unwrap()
      } catch {
        e => {
          out.push("SENDERR \{protocol_message(e)}")
          return false
        }
      }
      out.push("SENT \{hex(sent)}")
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
  out.push("STATES \{state_name(states.client)} \{state_name(states.server)}")
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
    let rest = line[2:]
    let chunks = if rest.is_empty() {
      []
    } else {
      rest.split(",").map(unhex).to_array()
    }
    let out = []
    run_case(role, chunks, out)
    for o in out {
      println(o)
    }
    println("END")
  }
}
