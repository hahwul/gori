require "json"
require "yaml"
require "uri"
require "./builder"

module Gori
  module Import
    module Oas
      HTTP_METHODS = %w(get post put patch delete head options trace)

      def self.parse_file(path : String) : ParseResult
        raw = File.read(path)
        json_raw = case File.extname(path).downcase
                   when ".yaml", ".yml"
                     begin
                       YAML.parse(raw).to_json
                     rescue ex : YAML::ParseException
                       raise Gori::Error.new("OpenAPI spec is not valid YAML: #{ex.message}")
                     end
                   else
                     raw
                   end
        spec = begin
          JSON.parse(json_raw)
        rescue ex : JSON::ParseException
          raise Gori::Error.new("OpenAPI spec is not valid JSON: #{ex.message}")
        end
        paths = spec["paths"]?
        raise Gori::Error.new("OpenAPI spec missing paths") unless paths
        # A `paths` that isn't an object (null / string / array) is a malformed spec, not
        # a valid-but-empty one — raise a clean error rather than a raw JSON type-cast.
        paths_h = paths.as_h? || raise Gori::Error.new("OpenAPI spec `paths` is not an object")
        base = server_base(spec)
        schemes = api_key_header_schemes(spec)
        root_security = spec["security"]?
        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        paths_h.each do |path, item|
          HTTP_METHODS.each do |m|
            # A path item / operation that isn't shaped as expected (null, string, array)
            # skips rather than aborting the whole spec import with a raw type-check error.
            op = item[m]? rescue nil
            next unless op
            begin
              pairs << operation_to_flow(now, base, path.to_s, m, op, item, schemes, root_security)
            rescue
              skipped += 1
            end
          end
        end
        ParseResult.new(pairs, skipped)
      end

      private def self.server_base(spec : JSON::Any) : String
        servers = spec["servers"]?
        if servers && (arr = servers.as_a?) && (first = arr[0]?)
          url = first["url"]?.to_s
          raise Gori::Error.new("OpenAPI spec has no servers[0].url") if url.empty?
          # A relative server URL (e.g. "/v3") has no host authority: every generated
          # request would prepend "https://" onto a leading "/", yielding an empty host
          # ("https:///v3/...") that Builder.endpoint rejects — so EVERY operation would
          # be skipped and the import would fail with an opaque "no flows found". Report
          # the real, actionable reason here, up front, instead.
          if url.starts_with?('/')
            raise Gori::Error.new(%(OpenAPI servers[0].url is relative (#{url.inspect}); provide an absolute server URL, e.g. "https://api.example.com/v3"))
          end
          return url
        end
        raise Gori::Error.new("OpenAPI spec missing servers — add a servers[0].url block")
      end

      private def self.operation_to_flow(created_at : Int64, base : String, path : String,
                                         method : String, op : JSON::Any, item : JSON::Any,
                                         schemes : Hash(String, String),
                                         root_security : JSON::Any?) : Builder::FlowPair
        # Merge path-item-level and operation-level parameters (operation wins on a
        # name+location clash) — OpenAPI commonly declares a shared path param like
        # {id} once at the path-item level for every method beneath it.
        params = merge_params(item, op)
        filled = fill_path_params(path, params) # /users/{id} -> /users/1
        query = query_string(params)            # required query params -> a=1&b=2
        target = query.empty? ? filled : "#{filled}?#{query}"
        url = join_url(base, target)
        headers = Builder::Headers.new
        ct = body_content_type(op) # nil when the operation declares no requestBody
        # Only fabricate a JSON `{}` stub for a JSON media type — a `{}` body under a
        # multipart/xml Content-Type is self-contradictory and useless as a seed request.
        json = ct.try { |t| t == "application/json" || t.ends_with?("+json") } || false
        body = json ? %({}).to_slice : nil
        headers << {"Content-Type", ct} if ct
        headers.concat(header_params(params))
        security_headers(op, root_security, schemes).each { |name| headers << {name, "PLACEHOLDER"} }
        Builder.pending_request(created_at, url, method.upcase, headers, body)
      end

      private def self.join_url(base : String, path : String) : String
        b = base.chomp('/')
        p = path.starts_with?('/') ? path : "/#{path}"
        "#{b}#{p}"
      end

      private def self.body_content_type(op : JSON::Any) : String?
        rb = op["requestBody"]?
        return nil unless rb
        content = rb["content"]?
        return nil unless content
        return "application/json" if content["application/json"]?
        content.as_h.keys.first?.try(&.to_s)
      end

      # Merge path-item + operation parameters, operation winning on a name+location clash.
      private def self.merge_params(item : JSON::Any, op : JSON::Any) : Array(JSON::Any)
        merged = {} of Tuple(String, String) => JSON::Any
        {item["parameters"]?, op["parameters"]?}.each do |node|
          arr = node.try(&.as_a?)
          next unless arr
          arr.each do |p|
            next unless p.as_h?
            name = p["name"]?.to_s
            loc = p["in"]?.to_s
            next if name.empty? || loc.empty?
            merged[{name, loc}] = p
          end
        end
        merged.values
      end

      # Path params are required by definition; fill every declared {name} regardless of a
      # `required` flag (specs frequently omit it). Undeclared {templates} pass through.
      private def self.fill_path_params(path : String, params : Array(JSON::Any)) : String
        result = path
        params.each do |p|
          next unless p["in"]?.to_s == "path"
          name = p["name"]?.to_s
          next if name.empty?
          result = result.gsub("{#{name}}", sample_value(p))
        end
        result
      end

      private def self.query_string(params : Array(JSON::Any)) : String
        params.compact_map do |p|
          next unless p["in"]?.to_s == "query"
          next unless required?(p)
          name = p["name"]?.to_s
          next if name.empty?
          "#{URI.encode_www_form(name)}=#{URI.encode_www_form(sample_value(p))}"
        end.join('&')
      end

      private def self.header_params(params : Array(JSON::Any)) : Builder::Headers
        params.compact_map do |p|
          next unless p["in"]?.to_s == "header"
          next unless required?(p)
          name = p["name"]?.to_s
          next if name.empty?
          {name, sample_value(p)}
        end
      end

      private def self.required?(p : JSON::Any) : Bool
        p["required"]?.try(&.as_bool?) == true
      end

      private def self.sample_value(p : JSON::Any) : String
        type = nil
        if schema = p["schema"]?.try(&.as_h?)
          type = schema["type"]?.try(&.to_s)
        end
        case type
        when "integer", "number" then "1"
        when "boolean"           then "true"
        else                          p["name"]?.to_s.presence || "value"
        end
      end

      # Map scheme-name => header-name for every components.securitySchemes entry that is a
      # header-borne API key. Bounded on purpose: apiKey-in-query/cookie and non-apiKey
      # schemes (http bearer, oauth2, openIdConnect) are NOT seeded.
      private def self.api_key_header_schemes(spec : JSON::Any) : Hash(String, String)
        result = {} of String => String
        comps = spec["components"]?.try(&.as_h?)
        return result unless comps
        schemes = comps["securitySchemes"]?.try(&.as_h?)
        return result unless schemes
        schemes.each do |name, scheme|
          h = scheme.as_h?
          next unless h
          next unless h["type"]?.to_s == "apiKey"
          next unless h["in"]?.to_s == "header"
          header = h["name"]?.to_s
          result[name] = header unless header.empty?
        end
        result
      end

      # Effective security = operation-level `security` (which may be [] to opt OUT) else
      # the root-level `security`. Returns the header names to seed.
      private def self.security_headers(op : JSON::Any, root_security : JSON::Any?,
                                        schemes : Hash(String, String)) : Array(String)
        return [] of String if schemes.empty?
        effective = op["security"]? || root_security
        reqs = effective.try(&.as_a?)
        return [] of String unless reqs
        names = [] of String
        reqs.each do |req|
          h = req.as_h?
          next unless h
          h.each_key do |scheme_name|
            header = schemes[scheme_name]?
            names << header if header
          end
        end
        names.uniq
      end
    end
  end
end
