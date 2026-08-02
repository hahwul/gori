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
    #
    # `trailers` is `synth_response`'s argument, and it is here for the reason `TRAILER_MARKER`
    # exists at all: a REQUEST trailer block (a gRPC client-streaming call, a `TE: trailers`
    # probe) is merged into the request head by `Assembler#finish_header_block` exactly as a
    # response trailer is, and after the merge it reads like a header the client sent in its
    # head. Whether a target/CDN/WAF treats a trailer as a header is the test the operator came
    # to run, and that question is no less real on the request side. Passed ONLY by the capture
    # projection; the rewrite path re-synthesizes from the live fields and passes nothing, so
    # the fabricated line can never reach an h2 wire.
    #
    # `pushed_by` is the same kind of capture-only line for a request the CLIENT NEVER SENT: a
    # PUSH_PROMISE is the origin inventing a request, and `Assembler#handle_push_promise`
    # projects it as an ordinary flow, so History / QL / the Sitemap handed an operator reading
    # for evidence a row the origin authored, with nothing saying so.
    #
    # `protocol` is the third, and the same discipline again: the loop below skips ALL
    # pseudo-headers, so an RFC 8441 extended CONNECT's `:protocol` — the one field that says
    # a WebSocket is running on this stream — reached no stored byte, and the head read as an
    # ordinary CONNECT tunnel in `gori run show`, HAR and MCP alike. Passed ONLY by the
    # capture projection; the rewrite path re-synthesizes from the live fields and passes
    # nothing, so this line can never reach an h2 wire.
    def synth_request(fields : Array({String, String}), authority : String,
                      trailers : Array(String)? = nil, pushed_by : UInt32? = nil,
                      protocol : String? = nil) : Bytes
      method = pseudo(fields, ":method") || "GET"
      path = pseudo(fields, ":path") || "/"
      String.build do |io|
        io << line_safe(method) << ' ' << line_safe(path) << " HTTP/2\r\n"
        io << "Host: " << line_safe(authority) << "\r\n" if !authority.empty? && !explicit_host?(fields)
        regular(fields) { |n, v| io << line_safe(n) << ": " << line_safe(v) << "\r\n" }
        if trailers && !trailers.empty?
          io << TRAILER_MARKER << ": " << line_safe(trailers.join(", ")) << "\r\n"
        end
        pushed_by.try { |sid| io << PUSHED_MARKER << ": server push promised on stream " << sid << "\r\n" }
        protocol.try do |p|
          io << PROTOCOL_MARKER << ": " << line_safe(p) << "\r\n" unless p.empty?
        end
        io << "\r\n"
      end.to_slice
    end

    # See `synth_request`'s `protocol`: the RFC 8441 `:protocol` pseudo-header, which the
    # pseudo filter drops and the h1 text form has no other place for. Additive, on the
    # stored projection only — same discipline as `TRAILER_MARKER` and `PUSHED_MARKER`.
    PROTOCOL_MARKER = "X-Gori-Protocol"

    # See `synth_request`'s `pushed_by`. Same discipline as `TRAILER_MARKER`: additive, on the
    # stored projection only, so nothing that reads a field off the head changes behaviour and
    # the line can never reach an h2 wire (the rewrite path re-synthesizes from live fields).
    PUSHED_MARKER = "X-Gori-Pushed"

    # The marker line that names which fields of a synthesized h2 response head arrived in a
    # TRAILING HEADERS block rather than the response head (`Assembler` merges the two — that
    # merge is what makes `grpc-status` reachable at all, see `finish_header_block`).
    #
    # After the merge a trailer was INDISTINGUISHABLE from a real response header, and for
    # gRPC the trailer IS the call's real status — while whether a target/CDN/WAF treats a
    # trailer as a header is itself a test the operator came to run. Additive on purpose:
    # renaming or moving the fields would break every consumer that reads `grpc-status` off
    # the parsed head (the Repeater's gRPC status row does exactly that), so the fields stay
    # exactly where they were and this line says which ones they are.
    TRAILER_MARKER = "X-Gori-Trailers"

    # Synthesized h1-equivalent response head. h2 has no reason phrase (RFC 9113 §8.3.2),
    # so the status line stops at the code. The code is normalized through `to_i` for the
    # same reason `Assembler` always did: the stored head must not vary with a peer's
    # zero-padded `:status`.
    #
    # `trailers` names the fields that came from a trailing HEADERS block; it is passed ONLY
    # by the capture projection (`Assembler`). The rewrite path re-synthesizes from the live
    # fields and passes nothing, so this fabricated line can never reach an h2 wire.
    #
    # `synth_request` takes the same argument for the same reason — see its own comment.
    def synth_response(fields : Array({String, String}), trailers : Array(String)? = nil) : Bytes
      status = (pseudo(fields, ":status") || "0").to_i? || 0
      String.build do |io|
        io << "HTTP/2 " << status << "\r\n"
        regular(fields) { |n, v| io << line_safe(n) << ": " << line_safe(v) << "\r\n" }
        if trailers && !trailers.empty?
          io << TRAILER_MARKER << ": " << line_safe(trailers.join(", ")) << "\r\n"
        end
        io << "\r\n"
      end.to_slice
    end

    # Keep the synthesis INJECTIVE at the line level: one h2 field must never become two text
    # lines (#517). `h1_faithful?` is that precondition for `parse_*`/`rewrite`/`encode_edited`,
    # which refuse outright — but `Assembler` calls `synth_*` DIRECTLY to build the stored head,
    # and had no such guard, so a peer field whose value carried a CRLF was projected as two
    # well-formed headers into everything derived from the head: `gori run show`, MCP get_flow,
    # QL `header:`, the Rewriter preview, and the bytes the Repeater/fuzz/mine editors replay
    # from. Response-direction is the dangerous one — the value is the ORIGIN'S, so it is a
    # header-injection primitive handed to whatever replays the projection.
    #
    # Refusing is not available here (a captured flow still has to render), so the CR/LF is
    # escaped instead: the field stays one line, the operator SEES the injected bytes, and the
    # text cannot be re-read as two fields. This is a projection, not the wire — the raw frames
    # remain the truth (P7), and `synth_response` already normalizes `:status` the same way.
    # Every path that could put these bytes back on an h2 wire refuses them before reaching
    # here, so nothing that was byte-exact stops being byte-exact.
    private def line_safe(s : String) : String
      return s unless needs_escape?(s)
      String.build do |io|
        chars = s.each_char.to_a
        chars.each_with_index do |c, i|
          case c
          when '\r' then io << "\\r"
          when '\n' then io << "\\n"
          when '\\'
            # A backslash is escaped ONLY when it could be read back as one of the escapes
            # above. Without this the projection is not injective in the direction that
            # matters: a value carrying the two literal characters `\` `r` rendered
            # identically to one carrying a real CR, and "was this CRLF injected by the
            # origin, or did it always contain that text?" is the question an operator opens
            # this view to ask. Leaving `\` alone before anything else keeps an ordinary
            # `C:\path` or a regex value byte-identical, so a Match&Replace rule written
            # against one still matches.
            #
            # A REAL CR/LF as the next char counts too: it is itself rendered as `\r`/`\n`
            # below, so a lone `\` in front of it would merge into `\\r` — indistinguishable
            # from a literal backslash-r. Escaping the `\` here makes `x\<CR>y` come back as
            # `x\\\ry` (three) versus a literal `x\ry` as `x\\ry` (two).
            nxt = chars[i + 1]?
            io << (nxt == 'r' || nxt == 'n' || nxt == '\\' || nxt == '\r' || nxt == '\n' ? "\\\\" : "\\")
          else io << c
          end
        end
      end
    end

    # `line_safe`'s guard, in one allocation-free pass: a real CR/LF, or a backslash that would
    # be read back as one of its escapes.
    private def needs_escape?(s : String) : Bool
      prev_backslash = false
      s.each_char do |c|
        return true if c == '\r' || c == '\n'
        return true if prev_backslash && (c == 'r' || c == 'n' || c == '\\')
        prev_backslash = c == '\\'
      end
      false
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
    #
    # ## Only for bytes gori produced, never for bytes the operator authored
    #
    # That argument is a RULE's. It is not an intercept edit's: on h1 the same edit is
    # forwarded byte-exact and the comment there says why — "the proxy must not rewrite bytes
    # the human chose to send (e.g. a deliberately CL-mismatched smuggling probe)"
    # (`client_conn.cr`). Whether a given origin/CDN/WAF/gRPC gateway actually enforces §8.1.1
    # is PRECISELY the probe an operator opens the intercept editor to run, and reverting their
    # value made it unexpressible on the live h2 path — silently, with the surface reporting
    # success. So the caller decides: `HeadRewrite#rewrite` restores, `#encode_edited` restores
    # only when the surface that produced the bytes recomputed the value itself (the TUI
    # editor's `^L`), which on a head-only hold would otherwise declare `content-length: 0`
    # beside DATA gori is still going to relay.
    #
    # Restored IN PLACE. Rejecting and re-appending moved `content-length` to the END of the
    # field list, so a rule that touched an unrelated header silently reordered the head on the
    # wire — a change gori made, that nothing displayed, in the one field order a header-order
    # probe is about.
    def restore_content_length(fields : Array(HPACK::Field),
                               original : Array(HPACK::Field)) : Array(HPACK::Field)
      orig = original.select { |f| f.name == "content-length" }
      return fields if orig.map(&.value) == fields.select { |f| f.name == "content-length" }.map(&.value)
      fields_out = [] of HPACK::Field
      taken = 0
      fields.each do |f|
        if f.name == "content-length"
          # Positional replacement while the original has one left to give; a rule that ADDED
          # a `content-length` the peer never sent has its extra occurrences dropped, which is
          # the same disposition the old reject-then-append had.
          if o = orig[taken]?
            fields_out << o
            taken += 1
          end
        else
          fields_out << f
        end
      end
      # The peer sent more than the rewritten head kept (a rule removed the line). Those go
      # back at the end — there is no position left to restore them to.
      fields_out.concat(orig[taken..]) if taken < orig.size
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
      h1_unfaithful_reason(fields, request).nil?
    end

    # `h1_faithful?`, but it says WHICH field and WHY — nil when the round trip is sound.
    #
    # The refusal above is correct and deliberate; what cost an operator a live test was that it
    # was invisible. An intercept edit on such a message was accepted by the surface and thrown
    # away here, and "gori will not apply an edit to this message" is a fact known the moment
    # the head is decoded, so it can be told BEFORE the operator writes one. A refusal has to
    # name its real cause, and "the peer's head has no HTTP/1.1 text form" names a class, not a
    # cause — the operator needs to read `x-evil` and `CR/LF` to connect it to the injection
    # sink they just probed.
    #
    # First offender wins: with a CRLF reflected into three headers the operator fixes the same
    # thing three times either way, and one field name is a sentence a CLI ack can carry.
    def h1_unfaithful_reason(fields : Array(HPACK::Field), request : Bool) : String?
      seen = Set(String).new
      regular = false
      fields.each do |f|
        if pseudo?(f.name)
          # §8.3 puts the pseudo-headers first and `parse_*` re-emits them there, so a peer
          # that sent one AFTER a regular field would get its order corrected. A duplicate is
          # dropped outright by the `seen` guard in `request_pseudo`.
          return "the pseudo-header #{f.name} arrives after a regular field, and the h1 text " \
                 "form would silently move it back in front (RFC 9113 §8.3)" if regular
          return "the pseudo-header #{f.name} appears more than once, and the h1 text form " \
                 "carries only one of them" unless seen.add?(f.name)
          if reason = pseudo_reason(f, fields, request)
            return reason
          end
        else
          regular = true
          if reason = regular_reason(f)
            return reason
          end
        end
      end
      request ? request_shape_reason(fields, seen) : shape_reason(seen.includes?(":status"), ":status")
    end

    # A regular field survives iff the text can hold it: `header_lines` cuts the line at its
    # FIRST `:` (so a name carrying one renames the field and moves the rest into the value),
    # `strip`s the name and `lstrip(' ')`s the value (so leading whitespace is eaten — a
    # trailing space survives, and is left alone), and `append_regular` lowercases the name.
    # A CR or LF anywhere is a line break in the text: CRLF splits the field in two, a second
    # CRLF truncates the head and drops every field after it, and a lone CR/LF survives here
    # today only because the synthesized EOL happens to be CRLF — the same byte still ends
    # the head early for `StreamGate#split_edit`'s `\n\n` scan on an intercept edit.
    private def regular_reason(f : HPACK::Field) : String?
      name = f.name
      return "a header field has an empty name" if name.empty?
      return "the field name #{name.inspect} contains a colon, and the h1 text form cuts a " \
             "line at its first colon — it would come back as a different field" if name.includes?(':')
      return "the field name #{name.inspect} carries a CR or LF, and the h1 text form would " \
             "read it back as two fields" if line_broken?(name)
      return "the field name #{name.inspect} is not lowercase and trimmed, and the h1 round " \
             "trip normalizes it — a different name would go on the wire" unless name == name.strip.downcase
      return "the value of #{name.inspect} carries a CR or LF, so the h1 text form would read " \
             "it back as two fields (a header-injection primitive — the raw frames are " \
             "untouched and the stored head escapes it)" if line_broken?(f.value)
      return "the value of #{name.inspect} starts with a space, which the h1 round trip eats" if f.value.starts_with?(' ')
      nil
    end

    # A pseudo-header survives iff the start line (or the synthetic `Host:` line) can hold it.
    # A pseudo belonging to the OTHER direction — a `:status` on a request, a `:method` on a
    # response — is copied straight off `original`, exactly like `:scheme` and an unknown one,
    # and so cannot be damaged.
    private def pseudo_reason(f : HPACK::Field, fields : Array(HPACK::Field), request : Bool) : String?
      request ? request_pseudo_reason(f, fields) : response_pseudo_reason(f)
    end

    private def request_pseudo_reason(f : HPACK::Field, fields : Array(HPACK::Field)) : String?
      case f.name
      when ":method"    then method_reason(f.value)
      when ":path"      then path_reason(f.value)
      when ":authority" then host_carrier?(fields) ? nil : authority_reason(f.value)
      end
    end

    # `request_line` splits the start line on its FIRST space: a method carrying one comes back
    # with its tail moved into `:path`.
    private def method_reason(value : String) : String?
      return ":method is empty, and the h1 text form has no way to say so" if value.empty?
      return ":method #{value.inspect} contains a space, and the h1 start line splits on its " \
             "first one — the tail would move into :path" if value.includes?(' ')
      ":method #{value.inspect} carries a CR or LF, which would split the start line" if line_broken?(value)
    end

    # A CRLF here splits the START line — the injected field lands ahead of every real one.
    private def path_reason(value : String) : String?
      return ":path is empty, and the h1 text form would come back with \"/\" invented" if value.empty?
      ":path #{value.inspect} carries a CR or LF, which splits the START line — the injected " \
      "field would land ahead of every real one" if line_broken?(value)
    end

    # Only the SYNTHETIC `Host:` line can damage `:authority`; with an explicit `host` field
    # `resolve_authority` preserves it off the original instead, so the caller skips this.
    private def authority_reason(value : String) : String?
      return ":authority is empty, and the h1 text form has no way to say so" if value.empty?
      return ":authority #{value.inspect} starts with a space, which the Host: round trip eats" if value.starts_with?(' ')
      ":authority #{value.inspect} carries a CR or LF, which the Host: line cannot hold" if line_broken?(value)
    end

    # `synth_response` normalizes the code through `to_i` so a stored head does not vary with a
    # peer's padding — which also turns a `:status` of `0200` (§8.3.2 requires exactly three
    # digits, so a conformant client rejects it) into an accepted `200`.
    private def response_pseudo_reason(f : HPACK::Field) : String?
      return nil unless f.name == ":status"
      return nil if (f.value.to_i? || 0).to_s == f.value
      ":status #{f.value.inspect} is not the normalized form of its code, and the h1 status " \
      "line would launder it into one a client accepts (RFC 9113 §8.3.2 wants exactly three digits)"
    end

    # `synth_request` defaults a missing `:method`/`:path` and `resolve_authority` maps the
    # `Host:` line back to `:authority`, so a request missing any of the three comes back
    # with it INVENTED — §8.3.1 requires all three, so that is another malformed head made
    # acceptable. (`:authority` may legitimately be absent when a `host` field carries it.)
    private def request_shape_reason(fields : Array(HPACK::Field), seen : Set(String)) : String?
      shape_reason(seen.includes?(":method"), ":method") ||
        shape_reason(seen.includes?(":path"), ":path") ||
        shape_reason(seen.includes?(":authority") || host_carrier?(fields), ":authority")
    end

    private def shape_reason(present : Bool, name : String) : String?
      return nil if present
      "the head carries no #{name}, and the h1 text form would come back with one invented " \
      "(RFC 9113 §8.3 requires it)"
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

    # Axis 5 (round 7 F3): a diagnostic is not traffic, and the converse — traffic must not
    # be able to impersonate a diagnostic. `synth_request`/`synth_response` append
    # `TRAILER_MARKER`/`PUSHED_MARKER`/`PROTOCOL_MARKER` into the SAME text namespace an
    # incoming field occupies, and gori deliberately does not enforce RFC 9113 §8.2.1
    # lowercase field names on receive (an `X-Upper` field survives verbatim — right for a
    # test tool), so a hostile origin/CDN/WAF can send a REAL field literally named
    # `X-Gori-Trailers` (gori's exact capitalisation) with an ordinary response — no real
    # trailer block required. Reproduced: `grpcorigin.py --scenario forgemarker` puts
    # `X-Gori-Trailers: grpc-status, grpc-message` in the INITIAL HEADERS, then sends real
    # trailers; the projected head carried the peer's line and gori's own diagnostic back to
    # back, byte-for-byte identical, with nothing distinguishing which is which.
    #
    # So an incoming field whose name collides with a marker (case-insensitively — the
    # marker string comparison, not the wire's lowercase requirement) is renamed BEFORE it
    # reaches the text, the same "stay injective, let the operator SEE the anomaly" discipline
    # `line_safe` already applies to a CRLF in a value (#517): the peer's bytes are still
    # shown, just under a name that cannot collide with gori's own.
    private def peer_field_name(n : String) : String
      reserved_marker?(n) ? "X-Peer-#{n}" : n
    end

    private def reserved_marker?(name : String) : Bool
      name.compare(TRAILER_MARKER, case_insensitive: true) == 0 ||
        name.compare(PUSHED_MARKER, case_insensitive: true) == 0 ||
        name.compare(PROTOCOL_MARKER, case_insensitive: true) == 0
    end

    private def regular(fields : Array({String, String}), &) : Nil
      fields.each { |(n, v)| yield peer_field_name(n), v unless pseudo?(n) }
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
        pair = header_field(line)
        return nil unless pair
        fields_out << pair
      end
      fields_out
    end

    # ONE head line as `{name, value}`, or nil when it is not a header field at all.
    #
    # Public because `Repeater::H2Engine` encodes the SAME h1 text into the SAME h2 fields and
    # had its own copy, which `strip`ped the value on BOTH sides. The two encoders then
    # disagreed about what an operator's `X-Pad: sp   ` means on the wire: the proxy's
    # intercept-edit path sent the trailing space (the RFC 9113 §8.2.1 probe that a conformant
    # peer must reject — the whole point of typing it), the repeater ate it. Sharing the line
    # rule and not the loop is deliberate: this cut is the same everywhere, but "stop at the
    # blank line" belongs to the round trip, and the repeater must instead REFUSE the text
    # after a bare-LF blank rather than silently drop it.
    #
    # See `regular_faithful?` for why the `strip`/`lstrip` asymmetry is what it is.
    def header_field(line : String) : {String, String}?
      idx = line.index(':')
      return nil if idx.nil? || idx == 0
      {line[0, idx].strip, line[(idx + 1)..].lstrip(' ')}
    end

    # {method, path} from a rewritten request line. Splits on the FIRST space, and on the
    # LAST one only when the trailing token is a version token — so a `:path` holding a raw
    # space (malformed, but a peer can send one and P7 says we carry it) survives the round
    # trip. Deliberately NOT `Codec::Http1.parse_request_head`, whose `parts.size != 3` rule
    # (`http1.cr:107-120`) would call that line malformed and truncate the path.
    #
    # Public for the same reason as `header_lines`: `Repeater::H2Engine` had a copy that cut
    # at the LAST space unconditionally, so a version-less `GET /noversion` — what a parser-
    # differential probe writes, and what hand-editing the line in the TUI editor produces —
    # had `last_sp == first_sp`, fell through the ternary, and went out as `:path` `/`.
    def request_line(start : String) : {String?, String?}
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
