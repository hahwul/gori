module Gori::Fuzz
  # Recomputes a request's Content-Length to match its actual body length after a
  # payload was substituted into the body. Burp's "update Content-Length" option,
  # default on.
  #
  # Deliberately NOT the TUI's repeater_view#sync_content_length: that one round-trips
  # the WHOLE request through `String` (corrupting non-UTF-8 body bytes) and only
  # touches an existing header. This rewrites ONLY the head and splices the body slice
  # back byte-exact, so a binary payload survives. h1 and h2 are handled identically —
  # for h2 the header simply needs to agree with the DATA frames H2Engine emits.
  #
  # Runs on EVERY dispatched request (the dispatcher fiber is a single-threaded
  # serialization point), so the head is scanned at the BYTE level: the common GET /
  # no-Content-Length shape returns the input untouched with zero allocation, and the
  # rewrite path never materializes a head String or a per-line Array. The output is
  # byte-for-byte identical to the old split/rejoin implementation.
  module ContentLength
    CL_CANON = "Content-Length: " # canonical header prefix the rewrite emits

    # Returns `bytes` with its `Content-Length` header set to the real body length.
    # No-ops when: there's no head/body boundary (a bare request), the body is
    # `Transfer-Encoding: chunked` (CL is unused — chunk re-framing is out of scope),
    # or the header is absent and `add_when_missing` is false (keeps GETs clean).
    def self.sync(bytes : Bytes, add_when_missing : Bool = false) : Bytes
      sep, sep_w, eol = boundary(bytes)
      return bytes if sep.nil?

      body_start = sep + sep_w
      body_len = bytes.size - body_start
      cl = find_cl_line(bytes, sep, eol) # {line_start, line_end} of the CL header, or nil

      if cl.nil?
        # No Content-Length header. Both the "leave GETs clean" default and a chunked
        # request return the input unchanged, so we never build a head String or run the
        # chunked scan on this (dominant) path — only when actually adding a header.
        return bytes unless add_when_missing && body_len > 0
        return bytes if chunked?(bytes, sep, eol)
        return append_cl(bytes, sep, body_start, body_len, eol)
      end

      # CL present: a chunked request keeps its (unused) header verbatim (out of scope).
      return bytes if chunked?(bytes, sep, eol)
      ls, le = cl
      # Skip the rebuild when the line is already exactly the canonical form we'd emit —
      # same early-out as the old `lines[idx] == "Content-Length: #{body_len}"` guard.
      canon = "#{CL_CANON}#{body_len}"
      return bytes if line_eq?(bytes, ls, le, canon)
      replace_cl(bytes, ls, le, sep, body_start, body_len, eol, canon)
    end

    # ── head scanning (byte level, no String/Array allocation) ────────────────────

    # Byte range `{line_start, line_end}` of the Content-Length header line within the
    # head `[0, sep)`, or nil when absent. `line_end` is the index of the terminating
    # `eol` (or `sep` for the last header line). Header lines split on `eol`; the name is
    # matched case-insensitively with leading/trailing ASCII whitespace stripped and a
    # colon required past the line start — 1:1 with the old `header_name?`.
    private def self.find_cl_line(bytes : Bytes, sep : Int32, eol : String) : {Int32, Int32}?
      a = 0
      while a < sep
        le = line_end(bytes, a, sep, eol)
        return {a, le} if cl_line?(bytes, a, le)
        a = le >= sep ? sep : le + eol.bytesize
      end
      nil
    end

    # Index of the `eol` sequence starting at or after `a` (bounded by `sep`), or `sep`
    # when the line runs to the head boundary. Splits on the SAME `eol` the boundary
    # picked, so a bare LF inside a CRLF head stays part of one line (as split(eol) did).
    private def self.line_end(bytes : Bytes, a : Int32, sep : Int32, eol : String) : Int32
      if eol.bytesize == 2 # "\r\n"
        i = a
        while i + 1 < sep
          return i if bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8
          i += 1
        end
        sep
      else # "\n"
        i = a
        while i < sep
          return i if bytes[i] == 0x0a_u8
          i += 1
        end
        sep
      end
    end

    # True when the line `[a, le)` is the `content-length` header (case-insensitive,
    # ignoring surrounding ASCII whitespace, colon required past the line start).
    private def self.cl_line?(bytes : Bytes, a : Int32, le : Int32) : Bool
      colon = colon_of(bytes, a, le)
      return false unless colon > a
      ns, ne = trim_range(bytes, a, colon)
      name_eq_ci?(bytes, ns, ne, "content-length")
    end

    # Index of the first `:` in `[a, e)`, or -1 when absent.
    private def self.colon_of(bytes : Bytes, a : Int32, e : Int32) : Int32
      i = a
      while i < e
        return i if bytes[i] == 0x3a_u8 # ':'
        i += 1
      end
      -1
    end

    # `[a, e)` with leading/trailing ASCII whitespace removed (mirrors String#strip).
    private def self.trim_range(bytes : Bytes, a : Int32, e : Int32) : {Int32, Int32}
      s = a
      t = e
      while s < t && ws?(bytes[s])
        s += 1
      end
      while t > s && ws?(bytes[t - 1])
        t -= 1
      end
      {s, t}
    end

    # Case-insensitive ASCII compare of `bytes[s, e)` to `name` (already lowercase).
    private def self.name_eq_ci?(bytes : Bytes, s : Int32, e : Int32, name : String) : Bool
      return false unless e - s == name.bytesize
      k = 0
      while k < name.bytesize
        b = bytes[s + k]
        b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8 # A-Z → a-z
        return false unless b == name.to_unsafe[k]
        k += 1
      end
      true
    end

    # True when the head line `[ls, le)` equals `canon` byte-for-byte.
    private def self.line_eq?(bytes : Bytes, ls : Int32, le : Int32, canon : String) : Bool
      return false unless le - ls == canon.bytesize
      k = 0
      while k < canon.bytesize
        return false unless bytes[ls + k] == canon.to_unsafe[k]
        k += 1
      end
      true
    end

    private def self.ws?(b : UInt8) : Bool
      b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8 || b == 0x0b_u8 || b == 0x0c_u8
    end

    # ── rebuild (only when the value actually changes) ────────────────────────────

    # Replace the CL header line in place with the canonical form, keeping every other
    # head byte and the body slice exact. Equivalent to the old split/replace/rejoin.
    private def self.replace_cl(bytes : Bytes, ls : Int32, le : Int32, sep : Int32,
                                body_start : Int32, body_len : Int32, eol : String, canon : String) : Bytes
      io = IO::Memory.new(bytes.size + 16)
      io.write(bytes[0, ls])        # head up to the CL line
      io << canon                   # canonical "Content-Length: N"
      io.write(bytes[le, sep - le]) # the CL line's eol through the rest of the head
      io << eol << eol
      io.write(bytes[body_start, body_len]) if body_len > 0
      io.to_slice
    end

    # Append a fresh CL header line to a head that lacks one.
    private def self.append_cl(bytes : Bytes, sep : Int32, body_start : Int32,
                               body_len : Int32, eol : String) : Bytes
      io = IO::Memory.new(bytes.size + 32)
      io.write(bytes[0, sep])
      io << eol << CL_CANON << body_len
      io << eol << eol
      io.write(bytes[body_start, body_len]) if body_len > 0
      io.to_slice
    end

    # ── boundary + chunked ────────────────────────────────────────────────────────

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

    # True when the final transfer-coding is `chunked` (RFC 7230 §3.3.1) — mirrors
    # ContentDecode's strict check, not a loose substring scan. Tokenizes the head on
    # LF (NOT the boundary `eol`): a CRLF head can still carry a bare-LF-separated
    # header (a smuggling/desync vector the fuzzer deliberately crafts), and an
    # LF-lenient backend reads those as distinct lines — so chunked detection must split
    # them the same way, even though the byte-exact rewrite above splits on `eol` to
    # preserve the wire form. Scans the head bytes `[0, sep)` directly (no head String).
    private def self.chunked?(bytes : Bytes, sep : Int32, eol : String) : Bool
      a = 0
      while a < sep
        nl = a
        while nl < sep && bytes[nl] != 0x0a_u8
          nl += 1
        end
        # Line content is [a, e) with any trailing CR chomped (each_line + chomp).
        e = nl
        e -= 1 if e > a && bytes[e - 1] == 0x0d_u8
        break if e == a # blank line ends the head
        if te = transfer_encoding_last(bytes, a, e)
          return te == "chunked"
        end
        a = nl + 1
      end
      false
    end

    # For the header line `[a, e)`, when it is `Transfer-Encoding`, return the last
    # comma-separated coding (stripped, lowercased) — else nil. Mirrors the old
    # `line[(colon+1)..].split(',').map(&.strip.downcase).reject(&.empty?).last?`.
    private def self.transfer_encoding_last(bytes : Bytes, a : Int32, e : Int32) : String?
      colon = colon_of(bytes, a, e)
      return nil unless colon > a
      ns, ne = trim_range(bytes, a, colon)
      return nil unless name_eq_ci?(bytes, ns, ne, "transfer-encoding")
      last_ci_token(bytes, colon + 1, e)
    end

    # The last non-empty comma-separated token of `[from, to)`, stripped + lowercased,
    # or nil when every token is blank.
    private def self.last_ci_token(bytes : Bytes, from : Int32, to : Int32) : String?
      last : String? = nil
      ts = from
      while ts < to
        te = ts
        while te < to && bytes[te] != 0x2c_u8 # ','
          te += 1
        end
        cs, ce = trim_range(bytes, ts, te)
        last = String.new(bytes[cs, ce - cs]).downcase if ce > cs
        ts = te + 1
      end
      last
    end
  end
end
