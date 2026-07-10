require "json"
require "yaml"
require "./builder"

module Gori
  module Import
    module Oas
      HTTP_METHODS = %w(get post put patch delete head options trace)

      def self.parse_file(path : String) : ParseResult
        raw = File.read(path)
        json_raw = case File.extname(path).downcase
                   when ".yaml", ".yml" then YAML.parse(raw).to_json
                   else                      raw
                   end
        spec = JSON.parse(json_raw)
        paths = spec["paths"]?
        raise Gori::Error.new("OpenAPI spec missing paths") unless paths
        # A `paths` that isn't an object (null / string / array) is a malformed spec, not
        # a valid-but-empty one — raise a clean error rather than a raw JSON type-cast.
        paths_h = paths.as_h? || raise Gori::Error.new("OpenAPI spec `paths` is not an object")
        base = server_base(spec)
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
              pairs << operation_to_flow(now, base, path.to_s, m, op)
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
          return url
        end
        raise Gori::Error.new("OpenAPI spec missing servers — add a servers[0].url block")
      end

      private def self.operation_to_flow(created_at : Int64, base : String, path : String,
                                         method : String, op : JSON::Any) : Builder::FlowPair
        url = join_url(base, path)
        headers = Builder::Headers.new
        ct = body_content_type(op) # nil when the operation declares no requestBody
        # Only fabricate a JSON `{}` stub for a JSON media type — a `{}` body under a
        # multipart/xml Content-Type is self-contradictory and useless as a seed request.
        json = ct.try { |t| t == "application/json" || t.ends_with?("+json") } || false
        body = json ? %({}).to_slice : nil
        headers << {"Content-Type", ct} if ct
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
    end
  end
end
