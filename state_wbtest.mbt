// Port of h11/tests/test_state.py.

///|
fn st(client : State, server : State) -> States {
  { client, server, }
}

///|
fn expect_state_error(f : () -> Unit raise ProtocolError) -> Unit raise {
  try f() catch {
    LocalProtocolError(_, ..) => ()
    e => fail("expected LocalProtocolError, got \{e}")
  } noraise {
    _ => fail("expected LocalProtocolError")
  }
}

///|
test "ConnectionState" {
  let cs = ConnectionState::new()

  // Basic event-triggered transitions
  assert_eq(cs.states, st(Idle, Idle))
  cs.process_event(Client, Request)
  // The SERVER-Request special case:
  assert_eq(cs.states, st(SendBody, SendResponse))

  // Illegal transitions raise an error and nothing happens
  expect_state_error(() => cs.process_event(Client, Request))
  assert_eq(cs.states, st(SendBody, SendResponse))
  cs.process_event(Server, InformationalResponse)
  assert_eq(cs.states, st(SendBody, SendResponse))
  cs.process_event(Server, Response)
  assert_eq(cs.states, st(SendBody, SendBody))
  cs.process_event(Client, EndOfMessage)
  cs.process_event(Server, EndOfMessage)
  assert_eq(cs.states, st(Done, Done))

  // State-triggered transition
  cs.process_event(Server, ConnectionClosed)
  assert_eq(cs.states, st(MustClose, Closed))
}

///|
test "ConnectionState keep_alive" {
  // keep_alive = False
  let cs = ConnectionState::new()
  cs.process_event(Client, Request)
  cs.process_keep_alive_disabled()
  cs.process_event(Client, EndOfMessage)
  assert_eq(cs.states, st(MustClose, SendResponse))
  cs.process_event(Server, Response)
  cs.process_event(Server, EndOfMessage)
  assert_eq(cs.states, st(MustClose, MustClose))
}

///|
test "ConnectionState keep_alive in DONE" {
  // Check that if keep_alive is disabled when the CLIENT is already in DONE,
  // then this is sufficient to immediately trigger the DONE -> MUST_CLOSE
  // transition
  let cs = ConnectionState::new()
  cs.process_event(Client, Request)
  cs.process_event(Client, EndOfMessage)
  assert_eq(cs.states.client, Done)
  cs.process_keep_alive_disabled()
  assert_eq(cs.states.client, MustClose)
}

///|
test "ConnectionState switch denied" {
  for switch_type in [SwitchConnect, SwitchUpgrade] {
    for deny_early in [true, false] {
      let cs = ConnectionState::new()
      cs.process_client_switch_proposal(switch_type)
      cs.process_event(Client, Request)
      cs.process_event(Client, Data)
      assert_eq(cs.states, st(SendBody, SendResponse))
      assert_true(cs.pending_switch_proposals.contains(switch_type))
      if deny_early {
        // before client reaches DONE
        cs.process_event(Server, Response)
        assert_true(cs.pending_switch_proposals.is_empty())
      }
      cs.process_event(Client, EndOfMessage)
      if deny_early {
        assert_eq(cs.states, st(Done, SendBody))
      } else {
        assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))
        cs.process_event(Server, InformationalResponse)
        assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))
        cs.process_event(Server, Response)
        assert_eq(cs.states, st(Done, SendBody))
        assert_true(cs.pending_switch_proposals.is_empty())
      }
    }
  }
}

///|
fn response_type_for_switch(switch_event : SwitchType?) -> EventType {
  match switch_event {
    Some(SwitchUpgrade) => InformationalResponse
    Some(SwitchConnect) | None => Response
  }
}

///|
test "ConnectionState protocol switch accepted" {
  for switch_event in [SwitchUpgrade, SwitchConnect] {
    let cs = ConnectionState::new()
    cs.process_client_switch_proposal(switch_event)
    cs.process_event(Client, Request)
    cs.process_event(Client, Data)
    assert_eq(cs.states, st(SendBody, SendResponse))
    cs.process_event(Client, EndOfMessage)
    assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))
    cs.process_event(Server, InformationalResponse)
    assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))
    cs.process_event(
      Server,
      response_type_for_switch(Some(switch_event)),
      server_switch_event=switch_event,
    )
    assert_eq(cs.states, st(SwitchedProtocol, SwitchedProtocol))
  }
}

///|
test "ConnectionState double protocol switch" {
  // CONNECT + Upgrade is legal! Very silly, but legal. So we support it.
  // Because sometimes doing the silly thing is easier than not.
  for server_switch in [None, Some(SwitchUpgrade), Some(SwitchConnect)] {
    let cs = ConnectionState::new()
    cs.process_client_switch_proposal(SwitchUpgrade)
    cs.process_client_switch_proposal(SwitchConnect)
    cs.process_event(Client, Request)
    cs.process_event(Client, EndOfMessage)
    assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))
    cs.process_event(
      Server,
      response_type_for_switch(server_switch),
      server_switch_event?=server_switch,
    )
    if server_switch is None {
      assert_eq(cs.states, st(Done, SendBody))
    } else {
      assert_eq(cs.states, st(SwitchedProtocol, SwitchedProtocol))
    }
  }
}

///|
test "ConnectionState inconsistent protocol switch" {
  let cases : Array[(Array[SwitchType], SwitchType)] = [
    ([], SwitchConnect),
    ([], SwitchUpgrade),
    ([SwitchUpgrade], SwitchConnect),
    ([SwitchConnect], SwitchUpgrade),
  ]
  for case in cases {
    let (client_switches, server_switch) = case
    let cs = ConnectionState::new()
    for client_switch in client_switches {
      cs.process_client_switch_proposal(client_switch)
    }
    cs.process_event(Client, Request)
    expect_state_error(() => {
      cs.process_event(Server, Response, server_switch_event=server_switch)
    })
  }
}

///|
test "ConnectionState keepalive protocol switch interaction" {
  // keep_alive=False + pending_switch_proposals
  let cs = ConnectionState::new()
  cs.process_client_switch_proposal(SwitchUpgrade)
  cs.process_event(Client, Request)
  cs.process_keep_alive_disabled()
  cs.process_event(Client, Data)
  assert_eq(cs.states, st(SendBody, SendResponse))

  // the protocol switch "wins"
  cs.process_event(Client, EndOfMessage)
  assert_eq(cs.states, st(MightSwitchProtocol, SendResponse))

  // but when the server denies the request, keep_alive comes back into play
  cs.process_event(Server, Response)
  assert_eq(cs.states, st(MustClose, SendBody))
}

///|
test "ConnectionState reuse" {
  let cs = ConnectionState::new()
  expect_state_error(() => cs.start_next_cycle())
  cs.process_event(Client, Request)
  cs.process_event(Client, EndOfMessage)
  expect_state_error(() => cs.start_next_cycle())
  cs.process_event(Server, Response)
  cs.process_event(Server, EndOfMessage)
  cs.start_next_cycle()
  assert_eq(cs.states, st(Idle, Idle))

  // No keepalive
  cs.process_event(Client, Request)
  cs.process_keep_alive_disabled()
  cs.process_event(Client, EndOfMessage)
  cs.process_event(Server, Response)
  cs.process_event(Server, EndOfMessage)
  expect_state_error(() => cs.start_next_cycle())

  // One side closed
  let cs = ConnectionState::new()
  cs.process_event(Client, Request)
  cs.process_event(Client, EndOfMessage)
  cs.process_event(Client, ConnectionClosed)
  cs.process_event(Server, Response)
  cs.process_event(Server, EndOfMessage)
  expect_state_error(() => cs.start_next_cycle())

  // Successful protocol switch
  let cs = ConnectionState::new()
  cs.process_client_switch_proposal(SwitchUpgrade)
  cs.process_event(Client, Request)
  cs.process_event(Client, EndOfMessage)
  cs.process_event(
    Server,
    InformationalResponse,
    server_switch_event=SwitchUpgrade,
  )
  expect_state_error(() => cs.start_next_cycle())

  // Failed protocol switch
  let cs = ConnectionState::new()
  cs.process_client_switch_proposal(SwitchUpgrade)
  cs.process_event(Client, Request)
  cs.process_event(Client, EndOfMessage)
  cs.process_event(Server, Response)
  cs.process_event(Server, EndOfMessage)
  cs.start_next_cycle()
  assert_eq(cs.states, st(Idle, Idle))
}

///|
test "server request is illegal" {
  // There used to be a bug in how we handled the Request special case that
  // made this allowed...
  let cs = ConnectionState::new()
  expect_state_error(() => cs.process_event(Server, Request))
}

///|
test "error message for illegal transition" {
  let cs = ConnectionState::new()
  try cs.process_event(Client, Data) catch {
    e =>
      inspect(
        e.message(),
        content=(
          #|can't handle event type Data when role=CLIENT and state=IDLE
        ),
      )
  } noraise {
    _ => fail("expected error")
  }
}
