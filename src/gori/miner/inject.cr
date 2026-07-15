require "uri"
require "json"
require "mime/multipart"
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

    # JSON candidate keys are injected into EVERY object node in the body (see
    # inject_json_text). The node set is capped (BFS shallow-first) and derived once from the
    # BASE body — a fixed count independent of the current bucket, so a name always hits the same
    # nodes across the initial bucket, its bisection halves, and confirmation (coverage invariance).
    MAX_JSON_NODES = 32

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
      in Location::Query     then inject_query(request, params)
      in Location::Form      then Fuzz::ContentLength.sync(inject_form(request, params), add_cl_when_missing)
      in Location::Multipart then Fuzz::ContentLength.sync(inject_multipart(request, params), add_cl_when_missing)
      in Location::Json      then Fuzz::ContentLength.sync(inject_json(request, params), add_cl_when_missing)
      in Location::Headers   then inject_headers(request, params)
      in Location::Cookies   then inject_cookies(request, params)
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

    # ── multipart/form-data ──────────────────────────────────────────────────────────

    # Append candidate fields to a multipart body, byte-exact otherwise. We REUSE the
    # request's existing boundary and splice the new parts in just before the LAST
    # `--boundary--` close delimiter (not MIME::Multipart::Builder, which would mint a fresh
    # boundary and force a Content-Type rewrite + re-serialization that mangles binary parts).
    # Multipart is ALWAYS CRLF internally (RFC 7578), regardless of the head's EOL.
    private def self.inject_multipart(request : Bytes, params : Array({String, String})) : Bytes
      raw_ct = header_value(request, "content-type") # ORIGINAL case — the boundary is case-sensitive
      return request unless raw_ct
      boundary = MIME::Multipart.parse_boundary(raw_ct)
      return request if boundary.nil? || boundary.empty?

      additions = build_multipart_parts(boundary, params)
      return request if additions.empty?

      head, body, eol = split(request)
      io = IO::Memory.new(head.size + body.size + additions.bytesize + eol.bytesize * 2 + 16)
      io.write(head)
      io << eol << eol

      close = "--#{boundary}--".to_slice
      if ci = last_index_of(body, close)
        io.write(body[0, ci])
        # A boundary delimiter must be preceded by CRLF; a well-formed body already ends the
        # prior part with it (so this no-ops), but a synthesised/edited body might not.
        io << "\r\n" unless ci >= 2 && body[ci - 2] == 0x0d_u8 && body[ci - 1] == 0x0a_u8
        io << additions                    # each appended part already ends with CRLF
        io.write(body[ci, body.size - ci]) # the close delimiter + any epilogue, verbatim
      else
        # Malformed (no close delimiter) or empty body: synthesise a well-formed tail so the
        # baseline and test requests differ only by the injected fields.
        unless body.empty?
          io.write(body)
          io << "\r\n" unless ends_with_crlf?(body)
        end
        io << additions
        io << "--" << boundary << "--\r\n"
      end
      io.to_slice
    end

    private def self.build_multipart_parts(boundary : String, params : Array({String, String})) : String
      String.build do |sb|
        params.each do |(n, v)|
          next unless valid_multipart_name?(n)
          sb << "--" << boundary << "\r\n"
          sb << "Content-Disposition: form-data; name=\"" << n << "\"\r\n"
          sb << "\r\n"
          sb << sanitize_value(v) << "\r\n"
        end
      end
    end

    # Last occurrence of `needle` in `haystack`, byte-wise (String#rindex would corrupt a
    # non-UTF-8 body). Taking the LAST match makes a boundary literal inside binary part data
    # harmless — only a trailing epilogue can follow the real close delimiter.
    private def self.last_index_of(haystack : Bytes, needle : Bytes) : Int32?
      return nil if needle.empty? || needle.size > haystack.size
      i = haystack.size - needle.size
      while i >= 0
        return i if haystack[i, needle.size] == needle
        i -= 1
      end
      nil
    end

    private def self.ends_with_crlf?(body : Bytes) : Bool
      body.size >= 2 && body[body.size - 2] == 0x0d_u8 && body[body.size - 1] == 0x0a_u8
    end

    # ── json (object + nested objects + array roots) ─────────────────────────────────

    private def self.inject_json(request : Bytes, params : Array({String, String})) : Bytes
      head, body, eol = split(request)
      new_body = inject_json_text(String.new(body).scrub, params)
      return request unless new_body
      io = IO::Memory.new(head.size + new_body.bytesize + eol.bytesize * 2)
      io.write(head)
      io << eol << eol << new_body
      io.to_slice
    end

    # Inject candidate keys into EVERY object node of the JSON body — the root object, objects
    # inside a root array, and nested objects — capped BFS shallow-first (MAX_JSON_NODES). Returns
    # nil when the body carries no object node (array-of-scalars / scalar / bool / null root),
    # leaving it unchanged (Detect won't offer Json there; this only guards a hand-driven call).
    # A body that doesn't cleanly parse falls back to the top-level textual `{`-splice.
    def self.inject_json_text(btext : String, params : Array({String, String})) : String?
      begin
        any = JSON.parse(btext)
        nodes = collect_object_nodes(any, MAX_JSON_NODES)
        return nil if nodes.empty?
        nodes.each { |node| params.each { |(n, v)| node[n] = JSON::Any.new(v) } }
        return any.to_json
      rescue JSON::ParseException
        # fall through to the textual splice (nested/array injection needs a real parse)
      end
      bi = btext.index('{')
      return nil unless bi
      after = btext[(bi + 1)..]
      sep = after.lstrip.starts_with?('}') ? "" : ","
      inserts = params.map { |(n, v)| "#{n.to_json}:#{v.to_json}" }.join(',')
      "#{btext[0..bi]}#{inserts}#{sep}#{after}"
    end

    # Object-hash nodes reachable from `any`, BFS (shallow-first), capped at `cap`. Each returned
    # hash is the BACKING store of a JSON::Any (a reference), so mutating it in place persists
    # through `any.to_json`. Iterative (Deque) so an adversarially deep body can't blow the stack.
    private def self.collect_object_nodes(any : JSON::Any, cap : Int32) : Array(Hash(String, JSON::Any))
      out = [] of Hash(String, JSON::Any)
      queue = Deque(JSON::Any){any}
      until queue.empty? || out.size >= cap
        node = queue.shift
        if h = node.as_h?
          out << h
          h.each_value { |v| queue << v }
        elsif a = node.as_a?
          a.each { |v| queue << v }
        end
      end
      out
    end

    # How many injectable object nodes the body carries (capped). Shared by Detect (is Json
    # applicable?) and the engine (per-name bucket byte-budget), so the two never drift.
    def self.json_object_node_count(body : Bytes, cap : Int32) : Int32
      collect_object_nodes(JSON.parse(String.new(body).scrub), cap).size
    rescue JSON::ParseException
      0
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

    # A multipart field name sits in a quoted `name="…"`, so it may contain far more than an HTTP
    # token (real params like `user[id]`, `a/b`, `x:y` are common) — token_char? is intentionally
    # NOT reused. Reject only what breaks the Content-Disposition line or smuggles frames: the
    # quote itself, a backslash escape (RFC 7578 discourages it; naive parsers mishandle), the CD
    # param separator `;`, and any control char (covers CR/LF).
    def self.valid_multipart_name?(name : String) : Bool
      return false if name.empty? || name.bytesize > 256
      name.each_char do |c|
        return false if c == '"' || c == '\\' || c == ';'
        return false if c.ord < 0x20 || c.ord == 0x7f
      end
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
