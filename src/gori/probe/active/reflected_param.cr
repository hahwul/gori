require "uri"
require "json"
require "./types"
require "../../miner/types"
require "../../miner/inject"
require "../../fuzz/engine"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Reflected parameters. For one in-scope flow it replaces each existing parameter value
      # (query / form / JSON) with a distinct canary, sends ONE request, and reports the
      # parameters whose canary echoes back — grading each by whether the echo was ENCODED.
      # Gated to safe methods so an automatic probe never mutates server state.
      #
      # The canary carries a MARKER of the four characters that decide whether a reflection is
      # exploitable: `"`, `'`, `<`, `>`. An alphanumeric canary on its own cannot answer that
      # question — it survives HTML-escaping unchanged, so "the value came back" was reported
      # identically for a raw injection point and for output a template escaped correctly. Since
      # correct escaping is the norm, that made the common case the finding: nearly every
      # reflecting endpoint scored Medium.
      #
      # Reading which marker characters came back VERBATIM, immediately after the canary, splits
      # them apart:
      #   * `<` survived        — tag injection is possible; the classic XSS candidate.
      #   * only `"` / `'`      — an attribute-context break, exploitable only in some sinks.
      #   * none survived       — the value was escaped, stripped, or encoded. Still worth knowing
      #                           as a reflection point, so it is reported at Info rather than
      #                           dropped, but it is not an XSS finding.
      # A partial survival is read in order, so `"'&lt;&gt;` reports `"'` — an escaped `<` stops
      # the run exactly where the server's filter did.
      class ReflectedParam < Rule
        # Appended to every canary. Sent URL-encoded (query/form) or JSON-escaped (body), so the
        # server decodes real characters; what comes back tells us what its output layer did with
        # them. Order matters: `survived` reads this prefix-wise.
        MARKER = "\"'<>"

        # The full value sent for a canary. Public so specs (and a manual re-send) can reproduce
        # the exact bytes the probe put in the parameter.
        def self.probe_value(canary : String) : String
          canary + MARKER
        end

        def info : RuleInfo
          RuleInfo.new("reflected_param", "Reflected parameter",
            "Sends a canary in query parameters and flags unencoded reflection (potential XSS).",
            Category::ACTIVE)
        end

        # The dedup key WITHOUT generating canaries or rebuilding the request — extracts the same
        # (name, location) set `plan` derives from canary_pairs/canary_json (same skip rules), so
        # the key is byte-identical to `plan(detail).dedup_key`. Returns nil in exactly the cases
        # `plan` does (malformed / unsafe method / no params / too many). Verified against `plan`
        # by the equivalence spec.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # Start-line-only fast path: the key needs only method + target, so a non-eligible method
          # or malformed head is rejected WITHOUT allocating the whole header block. The dominant
          # bodyless GET/HEAD never parses headers; only a request that actually carries a body
          # falls through to a full parse (for Content-Type). Byte-identical to plan's key.
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          path, query = split_target(Active.origin_form(target))
          names = [] of {String, String} # {name, location}, matching Param.{name, location}
          each_param_name(query) { |raw| names << {decode_name(raw), "query"} }
          body = detail.request_body
          if body && !body.empty?
            # Full parse ONLY when a body exists — reuse HeaderList#get? so the Content-Type
            # last-match / case-insensitive semantics stay IDENTICAL to plan's (never hand-rolled).
            req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
            ct = (req.headers.get?("Content-Type") || "").downcase
            if ct.includes?("x-www-form-urlencoded")
              each_param_name(String.new(body).scrub) { |raw| names << {decode_name(raw), "form"} }
            elsif ct.includes?("json")
              each_json_string_key(body) { |k| names << {k, "json"} }
            end
          end
          return nil if names.empty? || names.size > opts.max_params
          build_dedup_key(detail, method_up, path, names)
        end

        # Build a probe from a captured flow, or nil if there is nothing reflectable.
        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless method_allowed?(req.method.upcase, opts)
          # A plaintext forward-proxy flow is captured ABSOLUTE-form ("GET http://h/p"); the
          # probe is sent DIRECT to the origin (Fuzz::Sender → Repeater::Engine, no rewrite),
          # so normalize to origin-form here the way the regular repeater path (FlowRequest)
          # does — some origins reject an absolute-form target on a non-proxied request.
          path, query = split_target(Active.origin_form(req.target))

          params = [] of Param
          new_query, qp = canary_pairs(query, "query")
          params.concat(qp)

          body = detail.request_body
          new_body = body
          if body && !body.empty?
            ct = (req.headers.get?("Content-Type") || "").downcase
            if ct.includes?("x-www-form-urlencoded")
              nb, fp = canary_pairs(String.new(body).scrub, "form")
              params.concat(fp)
              new_body = nb.to_slice
            elsif ct.includes?("json")
              nb, jp = canary_json(body)
              if nb
                params.concat(jp)
                new_body = nb
              end
            end
          end

          return nil if params.empty? || params.size > opts.max_params
          request = rebuild(detail.request_head, path, new_query, new_body)
          # Same key builder `dedup_key` uses, fed the built params — so the pre-build dedup key
          # and this one can't drift.
          key = build_dedup_key(detail, req.method.upcase, path, params.map { |p| {p.name, p.location} })
          Plan.new(request, params, key)
        end

        # Key by rule + host:PORT + METHOD + path + (name@location) so the same host on a different
        # port/service is a distinct surface. Length-prefix each name so a param name containing
        # '@'/','/':' can't collide with a different multi-param set. Sorted → order-independent.
        private def build_dedup_key(detail : Store::FlowDetail, method_upcase : String, path : String,
                                    names : Array({String, String})) : String
          sig = names.map { |(name, loc)| "#{name.bytesize}:#{name}@#{loc}" }.sort!.join(",")
          "reflected_param|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{sig}"
        end

        # The valid k=v names of an &-joined string — the SAME skip rules canary_pairs applies
        # (empty pair / no '=' / empty name are skipped), yielding the RAW (pre-decode) name.
        private def each_param_name(text : String, & : String ->)
          return if text.empty?
          text.split('&').each do |pair|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            name = pair[0...eq]
            next if name.empty?
            yield name
          end
        end

        # The top-level JSON keys with a STRING value — the SAME fields canary_json canaries.
        private def each_json_string_key(body : Bytes, & : String ->)
          h = begin
            JSON.parse(String.new(body).scrub).as_h?
          rescue JSON::ParseException
            nil
          end
          return unless h
          h.each { |k, v| yield k if v.as_s? }
        end

        # Interpret the probe's response: at most ONE Detection, graded by the strongest echo seen
        # (one grouped row per host).
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          hits = reflections(result, plan.params)
          return [] of Detection if hits.empty?
          html = response_content_type(result).includes?("html")
          # Grade on the strongest echo: a raw `<` anywhere outranks a bare quote, which outranks
          # an escaped echo. Only the params at that tier are named, so the evidence describes the
          # finding rather than mixing an injection point in with correctly-escaped output.
          tier, sev, title = grade(hits, html)
          names = hits.select { |(_, s)| tier_of(s) == tier }
            .map { |(p, s)| "#{p.name} (#{p.location}#{s.empty? ? "" : ", #{s} survived"})" }
          names.uniq!
          [Detection.new("reflected_param", Category::ACTIVE, detail.row.host, detail.row.url,
            title, sev, names.join(", ")[0, 120], detail.row.id)]
        end

        # 2 = a raw `<` (tag injection), 1 = a quote only (attribute context), 0 = escaped/stripped.
        private def tier_of(survived : String) : Int32
          return 2 if survived.includes?('<')
          survived.empty? ? 0 : 1
        end

        # {tier, severity, title} for the strongest echo present. Only a raw `<` in an HTML
        # response keeps the historic Medium; an escaped echo is Info — a reflection point worth
        # knowing, not a vulnerability.
        private def grade(hits : Array({Param, String}), html : Bool) : {Int32, Store::Severity, String}
          tier = hits.max_of { |(_, s)| tier_of(s) }
          case tier
          when 2
            if html
              {2, Store::Severity::Medium, "Reflected parameter (unencoded, tag injection possible)"}
            else
              {2, Store::Severity::Low, "Reflected parameter (unencoded, non-HTML context)"}
            end
          when 1
            {1, Store::Severity::Low, "Reflected parameter (quote survived, attribute context)"}
          else
            {0, Store::Severity::Info, "Reflected parameter (escaped or filtered)"}
          end
        end

        # {param, surviving marker characters} for every param whose canary echoed back. Scans BOTH
        # the response head (reflected Location/Set-Cookie/custom headers) and the decoded body —
        # header reflections (e.g. open-redirect Location) are invisible to a body-only scan.
        private def reflections(result : Repeater::Result, params : Array(Param)) : Array({Param, String})
          found = [] of {Param, String}
          # NOTE: not `out` — that is a Crystal keyword (C-binding output parameters), and
          # `return out unless …` parses as the keyword, not the local.
          return found unless result.ok?
          head = String.new(result.head).scrub
          # Canary search only reads the first BODY_CAP bytes, so cap the inflate to match.
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          body = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub : ""
          params.each do |p|
            # Search head and body separately: concatenating them allocated a full copy of both
            # (up to BODY_CAP + head) on every probe just to run one substring scan per param.
            # Take the BEST of the two — a value echoed into several contexts (escaped in the
            # page text, raw inside a script block or a header) is only as safe as its weakest
            # sink, so grading on whichever context preserved the most characters is the correct
            # reading, not merely the first one found.
            best = [survived(head, p.canary), survived(body, p.canary)].compact.max_by?(&.size)
            found << {p, best} if best
          end
          found
        end

        # The MARKER characters that came back VERBATIM right after `canary` in `hay`, read
        # prefix-wise; "" when the canary echoed but every marker character was escaped, stripped,
        # or re-encoded. nil when the canary does not appear at all.
        #
        # Every occurrence is examined, not just the first: the same value routinely lands in more
        # than one place in one response, and the first hit is as likely to be the escaped one as
        # the raw one. Returns the longest surviving prefix across them. Occurrences of a 10-char
        # random canary are few, so the walk is bounded in practice.
        private def survived(hay : String, canary : String) : String?
          from = 0
          best = nil.as(String?)
          while i = hay.index(canary, from)
            tail = i + canary.size
            n = 0
            while n < MARKER.size && (c = hay[tail + n]?) && c == MARKER[n]
              n += 1
            end
            best = MARKER[0, n] if best.nil? || n > best.size
            break if n == MARKER.size # nothing can beat a full survival
            from = tail
          end
          best
        end

        private def response_content_type(result : Repeater::Result) : String
          if r = result.response
            return (r.headers.get?("Content-Type") || "").downcase
          end
          (Proxy::Codec::Http1.parse_response_head(result.head).headers.get?("Content-Type") || "").downcase
        rescue
          ""
        end

        # {path, query-without-'?'} — query is "" when the target has none.
        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

        # Replace every k=v value in an &-joined string with a fresh canary, keeping bare flags
        # and empty segments verbatim. Returns {rebuilt string, params}.
        private def canary_pairs(text : String, location : String) : {String, Array(Param)}
          params = [] of Param
          return {text, params} if text.empty?
          rebuilt = text.split('&').map do |pair|
            next pair if pair.empty?
            eq = pair.index('=')
            next pair unless eq
            name = pair[0...eq]
            next pair if name.empty?
            canary = Miner::Canary.fresh
            params << Param.new(location, decode_name(name), canary)
            # URL-encoded: the marker carries `"'<>`, which have no business sitting raw in a
            # request line (the alnum canary alone needed no encoding). space_to_plus:false for
            # the same reason Ssti#inject uses it — `+` is not universally decoded back to a space.
            "#{name}=#{URI.encode_www_form(ReflectedParam.probe_value(canary), space_to_plus: false)}"
          end.join('&')
          {rebuilt, params}
        end

        private def decode_name(name : String) : String
          URI.decode_www_form(name)
        rescue
          name
        end

        # Replace top-level JSON string values with canaries; nil unless the root is an object
        # with at least one string field.
        private def canary_json(body : Bytes) : {Bytes?, Array(Param)}
          params = [] of Param
          h = begin
            JSON.parse(String.new(body).scrub).as_h?
          rescue JSON::ParseException
            nil
          end
          return {nil, params} unless h
          merged = {} of String => JSON::Any
          h.each do |k, v|
            if v.as_s?
              canary = Miner::Canary.fresh
              params << Param.new("json", k, canary)
              # `to_json` escapes the marker's `"` for the wire; the server decodes it back, so
              # what it reflects is the real character — exactly what `survived` needs to read.
              merged[k] = JSON::Any.new(ReflectedParam.probe_value(canary))
            else
              merged[k] = v
            end
          end
          return {nil, params} if params.empty?
          {merged.to_json.to_slice, params}
        end

        # Reassemble the request with the canary-stuffed request-line + body, re-syncing
        # Content-Length when the body changed.
        private def rebuild(orig_head : Bytes, path : String, new_query : String,
                            new_body : Bytes?) : Bytes
          # detail.request_head always ends in CRLFCRLF (read_head contract) and a well-formed
          # head has no earlier blank line, so Inject.split keys off that terminator regardless
          # of whether the body is appended. Splitting orig_head directly is byte-identical to
          # the old "concat head+body, split, discard the body half" — one alloc+copy fewer.
          head, _, eol = Miner::Inject.split(orig_head)
          lines = String.new(head).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              new_target = new_query.empty? ? path : "#{path}?#{new_query}"
              lines[0] = "#{parts[0]} #{new_target} #{parts[2]}"
            end
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          body = new_body || Bytes.empty
          io.write(body) unless body.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end
      end
    end
  end
end
