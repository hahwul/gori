require "uri"
require "json"
require "../fuzz/content_length"

module Gori::Miner
  # Adds candidate parameters to a request at a chosen location, keeping everything
  # else byte-exact. One uniform HTTP/1-form text path for h1 AND h2 (H2Engine re-frames
  # h1-form text to HPACK itself), preserving the request's existing EOL (captured/h2
  # requests are CRLF). Body locations re-sync Content-Length via Fuzz::ContentLength.
  module Inject
    # Query/form length guard — origins and intermediaries cap request-line/URL bytes.
    # The engine pre-splits buckets to respect this; this is the per-call ceiling.
    MAX_URL_BYTES = 8 * 1024

    # Hop-by-hop / framing headers a candidate name must never become.
    FORBIDDEN_HEADERS = Set{
      "host", "content-length", "connection", "transfer-encoding",
      "te", "upgrade", "keep-alive", "expect",
    }

    # Add `params` ({name, value}) to `request` at `location`, byte-exact otherwise.
    def self.apply(request : Bytes, location : Location,
                   params : Array({String, String}),
                   add_cl_when_missing : Bool = false) : Bytes
      return request if params.empty?
      case location
      in Location::Query   then inject_query(request, params)
      in Location::Form    then Fuzz::ContentLength.sync(inject_form(request, params), add_cl_when_missing)
      in Location::Json    then Fuzz::ContentLength.sync(inject_json(request, params), add_cl_when_missing)
      in Location::Headers then inject_headers(request, params)
      in Location::Cookies then inject_cookies(request, params)
      end
    end

    # ── head/body split (own copy of Fuzz::ContentLength's left-to-right scan) ────────

    # {head bytes (no trailing blank line), body bytes, line ending}. A request with no
    # blank line is treated as all-head with an empty body.
    def self.split(request : Bytes) : {Bytes, Bytes, String}
      sep, sep_w, eol = boundary(request)
      if sep.nil?
        return {request, Bytes.empty, "\r\n"}
      end
      head = request[0, sep]
      body_start = sep + sep_w
      body = request[body_start, request.size - body_start]
      {head, body, eol}
    end

    # The named header's value (case-insensitive), scanning only the head lines.
    def self.header_value(request : Bytes, name : String) : String?
      head, _, eol = split(request)
      String.new(head).split(eol).each do |line|
        if colon = line.index(':')
          return line[(colon + 1)..].strip if line[0...colon].strip.downcase == name.downcase
        end
      end
      nil
    end

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

    private def self.rebuild(head_lines : Array(String), eol : String, body : Bytes) : Bytes
      io = IO::Memory.new
      io << head_lines.join(eol) << eol << eol
      io.write(body) unless body.empty?
      io.to_slice
    end

    # ── query ───────────────────────────────────────────────────────────────────────

    private def self.inject_query(request : Bytes, params : Array({String, String})) : Bytes
      nl = request.index(0x0a_u8)
      return request unless nl
      first = String.new(request[0, nl]).rstrip('\r')
      parts = first.split(' ')
      return request unless parts.size == 3
      extra = encode_pairs(params)
      target = append_query(parts[1], extra)
      new_first = "#{parts[0]} #{target} #{parts[2]}"
      eol = (nl > 0 && request[nl - 1] == 0x0d_u8) ? "\r\n" : "\n"
      io = IO::Memory.new(request.size + extra.bytesize + 8)
      io << new_first << eol
      rest_at = nl + 1
      io.write(request[rest_at, request.size - rest_at])
      io.to_slice
    end

    private def self.append_query(target : String, extra : String) : String
      if !target.includes?('?')
        "#{target}?#{extra}"
      elsif target.ends_with?('?') || target.ends_with?('&')
        "#{target}#{extra}"
      else
        "#{target}&#{extra}"
      end
    end

    # ── form (application/x-www-form-urlencoded) ─────────────────────────────────────

    private def self.inject_form(request : Bytes, params : Array({String, String})) : Bytes
      head, body, eol = split(request)
      extra = encode_pairs(params)
      btext = String.new(body)
      new_body = if body.empty?
                   extra
                 elsif btext.ends_with?('&')
                   "#{btext}#{extra}"
                 else
                   "#{btext}&#{extra}"
                 end
      io = IO::Memory.new(head.size + new_body.bytesize + eol.bytesize * 2)
      io.write(head)
      io << eol << eol << new_body
      io.to_slice
    end

    private def self.encode_pairs(params : Array({String, String})) : String
      params.map { |(n, v)| "#{URI.encode_www_form(n)}=#{URI.encode_www_form(v)}" }.join('&')
    end

    # ── json (object root only) ──────────────────────────────────────────────────────

    private def self.inject_json(request : Bytes, params : Array({String, String})) : Bytes
      head, body, eol = split(request)
      new_body = inject_json_text(String.new(body).scrub, params)
      return request unless new_body
      io = IO::Memory.new(head.size + new_body.bytesize + eol.bytesize * 2)
      io.write(head)
      io << eol << eol << new_body
      io.to_slice
    end

    # Merge keys into a top-level JSON object. Falls back to a string-splice when the
    # body parses loosely as `{…}`; returns nil for non-object roots (Detect won't offer
    # Json there, so this only guards a hand-driven call).
    def self.inject_json_text(btext : String, params : Array({String, String})) : String?
      begin
        any = JSON.parse(btext)
        if h = any.as_h?
          merged = h.dup
          params.each { |(n, v)| merged[n] = JSON::Any.new(v) }
          return merged.to_json
        end
      rescue JSON::ParseException
        # fall through to the textual splice
      end
      bi = btext.index('{')
      return nil unless bi
      after = btext[(bi + 1)..]
      sep = after.lstrip.starts_with?('}') ? "" : ","
      inserts = params.map { |(n, v)| "#{n.to_json}:#{v.to_json}" }.join(',')
      "#{btext[0..bi]}#{inserts}#{sep}#{after}"
    end

    # ── headers ──────────────────────────────────────────────────────────────────────

    private def self.inject_headers(request : Bytes, params : Array({String, String})) : Bytes
      head, body, eol = split(request)
      lines = String.new(head).split(eol)
      params.each { |(n, v)| lines << "#{n}: #{sanitize_value(v)}" if valid_header_name?(n) }
      rebuild(lines, eol, body)
    end

    # ── cookies ──────────────────────────────────────────────────────────────────────

    private def self.inject_cookies(request : Bytes, params : Array({String, String})) : Bytes
      head, body, eol = split(request)
      lines = String.new(head).split(eol)
      additions = params.compact_map { |(n, v)| valid_cookie_name?(n) ? "#{n}=#{sanitize_value(v)}" : nil }
      return request if additions.empty?
      idx = lines.index { |l| (c = l.index(':')) && c > 0 && l[0...c].strip.downcase == "cookie" }
      if idx
        lines[idx] = "#{lines[idx].rstrip}; #{additions.join("; ")}"
      else
        lines << "Cookie: #{additions.join("; ")}"
      end
      rebuild(lines, eol, body)
    end

    # ── name/value validity ──────────────────────────────────────────────────────────

    def self.valid_header_name?(name : String) : Bool
      return false if name.empty? || name.size > 64
      ln = name.downcase
      return false if FORBIDDEN_HEADERS.includes?(ln)
      return false if ln.starts_with?("proxy-")
      name.each_char { |c| return false unless token_char?(c) }
      true
    end

    # A cookie name: token chars minus the cookie separators ; = and space (already
    # excluded by token_char?). Same charset is safe for cookies.
    def self.valid_cookie_name?(name : String) : Bool
      return false if name.empty? || name.size > 64
      name.each_char { |c| return false unless token_char?(c) }
      true
    end

    private def self.token_char?(c : Char) : Bool
      c.ascii_letter? || c.ascii_number? || "!#$%&'*+-.^_`|~".includes?(c)
    end

    # Strip CR/LF from an injected header/cookie value (header smuggling guard).
    private def self.sanitize_value(v : String) : String
      v.delete("\r\n")
    end
  end
end
