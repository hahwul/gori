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

  # The RFC 7540 §3.4 HTTP/2 client connection preface's request-line. When ALPN doesn't
  # negotiate h2 — e.g. Gori::Interceptor/Tunnel#intercept's deliberate h2→h1 ALPN downgrade
  # while Intercept/Sandbox/Match&Replace is active — an h2/gRPC client's preface bytes land on
  # this HTTP/1.1 parser instead of a real HTTP/2 stack. Its request-line happens to be
  # well-formed HTTP/1.1 SHAPE (exactly 3 space-separated tokens), so without this check it
  # parses cleanly as an ordinary (if odd-looking) request — method "PRI", target "*" — and
  # sails straight through: forwarded to an origin, or (Intercept catch mode) HELD forever with
  # nothing indicating it's actually an h2 client, not an HTTP/1.1 one. This exact literal is
  # what every RFC 7540-conformant client sends first, unambiguously — treat it as malformed so
  # callers can reject the connection cleanly instead of accepting a fake request.
  H2_PREFACE_LINE = "PRI * HTTP/2.0"

  def self.parse_request_head(raw : Bytes) : RawRequest
    first_crlf = index_crlf(raw, 0)
    start = String.new(raw[0, first_crlf || raw.size])
    parts = start.split(' ')
    malformed = parts.size != 3 || start == H2_PREFACE_LINE
    RawRequest.new(
      raw_head: raw,
      method: parts[0]? || "",
      target: parts[1]? || "",
      version: parts[2]? || "",
      headers: parse_headers(raw, first_crlf),
      malformed: malformed,
    )
  end

  # {method, target, version} of a HAND-AUTHORED head, tolerating a BARE-LF terminator.
  #
  # Deliberately NOT folded into `parse_request_head`: that parser's strict-CRLF scan is
  # load-bearing security machinery, not an oversight. `Body.framing_ambiguous?` detects a
  # response desync precisely by comparing this strict parse against what a LENIENT recipient
  # would read, and Fuzz's redirect guard refuses a `Location` whose bare LF splices a second
  # request. Both collapse the moment the shared parser learns to accept a bare LF — making
  # it lenient turned three of those specs red, which is how this split earned its keep.
  #
  # The record/replay side has the opposite need. A bare LF there is the OPERATOR'S payload
  # (`verbatim`), and the strict scan then finds either a CRLF inside the body or none at
  # all, so History filed `http_version` as `"HTTP/1.1\nHost:"` for a request whose bytes it
  # was holding byte-exact. This is an evidence projection only — nothing framed off it.
  def self.authored_start_line(raw : Bytes) : {String, String, String}
    i = 0
    n = raw.size
    eol = n
    while i < n
      b = raw.unsafe_fetch(i)
      if b == 0x0a_u8 || (b == 0x0d_u8 && i + 1 < n && raw.unsafe_fetch(i + 1) == 0x0a_u8)
        eol = i
        break
      end
      i += 1
    end
    parts = String.new(raw[0, eol]).split(' ')
    {parts[0]? || "", parts[1]? || "", parts[2]? || ""}
  end

  # True when `req`'s start-line is EXACTLY the HTTP/2 client preface (H2_PREFACE_LINE) — the
  # well-known, unambiguous signal that this connection is an h2/gRPC client, not HTTP/1.1, so a
  # caller (ClientConn) can reject it outright instead of treating it as a real request.
  def self.h2_preface?(req : RawRequest) : Bool
    req.method == "PRI" && req.target == "*" && req.version == "HTTP/2.0"
  end

  # The request start-line's {method, target, malformed} WITHOUT parsing/allocating the header
  # block. Mirrors parse_request_head's start-line parse EXACTLY (same index_crlf + String.new
  # over the first line + split(' ') + `parts.size != 3 || start == H2_PREFACE_LINE` malformed
  # rule), so a caller that only needs method+target (the active-probe dedup_key gate) keys
  # byte-identically to a full parse. The dedup_key ⇔ plan equivalence spec guards against any
  # drift from parse_request_head.
  def self.parse_request_line(raw : Bytes) : {String, String, Bool}
    first_crlf = index_crlf(raw, 0)
    start = String.new(raw[0, first_crlf || raw.size])
    parts = start.split(' ')
    {parts[0]? || "", parts[1]? || "", parts.size != 3 || start == H2_PREFACE_LINE}
  end

  # The request-target the SCOPE GATE reads — NOT what goes on the wire.
  #
  # `parse_request_head`'s strict `split(' ')` is right for the forwarding path and must stay:
  # it feeds `resolve_forward`/`rewrite_request_line`, whose `version` is `parts[2]`, so making
  # the parse lenient would rebuild a doubled-space `GET  http://x/y HTTP/1.1` as
  # `GET /y http://x/y` — gori corrupting the operator's bytes (P7). But the same strictness
  # hands the GATE a target of `""` (doubled space / leading blank line) or of `"HTTP/1.1"`
  # (a tab between method and target), and an origin that collapses whitespace still reads the
  # real path. That gap is a Sandbox/scope BYPASS: with `include host:acme.test` +
  # `exclude string:/admin` and Sandbox on, `GET  /admin HTTP/1.1` evaluated as
  # `http://acme.test` misses the exclude and reaches the origin, while `GET /admin HTTP/1.1`
  # is 403'd. Verified end-to-end against 0.2.0.
  #
  # `Outbound` fixed exactly this on the gori-originated side (#491); this is the same
  # predicate's ONE home, which `Outbound.request_target` now delegates to rather than
  # re-deriving next to its own caller (the shape AGENTS.md flags as thrice-recurring).
  # The bytes still reach the wire byte-exact — only what the gate READS changes.
  #
  # Recovery is skipped on the common path: a well-formed line's `target` is returned as-is,
  # so the gate stays allocation-free (P6).
  def self.gate_target(req : RawRequest) : String
    return req.target unless req.malformed? || req.target.empty?
    request_target_line(String.new(req.raw_head))
  end

  # Read the request-TARGET off the request line — but from the first NON-BLANK line, not
  # blindly the first line. A raw request may arrive with LEADING BLANK LINE(S) (an operator's
  # authored bytes, or a peer that emits an empty line before the request-line, which RFC 9112
  # §2.2 tells a recipient to ignore); reading the first line blindly then gates the innocuous
  # "/" while the REAL target sits on a later line and goes on the wire.
  #
  # The no-arg `split` collapses whitespace RUNS and drops empty parts, so a doubled space or a
  # tab recovers the real target; a line with no target (or an all-blank input) degrades to "/".
  # Bytes is the real implementation and String delegates, because the callers on the active
  # send path hold `Bytes` — and `String.new(bytes)` there copied the WHOLE message (head and
  # body both) on every send, for a 50 KB POST a 50 KB copy per request, to read one line.
  # `String#to_slice` is an O(1) view of the string's own bytes, so the delegation is free.
  #
  # Only the CANDIDATE LINE becomes a String, never the message. That is deliberate rather
  # than a byte-level re-implementation of the tokenizer: `strip` and the no-arg `split` are
  # Unicode-aware (U+00A0 and friends count as whitespace), so an ASCII-only byte scan would
  # answer differently for a request line carrying one — and this feeds the SCOPE GATE, where
  # a divergence is a bypass, not a rounding error. Building one line per blank prefix costs
  # nothing: real input has zero or one. `spec/outbound_spec.cr` pins the two overloads
  # against each other over a hostile corpus for exactly this reason.
  def self.request_target_line(raw : Bytes) : String
    pos = 0
    size = raw.size
    while pos < size
      nl = raw.index(0x0a_u8, pos)
      stop = nl || size
      # The line excludes the LF and keeps a trailing CR. `String#each_line` chomps `\r\n`,
      # so the two differ there — harmlessly, because both `strip` (the blank test) and the
      # no-arg `split` (the tokenizer) treat that CR as whitespace either way. The corpus in
      # spec/outbound_spec.cr covers the CR-bearing shapes for exactly this reason.
      line = String.new(raw[pos, stop - pos])
      return line.split[1]? || "/" unless line.strip.empty?
      break unless nl
      pos = nl + 1
    end
    "/"
  end

  def self.request_target_line(text : String) : String
    request_target_line(text.to_slice)
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

  # Whether `s` may be written onto a request line as ONE space-delimited token — the
  # method, the request target, or an authority. False for any octet at or below SP
  # (0x20, which covers SP, HTAB, CR, LF and NUL) and for DEL (0x7F).
  #
  # A request line is `METHOD SP target SP version`, so a single SP inside any of the three
  # forges it: `GET /a b HTTP/1.1` reads to a lenient origin as target `/a` and version `b`,
  # and gori then records a request it did not send. CR or LF is the worse half of the same
  # class — it terminates the line and splices a second, fully attacker-chosen request onto
  # the connection.
  #
  # This is the one home for that rule. gori has now hit the same shape in three subsystems
  # (#390 a crawled `<a href>` in Discover, #394 a raw space in the same, #397 a redirect
  # `Location` in the fuzzer), each time because the rule was written next to one caller and
  # the next subsystem did not know it existed. It lives with the HTTP/1 framing predicates
  # because that is what it is, and because every engine and every surface already depends on
  # this codec — `Fuzz::Engine`'s redirect follower and the MCP request builder's
  # `reject_token_breakers` both call it, and `Discover::Headers.safe_url?` (CR/LF only today)
  # is the third caller once #394 settles whether Discover encodes or refuses.
  #
  # It does NOT apply to bytes an operator handed gori to replay: those go out verbatim,
  # malformed or not (P7). It applies where gori SYNTHESIZES a request line out of text that
  # a remote chose.
  def self.request_token_safe?(s : String) : Bool
    # Bytes, not chars: the multi-byte UTF-8 continuation octets are all >= 0x80, so this is
    # identical to the char-wise test on valid input and correct on invalid input too.
    s.each_byte { |b| return false if b <= 0x20_u8 || b == 0x7f_u8 }
    true
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
  #
  # A bare CR (0x0d NOT immediately followed by 0x0a) is the mirror image and is rejected
  # for the same reason: index_crlf/parse_headers only ever break a line on the 2-byte
  # CRLF, so a lone CR is just another byte inside the current field-value and everything
  # after it — up to the next real CRLF — is swallowed into that value. A recipient that
  # treats a lone CR as end-of-line (they exist; CR is not a legal field-vchar, so parsers
  # differ on what to do with one) reads the smuggled `Transfer-Encoding: chunked` sitting
  # after it. CR is never valid inside a field-value (RFC 7230 §3.2.6 field-vchar is
  # VCHAR/obs-text), so this can't false-positive on conformant traffic. A CR as the very
  # last byte counts as bare: a genuine head always ends CRLFCRLF, never a dangling CR.
  def self.obfuscated_header?(raw : Bytes) : Bool
    return true if bare_cr_or_lf?(raw)
    start_crlf = index_crlf(raw, 0)
    return false if start_crlf.nil?
    pos = start_crlf + 2 # first byte after the start-line's CRLF
    while pos < raw.size
      crlf = index_crlf(raw, pos)
      line_end = crlf || raw.size
      break if line_end == pos # empty line → end of headers
      first = raw.unsafe_fetch(pos)
      return true if first == 0x20_u8 || first == 0x09_u8 # obs-fold continuation line
      return true if space_before_colon?(raw, pos, line_end)
      break if crlf.nil?
      pos = crlf + 2
    end
    false
  end

  # Whitespace between field-name and colon on the header line spanning [pos, line_end):
  # the byte just before the first ':' is SP/HTAB (`Transfer-Encoding : chunked`), which the
  # exact-match framing lookups cannot see but a lenient backend still reads.
  private def self.space_before_colon?(raw : Bytes, pos : Int32, line_end : Int32) : Bool
    i = pos
    while i < line_end && raw.unsafe_fetch(i) != 0x3a_u8 # ':'
      i += 1
    end
    return false unless i < line_end && i > pos
    prev = raw.unsafe_fetch(i - 1)
    prev == 0x20_u8 || prev == 0x09_u8
  end

  # Any LF not immediately preceded by CR, or CR not immediately followed by LF — either
  # one lets a recipient that ends a line on it see a header this CRLF-only codec cannot
  # (see obfuscated_header?, whose contract this implements).
  private def self.bare_cr_or_lf?(raw : Bytes) : Bool
    i = 0
    while i < raw.size
      b = raw.unsafe_fetch(i)
      if b == 0x0a_u8
        return true if i == 0 || raw.unsafe_fetch(i - 1) != 0x0d_u8
      elsif b == 0x0d_u8
        return true if i + 1 >= raw.size || raw.unsafe_fetch(i + 1) != 0x0a_u8
      end
      i += 1
    end
    false
  end

  # The only header names body framing ever reads (see Body.request_framing /
  # Body.response_framing). Obfuscation that cannot change one of these cannot move the
  # body boundary, so it cannot desync anyone. Lowercase, for the stripped-name compare.
  FRAMING_NAMES = {"content-length", "transfer-encoding"}

  # True when a LENIENT recipient would read DIFFERENT body-framing headers out of `raw`
  # than gori's strict CRLF-only parse did (`headers`, i.e. what parse_headers produced).
  #
  # This is the RESPONSE-side counterpart to obfuscated_header?, and it is deliberately
  # narrower. request_framing rejects on ANY obfuscation because a request's peer is the
  # operator's own browser, which never emits one — so a blunt rule costs nothing. A
  # RESPONSE's peer is the whole internet, and the sloppy-but-harmless origins that emit a
  # bare LF or an obs-fold on some unrelated header (embedded devices, legacy CGI) are
  # exactly the systems a pentester points gori at. Refusing those outright would break the
  # target's pages and read as "gori is broken". So: reject only when the ambiguity actually
  # lands on Content-Length / Transfer-Encoding, and let everything else through byte-exact.
  #
  # obfuscated_header? is the cheap gate — a clean CRLF head can hide nothing, so the common
  # path is one byte scan and no allocation at all; only a head that already looks odd pays
  # for the two views.
  def self.framing_ambiguous?(raw : Bytes, headers : HeaderList) : Bool
    return false unless obfuscated_header?(raw)
    strict_framing_view(headers) != lenient_framing_view(raw)
  end

  # The framing headers as gori's STRICT parse sees them, "name:value" in wire order.
  # parse_headers keeps the field-name UNSTRIPPED, so `Transfer-Encoding : chunked` arrives
  # here named "transfer-encoding " and correctly fails to match FRAMING_NAMES — that
  # blindness is precisely what this view is measuring.
  private def self.strict_framing_view(headers : HeaderList) : Array(String)
    view = [] of String
    headers.each do |h|
      name = h.name.downcase
      view << "#{name}:#{h.value}" if FRAMING_NAMES.includes?(name)
    end
    view
  end

  # The framing headers as a LENIENT recipient would see them, in the same "name:value"
  # shape so the two views compare directly: a line ends at CR, LF *or* CRLF (not only
  # CRLF); a line starting with SP/HTAB is an obs-fold continuation appended to the
  # previous field-value; and the field-name is stripped before it is matched.
  private def self.lenient_framing_view(raw : Bytes) : Array(String)
    view = [] of String
    pos = lenient_next_line(raw, lenient_line_end(raw, 0)) # skip the start-line
    folds_into = -1                                        # index in `view` an obs-fold continuation would extend, or -1
    while pos < raw.size
      stop = lenient_line_end(raw, pos)
      break if stop == pos # empty line → end of headers
      line = raw[pos, stop - pos]
      first = line.unsafe_fetch(0)
      if first == 0x20_u8 || first == 0x09_u8 # obs-fold: continues the previous field-value
        view[folds_into] = "#{view[folds_into]} #{String.new(line).strip}" if folds_into >= 0
      elsif (kv = lenient_header(line)) && FRAMING_NAMES.includes?(kv[0])
        view << "#{kv[0]}:#{kv[1]}"
        folds_into = view.size - 1
      else
        folds_into = -1
      end
      pos = lenient_next_line(raw, stop)
    end
    view
  end

  # Index of the first CR or LF at/after `pos` (i.e. where a lenient recipient ends the
  # line), or raw.size when the line runs to the end of the buffer.
  private def self.lenient_line_end(raw : Bytes, pos : Int32) : Int32
    i = pos
    while i < raw.size
      b = raw.unsafe_fetch(i)
      break if b == 0x0d_u8 || b == 0x0a_u8
      i += 1
    end
    i
  end

  # Start of the next line, stepping over the terminator at `stop`. CRLF counts as ONE
  # terminator; a lone CR and a lone LF each end a line on their own.
  private def self.lenient_next_line(raw : Bytes, stop : Int32) : Int32
    return stop if stop >= raw.size
    crlf = raw.unsafe_fetch(stop) == 0x0d_u8 && stop + 1 < raw.size && raw.unsafe_fetch(stop + 1) == 0x0a_u8
    stop + (crlf ? 2 : 1)
  end

  # {stripped+downcased field-name, stripped field-value} of one header line, or nil when
  # the line carries no colon (a lenient recipient has no header to read out of it either).
  private def self.lenient_header(line : Bytes) : {String, String}?
    colon = line.index(0x3a_u8) # ':'
    return nil unless colon
    {String.new(line[0, colon]).strip.downcase,
     String.new(line[colon + 1, line.size - colon - 1]).strip}
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
