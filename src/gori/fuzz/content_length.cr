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
      sync_at(bytes, add_when_missing)[0]
    end

    # `sync`, plus WHERE it edited and by how much: `{bytes, at, delta}`, where every byte
    # offset `>= at` in the input has moved by `delta` in the output. `{bytes, 0, 0}` on
    # every no-op path.
    #
    # A caller holding offsets INTO the pre-sync bytes — `Fuzz::Generator`, which knows each
    # payload's span — cannot re-derive them afterwards, because this rewrite happens between
    # the splice and the socket and can change the head's length. Returning the edit instead
    # of the whole mapping keeps the (dominant) untouched-request path allocation-free.
    def self.sync_at(bytes : Bytes, add_when_missing : Bool = false) : {Bytes, Int32, Int32}
      sep, sep_w, eol = boundary(bytes)
      return {bytes, 0, 0} if sep.nil?

      body_start = sep + sep_w
      body_len = bytes.size - body_start
      cl = find_cl_line(bytes, sep) # {line_start, content_end} of the CL header, or nil

      if cl.nil?
        # No Content-Length header. Both the "leave GETs clean" default and a chunked
        # request return the input unchanged, so we never build a head String or run the
        # chunked scan on this (dominant) path — only when actually adding a header.
        return {bytes, 0, 0} unless add_when_missing && body_len > 0
        return {bytes, 0, 0} if chunked?(bytes, sep, eol)
        # The insertion goes in at `sep`, so everything from the head/body separator on has
        # moved by the line it added (its own eol + name + digits).
        return {append_cl(bytes, sep, sep_w, body_start, body_len, eol), sep,
                eol.bytesize + CL_CANON.bytesize + body_len.to_s.bytesize}
      end

      # CL present: a chunked request keeps its (unused) header verbatim (out of scope).
      return {bytes, 0, 0} if chunked?(bytes, sep, eol)
      ls, le = cl
      # Skip the rebuild when the line is already exactly the canonical form we'd emit —
      # same early-out as the old `lines[idx] == "Content-Length: #{body_len}"` guard.
      canon = "#{CL_CANON}#{body_len}"
      return {bytes, 0, 0} if line_eq?(bytes, ls, le, canon)
      # `[ls, le)` is replaced by `canon`, so `le` onwards moves. Offsets INSIDE the old line
      # have no image in the output at all — a payload spliced into the Content-Length VALUE
      # is what this pass overwrites, and the caller is told the region ends at `le`.
      {replace_cl(bytes, ls, le, sep, sep_w, body_start, body_len, canon), le,
       canon.bytesize - (le - ls)}
    end

    # ── head scanning (byte level, no String/Array allocation) ────────────────────

    # Byte range `{line_start, content_end}` of the Content-Length header line within the
    # head `[0, sep)`, or nil when absent. `content_end` is the START of the line's terminator
    # (or `sep` for the last header line, whose terminator is the blank-line separator). The
    # name is matched case-insensitively with leading/trailing ASCII whitespace stripped and a
    # colon required past the line start — 1:1 with the old `header_name?`.
    #
    # Head lines are tokenized on LF (0x0A) then a trailing CR is chomped — the SAME rule as
    # `chunked?` below, NOT a split on the boundary `eol`. A CRLF head can still carry a
    # bare-LF-terminated header (a smuggling/desync vector the fuzzer deliberately crafts), and
    # an LF-lenient backend reads that as its own line — so a bare-LF-hidden SECOND
    # `Content-Length` must become its own line here too. That is the whole point: only the
    # FIRST `Content-Length` is bounded (and rewritten), and the hidden one is left byte-intact,
    # matching the already-correct CRLF-visible-duplicate case. Splitting on `eol` (CRLF-only)
    # would instead swallow the bare LF, merge the two headers into one "line", and silently
    # delete the hidden one on rewrite — corrupting the very primitive under test.
    private def self.find_cl_line(bytes : Bytes, sep : Int32) : {Int32, Int32}?
      a = 0
      while a < sep
        nl = a
        while nl < sep && bytes[nl] != 0x0a_u8
          nl += 1
        end
        # `[a, e)` is the line content with any trailing CR chomped; `e` also marks the START of
        # the terminator (CR+LF, a bare LF, or the head boundary when no LF is found), so
        # `replace_cl` can splice `[e, …)` — the terminator plus every following byte — verbatim.
        e = nl
        e -= 1 if e > a && bytes[e - 1] == 0x0d_u8
        return {a, e} if cl_line?(bytes, a, e)
        a = nl + 1 # resume just past the LF (or past `sep`, ending the loop, when none was found)
      end
      nil
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

    # Replace the CL header line in place with the canonical form, keeping every other head
    # byte and the body slice exact. The blank-line separator is spliced back VERBATIM
    # (`bytes[sep, sep_w]`) rather than rebuilt from a doubled `eol`: a mixed `\n\r\n` separator
    # (last header line ended in a bare LF, blank line was CRLF) is not a repeated `eol`, so
    # doubling `eol` would silently rewrite the operator's separator bytes.
    private def self.replace_cl(bytes : Bytes, ls : Int32, le : Int32, sep : Int32, sep_w : Int32,
                                body_start : Int32, body_len : Int32, canon : String) : Bytes
      io = IO::Memory.new(bytes.size + 16)
      io.write(bytes[0, ls])        # head up to the CL line
      io << canon                   # canonical "Content-Length: N"
      io.write(bytes[le, sep - le]) # the CL line's terminator through the rest of the head
      io.write(bytes[sep, sep_w])   # the blank-line separator, verbatim (may be mixed `\n\r\n`)
      io.write(bytes[body_start, body_len]) if body_len > 0
      io.to_slice
    end

    # Append a fresh CL header line to a head that lacks one. `eol` terminates the prior last
    # header line; the separator is then spliced VERBATIM (`bytes[sep, sep_w]`) — for a mixed
    # `\n\r\n` separator its leading byte is the new CL line's own (bare-LF) terminator, so the
    # operator's blank-line spelling survives the insert. `sync_at`'s append `delta`
    # (`eol.bytesize + CL_CANON + digits`) still holds: only that prefix is inserted at `sep`.
    private def self.append_cl(bytes : Bytes, sep : Int32, sep_w : Int32, body_start : Int32,
                               body_len : Int32, eol : String) : Bytes
      io = IO::Memory.new(bytes.size + 32)
      io.write(bytes[0, sep])           # head, up to the blank-line separator
      io << eol << CL_CANON << body_len # terminate the prior header line, then the new CL line
      io.write(bytes[sep, sep_w])       # blank-line separator, verbatim (its lead byte(s) terminate the new line)
      io.write(bytes[body_start, body_len]) if body_len > 0
      io.to_slice
    end

    # ── boundary + chunked ────────────────────────────────────────────────────────

    # Locate the head/body separator = the FIRST blank line. Returns its start index
    # (nil if none), its full byte WIDTH, and the terminator of the header line that
    # PRECEDES the blank line. Three spellings are recognized:
    #   LFLF `\n\n` (width 2, prior eol `\n`), CRLFCRLF `\r\n\r\n` (width 4, prior eol `\r\n`),
    #   and the mixed `\n\r\n` (width 3, prior eol `\n`) — the last header line ended in a bare
    #   LF and the blank line itself was CRLF. `\r\n\n` needs no branch: it is already caught as
    #   LFLF one byte in (the leading CR stays in the head, matching the old behavior).
    # For the mixed spelling the separator is NOT a repeated `eol`, so callers splice
    # `bytes[start, width]` VERBATIM instead of doubling `eol` (see replace_cl / append_cl);
    # `eol` is retained only as the prior line's terminator (all `append_cl` needs).
    # A single left-to-right scan (not "all CRLFCRLF, then all LFLF") matters when the head is
    # LF-terminated but the BODY contains a CRLFCRLF: scanning all CRLFCRLF first would find the
    # body's and split at the wrong place. A well-formed CRLF head has no LFLF/`\n\r\n` inside
    # it, so this is unchanged for normal CRLF messages; the earliest match wins because every
    # spelling is tested at the same `i` and the leftmost hit is returned first.
    private def self.boundary(bytes : Bytes) : {Int32?, Int32, String}
      i = 0
      while i + 1 < bytes.size
        return {i, 2, "\n"} if bytes[i] == 0x0a_u8 && bytes[i + 1] == 0x0a_u8 # LFLF
        if i + 2 < bytes.size && bytes[i] == 0x0a_u8 &&
           bytes[i + 1] == 0x0d_u8 && bytes[i + 2] == 0x0a_u8 # mixed `\n\r\n` (bare-LF header + CRLF blank)
          return {i, 3, "\n"}
        end
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
