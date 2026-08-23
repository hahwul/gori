require "uri"
require "json"
require "./types"
require "../../miner/types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # The shared INSERTION-POINT model for the active value-injection rules. Before this, each
      # rule (reflected_param, ssti, error_based_sqli, backslash_powered, lfi_param_traversal)
      # re-implemented the same query parsing, value mutation, request rebuild, and dedup-key
      # construction — and most only ever touched query parameters. This module owns that logic
      # once, across query / form / JSON / header / cookie, so a rule declares WHICH locations it
      # cares about and WHAT it does to a value, and nothing else.
      #
      # Two design constraints shape every method here:
      #   * PURITY / equivalence. `enumerate` is a pure function of (detail, opts, locations); a
      #     rule feeds the SAME enumeration into both `dedup_key` and `plan`, so the analyzer's
      #     cheap pre-plan dedup key can never drift from the built plan's (the per-rule
      #     equivalence spec). `enumerate` therefore applies only STRUCTURAL/location gates — the
      #     method gate and the per-rule param cap stay in the rule, applied identically on both
      #     paths.
      #   * BYTE PRESERVATION. Captured bytes may be invalid UTF-8, and a probe must re-send an
      #     operator's untouched fields verbatim (never as U+FFFD). So query/form parsing slices on
      #     byte offsets found by scanning (never scrubs what is re-sent), JSON carries non-injected
      #     fields through as their parsed `JSON::Any`, and header/cookie walking is byte-safe. The
      #     ONE decoded value a rule inspects (`Slot#value`) is exposed UNSCRUBBED; a rule that runs
      #     a PCRE over it scrubs at the point of use (only lfi does).
      module InsertionPoints
        # One injectable EXISTING value in a captured request. `index`/`raw_name`/`raw_value` are
        # the addressing + on-wire bytes `build` needs to splice a new value back and leave every
        # other byte untouched; `name`/`value` are the decoded views a rule reads.
        #
        #   loc       — the insertion surface (query/form/json/headers/cookies).
        #   index     — position in that surface's ORDERED member list: the index into the FULL
        #               `split('&')` list for query/form (so non-slot pairs pass through verbatim)
        #               and the head-line index for headers; -1 for json/cookies, which `build`
        #               re-addresses by `name` (JSON top-level key / cookie crumb name).
        #   name      — DECODED name. Becomes `Param.name` and the dedup token. UNSCRUBBED.
        #   raw_name  — on-wire name, spliced back verbatim.
        #   value     — DECODED current value. UNSCRUBBED — inspection/gating only, never re-sent.
        #   raw_value — on-wire value substring, for byte-preserving RAW prefix/suffix.
        record Slot,
          loc : Miner::Location,
          index : Int32,
          name : String,
          raw_name : String,
          value : String,
          raw_value : String

        # What a rule does to ONE slot's value. Exactly one strategy per change:
        #   REPLACE — `replace` is a DECODED value; `build` encodes it for the slot's location
        #             (URL-encode for query/form, JSON string for json, sanitized literal for
        #             header/cookie). Used by reflected_param (canary+marker) and ssti (polyglot).
        #   RAW     — `prefix`/`suffix` are WIRE-READY text wrapped around the slot's raw_value with
        #             NO decode/re-encode, so bytes are preserved exactly (`42` + `%27%22` stays
        #             `42%27%22`, never double-encoded). Used by error_based_sqli / backslash_powered
        #             (suffix) and lfi_param_traversal (prefix). JSON honours REPLACE only.
        record Change, replace : String? = nil, prefix : String = "", suffix : String = ""

        # The insertion surfaces the value-injection rules inject by default: the parameter-bearing
        # bodies. Headers/Cookies are NOT here — mutating an existing header/cookie value in the
        # single batched request a rule builds today can clobber Authorization/Content-Type/session
        # and break every OTHER param's probe, so header/cookie injection needs a per-slot multi-probe
        # rule model (a future rule passes an explicit `[..., Headers, Cookies]` list).
        DEFAULT_LOCATIONS = [Miner::Location::Query, Miner::Location::Form, Miner::Location::Json]

        # The empty change-set: `build(detail, NO_CHANGES)` reproduces the original request (a
        # differential rule's baseline). A shared constant so the differential rules don't each
        # re-declare the typed empty array.
        NO_CHANGES = [] of {Slot, Change}

        # Request-semantics-critical headers never offered as injection slots even under aggressive:
        # replacing Authorization breaks auth (the response is an error page, not a reflection) and
        # replacing Content-Type changes how the body is parsed. `valid_header_name?` already drops
        # the hop-by-hop/framing set; this adds the two whose VALUE carries request meaning, not data.
        HEADER_INJECT_SKIP = Set{"authorization", "content-type"}

        # The enumerated request: its method (upcased), origin-form path (no query), and the
        # ordered injectable slots. Slot order is stable — query, then form/json body, then
        # headers, then cookies — so a rule's `.first(cap)` is deterministic and identical between
        # dedup_key and plan.
        record Surface, method : String, path : String, slots : Array(Slot)

        # Enumerate the injectable slots of `detail` across the requested `locations`. Returns nil
        # ONLY when the request line is malformed (the single case every rule declines on). Applies
        # location gates ONLY: Content-Type for form/json, `opts.aggressive` for headers/cookies,
        # and Inject's forbidden/hop-by-hop filter for headers. The method gate and the param cap
        # are the rule's to apply, on both the dedup_key and plan paths.
        def self.enumerate(detail : Store::FlowDetail, opts : Options,
                           locations : Array(Miner::Location)) : Surface?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          path, query = split_target(Active.origin_form(target))
          slots = [] of Slot

          if locations.includes?(Miner::Location::Query)
            each_pair(query) do |idx, raw_name, raw_value|
              slots << Slot.new(Miner::Location::Query, idx, decode(raw_name), raw_name,
                decode(raw_value), raw_value)
            end
          end

          want_form = locations.includes?(Miner::Location::Form)
          want_json = locations.includes?(Miner::Location::Json)
          body = detail.request_body
          if (want_form || want_json) && body && !body.empty?
            # Full head parse ONLY when a body exists — reuse HeaderList#get? so the Content-Type
            # last-match / case-insensitive semantics stay identical to the old per-rule reads. A
            # bodyless query-only GET/HEAD never reaches here, so its dedup key never allocates the
            # header block (the reflected_param fast path).
            ct = content_type(detail.request_head)
            if want_form && ct.includes?("x-www-form-urlencoded")
              # Not `.scrub`: this is the body the probe re-sends. `each_pair` slices on scanned
              # byte offsets, so an untouched field carrying a raw non-UTF-8 byte survives verbatim.
              each_pair(String.new(body)) do |idx, raw_name, raw_value|
                slots << Slot.new(Miner::Location::Form, idx, decode(raw_name), raw_name,
                  decode(raw_value), raw_value)
              end
            elsif want_json && ct.includes?("json")
              each_json_string_key(body) do |k, v|
                slots << Slot.new(Miner::Location::Json, -1, k, k, v, v)
              end
            end
          end

          if opts.aggressive
            want_headers = locations.includes?(Miner::Location::Headers)
            want_cookies = locations.includes?(Miner::Location::Cookies)
            if want_headers || want_cookies
              enumerate_head(detail.request_head, want_headers, want_cookies) { |s| slots << s }
            end
          end

          Surface.new(method_up, path, slots)
        end

        # The dedup key for `slots` — rule + host:PORT + METHOD + path + sorted, length-prefixed
        # `name@location` tokens. Length-prefixing stops a name containing '@'/','/':' from
        # colliding with a different set; sorting makes a reordered query dedup to one probe. This
        # is exactly reflected_param's historic format, now shared so every rule keys the same way.
        def self.dedup_key(rule_id : String, detail : Store::FlowDetail, method_upcase : String,
                           path : String, slots : Array(Slot)) : String
          sig = slots.map { |s| "#{s.name.bytesize}:#{s.name}@#{s.loc.label}" }.sort!.join(",")
          "#{rule_id}|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{sig}"
        end

        # Rebuild `detail`'s request with each (slot ⇒ change) applied and every other byte
        # verbatim, the request line normalized to origin-form, per-location encoding, and
        # Content-Length re-synced once. An EMPTY `changes` reproduces the original request
        # (re-normalized + CL-synced) — the baseline the differential rules send.
        def self.build(detail : Store::FlowDetail, changes : Array({Slot, Change})) : Bytes
          head_bytes, _, eol = Miner::Inject.split(detail.request_head)
          _, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          path, query = split_target(Active.origin_form(target))
          body = detail.request_body
          new_body = body

          # Query: rebuild from the FULL split list so bare flags / empty / no-'=' segments pass
          # through verbatim; splitting-then-joining an unchanged query is the identity.
          q_changes = changes.select { |(s, _)| s.loc.query? }
          unless q_changes.empty? && query.empty?
            pairs = query.split('&')
            q_changes.each { |(s, c)| pairs[s.index] = render_pair(s.raw_name, s.raw_value, c) if s.index < pairs.size }
            query = pairs.join('&')
          end

          # Form body: same pair rewrite over the urlencoded body.
          f_changes = changes.select { |(s, _)| s.loc.form? }
          if !f_changes.empty? && body && !body.empty?
            pairs = String.new(body).split('&')
            f_changes.each { |(s, c)| pairs[s.index] = render_pair(s.raw_name, s.raw_value, c) if s.index < pairs.size }
            new_body = pairs.join('&').to_slice
          end

          # JSON body: re-serialize top-level object with chosen string keys replaced, every other
          # field carried through as its parsed JSON::Any (byte-preserving for untouched fields).
          j_changes = changes.select { |(s, _)| s.loc.json? }
          if !j_changes.empty? && body && !body.empty?
            rebuilt = rebuild_json(body, j_changes)
            new_body = rebuilt if rebuilt
          end

          lines = String.new(head_bytes).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              t = query.empty? ? path : "#{path}?#{query}"
              lines[0] = "#{parts[0]} #{t} #{parts[2]}"
            end
          end

          # Header / cookie value rewrites (aggressive-only surfaces).
          h_changes = changes.select { |(s, _)| s.loc.headers? }
          apply_header_changes(lines, h_changes) unless h_changes.empty?
          c_changes = changes.select { |(s, _)| s.loc.cookies? }
          apply_cookie_changes(lines, c_changes) unless c_changes.empty?

          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          b = new_body || Bytes.empty
          io.write(b) unless b.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end

        # ── internals ────────────────────────────────────────────────────────────────

        # "#{name}=#{value}" for one slot, encoded by strategy. REPLACE URL-encodes the decoded
        # value (space_to_plus:false — a `+` is not universally decoded back to a space, and the
        # markers/polyglots carry chars that must not sit raw on the request line). RAW wraps the
        # ON-WIRE value with no re-encode, so an already-encoded payload stays single-encoded.
        private def self.render_pair(raw_name : String, raw_value : String, change : Change) : String
          if r = change.replace
            "#{raw_name}=#{URI.encode_www_form(r, space_to_plus: false)}"
          else
            "#{raw_name}=#{change.prefix}#{raw_value}#{change.suffix}"
          end
        end

        # Re-serialize a JSON object body with the chosen top-level string fields mutated. nil unless
        # the root parses as an object (matching each_json_string_key, so build never gets a json
        # change on a body that yielded no json slot). REPLACE substitutes the decoded value; RAW
        # wraps the decoded string value with the payload URL-DECODED first — the rules' RAW payloads
        # are URL-wire form (`%27%22`, `%5C`) for the query/form layer, so in a JSON string the
        # decoded character (`'"`, `\`) is what a server actually concatenates into its SQL/template.
        # Not `.scrub`: JSON.parse does not require valid UTF-8 inside a string, and to_json
        # round-trips the untouched fields' bytes as-is.
        private def self.rebuild_json(body : Bytes, changes : Array({Slot, Change})) : Bytes?
          h = begin
            JSON.parse(String.new(body)).as_h?
          rescue JSON::ParseException
            nil
          end
          return nil unless h
          by_name = {} of String => Change
          changes.each { |(s, c)| by_name[s.name] = c }
          merged = {} of String => JSON::Any
          h.each do |k, v|
            if c = by_name[k]?
              if r = c.replace
                merged[k] = JSON::Any.new(r)
              elsif base = v.as_s?
                merged[k] = JSON::Any.new("#{decode(c.prefix)}#{base}#{decode(c.suffix)}")
              else
                merged[k] = v
              end
            else
              merged[k] = v
            end
          end
          merged.to_json.to_slice
        end

        # Yield {full-list index, raw name, raw value} for each valid k=v of an &-joined string.
        # Same skip rules every rule used (empty pair / no '=' / empty name are skipped) — the
        # index counts ALL segments so a rebuilder can pass the skipped ones through untouched.
        private def self.each_pair(text : String, & : Int32, String, String ->)
          return if text.empty?
          text.split('&').each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            name = pair[0...eq]
            next if name.empty?
            yield i, name, pair[(eq + 1)..]
          end
        end

        # Yield {key, string value} for every top-level JSON object field with a string value —
        # the fields reflected_param#canary_json canaries. Not `.scrub`: must read the same bytes
        # build re-serializes, and JSON.parse tolerates non-UTF-8 inside a string value.
        private def self.each_json_string_key(body : Bytes, & : String, String ->)
          h = begin
            JSON.parse(String.new(body)).as_h?
          rescue JSON::ParseException
            nil
          end
          return unless h
          h.each { |k, v| yield k, v.as_s if v.as_s? }
        end

        # Enumerate header / cookie slots from the head bytes. Byte-safe line walk (skips a line
        # that is not valid UTF-8, via the shared Miner::Inject.each_ascii_line) so a binary/garbled
        # header can never make this raise. BOTH headers and cookie crumbs are addressed by NAME
        # (index -1), so `build` locates the target line by matching — a non-UTF-8 line the walk
        # skipped can never desync a positional index. Only names Inject deems injectable qualify
        # (forbidden/hop-by-hop headers excluded), minus the request-semantics-critical HEADER_INJECT_SKIP.
        private def self.enumerate_head(head : Bytes, want_headers : Bool, want_cookies : Bool,
                                        & : Slot ->)
          first = true
          Miner::Inject.each_ascii_line(head) do |line|
            if first
              first = false
              next # request line
            end
            colon = line.index(':')
            next unless colon
            name = line[0...colon].strip
            value = line[(colon + 1)..].strip
            if want_cookies && name.downcase == "cookie"
              value.split(';').each do |crumb|
                eq = crumb.index('=') || next
                cname = crumb[0...eq].strip
                next unless Miner::Inject.valid_cookie_name?(cname)
                cval = crumb[(eq + 1)..].strip
                yield Slot.new(Miner::Location::Cookies, -1, cname, cname, cval, cval)
              end
            elsif want_headers && Miner::Inject.valid_header_name?(name) &&
                  !HEADER_INJECT_SKIP.includes?(name.downcase)
              yield Slot.new(Miner::Location::Headers, -1, name, name, value, value)
            end
          end
        end

        # Rewrite the value of each targeted header, matched by NAME (first case-insensitive match).
        # REPLACE sanitizes CR/LF out of the injected value (header-smuggling guard); RAW wraps the
        # existing value. The name portion (original case + spacing before the colon) is preserved.
        private def self.apply_header_changes(lines : Array(String), changes : Array({Slot, Change}))
          changes.each do |(s, c)|
            target = s.raw_name.downcase
            lines.each_with_index do |line, i|
              next if i == 0
              colon = line.index(':') || next
              next unless line[0...colon].strip.downcase == target
              name_part = line[0...colon]
              newval = c.replace ? Miner::Inject.sanitize_value(c.replace.not_nil!) : "#{c.prefix}#{s.raw_value}#{c.suffix}"
              lines[i] = "#{name_part}: #{newval}"
              break
            end
          end
        end

        # Rewrite the targeted crumb(s) inside the (first) Cookie: header line, matched by name.
        private def self.apply_cookie_changes(lines : Array(String), changes : Array({Slot, Change}))
          by_name = {} of String => Change
          changes.each { |(s, c)| by_name[s.name] = c }
          lines.each_with_index do |line, i|
            colon = line.index(':') || next
            next unless line[0...colon].strip.downcase == "cookie"
            crumbs = line[(colon + 1)..].split(';').map do |crumb|
              eq = crumb.index('=')
              next crumb unless eq
              cname = crumb[0...eq].strip
              c = by_name[cname]? || next crumb
              lead = crumb[0...eq] # preserve any leading space before the name
              newval = c.replace ? Miner::Inject.sanitize_value(c.replace.not_nil!) : "#{c.prefix}#{crumb[(eq + 1)..].strip}#{c.suffix}"
              "#{lead}=#{newval}"
            end
            lines[i] = "#{line[0...colon]}:#{crumbs.join(';')}"
            break
          end
        end

        # The request's Content-Type (last match, case-insensitive, lower-cased), or "".
        private def self.content_type(head : Bytes) : String
          req = Proxy::Codec::Http1.parse_request_head(head)
          (req.headers.get?("Content-Type") || "").downcase
        rescue
          ""
        end

        # {path, query-without-'?'} — query is "" when the target has none.
        private def self.split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

        # Percent-decoded name/value. UNSCRUBBED (a rule that PCREs it scrubs at the point of use).
        private def self.decode(s : String) : String
          URI.decode_www_form(s)
        rescue
          s
        end
      end
    end
  end
end
