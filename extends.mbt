///|
/// `Show` is the canonical rendering of an h11 error, so `err.to_string()`
/// stays available as a method. Use `ProtocolError::message` for the bare
/// message text.
pub extend ProtocolError with Show::{to_string}

///|
pub extend RuntimeError with Show::{to_string}
