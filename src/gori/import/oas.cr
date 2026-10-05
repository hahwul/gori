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
        # OpenAPI 3 lets an operation or a path item name its own servers, overriding the
        # root list — gori's own export writes one per path when a capture spans hosts.
        unless swagger2
          base = local_server_url(op.as_h?.try(&.["servers"]?)) ||
                 local_server_url(item.as_h?.try(&.["servers"]?)) || base
        end
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
                       yaml_prescan!(raw)
                       YAML.parse(raw).to_json
                     rescue ex : YAML::ParseException
                       raise Gori::Error.new("OpenAPI spec is not valid YAML: #{ex.message}")
                     rescue ex : JSON::Error
                       # The YAML parsed and the `to_json` in the SAME expression is what
                       # raised — a `JSON::Error`, which the clause above does not cover. Three
                       # ordinary hand-written specs reach it, so the message says what was
                       # attempted rather than guessing which one: a self-referential anchor
                       # (`a: &x` / `b: *x`) yields a CYCLIC `YAML::Any` and trips the builder's
                       # nesting guard (1024, see json_nesting.cr), `maximum: .inf` and `.nan` are
                       # legal YAML scalars with no JSON spelling, and a chain of aliases can stack
                       # an acyclic spec past the same guard.
                       # `ex.message` separates them for anyone who needs to know which.
                       raise Gori::Error.new(
                         "OpenAPI spec cannot be represented as JSON — a self-referential anchor, " \
                         "an infinite/NaN number, or nesting past the reader's limit: #{ex.message}")
                     rescue ex : Gori::Error
                       raise ex
                     rescue ex
                       # The YAML core schema reaches further than the two classes above: a
                       # `!!binary` scalar parses to a Slice that `to_json` refuses with a bare
                       # `Exception`, and a timestamp with a `+99:00` offset raises
                       # `Time::Location::InvalidTimezoneOffsetError` inside `YAML.parse`. Both are
                       # the spec's content, so they are the spec's error, not a backtrace.
                       raise Gori::Error.new("OpenAPI spec could not be read as YAML (#{ex.class}): #{ex.message}")
                     end
                   else
                     raw
                   end
        JSON.parse(json_raw)
      rescue ex : JSON::ParseException
        raise Gori::Error.new("OpenAPI spec is not valid JSON: #{ex.message}")
      end

      # Refuse, before `YAML.parse`, a mapping key that is not a scalar. `YAML.parse` inserts
      # every key into a Hash, and comparing two keys that are CYCLIC sequences
      # (`{? &a [*a] : 1, ? &b [*b] : 2}`) recurses in `YAML::Any#==` until the stack
      # overflows — a SIGSEGV no rescue reaches, so a three-line file ended the process.
      # OpenAPI keys are strings, so nothing real is lost. The walk is iterative and over
      # `YAML::Nodes`, where an alias is a node pointing at its anchor rather than a copy of
      # it, so it visits each written node once and never follows a cycle. (An alias bomb
      # needs no guard here: the stdlib pull parser refuses "excessive aliasing" itself.)
      private def self.yaml_prescan!(raw : String) : Nil
        stack = YAML::Nodes.parse(raw).nodes.dup
        while node = stack.pop?
          case node
          when YAML::Nodes::Mapping
            node.nodes.each_slice(2) do |(key, _)|
              k = key.is_a?(YAML::Nodes::Alias) ? key.value : key
              next if k.is_a?(YAML::Nodes::Scalar)
              raise Gori::Error.new(
                "OpenAPI spec has a YAML mapping key that is not a string (line #{key.start_line})")
            end
            stack.concat(node.nodes)
          when YAML::Nodes::Sequence
            stack.concat(node.nodes)
          end
        end
      end

      private def self.server_base(spec : JSON::Any) : String
        server_url(spec["servers"]?) ||
          raise Gori::Error.new("OpenAPI spec missing servers — add a servers[0].url block")
      end

      # A path-item or operation `servers[0].url` to send to instead of the root one, or nil to
      # keep the root: a relative (`/v2`) entry, or a templated one naming a variable it gives no
      # `default` for, is valid OpenAPI but names no host by itself, and used to import against
      # the root server — so it still does, rather than skipping the operation.
      private def self.local_server_url(servers : JSON::Any?) : String?
        server_url(servers) rescue nil
      end

      # `servers[0].url` of a root, path-item or operation `servers` list, or nil when the
      # list is absent or empty.
      private def self.server_url(servers : JSON::Any?) : String?
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
          # `JSON.parse` hands raw bytes through unchecked, and the variable gsub below is PCRE,
          # which RAISES on invalid UTF-8 — outside the per-operation rescue.
          raise Gori::Error.new("OpenAPI servers[0].url is not valid UTF-8") unless url.valid_encoding?
          url = substitute_server_variables(url, first_h["variables"]?)
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
        nil
      end

      SERVER_VARIABLE = /\{([^{}]*)\}/

      # Fill each `{name}` in a server url with its `variables.<name>.default` — OpenAPI 3
      # requires every variable to carry one, and it is the value the spec's author means when
      # nothing else is chosen. Left templated, `http://{host}:8080/{base}` failed to parse and
      # skipped every operation, and `https://api.test/{base}` imported a literal `/{base}/`
      # path. A spec that leaves `default` out (it is required, but common in the wild) and lists
      # an `enum` gets its first member — the one value it names. A variable with neither names
      # no URL, so it is refused rather than guessed.
      private def self.substitute_server_variables(url : String, variables : JSON::Any?) : String
        return url unless url.includes?('{')
        vars = variables.try(&.as_h?)
        url.gsub(SERVER_VARIABLE) do |_, match|
          name = match[1]
          var = vars.try(&.[name]?).try(&.as_h?)
          chosen = var.try(&.["default"]?) || var.try(&.["enum"]?).try(&.as_a?).try(&.first?)
          value = chosen.try { |d| d.as_s? || (d.raw.is_a?(Int64 | Float64) ? d.to_json : nil) }
          value || raise Gori::Error.new(
            %(OpenAPI servers[0].url variable {#{name}} has no default — add servers[0].variables.#{name}.default))
        end
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
        request_body_payload(spec, op)
      end

      # An OpenAPI 3 operation's `requestBody`, as the media type it prefers and a body for it.
      private def self.request_body_payload(spec : JSON::Any, op : JSON::Any) : {String?, Bytes?}
        request_body = op["requestBody"]?
        return {nil, nil} unless request_body
        request_body = resolve_ref(spec, request_body)
        content_node = request_body["content"]?
        return {nil, nil} unless content_node
        content = content_node.as_h? ||
                  raise Gori::Error.new("OpenAPI requestBody content is not an object")
        media_type = content.has_key?("application/json") ? "application/json" : content.keys.first?
        return {nil, nil} unless media_type
        media = resolve_ref(spec, content[media_type]).as_h? ||
                raise Gori::Error.new("OpenAPI requestBody content #{media_type} is not an object")
        schema = media["schema"]?
        # The author's own example beats anything synthesized from the schema.
        if (example = media_example(spec, media)) && (bytes = example_body(example, media_type))
          return {media_type, bytes}
        end
        case form_kind(media_type)
        when :urlencoded
          {media_type, urlencoded_body(schema_form_fields(spec, schema))}
        when :multipart
          {"#{media_type}; boundary=#{MULTIPART_BOUNDARY}",
           multipart_body(schema_form_fields(spec, schema), "OpenAPI form property")}
        else
          {media_type, body_stub(spec, schema, media_type)}
        end
      end

      # A media type's `example`, else the `value` of the first usable entry of its `examples`
      # map (an Example Object, possibly a local `$ref`; an `externalValue` is not fetched).
      private def self.media_example(spec : JSON::Any, media : Hash(String, JSON::Any)) : JSON::Any?
        if (example = media["example"]?) && !example.raw.nil?
          return example
        end
        media["examples"]?.try(&.as_h?).try &.each_value do |entry|
          object = (resolve_ref(spec, entry).as_h? rescue nil)
          value = object.try(&.["value"]?)
          return value if value && !value.raw.nil?
        end
        nil
      end

      # The bytes an example stands for in `media_type`, or nil when it cannot be one — a
      # multipart example is a string whose boundary gori cannot know, so it is rebuilt from the
      # schema instead.
      private def self.example_body(example : JSON::Any, media_type : String) : Bytes?
        return example.to_json.to_slice if json_media_type?(media_type)
        kind = form_kind(media_type)
        return nil if kind == :multipart
        if kind == :urlencoded && (object = example.as_h?)
          return urlencoded_body(object.map { |k, v| FormField.new(k, v.as_s? || v.to_json, false) })
        end
        example.as_s?.try(&.to_slice)
      end

      private def self.form_kind(content_type : String) : Symbol?
        media_type = content_type.split(';', 2)[0].strip
        if media_type.compare("application/x-www-form-urlencoded", case_insensitive: true) == 0
          :urlencoded
        elsif media_type.compare("multipart/form-data", case_insensitive: true) == 0
          :multipart
        end
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

      # The author's own value beats a synthesized one, as it does for a body: the parameter's
      # `example`/`examples` (Swagger 2: its `default`/`enum`), then its schema's. A `sort=sort`
      # where the spec says `enum: [asc, desc]` is a template the server answers with a 400.
      private def self.sample_value(spec : JSON::Any, p : JSON::Any) : String
        schema_node = p["schema"]?
        schema = schema_node ? resolve_ref(spec, schema_node).as_h? : nil
        given = p.as_h?.try { |param| media_example(spec, param) || given_sample(param) }
        given ||= schema.try { |h| given_sample(h) }
        if text = given.try { |g| param_text(g) }
          return text
        end
        type = schema.try { |h| h["type"]?.try(&.as_s?) } || p["type"]?.try(&.as_s?)
        scalar_sample(type, p["name"]?.to_s)
      end

      # A given value as the text a path, query or header carries: a scalar as written, an
      # array's first member. An object has no single spelling, so it is not one.
      private def self.param_text(value : JSON::Any) : String?
        value = (list = value.as_a?) ? list.first? : value
        case raw = value.try(&.raw)
        when String               then raw
        when Int64, Float64, Bool then raw.to_s
        end
      end

      private def self.scalar_sample(type : String?, name : String) : String
        case type
        when "integer", "number" then "1"
        when "boolean"           then "true"
        else                          name.presence || "value"
        end
      end

      # How deep and how wide a synthesized JSON body may grow. A schema's properties are
      # followed so a body carries its fields, and recursive schemas (a tree node whose children
      # are nodes) are ordinary — both bounds are what stop one from expanding without end.
      MAX_SAMPLE_DEPTH =   8
      MAX_SAMPLE_NODES = 512

      private class SampleBudget
        property left : Int32 = MAX_SAMPLE_NODES
      end

      private def self.body_stub(spec : JSON::Any, schema_node : JSON::Any?, content_type : String) : Bytes?
        return nil unless json_media_type?(content_type)
        return %({}).to_slice unless schema_node
        schema = resolve_ref(spec, schema_node)
        schema.as_h? || raise Gori::Error.new("OpenAPI body schema is not an object")
        (json_sample(spec, schema, nil, 0, SampleBudget.new) || JSON::Any.new({} of String => JSON::Any)).to_json.to_slice
      end

      # A placeholder JSON value for `schema`: its `example`, `default` or first `enum` value, else
      # one by `type` — an object gets each of its `properties` in turn (a string property holds
      # its own name, as a generated parameter does). A property whose schema cannot be read is
      # left out rather than failing the whole operation, since the body is only a template.
      private def self.json_sample(spec : JSON::Any, schema : JSON::Any, name : String?,
                                   depth : Int32, budget : SampleBudget) : JSON::Any?
        budget.left -= 1
        object = schema.as_h?
        return nil unless object
        if given = given_sample(object)
          return given
        end
        case schema_type(object)
        when "array"             then JSON::Any.new([] of JSON::Any)
        when "string"            then JSON::Any.new(name || "")
        when "integer", "number" then JSON::Any.new(0_i64)
        when "boolean"           then JSON::Any.new(true)
        else                          object_sample(spec, object, depth, budget)
        end
      end

      # The value a schema names for itself: its `example`, `default` or first `enum` entry.
      private def self.given_sample(object : Hash(String, JSON::Any)) : JSON::Any?
        {"example", "default"}.each do |key|
          value = object[key]?
          return value if value && !value.raw.nil?
        end
        object["enum"]?.try(&.as_a?).try(&.first?)
      end

      private def self.object_sample(spec : JSON::Any, object : Hash(String, JSON::Any),
                                     depth : Int32, budget : SampleBudget) : JSON::Any
        fields = {} of String => JSON::Any
        properties = object["properties"]?.try(&.as_h?)
        if properties && depth < MAX_SAMPLE_DEPTH
          properties.each do |key, node|
            break if budget.left <= 0
            value = (json_sample(spec, resolve_ref(spec, node), key, depth + 1, budget) rescue nil)
            fields[key] = value if value
          end
        end
        JSON::Any.new(fields)
      end

      # A schema's `type`, taking the first non-null one of an OpenAPI 3.1 type list.
      private def self.schema_type(object : Hash(String, JSON::Any)) : String?
        node = object["type"]?
        return nil unless node
        node.as_s? || node.as_a?.try(&.compact_map(&.as_s?).find { |t| t != "null" })
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
        fields = params.map do |p|
          FormField.new(p["name"]?.to_s, sample_value(spec, p), p["type"]?.try(&.as_s?) == "file")
        end
        case form_kind(content_type)
        when :urlencoded
          if fields.any?(&.file)
            raise Gori::Error.new("Swagger 2.0 file formData requires multipart/form-data consumes")
          end
          {content_type, urlencoded_body(fields)}
        when :multipart
          {"multipart/form-data; boundary=#{MULTIPART_BOUNDARY}",
           multipart_body(fields, "Swagger 2.0 formData parameter")}
        else
          raise Gori::Error.new("Swagger 2.0 formData requires multipart/form-data or application/x-www-form-urlencoded consumes")
        end
      end

      # One field of a generated form body: a Swagger 2 `formData` parameter or an OpenAPI 3
      # form schema property.
      private record FormField, name : String, value : String, file : Bool

      MULTIPART_BOUNDARY = "gori-openapi-boundary"

      # The fields of an OpenAPI 3 form body: each of the schema's `properties`, valued from the
      # schema-level `example` object, the property's own `example` or `default`, or a
      # placeholder by type. A `format: binary` (or `base64`) string is a file part.
      private def self.schema_form_fields(spec : JSON::Any, schema_node : JSON::Any?) : Array(FormField)
        return [] of FormField unless schema_node
        # A schema this cannot read — a remote or dangling `$ref`, or not an object — leaves the
        # form empty, as the operation imported before form bodies were built at all. Raising
        # here skipped the operation, and a remote ref aborted the whole import.
        schema = (resolve_ref(spec, schema_node).as_h? rescue nil)
        return [] of FormField unless schema
        properties = schema["properties"]?.try(&.as_h?)
        return [] of FormField unless properties
        example = schema["example"]?.try(&.as_h?)
        properties.map { |name, node| form_field(spec, name, node, example.try(&.[name]?)) }
      end

      # One form property: the schema-level example's value for it, else its own `example` or
      # `default`, else a placeholder by type.
      private def self.form_field(spec : JSON::Any, name : String, node : JSON::Any,
                                  example : JSON::Any?) : FormField
        property = (resolve_ref(spec, node).as_h? rescue nil)
        type = property.try { |h| schema_type(h) }
        format = property.try(&.["format"]?).try(&.as_s?)
        value = example || property.try(&.["example"]?) || property.try(&.["default"]?)
        value = nil if value.try(&.raw.nil?)
        text = value ? (value.as_s? || value.to_json) : scalar_sample(type, name)
        FormField.new(name, text, type == "string" && (format == "binary" || format == "base64"))
      end

      private def self.urlencoded_body(fields : Array(FormField)) : Bytes
        fields.join('&') do |f|
          "#{URI.encode_www_form(f.name)}=#{URI.encode_www_form(f.value)}"
        end.to_slice
      end

      private def self.multipart_body(fields : Array(FormField), label : String) : Bytes
        String.build do |io|
          fields.each do |f|
            raise Gori::Error.new("#{label} has an invalid name") if Builder.inject_bytes?(f.name)
            quoted_name = f.name.gsub("\\", "\\\\").gsub("\"", "\\\"")
            io << "--" << MULTIPART_BOUNDARY << "\r\n"
            if f.file
              io << "Content-Disposition: form-data; name=\"" << quoted_name << "\"; filename=\"file\"\r\n"
              io << "Content-Type: application/octet-stream\r\n"
            else
              io << "Content-Disposition: form-data; name=\"" << quoted_name << "\"\r\n"
            end
            io << "\r\n" << f.value << "\r\n"
          end
          io << "--" << MULTIPART_BOUNDARY << "--\r\n"
        end.to_slice
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
          # A `$ref` is a URI fragment, so its tokens are percent-encoded first (RFC 6901 §6):
          # `#/paths/~1users~1%7Bid%7D`. The raw token is still tried for a spec that wrote a
          # bare `%` in a key.
          decoded = escaped.includes?('%') ? (URI.decode(escaped).gsub("~1", "/").gsub("~0", "~") rescue token) : token
          child = if object = node.as_h?
                    object[decoded]? || object[token]?
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
