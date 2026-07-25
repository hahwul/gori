require "uri"
require "./types"
require "../../miner/types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active CRLF / response-header injection probe. When a query parameter flows unsanitized into a
      # response header (a `Location`, a `Set-Cookie`, a custom header), an attacker who smuggles a
      # `\r\n` splits the response: injecting arbitrary headers (cache-poisoning keys, cookies) or, in
      # older stacks, a whole second response. Passive analysis cannot see a header the browser never
      # provoked.
      #
      # For one in-scope flow it appends a URL-encoded `\r\nGori-Probe: <canary>` to EVERY query
      # parameter value in ONE request, each parameter carrying a DISTINCT canary. It flags High for a
      # parameter whose canary comes back as a REAL parsed response header `Gori-Probe: <canary>`.
      # Confirmation is binary and self-attributing:
      #   * a distinct per-parameter canary tells exactly which parameter split the response, and can
      #     never collide with a pre-existing static `Gori-Probe: 1`;
      #   * the value is read from the PARSED response header list, so a body that merely echoes the
      #     literal `Gori-Probe:` text never counts.
      # A server that percent-decodes but header-sanitizes (the correct behavior) reflects nothing.
      # Gated to safe methods (GET/HEAD) so an automatic probe never mutates state.
      class CrlfInjection < Rule
        # The URL-encoded CR LF + header the payload smuggles into each parameter value. `%0d%0a`
        # decodes to CRLF server-side; `%20` is the space after the colon. `Gori-Probe` is a benign,
        # unique header name — its mere presence in the response proves a split.
        INJECT      = "%0d%0aGori-Probe:%20"
        HEADER_NAME = "Gori-Probe"

        def info : RuleInfo
          RuleInfo.new("crlf_injection", "CRLF header injection",
            "Injects an encoded CRLF + header in query parameters and flags a reflected response header.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          path, query = split_target(Active.origin_form(target))
          names = [] of {String, String}
          each_param_name(query) { |raw| names << {decode_name(raw), "query"} }
          return nil if names.empty? || names.size > opts.max_params
          build_dedup_key(detail, method_up, path, names)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          path, query = split_target(Active.origin_form(target))
          new_query, params = inject_pairs(query)
          return nil if params.empty? || params.size > opts.max_params
          request = rebuild(detail.request_head, path, new_query, detail.request_body)
          key = build_dedup_key(detail, method_up, path, params.map { |p| {p.name, p.location} })
          Plan.new(request, params, key)
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          injected = Proxy::Codec::Http1.parse_response_head(result.head).headers.get_all(HEADER_NAME)
          return [] of Detection if injected.empty?
          # Substring, not equality: a param reflected mid-header (`Location: <value>/dashboard`) makes
          # the split header `Gori-Probe: <canary>/dashboard`, so the canary is a substring, not the whole
          # value. The 10-char random canary keeps a substring match essentially FP-free.
          hits = plan.params.select { |p| injected.any?(&.includes?(p.canary)) }.map(&.name)
          return [] of Detection if hits.empty?
          hits.uniq!
          [Detection.new("crlf_injection", Category::ACTIVE, detail.row.host, detail.row.url,
            "CRLF header injection (response split via parameter)", Store::Severity::High,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Key by rule + host:PORT + METHOD + path + sorted (length-prefixed) name@query set — the same
        # builder ReflectedParam uses, so a reordered query dedups to one probe and a name with ','/':'
        # can't collide.
        private def build_dedup_key(detail : Store::FlowDetail, method_upcase : String, path : String,
                                    names : Array({String, String})) : String
          sig = names.map { |(name, loc)| "#{name.bytesize}:#{name}@#{loc}" }.sort!.join(",")
          "crlf_injection|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{sig}"
        end

        # The valid k=v names of an &-joined query — the SAME skip rules inject_pairs applies (empty
        # pair / no '=' / empty name are skipped), yielding the RAW (pre-decode) name.
        private def each_param_name(query : String, & : String ->)
          return if query.empty?
          query.split('&').each do |pair|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            name = pair[0...eq]
            next if name.empty?
            yield name
          end
        end

        # Append `\r\nGori-Probe: <fresh canary>` (URL-encoded) to each k=v value, a distinct canary
        # per parameter. Returns {rebuilt query, params}.
        private def inject_pairs(query : String) : {String, Array(Param)}
          params = [] of Param
          return {query, params} if query.empty?
          rebuilt = query.split('&').map do |pair|
            next pair if pair.empty?
            eq = pair.index('=')
            next pair unless eq
            name = pair[0...eq]
            next pair if name.empty?
            value = pair[(eq + 1)..]
            canary = Miner::Canary.fresh
            params << Param.new("query", decode_name(name), canary)
            "#{name}=#{value}#{INJECT}#{canary}"
          end.join('&')
          {rebuilt, params}
        end

        private def decode_name(name : String) : String
          URI.decode_www_form(name)
        rescue
          name
        end

        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

        private def rebuild(orig_head : Bytes, path : String, new_query : String, body : Bytes?) : Bytes
          head, _, eol = Miner::Inject.split(orig_head)
          lines = String.new(head).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              target = new_query.empty? ? path : "#{path}?#{new_query}"
              lines[0] = "#{parts[0]} #{target} #{parts[2]}"
            end
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          b = body || Bytes.empty
          io.write(b) unless b.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end
      end
    end
  end
end
