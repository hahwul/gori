require "uri"
require "../store"

module Gori
  module Replay
    # Reconstructs a replayable request from a captured flow — the headless
    # counterpart of the TUI's ReplayView#load. Unlike the editor (which splits the
    # request into text lines and re-encodes them), this keeps request_head +
    # request_body BYTE-EXACT, rewriting ONLY an absolute-form request line
    # ("GET http://h/p HTTP/1.1" → "GET /p HTTP/1.1") so the bytes can go straight
    # to the origin server. Byte-exactness matters for binary bodies, which a text
    # round-trip would corrupt.
    #
    # The result feeds Replay::Engine.send / Replay::H2Engine.send, which take
    # `request, scheme:, host:, port:, verify_upstream:`.
    module FlowRequest
      record Built, target : String, bytes : Bytes, http2 : Bool

      def self.build(detail : Store::FlowDetail) : Built
        row = detail.row
        head = detail.request_head
        body = detail.request_body
        # The captured body is capped at CAPTURE_MAX (8 MiB). If it was truncated, a faithful
        # h1 replay would BLOCK the origin waiting for bytes that no longer exist (a
        # Content-Length over-promising, or a chunked stream cut before its 0-chunk). Byte-
        # exactness is already lost at the cap, so re-frame the head to a fixed Content-Length
        # over the bytes we actually send, so the replay terminates instead of hanging.
        head = resync_truncated_head(head, body.try(&.size) || 0) if detail.request_body_truncated?
        Built.new(
          target: build_target(row.scheme, row.host, row.port),
          bytes: origin_form_bytes(head, body),
          http2: detail.http_version == "HTTP/2",
        )
      end

      # Make a TRUNCATED request self-framed so the replay can't hang. Used ONLY when the
      # captured body was capped. Rewrites an existing Content-Length to the stored byte
      # count, OR replaces a Transfer-Encoding (chunked — whose stored wire-form bytes were
      # cut mid-stream) with a Content-Length over those bytes so the origin reads a complete
      # body. Case-insensitive header-name match; preserves each line's CRLF/LF terminator.
      private def self.resync_truncated_head(head : Bytes, length : Int32) : Bytes
        String.build do |io|
          String.new(head).each_line(chomp: false) do |line|
            lname = line.lstrip
            eol = line.ends_with?("\r\n") ? "\r\n" : (line.ends_with?('\n') ? "\n" : "")
            if lname[0, 15]?.try(&.downcase) == "content-length:" ||
               lname[0, 18]?.try(&.downcase) == "transfer-encoding:"
              io << "Content-Length: " << length << eol # RFC 7230 forbids TE+CL, so only one fires
            else
              io << line
            end
          end
        end.to_slice
      end

      # "scheme://host[:port]", omitting the port when it's the scheme default —
      # matches ReplayView#build_target so the parsed {scheme,host,port} round-trips.
      def self.build_target(scheme : String, host : String, port : Int32) : String
        default = scheme == "https" ? 443 : 80
        # An IPv6 literal host (contains ':') must be bracketed in a URL, else both the
        # `:port` suffix below and URI.parse in parse_target split it wrong (host → "").
        h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        port == default ? "#{scheme}://#{h}" : "#{scheme}://#{h}:#{port}"
      end

      # {scheme, host, port} parsed back out of a target string (the inverse of
      # build_target; also used when the CLI accepts a hand-supplied --target).
      def self.parse_target(target : String) : {String, String, Int32}
        raw = target.strip
        raw = "http://#{raw}" unless raw.includes?("://")
        uri = URI.parse(raw)
        scheme = uri.scheme || "http"
        host = strip_ipv6_brackets(uri.host || "")
        port = uri.port || (scheme == "https" ? 443 : 80)
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
