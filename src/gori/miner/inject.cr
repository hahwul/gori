require "uri"
require "json"
require "mime/multipart"
require "./types" # Location, which apply's own signature names
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
      apply_with_spans(request, location, params, add_cl_when_missing)[0]
    end

    # `apply`, PLUS the byte spans in the RETURNED bytes that hold the injected candidate
    # names and values (final, post Content-Length sync offsets). A send seam marks those
    # `verbatim` so a `$NAME` an operator's wordlist carries — or any injected byte that
    # collides with a live session binding — is NOT expanded to the real credential on the
    # way to the target and reported back as a clean `0 errors` run. This is the same role
    # `Fuzz::Job#payload_spans` plays for the Fuzzer (the round-5 fix); the miner reaches the
    # send seam through here rather than through the fuzz Generator, so it needs its own spans.
    #
    # Only the INJECTED regions are protected: the seed's OWN `$BINDING` placeholders (the
    # operator's captured request) lie outside every span and still resolve at send. The
    # spans come out sorted and disjoint — what `Env.expand_bindings`' single-cursor walk
    # requires — and a location that injects nothing returns an empty list.
    def self.apply_with_spans(request : Bytes, location : Location,
                              params : Array({String, String}),
                              add_cl_when_missing : Bool = false) : {Bytes, Array({Int32, Int32})}
      return {request, [] of {Int32, Int32}} if params.empty?
      case location
      in Location::Query     then inject_query(request, params)
      in Location::Form      then sync_spans(inject_form(request, params), add_cl_when_missing)
      in Location::Multipart then sync_spans(inject_multipart(request, params), add_cl_when_missing)
      in Location::Json      then sync_spans(inject_json(request, params), add_cl_when_missing)
      in Location::Headers   then inject_headers(request, params)
      in Location::Cookies   then inject_cookies(request, params)
      end
    end

    # Content-Length sync over a freshly injected BODY, carrying the injected spans across
    # the rewrite. The head's CL line can change length, moving every body offset by `delta`
    # from `at` on — the exact shift `Fuzz::Generator#shift_spans` applies, for the exact
    # reason: this rewrite happens between the splice and the socket, so a caller holding
    # pre-sync offsets cannot re-derive them. A span at or past `at` moves; one before it
    # (there is none here — every injected span lives in the body, well past the head) stays.
    private def self.sync_spans(pair : {Bytes, Array({Int32, Int32})},
                                add_when_missing : Bool) : {Bytes, Array({Int32, Int32})}
      bytes, spans = pair
      synced, at, delta = Fuzz::ContentLength.sync_at(bytes, add_when_missing)
      spans = spans.map { |(a, b)| a >= at ? {a + delta, b + delta} : {a, b} } unless delta == 0
      {synced, spans}
    end

    # ── head/body split (own copy of Fuzz::ContentLength's left-to-right scan) ────────

    # {head bytes (no trailing blank line), body bytes, line ending}. A request with no
    # blank line is treated as all-head with an empty body.
    def self.split(request : Bytes) : {Bytes, Bytes, String}
      sep, sep_w, eol = boundary(request)
      if sep.nil?
        # "no trailing blank line" is this method's stated contract, and the no-boundary
        # branch was breaking it: the whole request came back INCLUDING its last line
        # terminator, so `inject_headers`/`inject_cookies` (which append `head + eol + line`)
        # completed a blank line and wrote their header into the BODY. `inject_query` rewrites
        # the request line in place, which is why the three disagreed on the same input.
        return {chomp_eol(request), Bytes.empty, "\r\n"}
      end
      head = request[0, sep]
      body_start = sep + sep_w
      body = request[body_start, request.size - body_start]
      {head, body, eol}
    end

    # `bytes` without ONE trailing CRLF or LF. Byte-level and single: the head's own last line
    # terminator is what `split` must not hand back, and eating more would delete a header.
    private def self.chomp_eol(bytes : Bytes) : Bytes
      return bytes if bytes.empty? || bytes[bytes.size - 1] != 0x0a_u8
      drop = bytes.size >= 2 && bytes[bytes.size - 2] == 0x0d_u8 ? 2 : 1
      bytes[0, bytes.size - drop]
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

    # ── query ───────────────────────────────────────────────────────────────────────

    private def self.inject_query(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      nl = request.index(0x0a_u8)
      return {request, [] of {Int32, Int32}} unless nl
      first = String.new(request[0, nl]).rstrip('\r')
      parts = first.split(' ')
      return {request, [] of {Int32, Int32}} unless parts.size == 3
      extra = encode_pairs(params)
      target = parts[1]
      sep = query_separator(target)
      eol = (nl > 0 && request[nl - 1] == 0x0d_u8) ? "\r\n" : "\n"
      io = IO::Memory.new(request.size + extra.bytesize + 8)
      io << parts[0] << ' ' << target << sep
      start = io.pos.to_i32
      io << extra
      span = {start, io.pos.to_i32}
      io << ' ' << parts[2] << eol
      rest_at = nl + 1
      io.write(request[rest_at, request.size - rest_at])
      {io.to_slice, [span]}
    end

    # The join byte that appends `extra` to the request target: `?` when there is no query
    # yet, nothing when the target already ends in `?`/`&`, `&` otherwise. Split out from the
    # old `append_query` so the injected span starts exactly AFTER this separator (the
    # separator is framing gori wrote, not an injected candidate byte).
    private def self.query_separator(target : String) : String
      if !target.includes?('?')
        "?"
      elsif target.ends_with?('?') || target.ends_with?('&')
        ""
      else
        "&"
      end
    end

    # ── form (application/x-www-form-urlencoded) ─────────────────────────────────────

    # Applicable only when there's an existing urlencoded-form body to append params to —
    # the same test Detect uses to decide whether Form is offered at all (see detect.cr).
    # A bodyless (or non-form) request has no Content-Type to splice params under and no
    # body shape to preserve, so injecting here would fabricate a framing-broken request:
    # a body with no Content-Length and no Content-Type header at all. Bail out unmodified
    # instead, same as inject_multipart/inject_json do when their location doesn't apply.
    private def self.inject_form(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      head, body, eol = split(request)
      return {request, [] of {Int32, Int32}} if body.empty?
      ct = (header_value(request, "content-type") || "").downcase
      return {request, [] of {Int32, Int32}} unless ct.includes?("x-www-form-urlencoded")
      extra = encode_pairs(params)
      # The body is spliced through as bytes. It used to be copied into a String, then again by
      # the interpolation that joined it to `extra`, then a third time into the IO — and the
      # trailing-'&' test is a single byte compare that needs no String at all.
      io = IO::Memory.new(head.size + body.size + extra.bytesize + eol.bytesize * 2 + 1)
      io.write(head)
      io << eol << eol
      unless body.empty?
        io.write(body)
        io << '&' unless body[body.size - 1] == 0x26_u8 # '&'
      end
      start = io.pos.to_i32
      io << extra
      {io.to_slice, [{start, io.pos.to_i32}]}
    end

    # Encoded straight into one builder. The map/join form allocated two encoded Strings plus an
    # interpolated third PER PAIR, plus the intermediate Array, before join copied them all again
    # — and a bucket is up to 256 pairs, rebuilt for every probe the bisection sends.
    private def self.encode_pairs(params : Array({String, String})) : String
      String.build do |io|
        params.each_with_index do |(n, v), i|
          io << '&' if i > 0
          URI.encode_www_form(n, io)
          io << '='
          URI.encode_www_form(v, io)
        end
      end
    end

    # ── multipart/form-data ──────────────────────────────────────────────────────────

    # Append candidate fields to a multipart body, byte-exact otherwise. We REUSE the
    # request's existing boundary and splice the new parts in just before the LAST
    # `--boundary--` close delimiter (not MIME::Multipart::Builder, which would mint a fresh
    # boundary and force a Content-Type rewrite + re-serialization that mangles binary parts).
    # Multipart is ALWAYS CRLF internally (RFC 7578), regardless of the head's EOL.
    private def self.inject_multipart(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      raw_ct = header_value(request, "content-type") # ORIGINAL case — the boundary is case-sensitive
      return {request, [] of {Int32, Int32}} unless raw_ct
      boundary = MIME::Multipart.parse_boundary(raw_ct)
      return {request, [] of {Int32, Int32}} if boundary.nil? || boundary.empty?

      additions = build_multipart_parts(boundary, params)
      return {request, [] of {Int32, Int32}} if additions.empty?

      head, body, eol = split(request)
      io = IO::Memory.new(head.size + body.size + additions.bytesize + eol.bytesize * 2 + 16)
      io.write(head)
      io << eol << eol

      # The whole injected `additions` block is candidate content (Content-Disposition
      # framing gori wrote plus the injected names/values) — mark it all verbatim: no injected
      # byte is ever scanned for a `$NAME`, and the framing carries none.
      start = 0
      stop = 0
      close = "--#{boundary}--".to_slice
      if ci = last_index_of(body, close)
        io.write(body[0, ci])
        # A boundary delimiter must be preceded by CRLF; a well-formed body already ends the
        # prior part with it (so this no-ops), but a synthesised/edited body might not.
        io << "\r\n" unless ci >= 2 && body[ci - 2] == 0x0d_u8 && body[ci - 1] == 0x0a_u8
        start = io.pos.to_i32
        io << additions # each appended part already ends with CRLF
        stop = io.pos.to_i32
        io.write(body[ci, body.size - ci]) # the close delimiter + any epilogue, verbatim
      else
        # Malformed (no close delimiter) or empty body: synthesise a well-formed tail so the
        # baseline and test requests differ only by the injected fields.
        unless body.empty?
          io.write(body)
          io << "\r\n" unless ends_with_crlf?(body)
        end
        start = io.pos.to_i32
        io << additions
        stop = io.pos.to_i32
        io << "--" << boundary << "--\r\n"
      end
      {io.to_slice, [{start, stop}]}
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

    # First occurrence of `needle` at or after `from`, byte-wise (String#index would corrupt a
    # non-UTF-8 body). Used to locate an injected JSON fragment whose final offset only exists
    # after `any.to_json` has reserialized the whole body.
    private def self.forward_index_of(haystack : Bytes, needle : Bytes, from : Int32) : Int32?
      return nil if needle.empty? || needle.size > haystack.size
      i = from < 0 ? 0 : from
      last = haystack.size - needle.size
      while i <= last
        return i if haystack[i, needle.size] == needle
        i += 1
      end
      nil
    end

    # Sort spans by start and fold any that touch or overlap into one. `Env.expand_bindings`
    # walks the verbatim list with a single forward cursor, so it requires sorted + disjoint
    # ranges; only the JSON path can emit incidentally overlapping fragments, but every caller
    # runs this so the invariant holds uniformly.
    private def self.merge_spans(spans : Array({Int32, Int32})) : Array({Int32, Int32})
      return spans if spans.size <= 1
      sorted = spans.sort_by! { |(a, _)| a }
      out = [] of {Int32, Int32}
      cs, ce = sorted[0]
      sorted.each_with_index do |(a, b), i|
        next if i == 0
        if a <= ce
          ce = b if b > ce
        else
          out << {cs, ce}
          cs, ce = a, b
        end
      end
      out << {cs, ce}
      out
    end

    # ── json (object + nested objects + array roots) ─────────────────────────────────

    private def self.inject_json(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      head, body, eol = split(request)
      new_body = inject_json_body(body, params)
      return {request, [] of {Int32, Int32}} unless new_body
      io = IO::Memory.new(head.size + new_body.size + eol.bytesize * 2)
      io.write(head)
      io << eol << eol
      io.write(new_body)
      out = io.to_slice

      # A JSON candidate is reserialized (`any.to_json`) or textually spliced, so its final
      # position is only known after the fact: locate every injected `"name":"value"` fragment
      # in the new body (the SAME spelling both paths emit — `n.to_json`/`v.to_json`, no space,
      # Crystal-compact). A name is injected into every object node, so a fragment can recur;
      # each occurrence is a span. Values are canaries here (unique), so a fragment cannot
      # collide with pre-existing body content, and merge_spans folds any incidental overlap so
      # the list stays sorted+disjoint for `Env.expand_bindings`' cursor.
      body_off = head.size + eol.bytesize * 2
      spans = [] of {Int32, Int32}
      params.each do |(n, v)|
        frag = "#{n.to_json}:#{v.to_json}".to_slice
        from = 0
        while idx = forward_index_of(new_body, frag, from)
          spans << {body_off + idx, body_off + idx + frag.size}
          from = idx + frag.size
        end
      end
      {out, merge_spans(spans)}
    end

    # The new JSON body for `body`, or nil when this location has nothing to inject into.
    # Bytes in, bytes out.
    #
    # BYTE SAFETY — read before reaching for `String.new(body).scrub` here, which is exactly
    # what this used to hand `inject_json_text`. `body` can be a CAPTURE (the miner's `--flow`
    # / MCP `flow_id` road) and may legitimately not be valid UTF-8: a latin-1 form field, a
    # binary blob a lax server accepts inside a JSON string. `String#scrub` substitutes the
    # three bytes of U+FFFD for every byte that is not valid UTF-8, and the miner then SENT
    # that. Measured through `Inject.apply`, body `{"q":"hi","bin":"<ff fe 01 02>"}`:
    #
    #   before  … 62 69 6e 22 3a 22 ef bf bd ef bf bd 01 02 22 7d   4 captured bytes → 8
    #   after   … 62 69 6e 22 3a 22 ff fe 01 02 22 7d               intact
    #
    # …while the FORM location on the same shape was already byte-exact, which is the control.
    #
    # A body that is not valid UTF-8 cannot round-trip through `JSON::Any` AT ALL — `JSON.parse`
    # takes a String and `any.to_json` emits one — so it takes the road a body that does not
    # cleanly parse already takes: the top-level `{`-splice, done on BYTES here so every
    # captured byte survives. And `json_object_node_count`, the gate `Detect` asks, reports 0
    # for such a body, so the Json location is not OFFERED for it and `gori run mine` names it
    # skipped (`warn_mine_locations`) instead of quietly mining a request it had rewritten.
    private def self.inject_json_body(body : Bytes, params : Array({String, String})) : Bytes?
      text = String.new(body)
      return splice_json_object(body, params) unless text.valid_encoding?
      inject_json_text(text, params).try(&.to_slice)
    end

    # The top-level `{`-splice on BYTES: the pairs go in right after the FIRST `{`, every other
    # byte of `body` copied through verbatim. Same spelling and same position as the String
    # fallback in `inject_json_text` produces, so the two paths agree; this one exists for the
    # bodies `JSON::Any` cannot hold. nil when there is no `{` to splice into.
    private def self.splice_json_object(body : Bytes, params : Array({String, String})) : Bytes?
      bi = forward_index_of(body, "{".to_slice, 0)
      return nil unless bi
      at = bi + 1
      inserts = params.map { |(n, v)| "#{n.to_json}:#{v.to_json}" }.join(',')
      sep = closes_immediately?(body, at) ? "" : ","
      io = IO::Memory.new(body.size + inserts.bytesize + 1)
      io.write(body[0, at])
      io << inserts << sep
      io.write(body[at, body.size - at])
      io.to_slice
    end

    # Whether the object just spliced into closes immediately (only JSON whitespace between
    # `from` and its `}`) — then the inserted pairs need no trailing comma. This is what the
    # String fallback spells `after.lstrip.starts_with?('}')`.
    private def self.closes_immediately?(body : Bytes, from : Int32) : Bool
      i = from
      while i < body.size
        b = body[i]
        return b == 0x7d_u8 unless b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
        i += 1
      end
      false
    end

    # Inject candidate keys into EVERY object node of the JSON body — the root object, objects
    # inside a root array, and nested objects — capped BFS shallow-first (MAX_JSON_NODES). Returns
    # nil when the body carries no object node (array-of-scalars / scalar / bool / null root),
    # leaving it unchanged (Detect won't offer Json there; this only guards a hand-driven call).
    # A body that doesn't cleanly parse falls back to the top-level textual `{`-splice.
    #
    # `btext` must be valid UTF-8 — `inject_json_body` owns that check and routes bytes that
    # are not to `splice_json_object`. Do NOT restore a `scrub` here to make it total.
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
    #
    # 0 for a body that is not valid UTF-8, and NOT via a `scrub`: `JSON.parse` cannot hold
    # those bytes (see `inject_json_body`), so there is no node set to count. The scrubbed
    # parse this used to do answered "yes, N nodes" about a body it had just rewritten — which
    # is how the Json location came to be auto-selected for `application/json` traffic the
    # miner could then only send corrupted. Reporting 0 makes `Detect` stop offering it, so a
    # surface that names it anyway gets the inapplicable-location warning it already has.
    # `splice_json_object` still injects into exactly ONE node on that road, which is what the
    # engine's `{count, 1}.max` byte budget then assumes.
    def self.json_object_node_count(body : Bytes, cap : Int32) : Int32
      text = String.new(body)
      return 0 unless text.valid_encoding?
      collect_object_nodes(JSON.parse(text), cap).size
    rescue JSON::ParseException
      0
    end

    # ── headers ──────────────────────────────────────────────────────────────────────

    # Appending header lines needs no head parsing: the new lines go at the END, so the existing
    # head bytes are copied through verbatim. The old path took String.new(head) (a full copy),
    # split it into a String per line, then rebuild joined them back into another full copy
    # before writing — three passes over the head to append to it.
    private def self.inject_headers(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      head, body, eol = split(request)
      io = IO::Memory.new(head.size + params.size * 48 + body.size + eol.bytesize * 2)
      io.write(head)
      spans = [] of {Int32, Int32}
      params.each do |(n, v)|
        next unless valid_header_name?(n)
        io << eol
        start = io.pos.to_i32
        io << n << ": " << sanitize_value(v)
        spans << {start, io.pos.to_i32}
      end
      io << eol << eol
      io.write(body) unless body.empty?
      {io.to_slice, spans}
    end

    # ── cookies ──────────────────────────────────────────────────────────────────────

    private def self.inject_cookies(request : Bytes, params : Array({String, String})) : {Bytes, Array({Int32, Int32})}
      head, body, eol = split(request)
      lines = String.new(head).split(eol)
      additions = params.compact_map { |(n, v)| valid_cookie_name?(n) ? "#{n}=#{sanitize_value(v)}" : nil }
      return {request, [] of {Int32, Int32}} if additions.empty?
      joined = additions.join("; ")
      idx = lines.index { |l| (c = l.index(':')) && c > 0 && l[0...c].strip.downcase == "cookie" }

      # Byte-identical to the old split/mutate/rebuild, but built through an IO so the injected
      # `joined` span (the added `name=value; …`) is recorded in final offsets. Appended to an
      # existing Cookie line, or added as a fresh one when there is none.
      io = IO::Memory.new(head.size + joined.bytesize + body.size + eol.bytesize * 4 + 16)
      start = 0
      stop = 0
      if idx
        lines.each_with_index do |line, i|
          io << eol if i > 0
          if i == idx
            io << line.rstrip << "; "
            start = io.pos.to_i32
            io << joined
            stop = io.pos.to_i32
          else
            io << line
          end
        end
      else
        lines.each_with_index do |line, i|
          io << eol if i > 0
          io << line
        end
        io << eol << "Cookie: "
        start = io.pos.to_i32
        io << joined
        stop = io.pos.to_i32
      end
      io << eol << eol
      io.write(body) unless body.empty?
      {io.to_slice, [{start, stop}]}
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
