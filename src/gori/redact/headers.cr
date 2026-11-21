module Gori
  module Redact
    # Header names whose VALUES carry credentials or session material — the ONE list behind
    # every header `[REDACTED]` in the tree: MCP's read tools, `gori run history --format
    # json`, `gori run evidence show` and the SARIF issues export (#1191). Kept here rather
    # than in `MCP::Serialize` so a core exporter can ask without depending on a surface.
    #
    # A different axis from the body `Profile`s in redact.cr: those are operator-configured
    # and match structure; this is fixed and matches a field NAME.
    SENSITIVE_HEADERS = {"authorization", "proxy-authorization", "cookie", "set-cookie",
                         "x-api-key", "api-key", "x-auth-token"}

    def self.sensitive_header?(name : String) : Bool
      SENSITIVE_HEADERS.includes?(name.strip.downcase)
    end

    # Project just the header lines, preserving line endings, public fields and any body.
    # A clipped sensitive field cannot safely identify even a Set-Cookie attribute.
    def self.redact_head(text : String, include_sensitive : Bool = false, *, truncated : Bool = false) : String
      return text if include_sensitive || !text.includes?(':')
      bytes = text.to_slice
      buffer = IO::Memory.new(bytes.size)
      pos = 0
      sensitive_continuation = false
      while pos < bytes.size
        stop = pos
        while stop < bytes.size && !bytes[stop].in?(0x0a_u8, 0x0d_u8)
          stop += 1
        end
        if stop == pos
          buffer.write(bytes[pos..]) # first empty line ends the header block
          break
        end
        line = bytes[pos, stop - pos]
        sensitive_continuation = write_header_line(buffer, line, sensitive_continuation, truncated && stop == bytes.size)
        pos = stop
        if pos < bytes.size
          pos += 1
          pos += 1 if bytes[stop] == 0x0d_u8 && bytes[pos]? == 0x0a_u8
          buffer.write(bytes[stop, pos - stop])
        end
      end
      String.new(buffer.to_slice)
    end

    private def self.write_header_line(buffer : IO, line : Bytes, sensitive_continuation : Bool, truncated : Bool) : Bool
      if sensitive_continuation && line[0].in?(0x20_u8, 0x09_u8)
        indent = 0
        while indent < line.size && line[indent].in?(0x20_u8, 0x09_u8)
          indent += 1
        end
        buffer.write(line[0, indent])
        buffer << "[REDACTED]"
        return true
      end
      # A malformed head can start directly with a credential field.
      if colon = line.index(0x3a_u8)
        name = String.new(line[0, colon]).scrub
        if sensitive_header?(name)
          buffer.write(line[0, colon])
          buffer << ": " << (truncated ? "[REDACTED]" : redacted_value(name, String.new(line[colon + 1..]).scrub.strip))
          return true
        end
      end
      buffer.write(line)
      false
    end

    # The attributes a Set-Cookie may carry (RFC 6265 §4.1, plus Partitioned and Priority).
    COOKIE_ATTRIBUTES = {"path", "domain", "expires", "max-age", "secure", "httponly", "samesite",
                         "partitioned", "priority"}

    # What a sensitive header's value prints as. `[REDACTED]`, except a Set-Cookie keeps its
    # cookie name and its attributes: whether a cookie is `HttpOnly`, `Secure` or `SameSite` is
    # what a tester reads it for, and only the value is session material. An agent shown
    # `Set-Cookie: [REDACTED]` fetched flow after flow and still could not say which cookies
    # lacked HttpOnly. Allowlisted, not just "everything after the first `;`": a segment that is
    # not a known attribute, or an attribute value holding `=` (a comma-folded second cookie,
    # `a=1; Path=/, b=2`), is redacted too.
    def self.redacted_value(name : String, value : String) : String
      return "[REDACTED]" unless name.strip.downcase == "set-cookie"
      first, *attrs = value.split(';')
      cookie, eq, _ = first.partition('=')
      parts = [eq.empty? ? "[REDACTED]" : "#{cookie.strip}=[REDACTED]"]
      attrs.each do |seg|
        attr, aeq, avalue = seg.strip.partition('=')
        parts << if !COOKIE_ATTRIBUTES.includes?(attr.downcase)
          "[REDACTED]"
        elsif aeq.empty?
          attr
        elsif avalue.includes?('=')
          "#{attr}=[REDACTED]"
        else
          "#{attr}=#{avalue}"
        end
      end
      parts.join("; ")
    end
  end
end
