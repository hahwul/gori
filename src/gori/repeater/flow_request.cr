require "uri"
require "../env"
require "../store"

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
      record Built, target : String, bytes : Bytes, http2 : Bool, sni : String?

      def self.build(detail : Store::FlowDetail) : Built
        row = detail.row
        head = detail.request_head
        body = detail.request_body
        # The captured body is capped at CAPTURE_MAX. If it was truncated, a faithful
        # h1 repeater would BLOCK the origin waiting for bytes that no longer exist (a
        # Content-Length over-promising, or a chunked stream cut before its 0-chunk). Byte-
        # exactness is already lost at the cap, so re-frame the head to a fixed Content-Length
        # over the bytes we actually send, so the repeater terminates instead of hanging.
        head = resync_truncated_head(head, body.try(&.size) || 0) if detail.request_body_truncated?
        Built.new(
          target: build_target(row.scheme, row.host, row.port),
          bytes: origin_form_bytes(head, body),
          http2: detail.http_version == "HTTP/2",
          sni: detail.sni,
        )
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

      # Rewrite an EXISTING Content-Length to match the actual body length of a wire-form
      # request. Used after env-var expansion changes body bytes (a `$KEY` in the body):
      # `build` framed the CL over the pre-expansion body, so re-sync it or the origin
      # over/under-reads. Never ADDS a header (GETs stay clean) and leaves chunked/h2
      # bodies (no Content-Length) untouched. Shared by the TUI Repeater editor and the
      # headless CLI/MCP repeater-send paths so they can't disagree.
      def self.resync_content_length(bytes : Bytes) : Bytes
        text = String.new(bytes)
        sep = text.index("\r\n\r\n")
        return bytes unless sep
        head = text[0, sep]
        body = text[(sep + 4)..]
        lines = head.split("\r\n")
        idx = lines.index { |l| l.lstrip.downcase.starts_with?("content-length:") }
        return bytes unless idx
        lines[idx] = "Content-Length: #{body.bytesize}"
        "#{lines.join("\r\n")}\r\n\r\n#{body}".to_slice
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
      def self.origin_form_bytes(head : Bytes, body : Bytes?) : Bytes
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
            return io.to_slice
          end
        end
        combine(head, body)
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
      # here as an opt-in step rather than inside `expand_wire`. It is sound only where the
      # CRs are already gone: the TUI editors hold the request as an LF-joined line buffer
      # (`TextArea#set_text` strips \r off every line), so a multipart body typed or pasted
      # there cannot reach the wire intact by any other route. ^X hex mode remains the
      # byte-exact escape hatch for a multipart body with binary parts.
      def self.normalize_multipart_body(bytes : Bytes) : Bytes
        text = String.new(bytes)
        sep = text.index("\r\n\r\n")
        return bytes unless sep
        body_at = sep + 4
        return bytes if body_at >= bytes.size
        return bytes unless multipart_head?(text[0, sep])
        head = bytes[0, body_at]
        body = Env.normalize_crlf(bytes[body_at..])
        io = IO::Memory.new(head.size + body.size)
        io.write(head)
        io.write(body)
        io.to_slice
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
