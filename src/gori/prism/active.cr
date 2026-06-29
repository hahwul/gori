require "uri"
require "json"
require "./issue"
require "../miner/types"
require "../miner/inject"
require "../fuzz/engine"
require "../fuzz/content_length"
require "../proxy/codec/http1"
require "../proxy/codec/content_decode"

module Gori
  module Prism
    # The lightweight active check: reflected parameters. For one in-scope flow it replaces
    # each existing parameter value (query / form / JSON) with a distinct canary, sends ONE
    # request, and reports the parameters whose canary echoes back unencoded (XSS candidates).
    # Pure: depends only on the Fuzz sender, the codec, and the body decoder — no Store/TUI.
    module Active
      BODY_CAP   = 64 * 1024
      MAX_PARAMS = 50 # don't probe pathological param sets (request-size / canary budget)

      record Param, location : String, name : String, canary : String

      # A built probe: the canary-stuffed request bytes, the canary↔param map, and the
      # dedup key the analyzer uses to probe each (host, path, param-set) only once.
      record Plan, request : Bytes, params : Array(Param), dedup_key : String

      # Build a probe from a captured flow, or nil if there is nothing reflectable.
      def self.plan(detail : Store::FlowDetail) : Plan?
        req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
        return nil if req.malformed?
        path, query = split_target(req.target)

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
        key = "#{detail.row.host}|#{path}|#{params.map(&.name).sort!.join(",")}"
        Plan.new(request, params, key)
      end

      # Send the probe and return any reflected-parameter Detection (one grouped row per host).
      def self.detections(plan : Plan, result : Replay::Result, detail : Store::FlowDetail) : Array(Detection)
        reflected = reflections(result, plan.params)
        return [] of Detection if reflected.empty?
        names = reflected.map { |p| "#{p.name} (#{p.location})" }
        names.uniq!
        url = "#{detail.row.scheme}://#{detail.row.host}#{detail.row.target}"
        [Detection.new("reflected_param", Category::ACTIVE, detail.row.host, url,
          "Reflected parameter", Store::Severity::Medium, names.join(", ")[0, 120], detail.row.id)]
      end

      private def self.reflections(result : Replay::Result, params : Array(Param)) : Array(Param)
        return [] of Param unless result.ok?
        decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body)
        bytes = decoded || result.body
        return [] of Param if bytes.nil? || bytes.empty?
        text = String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        params.select { |p| text.includes?(p.canary) }
      end

      # {path, query-without-'?'} — query is "" when the target has none.
      private def self.split_target(target : String) : {String, String}
        qi = target.index('?')
        return {target, ""} unless qi
        {target[0...qi], target[(qi + 1)..]}
      end

      # Replace every k=v value in an &-joined string with a fresh canary, keeping bare flags
      # and empty segments verbatim. Returns {rebuilt string, params}.
      private def self.canary_pairs(text : String, location : String) : {String, Array(Param)}
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

      private def self.decode_name(name : String) : String
        URI.decode_www_form(name)
      rescue
        name
      end

      # Replace top-level JSON string values with canaries; nil unless the root is an object
      # with at least one string field.
      private def self.canary_json(body : Bytes) : {Bytes?, Array(Param)}
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
      private def self.rebuild(orig_head : Bytes, orig_body : Bytes?, orig_target : String,
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
