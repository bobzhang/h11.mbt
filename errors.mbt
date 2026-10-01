///|
/// Exception indicating a violation of the HTTP/1.1 protocol.
///
/// - `LocalProtocolError` indicates that *you* tried to do something that
///   HTTP/1.1 says is illegal (raised by `Connection::send` and the event
///   constructors).
/// - `RemoteProtocolError` indicates that the remote peer tried to do
///   something that HTTP/1.1 says is illegal (raised by
///   `Connection::next_event`).
///
/// `error_status_hint` gives a suggestion as to what status code a server
/// might use if this error occurred as part of a request. The default is
/// 400 Bad Request.
pub(all) suberror ProtocolError {
  LocalProtocolError(String, error_status_hint~ : Int)
  RemoteProtocolError(String, error_status_hint~ : Int)
}

///|
/// Raised when the caller misuses the API in a way that is not an HTTP
/// protocol violation, e.g. feeding more data after signalling EOF.
pub(all) suberror RuntimeError {
  RuntimeError(String)
}

///|
/// The human readable message carried by this error.
pub fn ProtocolError::message(self : ProtocolError) -> String {
  match self {
    LocalProtocolError(msg, ..) | RemoteProtocolError(msg, ..) => msg
  }
}

///|
/// The suggested HTTP status code for responding to this error.
pub fn ProtocolError::error_status_hint(self : ProtocolError) -> Int {
  match self {
    LocalProtocolError(_, error_status_hint~)
    | RemoteProtocolError(_, error_status_hint~) => error_status_hint
  }
}

///|
/// Whether this is a `LocalProtocolError`.
pub fn ProtocolError::is_local(self : ProtocolError) -> Bool {
  self is LocalProtocolError(_, ..)
}

///|
/// Whether this is a `RemoteProtocolError`.
pub fn ProtocolError::is_remote(self : ProtocolError) -> Bool {
  self is RemoteProtocolError(_, ..)
}

///|
pub impl Show for ProtocolError with fn output(self, logger) {
  match self {
    LocalProtocolError(msg, error_status_hint~) =>
      logger.write_string(
        "LocalProtocolError(\{repr(msg)}, error_status_hint=\{error_status_hint})",
      )
    RemoteProtocolError(msg, error_status_hint~) =>
      logger.write_string(
        "RemoteProtocolError(\{repr(msg)}, error_status_hint=\{error_status_hint})",
      )
  }
}

///|
pub impl Show for RuntimeError with fn output(self, logger) {
  match self {
    RuntimeError(msg) => logger.write_string("RuntimeError(\{repr(msg)})")
  }
}

///|
/// Internally we always raise `LocalProtocolError`; `next_event` translates
/// it into a `RemoteProtocolError`.
fn local_error(msg : String, error_status_hint? : Int = 400) -> ProtocolError {
  LocalProtocolError(msg, error_status_hint~)
}
