require "./hpack"

module Gori::Proxy::H2
  # The bridge between an h2 header block and the HTTP/1.1 head text every other gori
  # surface speaks — the Match&Replace rules included (#492 step 2, decision A).
  #
  # `Rules` operates on head BYTES: it gsubs the whole head as one string and its
  # add/set/remove-header ops split on the head's EOL and skip line 0 as the start line
  # (`rules.cr:246`, `rules.cr:264`). An h2 head has no start line and no `Host:` field, so
  # wiring the rewriter to h2 needs a representation to run the rules against.
  #
  # It is the SYNTHESIZED h1 head, and specifically the one `Assembler` already stores on
  # every h2 flow — because that is the text an operator reads before writing a rule, and
  # the Rewriter tab's "would affect N flows" preview already evaluates rules against
  # exactly those bytes (`rules.cr:331-345` → `detail.request_head`). A field-array-native
  # rewrite path would make the live proxy disagree with its own preview.
  #
  # So `synth_request` / `synth_response` are the single implementation, called from both
  # `Assembler` (capture) and the rewrite path (`HeadRewrite`) — the two cannot drift.
  # `parse_request` / `parse_response` invert them, restoring from the ORIGINAL fields what
  # the h1 text has nowhere to carry: `:scheme`, the §6.2.3 never-indexed markings, and
  # whether the `Host:` line was ours or the peer's.
  #
  # ## The round trip is only sound while it is INJECTIVE (#517)
  #
  # "Invert" holds for a head the text can represent, and NOT for one it cannot: a field value
  # carrying a CRLF comes back as two fields, a duplicate pseudo-header comes back as one, an
  # uppercase name comes back lowercased. Every such input is malformed h2 a conformant peer
  # would REJECT, so the round trip would launder it into a message the far side ACCEPTS —
  # gori promoting the peer's malformed head, a header-injection primitive that exists only
  # because of this bridge. `h1_faithful?` is the precondition that says no; `parse_*` refuse
  # outright rather than trust a caller to ask.
  module HeadCodec
    extend self

    # Synthesized h1-equivalent request head. HTTP/2 carries the target host in the
    # `:authority` pseudo-header (RFC 9113 §8.3.1) rather than a `Host:` field, and the
    # loop below skips ALL pseudo-headers — so without the `Host:` line the head has no
    # host at all, breaking `gori run show` / MCP get_flow / QL `header:host`. Emitted only
    # when the fields carry no explicit (non-pseudo) `host`, which is what makes the
    # mapping reversible: see `parse_request`.
    def synth_request(fields : Array({String, String}), authority : String) : Bytes
      method = pseudo(fields, ":method") || "GET"
      path = pseudo(fields, ":path") || "/"
      String.build do |io|
        io << method << ' ' << path << " HTTP/2\r\n"
        io << "Host: " << authority << "\r\n" if !authority.empty? && !explicit_host?(fields)
        regular(fields) { |n, v| io << n << ": " << v << "\r\n" }
        io << "\r\n"
      end.to_slice
    end

    # Synthesized h1-equivalent response head. h2 has no reason phrase (RFC 9113 §8.3.2),
    # so the status line stops at the code. The code is normalized through `to_i` for the
    # same reason `Assembler` always did: the stored head must not vary with a peer's
    # zero-padded `:status`.
    def synth_response(fields : Array({String, String})) : Bytes
      status = (pseudo(fields, ":status") || "0").to_i? || 0
      String.build do |io|
        io << "HTTP/2 " << status << "\r\n"
        regular(fields) { |n, v| io << n << ": " << v << "\r\n" }
        io << "\r\n"
      end.to_slice
    end

    # Invert `synth_request`. `original` supplies everything the h1 text cannot carry.
    # Returns nil when the rewritten bytes are no longer a head — the caller then forwards
    # the original block unchanged and says so, rather than guessing (#492 decision A).
    def parse_request(head : Bytes, original : Array(HPACK::Field)) : Array(HPACK::Field)?
      return nil unless h1_faithful?(original, request: true)
      start, lines = split_head(head)
      return nil unless start
      method, path = request_line(start)
      return nil unless method && path
      pairs = header_lines(lines)
      return nil unless pairs

      fields_out = request_pseudo(original, method, path, resolve_authority(pairs, original))
      append_regular(fields_out, pairs, original)
      fields_out
    end

    # `synth_request` invents a `Host:` line ONLY when the fields carried no explicit `host`;
    # mirror that exactly, or a request that legitimately carried both would come back with
    # one of them duplicated into the other. Consumes the Host line it maps back, so it does
    # not also survive as a regular field. A rule that REMOVED the line removes `:authority`
    # with it — the operator asked for a request with no authority and gets one, as on h1.
    private def resolve_authority(pairs : Array({String, String}),
                                  original : Array(HPACK::Field)) : String?
      return pseudo_of(original, ":authority") if original.any? { |f| host_field?(f.name) }
      idx = pairs.index { |(n, _)| host_field?(n) }
      idx ? pairs.delete_at(idx)[1] : nil
    end

    # Pseudo-headers keep the ORIGINAL's relative order and its never-indexed markings;
    # RFC 9113 §8.3 only requires that they all precede the regular fields.
    private def request_pseudo(original : Array(HPACK::Field), method : String, path : String,
                               authority : String?) : Array(HPACK::Field)
      fields_out = [] of HPACK::Field
      seen = Set(String).new
      original.each do |f|
        next unless pseudo?(f.name)
        next if seen.includes?(f.name)
        value = case f.name
                when ":method"    then method
                when ":path"      then path
                when ":authority" then authority
                else                   f.value
                end
        next unless value
        seen << f.name
        fields_out << HPACK::Field.new(f.name, value, f.never_indexed?)
      end
      fields_out << HPACK::Field.new(":method", method) unless seen.includes?(":method")
      fields_out << HPACK::Field.new(":path", path) unless seen.includes?(":path")
      fields_out << HPACK::Field.new(":authority", authority) if authority && !seen.includes?(":authority")
      fields_out
    end

    # Invert `synth_response`. See `parse_request`.
    def parse_response(head : Bytes, original : Array(HPACK::Field)) : Array(HPACK::Field)?
      return nil unless h1_faithful?(original, request: false)
      start, lines = split_head(head)
      return nil unless start
      status = status_code(start)
      return nil unless status
      pairs = header_lines(lines)
      return nil unless pairs

      fields_out = [] of HPACK::Field
      seen = false
      original.each do |f|
        next unless pseudo?(f.name)
        if f.name == ":status"
          next if seen
          seen = true
          fields_out << HPACK::Field.new(":status", status, f.never_indexed?)
        else
          fields_out << HPACK::Field.new(f.name, f.value, f.never_indexed?)
        end
      end
      fields_out.unshift(HPACK::Field.new(":status", status)) unless seen
      append_regular(fields_out, pairs, original)
      fields_out
    end

    # Put the ORIGINAL `content-length` back. DATA frames stream untouched (body rewrite is
    # #492 step 5) and h2 validates content-length against the DATA it receives (RFC 9113
    # §8.1.1), so a rule-changed value would RST the stream instead of rewriting anything.
    # The h1 path restores framing headers after a head rewrite for the same reason (#403,
    # `client_conn.cr:1367`); h2 has no Transfer-Encoding to restore alongside it.
    def restore_content_length(fields : Array(HPACK::Field),
                               original : Array(HPACK::Field)) : Array(HPACK::Field)
      orig = original.select { |f| f.name == "content-length" }
      return fields if orig.map(&.value) == fields.select { |f| f.name == "content-length" }.map(&.value)
      fields_out = fields.reject { |f| f.name == "content-length" }
      fields_out.concat(orig)
      fields_out
    end

    # Whether `synth_* -> parse_*` returns these fields UNCHANGED — the precondition the
    # whole rewrite path rests on, and the one #492's hazard table did not state (#517).
    #
    # The h1 head text is a lossy carrier. `synth_*` writes `name: value\r\n` per field and
    # `parse_*` reads it back by splitting on the line ending and cutting at the first `:`,
    # so a field the peer sent can come back as two fields, as none, or as a DIFFERENT
    # well-formed field. Every one of those inputs is malformed h2 (RFC 9113 §8.2.1/§8.3)
    # that a conformant endpoint would REJECT — which is exactly what makes it matter: the
    # round trip would hand the far side a message it accepts, so gori would be laundering
    # the peer's malformed head into a valid one. A header-injection primitive
    # (`set-cookie`, `location`, `x-admin`, ...) that exists only because of the bridge.
    #
    # So the round trip is refused for these fields instead. The caller's disposition is the
    # one an unparseable rewrite already takes: emit the ORIGINAL fields. On an engaged
    # direction that is a re-encode of those fields, not a raw frame passthrough, so the
    # §6.2.1 latch invariant is untouched (`HeadRewrite#finish`) — malformed in, malformed
    # out, and the far side rejects it exactly as it would have without gori.
    #
    # Judged on what the PEER sent, never on what a rule produced. A rule whose replacement
    # contains a CRLF adds two headers here for the same reason it does on h1: those are the
    # operator's bytes, and carrying operator-supplied malformed input is the point (P7).
    #
    # Deliberately conservative in one place: a duplicate pseudo-header is refused in both
    # directions, though only `request_pseudo` drops every duplicate while `parse_response`
    # drops only a second `:status`. Duplicate pseudo-headers are malformed either way.
    def h1_faithful?(fields : Array(HPACK::Field), request : Bool) : Bool
      seen = Set(String).new
      regular = false
      fields.each do |f|
        if pseudo?(f.name)
          # §8.3 puts the pseudo-headers first and `parse_*` re-emits them there, so a peer
          # that sent one AFTER a regular field would get its order corrected. A duplicate is
          # dropped outright by the `seen` guard in `request_pseudo`.
          return false if regular || !seen.add?(f.name)
          return false unless pseudo_faithful?(f, fields, request)
        else
          regular = true
          return false unless regular_faithful?(f)
        end
      end
      request ? request_shape?(fields, seen) : seen.includes?(":status")
    end

    # A regular field survives iff the text can hold it: `header_lines` cuts the line at its
    # FIRST `:` (so a name carrying one renames the field and moves the rest into the value),
    # `strip`s the name and `lstrip(' ')`s the value (so leading whitespace is eaten — a
    # trailing space survives, and is left alone), and `append_regular` lowercases the name.
    # A CR or LF anywhere is a line break in the text: CRLF splits the field in two, a second
    # CRLF truncates the head and drops every field after it, and a lone CR/LF survives here
    # today only because the synthesized EOL happens to be CRLF — the same byte still ends
    # the head early for `StreamGate#split_edit`'s `\n\n` scan on an intercept edit.
    private def regular_faithful?(f : HPACK::Field) : Bool
      name = f.name
      !name.empty? && !name.includes?(':') && !line_broken?(name) &&
        name == name.strip.downcase &&
        !line_broken?(f.value) && !f.value.starts_with?(' ')
    end

    # A pseudo-header survives iff the start line (or the synthetic `Host:` line) can hold it.
    # A pseudo belonging to the OTHER direction — a `:status` on a request, a `:method` on a
    # response — is copied straight off `original`, exactly like `:scheme` and an unknown one,
    # and so cannot be damaged.
    private def pseudo_faithful?(f : HPACK::Field, fields : Array(HPACK::Field), request : Bool) : Bool
      request ? request_pseudo_faithful?(f, fields) : response_pseudo_faithful?(f)
    end

    private def request_pseudo_faithful?(f : HPACK::Field, fields : Array(HPACK::Field)) : Bool
      value = f.value
      case f.name
      when ":method"
        # `request_line` splits the start line on its FIRST space: a method carrying one comes
        # back with its tail moved into `:path`.
        !value.empty? && !value.includes?(' ') && !line_broken?(value)
      when ":path"
        # A CRLF here splits the START line — the injected field lands ahead of every real one.
        !value.empty? && !line_broken?(value)
      when ":authority"
        # Only the SYNTHETIC `Host:` line can damage it; with an explicit `host` field
        # `resolve_authority` preserves `:authority` off the original instead.
        return true if host_carrier?(fields)
        !value.empty? && !value.starts_with?(' ') && !line_broken?(value)
      else
        true
      end
    end

    # `synth_response` normalizes the code through `to_i` so a stored head does not vary with a
    # peer's padding — which also turns a `:status` of `0200` (§8.3.2 requires exactly three
    # digits, so a conformant client rejects it) into an accepted `200`.
    private def response_pseudo_faithful?(f : HPACK::Field) : Bool
      return true unless f.name == ":status"
      (f.value.to_i? || 0).to_s == f.value
    end

    # `synth_request` defaults a missing `:method`/`:path` and `resolve_authority` maps the
    # `Host:` line back to `:authority`, so a request missing any of the three comes back
    # with it INVENTED — §8.3.1 requires all three, so that is another malformed head made
    # acceptable. (`:authority` may legitimately be absent when a `host` field carries it.)
    private def request_shape?(fields : Array(HPACK::Field), seen : Set(String)) : Bool
      seen.includes?(":method") && seen.includes?(":path") &&
        (seen.includes?(":authority") || host_carrier?(fields))
    end

    private def line_broken?(s : String) : Bool
      s.includes?('\r') || s.includes?('\n')
    end

    # `explicit_host?` over decoded fields — the same test `synth_request` makes before it
    # invents a `Host:` line, without building the tuple array to ask it.
    private def host_carrier?(fields : Array(HPACK::Field)) : Bool
      fields.any? { |f| host_field?(f.name) }
    end

    def pseudo(fields : Array({String, String}), name : String) : String?
      fields.find { |(n, _)| n == name }.try(&.[1])
    end

    def pseudo_of(fields : Array(HPACK::Field), name : String) : String?
      fields.find { |f| f.name == name }.try(&.value)
    end

    private def pseudo?(name : String) : Bool
      name.starts_with?(':')
    end

    private def host_field?(name : String) : Bool
      !pseudo?(name) && name.compare("host", case_insensitive: true) == 0
    end

    private def explicit_host?(fields : Array({String, String})) : Bool
      fields.any? { |(n, _)| host_field?(n) }
    end

    private def regular(fields : Array({String, String}), &) : Nil
      fields.each { |(n, v)| yield n, v unless pseudo?(n) }
    end

    # Regular fields in the rewritten head's order, LOWERCASED: an uppercase field name is
    # malformed h2 (RFC 9113 §8.2.1) and would kill the stream where the identical rule
    # works on h1, while field names are case-insensitive by definition so nothing is lost.
    # A §6.2.3 never-indexed marking is carried across the round trip BY NAME — the h1 text
    # has nowhere to hold it, and dropping it would put an `authorization` header the peer
    # asked us to keep out of compression tables back into the ordinary representation.
    # That is propagating a marking the sender actually sent, not guessing from the name.
    private def append_regular(fields_out : Array(HPACK::Field), pairs : Array({String, String}),
                               original : Array(HPACK::Field)) : Nil
      secret = Set(String).new
      original.each { |f| secret << f.name if f.never_indexed? }
      pairs.each do |(name, value)|
        lower = name.downcase
        fields_out << HPACK::Field.new(lower, value, secret.includes?(lower))
      end
    end

    # {start line, header lines}. nil start line = not a head at all.
    private def split_head(head : Bytes) : {String?, Array(String)}
      text = String.new(head)
      eol = text.includes?("\r\n") ? "\r\n" : "\n"
      lines = text.split(eol)
      start = lines.shift?
      return {nil, lines} if start.nil? || start.empty?
      {start, lines}
    end

    # `name: value` per line, stopping at the blank line that ends the head. A non-empty
    # line with no colon is not a header field: the head is unusable and the caller keeps
    # the original block rather than inventing a name for it.
    private def header_lines(lines : Array(String)) : Array({String, String})?
      fields_out = [] of {String, String}
      lines.each do |line|
        break if line.empty?
        idx = line.index(':')
        return nil if idx.nil? || idx == 0
        fields_out << {line[0, idx].strip, line[(idx + 1)..].lstrip(' ')}
      end
      fields_out
    end

    # {method, path} from a rewritten request line. Splits on the FIRST space, and on the
    # LAST one only when the trailing token is a version token — so a `:path` holding a raw
    # space (malformed, but a peer can send one and P7 says we carry it) survives the round
    # trip. Deliberately NOT `Codec::Http1.parse_request_head`, whose `parts.size != 3` rule
    # (`http1.cr:107-120`) would call that line malformed and truncate the path.
    private def request_line(start : String) : {String?, String?}
      sp = start.index(' ')
      return {nil, nil} if sp.nil? || sp == 0
      rest = start[(sp + 1)..]
      if (last = rest.rindex(' ')) && rest[(last + 1)..].starts_with?("HTTP/")
        rest = rest[0, last]
      end
      return {nil, nil} if rest.empty?
      {start[0, sp], rest}
    end

    # The status code out of a rewritten `HTTP/2 404` line. h2 has no reason phrase, so a
    # rule that writes one has it dropped here.
    private def status_code(start : String) : String?
      sp = start.index(' ')
      return nil unless sp
      code = start[(sp + 1)..].lstrip(' ').split(' ').first? || ""
      code.to_i? ? code : nil
    end
  end
end
