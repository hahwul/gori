require "uri"
require "../env"
require "../store"
require "../proxy/codec/content_decode"

module Gori
  module Repeater
    # Reconstructs a replayable request from a captured flow — the headless
    # counterpart of the TUI's RepeaterView#load. Unlike the editor (which splits the
    # request into text lines and re-encodes them), this keeps request_head +
    # request_body BYTE-EXACT, rewriting ONLY an absolute-form request line
    # ("GET http://h/p HTTP/1.1" → "GET /p HTTP/1.1") so the bytes can go straight
    # to the origin server. Byte-exactness matters for binary bodies, which a text
    # round-trip would corrupt.
    #
    # The result feeds Repeater::Engine.send / Repeater::H2Engine.send, which take
    # `request, scheme:, host:, port:, verify_upstream:`.
    module FlowRequest
      # `rewrote_request_line` records that `origin_form_bytes` turned an absolute-form
      # request line into origin-form. A surface that reports the send must SAY so: for a
      # proxy capture the absolute form is a proxy artifact and the rewrite is invisible
      # housekeeping, but for a flow gori recorded from a DIRECT send it is the payload
      # (routing / cache-poisoning / SSRF probes are written that way), and a replay that
      # advertises itself as byte-exact must not change the line and stay quiet about it.
      record Built, target : String, bytes : Bytes, http2 : Bool, sni : String?,
        rewrote_request_line : Bool = false

      # A stored head that opens with an HTTP/2 PSEUDO-HEADER cannot be replayed over h1: the
      # h1 `Engine` puts the head on the wire verbatim, so `:method: POST` becomes the start
      # line, every later header is off by one, and an origin that answers anything at all
      # makes gori report a status for a request it never sent. The producer is an h2 FIELD
      # dump recorded as if it were HTTP/1.1 head text. Refusing here is the BACKSTOP; the
      # recording side is where the dump must stop being written.
      class PseudoHeaderHead < Gori::Error
      end

      def self.build(detail : Store::FlowDetail, *, rewrite_absolute_form : Bool = true) : Built
        row = detail.row
        head = detail.request_head
        body = detail.request_body
        refuse_pseudo_header_head(head)
        # The captured body is capped at CAPTURE_MAX. If it was truncated, a faithful
        # h1 repeater would BLOCK the origin waiting for bytes that no longer exist (a
        # Content-Length over-promising, or a chunked stream cut before its 0-chunk). Byte-
        # exactness is already lost at the cap, so re-frame the head to a fixed Content-Length
        # over the bytes we actually send, so the repeater terminates instead of hanging.
        head = resync_truncated_head(head, body.try(&.size) || 0) if detail.request_body_truncated?
        bytes, rewrote = rewrite_absolute_form ? origin_form_bytes(head, body) : {combine(head, body), false}
        Built.new(
          target: build_target(row.scheme, row.host, row.port),
          bytes: bytes,
          http2: detail.http_version == "HTTP/2",
          sni: detail.sni,
          rewrote_request_line: rewrote,
        )
      end

      # Refuse a head that OPENS WITH AN HTTP/2 PSEUDO-HEADER, and nothing else.
      #
      # As narrow as it can be and still catch the field dump, because P7 ("malformed input
      # IS the payload") owns everything else here: an empty head, a head that is not HTTP at
      # all, a two-token HTTP/0.9 line, a doubled space, a raw space inside the target, a
      # NUL — every one of those is somebody's test case and is replayed byte-for-byte (see
      # spec/cli/run/replay_reconstruct_spec.cr). A leading ':' is different in kind: the
      # METHOD is an RFC 9110 §5.6.2 token and ':' is not a tchar, so no request line can
      # begin with one, and the only thing that produces this shape is gori's own h2 field
      # dump. Shipping it is not "sending the operator's bytes" — it is sending a message
      # whose first header gori turned into a start line, and then reporting the status.
      private def self.refuse_pseudo_header_head(head : Bytes) : Nil
        return unless head.size > 0 && head[0] == 0x3A_u8 # ':'
        nl = head.index(0x0A_u8)
        line = String.new(nl ? head[0, nl] : head).rstrip('\r')
        raise PseudoHeaderHead.new(
          "the stored request head starts with an HTTP/2 pseudo-header, not a request line " \
          "(first line: #{line[0, 60].inspect}). It is an h2 field list recorded as HTTP/1.1 head " \
          "text; sending it would put that field on the wire AS the start line and leave every " \
          "later header off by one. Re-send it field-natively (`gori run repeater h2 --fields`).")
      end

      # Make a TRUNCATED request self-framed so the repeater can't hang. Used ONLY when the
      # captured body was capped. Rewrites an existing Content-Length to the stored byte
      # count, OR replaces a Transfer-Encoding (chunked — whose stored wire-form bytes were
      # cut mid-stream) with a Content-Length over those bytes so the origin reads a complete
      # body. Case-insensitive header-name match; preserves each line's CRLF/LF terminator.
      private def self.resync_truncated_head(head : Bytes, length : Int32) : Bytes
        cl_written = false
        String.build do |io|
          String.new(head).each_line(chomp: false) do |line|
            lname = line.lstrip
            eol = line.ends_with?("\r\n") ? "\r\n" : (line.ends_with?('\n') ? "\n" : "")
            if lname[0, 15]?.try(&.downcase) == "content-length:" ||
               lname[0, 18]?.try(&.downcase) == "transfer-encoding:"
              # A truncated body is re-framed with ONE Content-Length. If the capture had
              # BOTH CL and TE (a CL.TE/TE.CL smuggling probe), collapse them into a single
              # Content-Length instead of emitting a duplicate — RFC 7230 forbids TE+CL.
              if cl_written
                next # drop the second framing header
              else
                io << "Content-Length: " << length << eol
                cl_written = true
              end
            else
              io << line
            end
          end
        end.to_slice
      end

      # Keep Content-Length matching the actual body length of a wire-form request: rewrite
      # an EXISTING header (e.g. after env-var expansion changes body bytes — a `$KEY` in the
      # body means `build` framed the CL over the pre-expansion body, so re-sync it or the
      # origin over/under-reads), and — when `add_if_missing` (the repeater's own default-on
      # auto-CL toggle, as opposed to the captured-flow-replay caller below) — ADD one when a
      # non-empty body has none at all: an operator editing a repeater's raw request text and
      # leaving out Content-Length entirely otherwise sends a framing-ambiguous request that
      # most origins read as a zero-length body, silently, with gori's own recorded evidence
      # still showing the edited body text. A bodyless request (GETs stay clean) never gets a
      # header added. Shared by the TUI Repeater editor and the headless CLI/MCP
      # repeater-send paths so they can't disagree.
      #
      # A head carrying `Transfer-Encoding` is left ALONE, Content-Length or not (added or
      # existing). RFC 7230 §3.3.3 forbids sending both, so a message with both is a CL.TE /
      # TE.CL smuggling probe — the two headers disagreeing IS the test — and "correcting"
      # the CL over the chunked wire form turns it into a different probe with no notice.
      # This is the rule `build_single_flow_request` already applies on the sibling
      # flow-replay path (`!explicit_cl && !has_te && body_override`); it was missing here,
      # so `repeater create` + `send` under the default auto-CL rewrote exactly the requests
      # it exists to replay.
      def self.resync_content_length(bytes : Bytes, add_if_missing : Bool = true) : Bytes
        text = String.new(bytes)
        sep = text.index("\r\n\r\n")
        return bytes unless sep
        head = text[0, sep]
        body = text[(sep + 4)..]
        lines = head.split("\r\n")
        return bytes if lines.any? { |l| l.lstrip[0, 18]?.try(&.downcase) == "transfer-encoding:" }
        idx = lines.index { |l| l.lstrip.downcase.starts_with?("content-length:") }
        if idx
          lines[idx] = "Content-Length: #{body.bytesize}"
        elsif add_if_missing && body.bytesize > 0
          # ADD only into a head this function actually parsed. `split("\r\n")` collapses a
          # bare-LF-terminated line into the one before it, and both consequences are the exact
          # corruption this function exists to avoid:
          #   * a `Transfer-Encoding` hiding inside such a merged line is invisible to the guard
          #     above, so a pure TE probe would come back framed BOTH ways — a CL.TE desync test
          #     the operator never wrote, with the length counting the chunked wire bytes;
          #   * when the head is LF-framed, `\r\n\r\n` can first occur inside the BODY, so `head`
          #     runs past the real terminator and the new header lands INSIDE a smuggled request.
          # A leftover `\n` in any line means exactly that, so leave the bytes as written (P7).
          # Rewriting an EXISTING Content-Length keeps its pre-existing behaviour: this guard is
          # only about ADDING framing to bytes we could not parse.
          return bytes if lines.any?(&.includes?('\n'))
          lines << "Content-Length: #{body.bytesize}"
        else
          return bytes
        end
        "#{lines.join("\r\n")}\r\n\r\n#{body}".to_slice
      end

      # The CAPTURED-FLOW replay policy, as opposed to the repeater's auto-CL toggle above.
      #
      # A stored Content-Length is evidence: `Content-Length: 99` over a 2-byte body, a
      # `content-length:2` spelled without OWS, a `Content-Length:  0004  ` — each is a
      # request-smuggling / CL-desync probe someone captured *because* it is wrong, and
      # recomputing it means the operator reads a verdict about a request gori never sent.
      # So replay leaves the line alone.
      #
      # The one exception is the reason `resync_content_length` exists on this path at all:
      # a `$KEY` in the body. `build` framed the stored CL over the PRE-expansion bytes, so
      # after expansion the header under-counts a body the operator did not author, and the
      # origin over/under-reads. Detect that by the BODY LENGTH changing — an expansion that
      # only touched the head must not be allowed to overwrite a deliberately-wrong CL.
      #
      # `add_if_missing: false` — a captured flow with NO Content-Length at all (relying on
      # close-delimited framing, or itself a smuggling probe) is evidence same as a wrong one;
      # this path only ever RESYNCS an existing header, it does not invent framing the
      # operator's capture never had.
      def self.resync_content_length_if_body_changed(before : Bytes, after : Bytes) : Bytes
        b = body_bytesize(before)
        a = body_bytesize(after)
        return after if b.nil? || a.nil? || b == a
        resync_content_length(after, add_if_missing: false)
      end

      # Body length of a wire-form request, or nil when there is no CRLFCRLF terminator.
      # Splits exactly the way `resync_content_length` does so the two cannot disagree.
      private def self.body_bytesize(bytes : Bytes) : Int32?
        text = String.new(bytes)
        sep = text.index("\r\n\r\n")
        return nil unless sep
        text[(sep + 4)..].bytesize
      end

      # Is the STORED request body shorter than the framing its own head declares?
      #
      # The request-side fact behind the "captured incomplete" replay warning. It has to be
      # computed from the head and the body, not read off `FlowRow#state`: that column is the
      # whole flow's, and a RESPONSE-side failure (an origin that truncated its body, a
      # conflicting-Content-Length answer) sets it too — which is exactly the population an
      # operator replays, so keying the warning on it fired on nearly every replay and
      # prescribed `-b/--body` on bodyless GETs that have no Content-Length at all.
      #
      # True when a declared `Content-Length` exceeds the stored bytes, or when a `chunked`
      # body never reached its terminating 0-chunk. False for everything else, INCLUDING a
      # body LONGER than its Content-Length: over-long is a legal-and-deliberate desync probe
      # (the extra bytes are the smuggled prefix), not a truncated capture, and the origin
      # will not block on it.
      def self.request_short_of_framing?(head : Bytes, body : Bytes?) : Bool
        size = body.try(&.size) || 0
        te = nil.as(String?)
        cl = nil.as(String?)
        String.new(head).each_line do |raw|
          line = raw.chomp
          break if line.empty? # the blank line ends the head
          idx = line.index(':') || next
          name = line[0...idx].strip.downcase
          te = line[(idx + 1)..].strip if name == "transfer-encoding"
          cl = line[(idx + 1)..].strip if name == "content-length" && cl.nil?
        end
        # TE wins over CL when both are present, matching how a chunked message is framed
        # on the wire (and how `resync_truncated_head` collapses the pair).
        if t = te
          return false unless t.split(',').map(&.strip.downcase).reject(&.empty?).last? == "chunked"
          return false if size == 0 # no stored body at all is not a CUT chunked stream
          return !Proxy::Codec::ContentDecode.chunked_complete?(body || Bytes.empty)
        end
        declared = cl.try(&.strip.to_i?) || return false
        declared > size
      end

      # The default port for a scheme, **ws/wss included**.
      #
      # Deliberately NOT `Discover::Url.default_port?`, which knows only http/https: it answers
      # false for wss/443 and so would hang a redundant `:443` on every secure-WebSocket
      # authority. The crawler never speaks ws; the repeater does. Keep the two apart rather
      # than "unifying" them into that bug.
      def self.default_port(scheme : String) : Int32
        (scheme == "https" || scheme == "wss") ? 443 : 80
      end

      def self.default_port?(scheme : String, port : Int32) : Bool
        port == default_port(scheme)
      end

      # The authority — `host[:port]`, IPv6 literal bracketed, port omitted when it is the
      # scheme default. This is BOTH the `Host:` header value (RFC 7230 §5.4) and the part
      # `build_target` hangs off `scheme://`, so both derive from here and cannot drift.
      #
      # An IPv6 literal (contains ':') must be bracketed, else the `:port` suffix and
      # `URI.parse` in `parse_target` split it wrong (host → ""). `parse_target` returns a
      # BRACKET-FREE host (what TCPSocket wants to dial), so this is where they come back.
      def self.authority(scheme : String, host : String, port : Int32) : String
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        default_port?(scheme, port) ? h : "#{h}:#{port}"
      end

      # "scheme://host[:port]", omitting the port when it's the scheme default —
      # matches RepeaterView#build_target so the parsed {scheme,host,port} round-trips.
      def self.build_target(scheme : String, host : String, port : Int32) : String
        "#{scheme}://#{authority(scheme, host, port)}"
      end

      # {scheme, host, port} parsed back out of a target string (the inverse of
      # build_target; also used when the CLI accepts a hand-supplied --target).
      def self.parse_target(target : String) : {String, String, Int32}
        raw = target.strip
        raw = "http://#{raw}" unless raw.includes?("://")
        uri = URI.parse(raw)
        scheme = uri.scheme || "http"
        host = strip_ipv6_brackets(uri.host || "")
        port = uri.port || default_port(scheme)
        {scheme, host, port}
      rescue
        {"http", "", 0}
      end

      # URI.parse keeps the [] around an IPv6 literal host; strip them so the bare address
      # is what we dial/round-trip (TCPSocket wants "::1", not "[::1]").
      private def self.strip_ipv6_brackets(host : String) : String
        host.starts_with?('[') && host.ends_with?(']') ? host[1..-2] : host
      end

      # Rewrite the request-line to origin-form when it's absolute-form, keeping the
      # rest of the head + the body byte-exact; otherwise return head+body verbatim.
      # Returns {bytes, whether the request line was rewritten} — the caller REPORTS the
      # rewrite, because an absolute-form line is a proxy artifact on one flow and the
      # payload on the next and only the operator can tell those apart (see `Built`).
      def self.origin_form_bytes(head : Bytes, body : Bytes?) : {Bytes, Bool}
        nl = head.index(0x0A_u8)
        if nl
          first = String.new(head[0, nl]).rstrip('\r')
          if rewritten = rewrite_request_line(first)
            # Preserve the original request-line terminator (CRLF vs bare LF) so a
            # rewrite never introduces a mixed ending the rest of the head doesn't use.
            eol = (nl > 0 && head[nl - 1] == 0x0D_u8) ? "\r\n" : "\n"
            io = IO::Memory.new(head.size + (body.try(&.size) || 0))
            io << rewritten << eol
            rest_at = nl + 1
            io.write(head[rest_at, head.size - rest_at]) # remaining head bytes, exact
            io.write(body) if body && !body.empty?
            return {io.to_slice, true}
          end
        end
        {combine(head, body), false}
      end

      # Rewrite a request line's HTTP-version token to match the transport when the user
      # flips the h1↔h2 toggle. The h1 `Engine` sends the request line VERBATIM, so a flow
      # captured over h2 (stored with a "…​ HTTP/2" line, see H2 Assembler#synth_request_head)
      # would otherwise reach an h1 origin as a malformed "GET / HTTP/2"; `H2Engine` ignores
      # the token, but we still normalize it so the editor display agrees with the wire.
      # The version is the LAST space-delimited token (a raw space inside the target is
      # tolerated, as elsewhere). Returns the rewritten line, or nil when nothing needs to
      # change (already correct, or not a recognizable "… HTTP/x" request line).
      def self.retarget_version_line(line : String, http2 : Bool) : String?
        sp = line.rindex(' ')
        return nil unless sp
        version = line[(sp + 1)..]
        return nil unless version.starts_with?("HTTP/")
        want = http2 ? "HTTP/2" : "HTTP/1.1"
        return nil if version == want
        "#{line[0, sp]} #{want}"
      end

      # HTTP versions an HTTP/1.x connection cannot carry. A request line pasted from
      # another tool's HTTP/2 view ("GET /p HTTP/2" — Burp renders h2 requests that way)
      # is put on the wire VERBATIM by the h1 `Engine`, and an origin handed a version
      # token it doesn't speak answers 400.
      UNSENDABLE_OVER_H1 = {"HTTP/2", "HTTP/2.0", "HTTP/3", "HTTP/3.0"}

      # The request line rewritten to HTTP/1.1 when it declares a version h1 can't carry,
      # else nil (nothing to do). Version = the LAST space-delimited token, as in
      # `retarget_version_line`.
      #
      # Deliberately NARROWER than `retarget_version_line`: that one normalizes ANY
      # mismatch because it backs the explicit ^V toggle, while this runs unasked on every
      # send, so it must leave a version the operator meant alone. "HTTP/1.0" is a
      # legitimate thing to hand-type at an origin (and "HTTP/9.9" a legitimate thing to
      # probe with); "HTTP/2" down an h1 socket is never anything but a mistake.
      def self.downgrade_version_line(line : String) : String?
        sp = line.rindex(' ')
        return nil unless sp
        return nil unless UNSENDABLE_OVER_H1.includes?(line[(sp + 1)..])
        "#{line[0, sp]} HTTP/1.1"
      end

      # `downgrade_version_line` over a whole WIRE request, so `Plan.build` can apply it on the
      # one path every surface shares instead of only the TUI doing it. Operates on the first
      # CRLF-terminated line and returns the input UNCHANGED (same object) when there is
      # nothing to correct, so a request whose version the operator meant is byte-untouched.
      def self.downgrade_request_line(wire : Bytes) : Bytes
        text = String.new(wire)
        eol = text.index("\r\n") || return wire
        fixed = downgrade_version_line(text[0, eol]) || return wire
        "#{fixed}#{text[eol..]}".to_slice
      end

      # Normalize bare LFs in a MULTIPART body to CRLF. Multipart parts are delimited by
      # CRLF + boundary (RFC 2046 §5.1.1), so a body carrying bare LFs is unparseable and
      # the origin answers 400 — usually with no hint as to why, because auto-Content-Length
      # re-frames the shortened body so nothing hangs.
      #
      # EDITOR-DERIVED TEXT ONLY — never call this on captured or hand-supplied bytes.
      # `Env.expand_wire` normalizes the HEAD alone on purpose: a raw 0x0A in a body is a
      # BYTE (binary/compressed data), not a line ending, and rewriting it corrupts the
      # request. That reasoning still holds for every verbatim-bytes path (`Repeater::Plan`,
      # `Miner::Plan`, `Sequencer::Plan`, `FlowRequest.build`), which is why the fix lives
      # here as an opt-in step rather than inside `expand_wire`.
      #
      # It USED to be justified by "the CRs are already gone anyway": `TextArea#set_text`
      # stripped \r off every line, so a multipart body could not reach the wire with its
      # delimiters intact by any route. That premise is now FALSE — `set_text`/`wire_text`
      # round-trip each line's own terminator exactly (`text_area.cr`), so the step that used
      # to RESTORE missing delimiters would instead CORRUPT surviving ones: a captured upload
      # whose part data is LF-terminated file content came back three bytes longer, with
      # auto-Content-Length re-framing the body so nothing hung and nothing said a word.
      #
      # So it now runs only where its premise still holds — a body with NO CRLF in it at all,
      # which is what a freshly TYPED multipart looks like (every line's terminator is the
      # editor's default LF). A captured multipart always carries CRLF (RFC 2046 §5.1.1
      # delimits parts with it and the part headers are CRLF-terminated), so it is left
      # byte-exact. ^X hex mode remains the byte-exact escape hatch either way.
      def self.normalize_multipart_body(bytes : Bytes) : Bytes
        text = String.new(bytes)
        sep = text.index("\r\n\r\n")
        return bytes unless sep
        body_at = sep + 4
        return bytes if body_at >= bytes.size
        return bytes unless multipart_head?(text[0, sep])
        body = bytes[body_at..]
        return bytes if crlf?(body) # already wire-form — these bytes are evidence, not a draft
        head = bytes[0, body_at]
        normalized = Env.normalize_crlf(body)
        io = IO::Memory.new(head.size + normalized.size)
        io.write(head)
        io.write(normalized)
        io.to_slice
      end

      # Does this span contain a CRLF? Byte-level: the body may be binary, and a Regex or a
      # char-indexed `String#index` cannot take it as a subject.
      private def self.crlf?(bytes : Bytes) : Bool
        i = 0
        while i < bytes.size - 1
          return true if bytes[i] == 0x0D_u8 && bytes[i + 1] == 0x0A_u8
          i += 1
        end
        false
      end

      # True when the head declares a `multipart/*` Content-Type. Case-insensitive on both
      # the header name and the media type, per RFC 9110 §5.1/§8.3.
      private def self.multipart_head?(head : String) : Bool
        head.split("\r\n").any? do |line|
          next false unless line.lstrip[0, 13]?.try(&.downcase) == "content-type:"
          line.split(':', 2)[1].lstrip.downcase.starts_with?("multipart/")
        end
      end

      # Returns the origin-form request line for an absolute-form one, else nil
      # (origin-form already, or not a well-formed 3-token request line).
      def self.rewrite_request_line(line : String) : String?
        parts = line.split(' ')
        return nil unless parts.size == 3
        return nil unless parts[1].starts_with?("http://") || parts[1].starts_with?("https://")
        "#{parts[0]} #{to_origin(parts[1])} #{parts[2]}"
      end

      private def self.to_origin(url : String) : String
        uri = URI.parse(url)
        path = uri.path
        path = "/" if path.empty?
        uri.query ? "#{path}?#{uri.query}" : path
      rescue
        url
      end

      private def self.combine(head : Bytes, body : Bytes?) : Bytes
        return head if body.nil? || body.empty?
        io = IO::Memory.new(head.size + body.size)
        io.write(head)
        io.write(body)
        io.to_slice
      end
    end
  end
end
