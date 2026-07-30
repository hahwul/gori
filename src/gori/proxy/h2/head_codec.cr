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
