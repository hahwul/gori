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
  # terminating CRLFCRLF. Returns nil on clean EOF before any byte arrives.
  # Raises nothing on a truncated head — returns whatever was read so the
  # caller can still capture it (P7).
  def self.read_head(io : IO, max_bytes : Int32 = 1024 * 64) : Bytes?
    buf = IO::Memory.new
    while buf.bytesize < max_bytes
      byte = io.read_byte
      break if byte.nil? # EOF
      buf.write_byte(byte)
      break if buf.bytesize >= 4 && ends_with_crlf_crlf?(buf)
    end
    return nil if buf.bytesize == 0
    buf.to_slice.dup
  end

  private def self.ends_with_crlf_crlf?(buf : IO::Memory) : Bool
    s = buf.to_slice
    n = s.size
    s[n - 4] == 0x0d_u8 && s[n - 3] == 0x0a_u8 && s[n - 2] == 0x0d_u8 && s[n - 1] == 0x0a_u8
  end

  def self.parse_request_head(raw : Bytes) : RawRequest
    lines = head_lines(raw)
    start = lines[0]? || ""
    parts = start.split(' ')
    malformed = parts.size != 3
    RawRequest.new(
      raw_head: raw,
      method: parts[0]? || "",
      target: parts[1]? || "",
      version: parts[2]? || "",
      headers: parse_headers(lines),
      malformed: malformed,
    )
  end

  def self.parse_response_head(raw : Bytes) : RawResponse
    lines = head_lines(raw)
    start = lines[0]? || ""
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
      headers: parse_headers(lines),
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

  # Split head bytes into lines (best-effort latin1/utf8 projection). The raw
  # bytes remain the truth; this view is only for parsing projections.
  private def self.head_lines(raw : Bytes) : Array(String)
    String.new(raw).split(CRLF)
  end

  private def self.parse_headers(lines : Array(String)) : HeaderList
    list = HeaderList.new
    # lines[0] is the start-line; headers follow until the first empty line.
    lines.each_with_index do |line, idx|
      next if idx == 0
      break if line.empty? # end of headers
      colon = line.index(':')
      next unless colon # malformed header line: skip projection, raw_head keeps it
      name = line[0...colon]
      value = line[(colon + 1)..].strip
      list << Header.new(name, value)
    end
    list
  end
end
