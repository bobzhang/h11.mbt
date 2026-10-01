///|
test "basic request/response round trip" {
  let p = ConnectionPair::new()
  let wire = p.send(Client, [
    req(b"GET", b"/", [(b"Host", b"example.com")]),
    eom(),
  ])
  inspect(
    @utf8.decode(wire),
    content="GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
  )
  let wire = p.send(Server, [
    resp(200, [(b"Content-Length", b"2")]),
    data(b"hi"),
    eom(),
  ])
  inspect(
    @utf8.decode(wire),
    content="HTTP/1.1 200 \r\nContent-Length: 2\r\n\r\nhi",
  )
  debug_inspect(
    p.client.states(),
    content=(
      #|{ client: Done, server: Done }
    ),
  )
}
