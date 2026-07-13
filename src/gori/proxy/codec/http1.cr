require "socket"
require "./message"

# Pure, byte-exact HTTP/1.1 head codec (sans-IO).
#
# `parse_*_head` take the already-delimited head bytes (request-line/status-line
# + headers + CRLFCRLF) and return a message whose `raw_head` *is* the input,
# plus best-effort parsed projections. We never reject malformed input (P7);
# we flag `malformed?` and keep the original octets.
#
# `read_head` is the one IO boundary: it scans an IO byte-by-byte up to and
# including CRLFCRLF. Reading byte-by-byte (served from the socket's read
# buffer) means we stop exactly at the body boundary — there is no "over-read"
# to thread through keep-alive loops or the CONNECT->TLS handoff.
module Gori::Proxy::Codec::Http1
  CRLF      = "\r\n"
  CRLF_CRLF = "\r\n\r\n".to_slice

  # Reads one message head from `io`, returning the exact bytes including the
  # terminating CRLFCRLF. Returns nil on clean EOF before any byte arrives, OR
  # when the head exceeds `max_bytes` without ever reaching CRLFCRLF. Returning a
  # size-capped, un-terminated buffer as if it were a complete head would misframe
  # the body — the rest of the header block (and the real CRLFCRLF) would still be
  # in the socket and get consumed as the body, desyncing keep-alive — so we treat
  # an oversized head as an unusable connection (caller drops it). A head cut short
  # by EOF still returns its bytes (the connection is closing; P7 keeps the octets).
  # `deadline` + `timeout_sock` (both required to arm it) bound the total time to assemble a
  # head AFTER its first byte — the drip-feed slowloris defense a per-read timeout can't provide
  # (a byte-at-a-time trickle keeps resetting a per-read timer). The socket's read_timeout is
  # shrunk toward the deadline before each read and RESTORED on exit, so the body read that
  # follows sees the caller's baseline, not the leftover head budget. With `deadline`/`timeout_sock`
  # nil (every caller but the client request-head read) the loop is byte-for-byte the original.
  def self.read_head(io : IO, max_bytes : Int32 = 1024 * 256, *,
                     deadline : Time::Span? = nil, timeout_sock : ::Socket? = nil) : Bytes?
    # Deadline path only when BOTH are provided (the client request-head read); every other
    # caller takes the byte-for-byte original fast path.
    if (sock = timeout_sock) && (dl = deadline)
      return read_head_deadlined(io, sock, dl, max_bytes)
    end
    buf = IO::Memory.new(512) # presized: covers a typical head without regrowing
    while buf.bytesize < max_bytes
      byte = io.read_byte
      break if byte.nil? # EOF
      buf.write_byte(byte)
      # CRLFCRLF ends in LF, so only a just-written LF can complete the terminator
      # — skip the 4-byte tail compare on every other byte.
      break if byte == 0x0a_u8 && buf.bytesize >= 4 && ends_with_crlf_crlf?(buf)
    end
    finalize_head(buf, max_bytes)
  end

  # As read_head, but bounds the total time to assemble a head AFTER its first byte — the
  # drip-feed slowloris defense a per-read timeout can't provide (a byte-at-a-time trickle keeps
  # resetting a per-read timer). `sock`'s read_timeout is shrunk toward `deadline` before each
  # read and RESTORED on exit, so the body read that follows sees the caller's baseline.
  private def self.read_head_deadlined(io : IO, sock : ::Socket, deadline : Time::Span, max_bytes : Int32) : Bytes?
    buf = IO::Memory.new(512)
    saved_timeout = sock.read_timeout
    head_started = nil.as(Time::Instant?)
    begin
      while buf.bytesize < max_bytes
        if hs = head_started
          remaining = deadline - (Time.instant - hs)
          raise IO::TimeoutError.new("request head incomplete before deadline") if remaining <= Time::Span.zero
          sock.read_timeout = remaining
        end
        byte = io.read_byte
        break if byte.nil?            # EOF
        head_started ||= Time.instant # start the head clock at the first received byte
        buf.write_byte(byte)
        break if byte == 0x0a_u8 && buf.bytesize >= 4 && ends_with_crlf_crlf?(buf)
      end
    ensure
      sock.read_timeout = saved_timeout # restore the baseline for the following body read
    end
    finalize_head(buf, max_bytes)
  end

  # Turn a read head buffer into the returned bytes (or nil). A `buf` that hit the cap without a
  # terminator is an oversized/hostile head — returning it would misframe the body (the real
  # CRLFCRLF is still on the wire), so drop it. Otherwise the view (length = bytesize) is the
  # head's sole owner: it becomes an immutable `raw_head` (P7), so no defensive copy is made.
  private def self.finalize_head(buf : IO::Memory, max_bytes : Int32) : Bytes?
    return nil if buf.bytesize == 0
    return nil if buf.bytesize >= max_bytes && !ends_with_crlf_crlf?(buf)
    buf.to_slice
  end

  private def self.ends_with_crlf_crlf?(buf : IO::Memory) : Bool
    s = buf.to_slice
    n = s.size
    s[n - 4] == 0x0d_u8 && s[n - 3] == 0x0a_u8 && s[n - 2] == 0x0d_u8 && s[n - 1] == 0x0a_u8
  end

  def self.parse_request_head(raw : Bytes) : RawRequest
    first_crlf = index_crlf(raw, 0)
    start = String.new(raw[0, first_crlf || raw.size])
    parts = start.split(' ')
    malformed = parts.size != 3
    RawRequest.new(
      raw_head: raw,
      method: parts[0]? || "",
      target: parts[1]? || "",
      version: parts[2]? || "",
      headers: parse_headers(raw, first_crlf),
      malformed: malformed,
    )
  end

  def self.parse_response_head(raw : Bytes) : RawResponse
    first_crlf = index_crlf(raw, 0)
    start = String.new(raw[0, first_crlf || raw.size])
    # status-line: HTTP-version SP status-code SP [reason]
    first_sp = start.index(' ')
    version = first_sp ? start[0...first_sp] : ""
    rest = first_sp ? start[(first_sp + 1)..] : ""
    second_sp = rest.index(' ')
    code_str = second_sp ? rest[0...second_sp] : rest
    reason = second_sp ? rest[(second_sp + 1)..] : ""
    status = code_str.to_i?(strict: false) || 0
    malformed = version.empty? || status == 0
    RawResponse.new(
      raw_head: raw,
      version: version,
      status: status,
      reason: reason,
      headers: parse_headers(raw, first_crlf),
      malformed: malformed,
    )
  end

  # Forwarding/serialization is byte-exact: emit the captured head as-is (P7).
  def self.serialize_head(req : RawRequest) : Bytes
    req.raw_head
  end

  def self.serialize_head(resp : RawResponse) : Bytes
    resp.raw_head
  end

  # Index of the CRLF at or after `from`, or nil if none. Scans the raw bytes so
  # the parser never materializes the whole head as a String (P7: raw is truth).
  private def self.index_crlf(raw : Bytes, from : Int32) : Int32?
    i = from
    limit = raw.size - 1
    while i < limit
      return i if raw.unsafe_fetch(i) == 0x0d_u8 && raw.unsafe_fetch(i + 1) == 0x0a_u8
      i += 1
    end
    nil
  end

  # Parse header lines by scanning the raw bytes in place, starting at the
  # start-line's terminating CRLF (`start_crlf`; nil when the head has no CRLF).
  # Only the header name/value Strings are allocated — no whole-head String and
  # no per-line String array (see codec_bench). Byte-for-byte equivalent to the
  # old `String.new(raw).split(CRLF)` projection: name is bytes-before-colon
  # (unstripped), value is bytes-after-colon stripped; an empty line ends headers;
  # a colon-less line is skipped (raw_head still keeps it).
  # RFC 7230 §3.2.4: a field-name must be followed IMMEDIATELY by ':' with NO
  # whitespace, and obs-fold (a header line beginning with SP/HTAB) is obsolete and
  # forbidden in a request. Either form hides a header from parse_headers (whose name
  # match is exact) while a whitespace-lenient backend still reads it — so `Transfer-
  # Encoding : chunked` or an obs-folded TE slips past gori's CL/TE framing checks and
  # smuggles a request past the proxy. Return true when the header block contains
  # whitespace before a colon or an obs-fold continuation line, so the caller can reject
  # the message (record + close) exactly like the other ambiguous-framing vectors.
  #
  # A bare LF (0x0a not immediately preceded by 0x0d) used as an in-head line terminator
  # is the same class of vector: the CRLF-only index_crlf/parse_headers scan misses the
  # header after it (folding it into the previous value), yet an LF-lenient backend
  # (RFC 7230 §3.5) still reads it — a hidden Transfer-Encoding/Content-Length. read_head
  # only ever returns a head ending in CRLFCRLF, so a well-formed head has every LF
  # CR-preceded; reject any that doesn't.
  def self.obfuscated_header?(raw : Bytes) : Bool
    i = 0
    while i < raw.size
      return true if raw.unsafe_fetch(i) == 0x0a_u8 && (i == 0 || raw.unsafe_fetch(i - 1) != 0x0d_u8)
      i += 1
    end
    start_crlf = index_crlf(raw, 0)
    return false if start_crlf.nil?
    pos = start_crlf + 2 # first byte after the start-line's CRLF
    while pos < raw.size
      crlf = index_crlf(raw, pos)
      line_end = crlf || raw.size
      break if line_end == pos # empty line → end of headers
      first = raw.unsafe_fetch(pos)
      return true if first == 0x20_u8 || first == 0x09_u8 # obs-fold continuation line
      # Whitespace between field-name and colon: the byte just before the first ':' is SP/HTAB.
      i = pos
      while i < line_end && raw.unsafe_fetch(i) != 0x3a_u8 # ':'
        i += 1
      end
      if i < line_end && i > pos
        prev = raw.unsafe_fetch(i - 1)
        return true if prev == 0x20_u8 || prev == 0x09_u8
      end
      break if crlf.nil?
      pos = crlf + 2
    end
    false
  end

  private def self.parse_headers(raw : Bytes, start_crlf : Int32?) : HeaderList
    list = HeaderList.new
    return list if start_crlf.nil? # no CRLF → no header block
    pos = start_crlf + 2           # first byte after the start-line's CRLF
    while pos < raw.size
      crlf = index_crlf(raw, pos)
      line_end = crlf || raw.size
      break if line_end == pos # empty line → end of headers
      line = raw[pos, line_end - pos]
      if colon = line.index(0x3a_u8) # ':'
        name = String.new(line[0, colon])
        value = String.new(line[colon + 1, line.size - colon - 1]).strip
        list << Header.new(name, value)
      end
      break if crlf.nil? # last line, no trailing CRLF
      pos = crlf + 2
    end
    list
  end
end
