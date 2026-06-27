module Gori::Fuzz
  # Recomputes a request's Content-Length to match its actual body length after a
  # payload was substituted into the body. Burp's "update Content-Length" option,
  # default on.
  #
  # Deliberately NOT the TUI's replay_view#sync_content_length: that one round-trips
  # the WHOLE request through `String` (corrupting non-UTF-8 body bytes) and only
  # touches an existing header. This rewrites ONLY the head and splices the body slice
  # back byte-exact, so a binary payload survives. h1 and h2 are handled identically —
  # for h2 the header simply needs to agree with the DATA frames H2Engine emits.
  module ContentLength
    # Returns `bytes` with its `Content-Length` header set to the real body length.
    # No-ops when: there's no head/body boundary (a bare request), the body is
    # `Transfer-Encoding: chunked` (CL is unused — chunk re-framing is out of scope),
    # or the header is absent and `add_when_missing` is false (keeps GETs clean).
    def self.sync(bytes : Bytes, add_when_missing : Bool = false) : Bytes
      sep, sep_w, eol = boundary(bytes)
      return bytes if sep.nil?

      body_start = sep + sep_w
      body_len = bytes.size - body_start
      head = String.new(bytes[0, sep])
      return bytes if chunked?(head)

      lines = head.split(eol)
      idx = lines.index { |l| header_name?(l, "content-length") }
      if idx
        return bytes if lines[idx] == "Content-Length: #{body_len}" # already correct
        lines[idx] = "Content-Length: #{body_len}"
      elsif add_when_missing && body_len > 0
        lines << "Content-Length: #{body_len}"
      else
        return bytes
      end

      io = IO::Memory.new(bytes.size + 16)
      io << lines.join(eol) << eol << eol
      io.write(bytes[body_start, body_len]) if body_len > 0
      io.to_slice
    end

    # Locate the head/body separator = the FIRST blank line, whether CRLFCRLF or
    # LFLF. Returns its start index (nil if none), width, and line ending. A single
    # left-to-right scan (not "all CRLFCRLF, then all LFLF") matters when the head is
    # LF-terminated but the BODY contains a CRLFCRLF: scanning all CRLFCRLF first would
    # find the body's and split at the wrong place. A well-formed CRLF head has no
    # LFLF inside it, so this is unchanged for normal CRLF messages.
    private def self.boundary(bytes : Bytes) : {Int32?, Int32, String}
      i = 0
      while i + 1 < bytes.size
        return {i, 2, "\n"} if bytes[i] == 0x0a_u8 && bytes[i + 1] == 0x0a_u8 # LFLF
        if i + 3 < bytes.size && bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 &&
           bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8 # CRLFCRLF
          return {i, 4, "\r\n"}
        end
        i += 1
      end
      {nil, 0, "\r\n"}
    end

    # True when `line` is the named header (case-insensitive, ignoring leading space).
    private def self.header_name?(line : String, name : String) : Bool
      colon = line.index(':')
      return false unless colon && colon > 0
      line[0...colon].strip.downcase == name
    end

    # True when the final transfer-coding is `chunked` (RFC 7230 §3.3.1) — mirrors
    # ContentDecode's strict check, not a loose substring scan.
    private def self.chunked?(head : String) : Bool
      head.each_line do |raw|
        line = raw.chomp
        break if line.empty?
        next unless (colon = line.index(':')) && colon > 0
        next unless line[0...colon].strip.downcase == "transfer-encoding"
        last = line[(colon + 1)..].split(',').map(&.strip.downcase).reject(&.empty?).last?
        return last == "chunked"
      end
      false
    end
  end
end
