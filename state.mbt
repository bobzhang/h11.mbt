// The core state machine (port of h11/_state.py).
//
// Rule 1: everything that affects the state machine and state transitions
// must live here. As much as possible goes into the table-based
// representation, but for the bits that don't quite fit, the actual code and
// state must nonetheless live here.
//
// Rule 2: this file does not know about what role we're playing; it only
// knows about HTTP request/response cycles in the abstract.
//
// There are really 5 state machines here:
//
// 1) the client state, 2) the server state, 3) the keep-alive state
// ({true, false}), 4) the SWITCH_CONNECT state and 5) the SWITCH_UPGRADE
// state. (1)-(3) are stored explicitly; (4) and (5) are stored implicitly in
// `pending_switch_proposals`.
//
// Each machine has event-triggered transitions (some event happens) and
// state-triggered transitions (a joint configuration of states is reached,
// e.g. client DONE + keep-alive false => client MUST_CLOSE). The only
// conflict between state-triggered transitions (DONE -> MIGHT_SWITCH_PROTOCOL
// versus DONE -> MUST_CLOSE) is resolved in favour of the protocol switch.

///|
/// The two roles in an HTTP conversation.
pub(all) enum Role {
  Client
  Server
} derive(Eq, Hash, Debug)

///|
pub impl Show for Role with fn output(self, logger) {
  logger.write_string(
    match self {
      Client => "CLIENT"
      Server => "SERVER"
    },
  )
}

///|
/// The other role.
pub fn Role::other(self : Role) -> Role {
  match self {
    Client => Server
    Server => Client
  }
}

///|
/// The states of the client and server state machines. See the h11
/// documentation for the full diagrams.
pub(all) enum State {
  Idle
  SendResponse
  SendBody
  Done
  MustClose
  Closed
  MightSwitchProtocol
  SwitchedProtocol
  Error
} derive(Eq, Hash, Debug)

///|
pub impl Show for State with fn output(self, logger) {
  logger.write_string(
    match self {
      Idle => "IDLE"
      SendResponse => "SEND_RESPONSE"
      SendBody => "SEND_BODY"
      Done => "DONE"
      MustClose => "MUST_CLOSE"
      Closed => "CLOSED"
      MightSwitchProtocol => "MIGHT_SWITCH_PROTOCOL"
      SwitchedProtocol => "SWITCHED_PROTOCOL"
      Error => "ERROR"
    },
  )
}

///|
/// The joint state of both parties.
pub(all) struct States {
  client : State
  server : State
} derive(Eq, Hash, Debug)

///|
/// The state of `role`.
#alias("_[_]")
pub fn States::get(self : States, role : Role) -> State {
  match role {
    Client => self.client
    Server => self.server
  }
}

///|
pub impl Show for States with fn output(self, logger) {
  logger.write_string("{CLIENT: \{self.client}, SERVER: \{self.server}}")
}

///|
/// The kinds of protocol switch a client can propose.
priv enum SwitchType {
  SwitchUpgrade
  SwitchConnect
} derive(Eq)

///|
/// Keys of the event-triggered transition table.
priv enum TransitionKey {
  Plain(EventType)
  /// The server machine sees the client's `Request` event in this form.
  ClientRequest
  /// A server event annotated with an accepted protocol switch.
  Switch(EventType, SwitchType)
}

///|
/// EVENT_TRIGGERED_TRANSITIONS from the Python version.
fn event_triggered_transition(
  role : Role,
  state : State,
  key : TransitionKey,
) -> State? {
  match (role, state, key) {
    // Client
    (Client, Idle, Plain(Request)) => Some(SendBody)
    (Client, Idle, Plain(ConnectionClosed)) => Some(Closed)
    (Client, SendBody, Plain(Data)) => Some(SendBody)
    (Client, SendBody, Plain(EndOfMessage)) => Some(Done)
    (Client, Done | MustClose | Closed, Plain(ConnectionClosed)) => Some(Closed)
    // Server
    (Server, Idle, Plain(ConnectionClosed)) => Some(Closed)
    (Server, Idle, Plain(Response)) => Some(SendBody)
    (Server, Idle, ClientRequest) => Some(SendResponse)
    (Server, SendResponse, Plain(InformationalResponse)) => Some(SendResponse)
    (Server, SendResponse, Plain(Response)) => Some(SendBody)
    (Server, SendResponse, Switch(InformationalResponse, SwitchUpgrade)) =>
      Some(SwitchedProtocol)
    (Server, SendResponse, Switch(Response, SwitchConnect)) =>
      Some(SwitchedProtocol)
    (Server, SendBody, Plain(Data)) => Some(SendBody)
    (Server, SendBody, Plain(EndOfMessage)) => Some(Done)
    (Server, Done | MustClose | Closed, Plain(ConnectionClosed)) => Some(Closed)
    _ => None
  }
}

///|
/// STATE_TRIGGERED_TRANSITIONS from the Python version:
/// (client state, server state) -> new states.
fn state_triggered_transition(client : State, server : State) -> States? {
  match (client, server) {
    // Protocol negotiation
    (MightSwitchProtocol, SwitchedProtocol) =>
      Some({ client: SwitchedProtocol, server, })
    // Socket shutdown
    (Closed, Done) | (Closed, Idle) | (Error, Done) =>
      Some({ client, server: MustClose, })
    (Done, Closed) | (Idle, Closed) | (Done, Error) =>
      Some({ client: MustClose, server, })
    _ => None
  }
}

///|
priv struct ConnectionState {
  /// If this is false then it enables the automatic DONE -> MUST_CLOSE
  /// transition. Don't set this directly; call `process_keep_alive_disabled`.
  mut keep_alive : Bool
  /// Subset of {SwitchUpgrade, SwitchConnect}: the protocol switches the
  /// client proposed.
  mut pending_switch_proposals : Array[SwitchType]
  mut states : States
}

///|
fn ConnectionState::new() -> ConnectionState {
  {
    keep_alive: true,
    pending_switch_proposals: [],
    states: { client: Idle, server: Idle, },
  }
}

///|
fn ConnectionState::set_state(
  self : ConnectionState,
  role : Role,
  state : State,
) -> Unit {
  self.states = match role {
    Client => { ..self.states, client: state, }
    Server => { ..self.states, server: state, }
  }
}

///|
fn ConnectionState::process_error(self : ConnectionState, role : Role) -> Unit {
  self.set_state(role, Error)
  self.fire_state_triggered_transitions()
}

///|
fn ConnectionState::process_keep_alive_disabled(self : ConnectionState) -> Unit {
  self.keep_alive = false
  self.fire_state_triggered_transitions()
}

///|
fn ConnectionState::process_client_switch_proposal(
  self : ConnectionState,
  switch_event : SwitchType,
) -> Unit {
  if !self.pending_switch_proposals.contains(switch_event) {
    self.pending_switch_proposals.push(switch_event)
  }
  self.fire_state_triggered_transitions()
}

///|
fn ConnectionState::process_event(
  self : ConnectionState,
  role : Role,
  event_type : EventType,
  server_switch_event? : SwitchType,
) -> Unit raise ProtocolError {
  let key = match server_switch_event {
    // Only server rows of the transition table accept `Switch` keys, so a
    // client event with a switch annotation is rejected below.
    Some(switch_event) => {
      if !self.pending_switch_proposals.contains(switch_event) {
        raise local_error(
          "Received server _SWITCH_UPGRADE event without a pending proposal",
        )
      }
      Switch(event_type, switch_event)
    }
    None => {
      if event_type is Response {
        self.pending_switch_proposals = []
      }
      Plain(event_type)
    }
  }
  self.fire_event_triggered_transitions(role, key)
  // Special case: the server state does get to see Request events.
  // (A server-sent Request was already rejected by the table above.)
  if key is Plain(Request) && role is Client {
    self.fire_event_triggered_transitions(Server, ClientRequest)
  }
  self.fire_state_triggered_transitions()
}

///|
fn ConnectionState::fire_event_triggered_transitions(
  self : ConnectionState,
  role : Role,
  key : TransitionKey,
) -> Unit raise ProtocolError {
  let state = self.states.get(role)
  guard event_triggered_transition(role, state, key) is Some(new_state) else {
    let event_type = match key {
      Plain(t) | Switch(t, _) => t
      ClientRequest => Request
    }
    raise local_error(
      "can't handle event type \{event_type} when role=\{role} and state=\{state}",
    )
  }
  self.set_state(role, new_state)
}

///|
fn ConnectionState::fire_state_triggered_transitions(
  self : ConnectionState,
) -> Unit {
  // We apply these rules repeatedly until converging on a fixed point
  for ;; {
    let start_states = self.states
    // It could happen that both these special-case transitions are enabled
    // at the same time:
    //
    //    DONE -> MIGHT_SWITCH_PROTOCOL
    //    DONE -> MUST_CLOSE
    //
    // For example, this will always be true of a HTTP/1.0 client requesting
    // CONNECT. If this happens, the protocol switch takes priority. From
    // there the client will either go to SWITCHED_PROTOCOL, in which case
    // it's none of our business when they close the connection, or else the
    // server will deny the request, in which case the client will go back to
    // DONE and then from there to MUST_CLOSE.
    if !self.pending_switch_proposals.is_empty() {
      if self.states.client is Done {
        self.set_state(Client, MightSwitchProtocol)
      }
    }
    if self.pending_switch_proposals.is_empty() {
      if self.states.client is MightSwitchProtocol {
        self.set_state(Client, Done)
      }
    }
    if !self.keep_alive {
      for role in [Client, Server] {
        if self.states.get(role) is Done {
          self.set_state(role, MustClose)
        }
      }
    }
    // Tabular state-triggered transitions
    if state_triggered_transition(self.states.client, self.states.server)
      is Some(changes) {
      self.states = changes
    }
    if self.states == start_states {
      // Fixed point reached
      return
    }
  }
}

///|
fn ConnectionState::start_next_cycle(
  self : ConnectionState,
) -> Unit raise ProtocolError {
  // (DONE/DONE can't be reached with keep-alive disabled or a pending
  // protocol switch, but checking costs nothing and keeps this total.)
  if self.states != { client: Done, server: Done, } ||
    !self.keep_alive ||
    !self.pending_switch_proposals.is_empty() {
    raise local_error("not in a reusable state. self.states=\{self.states}")
  }
  self.states = { client: Idle, server: Idle, }
}
