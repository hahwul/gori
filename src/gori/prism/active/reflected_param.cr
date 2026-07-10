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
  module Prism
    module Active
      # Reflected parameters. For one in-scope flow it replaces each existing parameter value
      # (query / form / JSON) with a distinct canary, sends ONE request, and reports the
      # parameters whose canary echoes back unencoded (XSS candidates). Gated to safe methods
      # so an automatic probe never mutates server state.
      class ReflectedParam < Rule
        # The dedup key WITHOUT generating canaries or rebuilding the request — extracts the same
        # (name, location) set `plan` derives from canary_pairs/canary_json (same skip rules), so
        # the key is byte-identical to `plan(detail).dedup_key`. Returns nil in exactly the cases
        # `plan` does (malformed / unsafe method / no params / too many). Verified against `plan`
        # by the equivalence spec.
        def dedup_key(detail : Store::FlowDetail) : String?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless SAFE_METHODS.includes?(req.method.upcase)
          path, query = split_target(Active.origin_form(req.target))
          names = [] of {String, String} # {name, location}, matching Param.{name, location}
          each_param_name(query) { |raw| names << {decode_name(raw), "query"} }
          body = detail.request_body
          if body && !body.empty?
            ct = (req.headers.get?("Content-Type") || "").downcase
            if ct.includes?("x-www-form-urlencoded")
              each_param_name(String.new(body).scrub) { |raw| names << {decode_name(raw), "form"} }
            elsif ct.includes?("json")
              each_json_string_key(body) { |k| names << {k, "json"} }
            end
          end
          return nil if names.empty? || names.size > MAX_PARAMS
          build_dedup_key(detail, req.method.upcase, path, names)
        end

        # Build a probe from a captured flow, or nil if there is nothing reflectable.
        def plan(detail : Store::FlowDetail) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless SAFE_METHODS.includes?(req.method.upcase)
          # A plaintext forward-proxy flow is captured ABSOLUTE-form ("GET http://h/p"); the
          # probe is sent DIRECT to the origin (Fuzz::Sender → Replay::Engine, no rewrite),
          # so normalize to origin-form here the way the regular replay path (FlowRequest)
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

          return nil if params.empty? || params.size > MAX_PARAMS
          request = rebuild(detail.request_head, body, req.target, path, new_query, new_body)
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

        # Interpret the probe's response: any reflected-parameter Detection (one grouped row per host).
        def detections(plan : Plan, result : Replay::Result, detail : Store::FlowDetail) : Array(Detection)
          reflected = reflections(result, plan.params)
          return [] of Detection if reflected.empty?
          names = reflected.map { |p| "#{p.name} (#{p.location})" }
          names.uniq!
          url = detail.row.url
          # An echo in an HTML response is a plausible XSS sink (Medium); an echo in a non-HTML
          # response (JSON/text API) is just a reflected value, not exploitable as XSS (Low).
          html = response_content_type(result).includes?("html")
          sev = html ? Store::Severity::Medium : Store::Severity::Low
          title = html ? "Reflected parameter" : "Reflected parameter (non-HTML context)"
          [Detection.new("reflected_param", Category::ACTIVE, detail.row.host, url,
            title, sev, names.join(", ")[0, 120], detail.row.id)]
        end

        # Scan BOTH the response head (reflected Location/Set-Cookie/custom headers) and the
        # decoded body for each canary — header reflections (e.g. open-redirect Location) are
        # invisible to a body-only scan.
        private def reflections(result : Replay::Result, params : Array(Param)) : Array(Param)
          return [] of Param unless result.ok?
          head = String.new(result.head).scrub
          # Canary search only reads the first BODY_CAP bytes, so cap the inflate to match.
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          body = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub : ""
          hay = "#{head}\n#{body}"
          params.select { |p| hay.includes?(p.canary) }
        end

        private def response_content_type(result : Replay::Result) : String
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
            "#{name}=#{canary}"
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
              merged[k] = JSON::Any.new(canary)
            else
              merged[k] = v
            end
          end
          return {nil, params} if params.empty?
          {merged.to_json.to_slice, params}
        end

        # Reassemble the request with the canary-stuffed request-line + body, re-syncing
        # Content-Length when the body changed.
        private def rebuild(orig_head : Bytes, orig_body : Bytes?, orig_target : String,
                            path : String, new_query : String, new_body : Bytes?) : Bytes
          combined = if orig_body && !orig_body.empty?
                       io = IO::Memory.new(orig_head.size + orig_body.size)
                       io.write(orig_head)
                       io.write(orig_body)
                       io.to_slice
                     else
                       orig_head
                     end
          head, _, eol = Miner::Inject.split(combined)
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
