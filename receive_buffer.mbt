// Buffer for received data (port of h11/_receivebuffer.py).
//
// Operations we want to support:
// - find next \r\n or \r\n\r\n (\n or \n\n are also acceptable),
//   or wait until there is one
// - read at-most-N bytes
// Goals:
// - on average, do this fast
// - worst case, do this in O(n) where n is the number of bytes processed
// Plan:
// - store a growable byte array plus a start offset, and how far we've
//   searched for a separator token, to avoid rescanning
// - advance the start offset instead of constantly copying, and compact the
//   storage lazily when appending

///|
priv struct ReceiveBuffer {
  mut data : FixedArray[Byte]
  /// Offset of the first unconsumed byte in `data`.
  mut start : Int
  /// Offset one past the last valid byte in `data`.
  mut end : Int
  /// Relative to `start`: how far `maybe_extract_next_line` has searched.
  mut next_line_search : Int
  /// Relative to `start`: how far `maybe_extract_lines` has searched.
  mut multiple_lines_search : Int
}

///|
fn ReceiveBuffer::new() -> ReceiveBuffer {
  {
    data: FixedArray::make(0, 0),
    start: 0,
    end: 0,
    next_line_search: 0,
    multiple_lines_search: 0,
  }
}

///|
fn ReceiveBuffer::length(self : ReceiveBuffer) -> Int {
  self.end - self.start
}

///|
fn ReceiveBuffer::is_empty(self : ReceiveBuffer) -> Bool {
  self.end == self.start
}

///|
fn ReceiveBuffer::at(self : ReceiveBuffer, i : Int) -> Byte {
  self.data[self.start + i]
}

///|
fn ReceiveBuffer::append(self : ReceiveBuffer, bytes : BytesView) -> Unit {
  let len = self.length()
  let needed = len + bytes.length()
  if needed < 0 {
    abort("receive buffer size overflow")
  }
  // (Compare against the free space rather than computing `end + n`, which
  // could overflow for very large buffers.)
  if bytes.length() > self.data.length() - self.end {
    if needed <= self.data.length() / 2 {
      // At least half the storage is free after compaction, so the bytes
      // moved here are paid for by the bytes consumed since the last
      // compaction: amortized O(1) per byte.
      self.data.blit_to(self.data, len~, src_offset=self.start, dst_offset=0)
    } else {
      // Grow geometrically (relative to what we need, not to the current
      // capacity) so that repeated refills don't copy everything each time.
      let cap = if needed < 32 {
        64
      } else if needed <= @int.MAX_VALUE / 2 {
        needed * 2
      } else {
        needed
      }
      let new_data = FixedArray::make(cap, (0 : Byte))
      self.data.blit_to(new_data, len~, src_offset=self.start, dst_offset=0)
      self.data = new_data
    }
    self.start = 0
    self.end = len
  }
  for b in bytes {
    self.data[self.end] = b
    self.end += 1
  }
}

///|
/// The unprocessed data as an owned byte string.
fn ReceiveBuffer::to_bytes(self : ReceiveBuffer) -> Bytes {
  Bytes::makei(self.length(), i => self.at(i))
}

///|
/// Remove and return the first `count` bytes (`count <= length`).
fn ReceiveBuffer::extract(self : ReceiveBuffer, count : Int) -> Bytes {
  let out = Bytes::makei(count, i => self.at(i))
  self.start += count
  if self.start == self.end {
    self.start = 0
    self.end = 0
  }
  self.next_line_search = 0
  self.multiple_lines_search = 0
  out
}

///|
/// Extract at most `count` bytes from the buffer, or `None` if it's empty.
fn ReceiveBuffer::maybe_extract_at_most(
  self : ReceiveBuffer,
  count : Int64,
) -> Bytes? {
  let len = self.length()
  if len == 0 || count <= 0L {
    return None
  }
  let n = if count < len.to_int64() { count.to_int() } else { len }
  Some(self.extract(n))
}

///|
/// Extract the first line (terminated by \r\n), if it is complete in the
/// buffer. The returned line includes the \r\n.
fn ReceiveBuffer::maybe_extract_next_line(self : ReceiveBuffer) -> Bytes? {
  // Only search in buffer space that we've not already looked at.
  let len = self.length()
  let search_start = if self.next_line_search > 0 {
    self.next_line_search - 1
  } else {
    0
  }
  for i in search_start..<(len - 1) {
    if self.at(i) == b'\r' && self.at(i + 1) == b'\n' {
      // + 2 is to compensate len(b"\r\n")
      return Some(self.extract(i + 2))
    }
  }
  self.next_line_search = len
  None
}

///|
/// Extract everything up to the first blank line, and return the list of
/// lines (with line terminators and the blank line removed). Both \r\n and
/// bare \n are accepted as line terminators.
fn ReceiveBuffer::maybe_extract_lines(self : ReceiveBuffer) -> Array[Bytes]? {
  let len = self.length()
  // Handle the case where we have an immediate empty line.
  if len >= 1 && self.at(0) == b'\n' {
    self.extract(1) |> ignore
    return Some([])
  }
  if len >= 2 && self.at(0) == b'\r' && self.at(1) == b'\n' {
    self.extract(2) |> ignore
    return Some([])
  }
  // Only search in buffer space that we've not already looked at:
  // find the first match of /\n\r?\n/.
  // `head_end` is where the blank line starts, `found` where it ends.
  let mut head_end = -1
  let mut found = -1
  for i in self.multiple_lines_search..<len {
    if self.at(i) == b'\n' {
      if i + 1 < len && self.at(i + 1) == b'\n' {
        head_end = i
        found = i + 2
        break
      }
      if i + 2 < len && self.at(i + 1) == b'\r' && self.at(i + 2) == b'\n' {
        head_end = i
        found = i + 3
        break
      }
    }
  }
  if found < 0 {
    self.multiple_lines_search = if len > 2 { len - 2 } else { 0 }
    return None
  }
  // Truncate the buffer and split everything before the blank line into
  // lines, accepting both \r\n and bare \n as terminators.
  let out = self.extract(found)
  Some(
    split_on(out[:head_end], b'\n').map(line => {
      if line is [.. rest, b'\r'] {
        rest.to_owned()
      } else {
        line.to_owned()
      }
    }),
  )
}

///|
/// A cheap sanity check allowing early abort on garbage: an HTTP request or
/// status line never starts with a non-printable character or a space. This
/// is especially useful when the peer speaks TLS to us, since every TLS
/// handshake starts with a 0x16 byte.
fn ReceiveBuffer::is_next_line_obviously_invalid_request_line(
  self : ReceiveBuffer,
) -> Bool {
  !self.is_empty() && self.at(0) < b'\x21'
}
