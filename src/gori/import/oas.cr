require "json"
require "yaml"
require "uri"
require "./builder"

module Gori
  module Import
    module Oas
      HTTP_METHODS  = %w[get post put patch delete head options trace]
      MAX_REF_DEPTH = 64

      private class RemoteReference < Gori::Error
      end

      def self.parse_file(path : String, prov : Provenance = Provenance.none) : ParseResult
        spec = spec_file(path)
        # A valid-JSON-but-wrong-shape spec (top-level array/scalar) must yield a clean
        # Gori::Error, not the raw Exception JSON::Any#[](String) throws on a non-Hash —
        # cmd_import only rescues Gori::Error. Guarding here also makes the later
        # spec["servers"]/["security"]/["components"] accesses safe (spec is a Hash).
        raise Gori::Error.new("OpenAPI spec is not a JSON object") unless spec.as_h?
        paths = spec["paths"]?
        raise Gori::Error.new("OpenAPI spec missing paths") unless paths
        # A `paths` that isn't an object (null / string / array) is a malformed spec, not
        # a valid-but-empty one — raise a clean error rather than a raw JSON type-cast.
        paths_h = paths.as_h? || raise Gori::Error.new("OpenAPI spec `paths` is not an object")
        swagger2 = spec["swagger"]?.try(&.as_s?) == "2.0"
        base = swagger2 ? swagger2_base(spec) : server_base(spec)
        schemes = api_key_header_schemes(spec)
        root_security = spec["security"]?
        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        # `url_path`, not `path`: the enclosing method's `path` is the SPEC FILE on disk, and a
        # block parameter named `path` shadows it for the whole loop body.
        paths_h.each do |url_path, item|
          resolved_item = resolve_path_item(spec, item)
          unless resolved_item
            skipped += 1
            next
          end
          HTTP_METHODS.each do |m|
            flow, found = import_operation(now, base, url_path.to_s, m, resolved_item,
              spec, swagger2, schemes, root_security, prov)
            if flow
              pairs << flow
            elsif found
              skipped += 1
            end
          end
        end
        ParseResult.new(pairs, skipped)
      end

      private def self.resolve_path_item(spec : JSON::Any, item : JSON::Any) : JSON::Any?
        resolve_ref(spec, item)
      rescue ex : RemoteReference
        raise ex
      rescue
        nil
      end

      # Return whether the path item had this method separately from the optional flow: a
      # missing method is ordinary, while a malformed operation is a counted skip.
      private def self.import_operation(now : Int64, base : String, url_path : String,
                                        method : String, item : JSON::Any, spec : JSON::Any,
                                        swagger2 : Bool, schemes : Hash(String, String),
                                        root_security : JSON::Any?, prov : Provenance) : Tuple(Builder::FlowPair?, Bool)
        # External references are reported to the operator instead of being counted as skips.
        op = item[method]? rescue nil
        return {nil, false} unless op
        op = resolve_ref(spec, op)
        {operation_to_flow(now, base, url_path, method, op, item, spec, swagger2,
          schemes, root_security, prov), true}
      rescue ex : RemoteReference
        raise ex
      rescue
        {nil, true}
      end

      private def self.spec_file(path : String) : JSON::Any
        raw = File.read(path)
        json_raw = case File.extname(path).downcase
                   when ".yaml", ".yml"
                     begin
                       YAML.parse(raw).to_json
                     rescue ex : YAML::ParseException
                       raise Gori::Error.new("OpenAPI spec is not valid YAML: #{ex.message}")
                     rescue ex : JSON::Error
                       # The YAML parsed and the `to_json` in the SAME expression is what
                       # raised — a `JSON::Error`, which the clause above does not cover. Three
                       # ordinary hand-written specs reach it, so the message says what was
                       # attempted rather than guessing which one: a self-referential anchor
                       # (`a: &x` / `b: *x`) yields a CYCLIC `YAML::Any` and trips the nesting
                       # guard, `maximum: .inf` and `.nan` are legal YAML scalars with no JSON
                       # spelling, and a legitimately deep spec trips the same guard acyclically.
                       # `ex.message` separates them for anyone who needs to know which.
                       raise Gori::Error.new(
                         "OpenAPI spec cannot be represented as JSON — a self-referential anchor, " \
                         "an infinite/NaN number, or nesting past the reader's limit: #{ex.message}")
                     end
                   else
                     raw
                   end
        JSON.parse(json_raw)
      rescue ex : JSON::ParseException
        raise Gori::Error.new("OpenAPI spec is not valid JSON: #{ex.message}")
      end

      private def self.server_base(spec : JSON::Any) : String
        servers = spec["servers"]?
        if servers && (arr = servers.as_a?) && (first = arr[0]?)
          # `servers: ["https://api.example.com"]` is a common YAML shorthand but not the
          # OpenAPI shape, and `as_a?` proves only that the ELEMENT exists, not that it is an
          # object. `JSON::Any#[]?(String)` raises a raw Exception on a non-Hash raw, and this
          # call sits outside the per-operation rescue below — so the operator got a Crystal
          # backtrace. Shape-guard it the way `paths_h` above does, for the same reason.
          first_h = first.as_h? || raise Gori::Error.new(
            %(OpenAPI servers[0] is not an object — write `- url: "https://api.example.com"`))
          url = first_h["url"]?.to_s
          raise Gori::Error.new("OpenAPI spec has no servers[0].url") if url.empty?
          # A relative server URL ("/v3", "./v3", "../v3", "v3") has no host authority:
          # every generated request would prepend "https://" onto it, either yielding an
          # empty host ("https:///v3/...") or a bogus one ("https://./v3/..." → host
          # "."). Builder.endpoint only catches the empty-host case, so a "./"-style URL
          # would silently produce garbage requests instead of failing loudly. Reject any
          # URL without a scheme up front instead.
          #
          # `URI.parse` itself RAISES on a url the spec's author can write by hand: a port
          # that overflows Int32 (`:99999999999999999999`) comes back as `OverflowError`, a
          # non-numeric one as `URI::Error`. Neither is a `Gori::Error`, so both left this
          # method as a raw backtrace out of the CLI. The sibling importer already spells
          # this out — `Wsdl#port_endpoint` wraps its own `URI.parse` for the same reason.
          uri = begin
            URI.parse(url)
          rescue ex : URI::Error | OverflowError
            raise Gori::Error.new(%(OpenAPI servers[0].url is unparseable (#{url.inspect}): #{ex.message}))
          end
          if uri.scheme.nil?
            raise Gori::Error.new(%(OpenAPI servers[0].url is relative (#{url.inspect}); provide an absolute server URL, e.g. "https://api.example.com/v3"))
          end
          return url
        end
        raise Gori::Error.new("OpenAPI spec missing servers — add a servers[0].url block")
      end

      # Swagger 2.0 puts the authority and base path in separate root fields. Its `schemes`
      # list is optional; when absent, HTTPS is the safest usable default for a local template.
      private def self.swagger2_base(spec : JSON::Any) : String
        host = spec["host"]?.try(&.as_s?).try(&.presence) ||
               raise Gori::Error.new("Swagger 2.0 spec missing host — add a host value")
        scheme = spec["schemes"]?.try(&.as_a?).try(&.first?).try(&.as_s?).try(&.downcase) || "https"
        unless scheme == "http" || scheme == "https"
          raise Gori::Error.new("Swagger 2.0 spec has unsupported scheme #{scheme.inspect} — use http or https")
        end
        base_path = spec["basePath"]?.try(&.as_s?) || "/"
        base_path = "/#{base_path}" unless base_path.starts_with?('/')
        url = "#{scheme}://#{host}#{base_path}"
        uri = URI.parse(url)
        raise Gori::Error.new("Swagger 2.0 spec has an invalid host or basePath") if uri.host.nil?
        url
      rescue ex : URI::Error | OverflowError
        raise Gori::Error.new("Swagger 2.0 spec has an unparseable host/basePath: #{ex.message}")
      end

      private def self.operation_to_flow(created_at : Int64, base : String, path : String,
                                         method : String, op : JSON::Any, item : JSON::Any,
                                         spec : JSON::Any, swagger2 : Bool,
                                         schemes : Hash(String, String),
                                         root_security : JSON::Any?,
                                         prov : Provenance) : Builder::FlowPair
        # Merge path-item-level and operation-level parameters (operation wins on a
        # name+location clash) — OpenAPI commonly declares a shared path param like
        # {id} once at the path-item level for every method beneath it.
        params = merge_params(spec, item, op)
        filled = fill_path_params(spec, path, params) # /users/{id} -> /users/1
        query = query_string(spec, params)            # required query params -> a=1&b=2
        target = Builder.append_query(filled, query)
        url = join_url(base, target)
        headers = Builder::Headers.new
        ct, body = request_payload(spec, op, params, swagger2)
        headers << {"Content-Type", ct} if ct
        headers.concat(header_params(spec, params))
        security_headers(op, root_security, schemes).each { |name| headers << {name, "PLACEHOLDER"} }
        Builder.pending_request(created_at, url, method.upcase, headers, body,
          source_surface: prov.surface, source_ref: prov.ref)
      end

      private def self.join_url(base : String, path : String) : String
        b = base.chomp('/')
        p = path.starts_with?('/') ? path : "/#{path}"
        "#{b}#{p}"
      end

      private def self.request_payload(spec : JSON::Any, op : JSON::Any,
                                       params : Array(JSON::Any), swagger2 : Bool) : {String?, Bytes?}
        if swagger2
          if body_param = params.find { |p| p["in"]?.to_s == "body" }
            content_type = consumes(spec, op).first? || "application/json"
            return {content_type, body_stub(spec, body_param["schema"]?, content_type)}
          end
          form_params = params.select { |p| p["in"]?.to_s == "formData" }
          return {nil, nil} if form_params.empty?
          return form_data_payload(spec, op, form_params)
        end

        request_body = op["requestBody"]?
        return {nil, nil} unless request_body
        request_body = resolve_ref(spec, request_body)
        content_node = request_body["content"]?
        return {nil, nil} unless content_node
        content = content_node.as_h? ||
                  raise Gori::Error.new("OpenAPI requestBody content is not an object")
        media_type = content.has_key?("application/json") ? "application/json" : content.keys.first?
        return {nil, nil} unless media_type
        schema = content[media_type]["schema"]?
        {media_type, body_stub(spec, schema, media_type)}
      end

      # Merge path-item + operation parameters, operation winning on a name+location clash.
      private def self.merge_params(spec : JSON::Any, item : JSON::Any,
                                    op : JSON::Any) : Array(JSON::Any)
        merged = {} of Tuple(String, String) => JSON::Any
        {item["parameters"]?, op["parameters"]?}.each do |node|
          arr = node.try(&.as_a?)
          next unless arr
          arr.each do |raw_param|
            p = resolve_ref(spec, raw_param)
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
      private def self.fill_path_params(spec : JSON::Any, path : String,
                                        params : Array(JSON::Any)) : String
        result = path
        params.each do |p|
          next unless p["in"]?.to_s == "path"
          name = p["name"]?.to_s
          next if name.empty?
          result = result.gsub("{#{name}}", sample_value(spec, p))
        end
        result
      end

      private def self.query_string(spec : JSON::Any, params : Array(JSON::Any)) : String
        params.compact_map do |p|
          next unless p["in"]?.to_s == "query"
          next unless required?(p)
          name = p["name"]?.to_s
          next if name.empty?
          "#{URI.encode_www_form(name)}=#{URI.encode_www_form(sample_value(spec, p))}"
        end.join('&')
      end

      private def self.header_params(spec : JSON::Any, params : Array(JSON::Any)) : Builder::Headers
        params.compact_map do |p|
          next unless p["in"]?.to_s == "header"
          next unless required?(p)
          name = p["name"]?.to_s
          next if name.empty?
          {name, sample_value(spec, p)}
        end
      end

      private def self.required?(p : JSON::Any) : Bool
        p["required"]?.try(&.as_bool?) == true
      end

      private def self.sample_value(spec : JSON::Any, p : JSON::Any) : String
        schema_node = p["schema"]?
        schema = schema_node ? resolve_ref(spec, schema_node).as_h? : nil
        type = schema.try { |h| h["type"]?.try(&.as_s?) } || p["type"]?.try(&.as_s?)
        case type
        when "integer", "number" then "1"
        when "boolean"           then "true"
        else                          p["name"]?.to_s.presence || "value"
        end
      end

      private def self.body_stub(spec : JSON::Any, schema_node : JSON::Any?, content_type : String) : Bytes?
        return nil unless json_media_type?(content_type)
        return %({}).to_slice unless schema_node
        schema = resolve_ref(spec, schema_node)
        object = schema.as_h? || raise Gori::Error.new("OpenAPI body schema is not an object")
        return object["example"].to_json.to_slice if object["example"]?
        return object["default"].to_json.to_slice if object["default"]?
        type = object["type"]?.try(&.as_s?)
        case type
        when "array"             then "[]".to_slice
        when "string"            then JSON::Any.new("").to_json.to_slice
        when "integer", "number" then "0".to_slice
        when "boolean"           then "true".to_slice
        else                          %({}).to_slice
        end
      end

      private def self.json_media_type?(content_type : String) : Bool
        media_type = content_type.split(';', 2)[0].strip
        media_type == "application/json" || media_type.ends_with?("+json")
      end

      private def self.consumes(spec : JSON::Any, op : JSON::Any) : Array(String)
        node = op["consumes"]? || spec["consumes"]?
        node.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      end

      private def self.form_data_payload(spec : JSON::Any, op : JSON::Any,
                                         params : Array(JSON::Any)) : {String?, Bytes?}
        content_type = consumes(spec, op).first? || "application/x-www-form-urlencoded"
        media_type = content_type.split(';', 2)[0].strip
        if media_type.compare("application/x-www-form-urlencoded", case_insensitive: true) == 0
          if params.any? { |p| p["type"]?.try(&.as_s?) == "file" }
            raise Gori::Error.new("Swagger 2.0 file formData requires multipart/form-data consumes")
          end
          body = params.map do |p|
            name = p["name"]?.to_s
            "#{URI.encode_www_form(name)}=#{URI.encode_www_form(sample_value(spec, p))}"
          end.join('&')
          return {content_type, body.to_slice}
        end
        unless media_type.compare("multipart/form-data", case_insensitive: true) == 0
          raise Gori::Error.new("Swagger 2.0 formData requires multipart/form-data or application/x-www-form-urlencoded consumes")
        end

        boundary = "gori-openapi-boundary"
        body = String.build do |io|
          params.each do |p|
            name = p["name"]?.to_s
            raise Gori::Error.new("Swagger 2.0 formData parameter has an invalid name") if Builder.inject_bytes?(name)
            quoted_name = name.gsub("\\", "\\\\").gsub("\"", "\\\"")
            io << "--" << boundary << "\r\n"
            if p["type"]?.try(&.as_s?) == "file"
              io << "Content-Disposition: form-data; name=\"" << quoted_name << "\"; filename=\"file\"\r\n"
              io << "Content-Type: application/octet-stream\r\n"
            else
              io << "Content-Disposition: form-data; name=\"" << quoted_name << "\"\r\n"
            end
            io << "\r\n" << sample_value(spec, p) << "\r\n"
          end
          io << "--" << boundary << "--\r\n"
        end
        {"multipart/form-data; boundary=#{boundary}", body.to_slice}
      end

      # Dereference only the value the current operation needs. Recursive schemas are common,
      # so resolving their entire child tree would incorrectly reject otherwise usable body
      # stubs. A chain of refs is tracked explicitly to stop cycles and remote refs are named
      # rather than fetched from the network.
      private def self.resolve_ref(root : JSON::Any, node : JSON::Any,
                                   chain : Array(String) = [] of String) : JSON::Any
        reference = node.as_h?.try { |h| h["$ref"]?.try(&.as_s?) }
        return node unless reference
        unless reference == "#" || reference.starts_with?("#/")
          if reference.starts_with?('#')
            raise Gori::Error.new("OpenAPI local $ref must use a JSON Pointer: #{reference}")
          end
          raise RemoteReference.new("OpenAPI remote $ref is not fetched: #{reference}")
        end
        raise Gori::Error.new("OpenAPI $ref chain exceeds #{MAX_REF_DEPTH} references") if chain.size >= MAX_REF_DEPTH
        raise Gori::Error.new("OpenAPI $ref cycle: #{(chain + [reference]).join(" -> ")}") if chain.includes?(reference)
        target = if reference == "#"
                   root
                 else
                   resolve_pointer(root, reference)
                 end
        resolve_ref(root, target, chain + [reference])
      end

      private def self.resolve_pointer(root : JSON::Any, reference : String) : JSON::Any
        node = root
        reference[2..].split('/', remove_empty: false).each do |escaped|
          token = escaped.gsub("~1", "/").gsub("~0", "~")
          child = if object = node.as_h?
                    object[token]?
                  elsif array = node.as_a?
                    numeric = !token.empty? && token.each_byte.all? { |byte| byte >= 0x30_u8 && byte <= 0x39_u8 }
                    index = numeric ? token.to_i? : nil
                    index ? array[index]? : nil
                  end
          node = child || raise Gori::Error.new("OpenAPI local $ref does not exist: #{reference}")
        end
        node
      end

      # Map scheme-name => header-name for every OpenAPI 3 components.securitySchemes or
      # Swagger 2 securityDefinitions entry that is a header-borne API key. Bounded on purpose:
      # apiKey-in-query/cookie and non-apiKey schemes (http bearer, oauth2, openIdConnect) are
      # NOT seeded.
      private def self.api_key_header_schemes(spec : JSON::Any) : Hash(String, String)
        result = {} of String => String
        definitions = if spec["swagger"]?.try(&.as_s?) == "2.0"
                        spec["securityDefinitions"]?.try(&.as_h?)
                      else
                        spec["components"]?.try(&.as_h?).try { |comps| comps["securitySchemes"]?.try(&.as_h?) }
                      end
        schemes = definitions
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
