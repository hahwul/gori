require "json"
require "uri"
require "base64"
require "./builder"
require "./vars"

module Gori
  module Import
    # Postman Collection v2.0 / v2.1 (the JSON a collection's "Export" button writes). Like
    # OpenAPI this is a description of requests, not captured traffic, so every entry lands
    # as a response-less template via `Builder.pending_request`.
    #
    # Bounded on purpose, in the same spirit as `Oas.api_key_header_schemes`:
    #   * auth seeds only `bearer`, `basic` and `apikey`-in-header. oauth1/oauth2, awsv4,
    #     ntlm, digest, hawk and edgegrid need a live token exchange or a signing step, so a
    #     fabricated header would be worse than none.
    #   * body modes `raw`, `urlencoded`, `graphql` and `formdata` (text parts) are built.
    #     `file` mode names a path on the exporter's disk — an import never reads it.
    #   * saved `response` examples are ignored. They are Postman's own mock data, not a
    #     response the operator observed, and History would present them as if they were.
    module Postman
      # Folders nest arbitrarily; a flat read of `collection.item` imports almost nothing
      # from a real export. The cap is a runaway guard, not a real limit — no human-authored
      # collection is 32 folders deep.
      MAX_DEPTH = 32

      def self.parse_file(path : String) : ParseResult
        doc = begin
          JSON.parse(File.read(path))
        rescue ex : JSON::ParseException
          raise Gori::Error.new("Postman collection is not valid JSON: #{ex.message}")
        end
        root = doc.as_h? || raise Gori::Error.new("Postman collection is not a JSON object")
        if root["item"]?.nil? && root["requests"]?
          raise Gori::Error.new("this is a Postman v1 collection — re-export it as Collection v2.1 (Export → Collection v2.1)")
        end
        items = root["item"]?.try(&.as_a?)
        raise Gori::Error.new("Postman collection has no `item` array") unless items

        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        missing = Set(String).new
        skipped = walk(items, Vars.merge!(Vars::Table.new, root["variable"]?), root["auth"]?,
          0, now, pairs, missing)

        # A collection whose `{{baseUrl}}` lives in a separate ENVIRONMENT file resolves to
        # nothing, and the generic "all N entries were skipped as malformed" would blame the
        # file. Name the variables instead — the collection is fine, it just isn't self-contained.
        if pairs.empty? && !missing.empty?
          raise Gori::Error.new(unresolved_message(skipped, missing))
        end
        ParseResult.new(pairs, skipped)
      end

      # Depth-first over the item tree. Folders (an `item` array) may scope their own
      # `variable`/`auth`, both of which the nearest ancestor loses to.
      private def self.walk(items : Array(JSON::Any), vars : Vars::Table, auth : JSON::Any?,
                            depth : Int32, now : Int64,
                            pairs : Array(Builder::FlowPair), missing : Set(String)) : Int32
        return 0 if depth > MAX_DEPTH
        skipped = 0
        items.each do |node|
          h = node.as_h?
          next unless h
          scoped = h["variable"]? ? Vars.merge!(vars.dup, h["variable"]) : vars
          scoped_auth = h["auth"]? || auth
          if kids = h["item"]?.try(&.as_a?)
            skipped += walk(kids, scoped, scoped_auth, depth + 1, now, pairs, missing)
            next
          end
          req = h["request"]?
          next unless req
          # One bad request (unresolved variable, non-http scheme, host-less URL) skips
          # rather than aborting the collection — the contract every import parser shares.
          begin
            pairs << request_to_flow(now, req, scoped, scoped_auth, missing)
          rescue
            skipped += 1
          end
        end
        skipped
      end

      private def self.request_to_flow(now : Int64, req : JSON::Any, vars : Vars::Table,
                                       auth : JSON::Any?, missing : Set(String)) : Builder::FlowPair
        # `"request": "https://example.com/x"` is legal shorthand for a bare GET.
        if s = req.as_s?
          return Builder.pending_request(now, resolve_url(s, vars, missing))
        end
        h = req.as_h? || raise Gori::Error.new("request is neither a URL string nor an object")
        method = h["method"]?.to_s.presence || "GET"
        url = url_of(h["url"]?, vars, missing)
        headers = header_list(h["header"]?, vars)
        body, content_type = body_of(h["body"]?, vars)
        # An explicit Content-Type header always wins over the one the body mode implies.
        if content_type && !headers.any? { |(k, _)| k.compare("content-type", case_insensitive: true) == 0 }
          headers << {"Content-Type", content_type}
        end
        headers.concat(auth_headers(h["auth"]? || auth, vars))
        Builder.pending_request(now, url, method, headers, body)
      end

      # --- URL -----------------------------------------------------------------

      private def self.url_of(node : JSON::Any?, vars : Vars::Table, missing : Set(String)) : String
        raise Gori::Error.new("request has no url") unless node
        if s = node.as_s?
          return resolve_url(s, vars, missing)
        end
        h = node.as_h? || raise Gori::Error.new("url is neither a string nor an object")
        # `raw` is the canonical form Postman exports; the component fields are a parallel
        # projection of it. Only compose when `raw` is absent (hand-assembled collections).
        raw = h["raw"]?.try(&.as_s?).presence || compose(h)
        fill_path_params(resolve_url(raw, vars, missing), h["variable"]?, vars)
      end

      private def self.resolve_url(raw : String, vars : Vars::Table, missing : Set(String)) : String
        url = Vars.expand(raw.strip, vars)
        # `Builder::HOST_INVALID` does not reject `{`/`}`, so `https://{{baseUrl}}/x` would
        # otherwise be STORED with a literal host of `{{baseUrl}}` — a flow that can never be
        # sent, indistinguishable in History from a real one. Record the names and skip.
        left = Vars.unresolved(url)
        unless left.empty?
          left.each { |n| missing << n }
          raise Gori::Error.new("unresolved variable in URL: #{url}")
        end
        raise Gori::Error.new("templated host in URL: #{url}") if Vars.braced_authority?(url)
        raise Gori::Error.new("request has an empty url") if url.empty?
        url
      end

      # `url` as an object: {protocol, host: [...], port, path: [...], query: [{key,value}]}.
      # Only reached when `raw` is absent — Postman writes `raw` for everything it exports,
      # but a hand-assembled or API-generated collection may omit it.
      private def self.compose(h : Hash(String, JSON::Any)) : String
        proto = h["protocol"]?.to_s.presence || "https"
        host = join_parts(h["host"]?, '.')
        return "" if host.empty?
        port = h["port"]?.to_s.presence
        path = join_parts(h["path"]?, '/')
        query = (h["query"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |q|
          qh = q.as_h?
          next unless qh
          next if qh["disabled"]?.try(&.as_bool?) == true
          key = qh["key"]?.to_s
          next if key.empty?
          "#{key}=#{Vars.value_to_s(qh["value"]?)}"
        end.join('&')
        String.build do |b|
          b << proto << "://" << host
          b << ':' << port if port
          b << '/' << path unless path.empty?
          b << '?' << query unless query.empty?
        end
      end

      # `host`/`path` are arrays of segments ("api", "example", "com"), but both are
      # sometimes a plain string in hand-written collections.
      private def self.join_parts(node : JSON::Any?, sep : Char) : String
        return "" unless node
        if s = node.as_s?
          return s.strip(sep)
        end
        arr = node.as_a?
        return "" unless arr
        arr.map(&.to_s).reject(&.empty?).join(sep)
      end

      # `/users/:id` + `url.variable: [{key: "id", value: "1"}]` -> `/users/1`, mirroring
      # `Oas.fill_path_params`. `:name` only matches a word after a colon, so neither
      # `https://` nor a `:443` port is touched (and an undeclared `:token` passes through).
      PATH_PARAM = /:([A-Za-z_][A-Za-z0-9_-]*)/

      private def self.fill_path_params(url : String, node : JSON::Any?, vars : Vars::Table) : String
        table = Vars.merge!(Vars::Table.new, node)
        return url if table.empty?
        url.gsub(PATH_PARAM) { |full, m| table[m[1]]?.try { |v| Vars.expand(v, vars) } || full }
      end

      # --- headers / body / auth ------------------------------------------------

      private def self.header_list(node : JSON::Any?, vars : Vars::Table) : Builder::Headers
        list = Builder::Headers.new
        return list unless node
        # v2.0 permits one raw "Name: value\n…" blob instead of the array.
        if blob = node.as_s?
          blob.each_line do |line|
            name, sep, value = line.partition(':')
            next if sep.empty? || name.strip.empty?
            list << {Vars.expand(name.strip, vars), Vars.expand(value.strip, vars)}
          end
          return list
        end
        arr = node.as_a?
        return list unless arr
        arr.each do |item|
          h = item.as_h?
          next unless h
          next if h["disabled"]?.try(&.as_bool?) == true
          key = h["key"]?.to_s
          next if key.empty?
          list << {Vars.expand(key, vars), Vars.expand(Vars.value_to_s(h["value"]?), vars)}
        end
        list
      end

      # A fixed boundary (not a random one): imports must be reproducible, and two runs over
      # the same collection should produce byte-identical flows.
      FORM_BOUNDARY = "----GoriImportFormBoundary"

      private def self.body_of(node : JSON::Any?, vars : Vars::Table) : {Bytes?, String?}
        h = node.try(&.as_h?)
        return {nil, nil} unless h
        return {nil, nil} if h["disabled"]?.try(&.as_bool?) == true
        case h["mode"]?.to_s
        when "raw"
          text = Vars.expand(Vars.value_to_s(h["raw"]?), vars)
          text.empty? ? {nil, nil} : {text.to_slice, raw_content_type(h)}
        when "urlencoded"
          pairs = kv_pairs(h["urlencoded"]?, vars).map do |(k, v)|
            "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}"
          end
          pairs.empty? ? {nil, nil} : {pairs.join('&').to_slice, "application/x-www-form-urlencoded"}
        when "formdata"
          form_data(h["formdata"]?, vars)
        when "graphql"
          graphql(h["graphql"]?, vars)
        else
          {nil, nil} # "file" (a path on the exporter's disk) and anything unrecognised
        end
      end

      # `options.raw.language` is Postman's editor hint; it is the only Content-Type signal a
      # raw body carries when the request declares no explicit header.
      private def self.raw_content_type(h : Hash(String, JSON::Any)) : String?
        # Every hop guards with as_h? — JSON::Any#[]? RAISES on a non-Hash, and an options
        # block shaped as an array/scalar would otherwise skip an otherwise-valid request.
        opts = h["options"]?.try(&.as_h?).try(&.["raw"]?).try(&.as_h?)
        lang = opts.try(&.["language"]?).to_s
        case lang
        when "json"       then "application/json"
        when "xml"        then "application/xml"
        when "html"       then "text/html"
        when "javascript" then "application/javascript"
        when "text"       then "text/plain"
        end
      end

      private def self.kv_pairs(node : JSON::Any?, vars : Vars::Table) : Array({String, String})
        arr = node.try(&.as_a?)
        return [] of {String, String} unless arr
        arr.compact_map do |item|
          h = item.as_h?
          next unless h
          next if h["disabled"]?.try(&.as_bool?) == true
          key = h["key"]?.to_s
          next if key.empty?
          {Vars.expand(key, vars), Vars.expand(Vars.value_to_s(h["value"]?), vars)}
        end
      end

      private def self.form_data(node : JSON::Any?, vars : Vars::Table) : {Bytes?, String?}
        arr = node.try(&.as_a?)
        return {nil, nil} unless arr
        text_parts = arr.select do |item|
          h = item.as_h?
          # A `type: "file"` part references a path on the exporter's machine. Dropping it
          # keeps the other fields rather than discarding the whole request.
          !!h && h["disabled"]?.try(&.as_bool?) != true && h["type"]?.to_s != "file"
        end
        pairs = kv_pairs(JSON::Any.new(text_parts), vars)
        return {nil, nil} if pairs.empty?
        body = String.build do |b|
          pairs.each do |(k, v)|
            b << "--" << FORM_BOUNDARY << "\r\n"
            b << %(Content-Disposition: form-data; name="#{k}") << "\r\n\r\n"
            b << v << "\r\n"
          end
          b << "--" << FORM_BOUNDARY << "--\r\n"
        end
        {body.to_slice, "multipart/form-data; boundary=#{FORM_BOUNDARY}"}
      end

      private def self.graphql(node : JSON::Any?, vars : Vars::Table) : {Bytes?, String?}
        h = node.try(&.as_h?)
        return {nil, nil} unless h
        query = Vars.expand(Vars.value_to_s(h["query"]?), vars)
        return {nil, nil} if query.empty?
        variables = Vars.expand(Vars.value_to_s(h["variables"]?), vars).strip
        body = String.build do |b|
          b << %({"query":) << query.to_json
          unless variables.empty?
            # Postman stores `variables` as a STRING of JSON. Embed it as an object when it
            # parses, else as a string, so the body is always valid JSON either way.
            valid = begin
              JSON.parse(variables)
              true
            rescue JSON::ParseException
              false
            end
            b << %(,"variables":) << (valid ? variables : variables.to_json)
          end
          b << '}'
        end
        {body.to_slice, "application/json"}
      end

      # v2.1 stores auth params as `[{key, value, type}]`; v2.0 as a plain object.
      private def self.auth_params(node : JSON::Any?, vars : Vars::Table) : Vars::Table
        table = Vars::Table.new
        return table unless node
        if node.as_a?
          Vars.merge!(table, node)
        elsif h = node.as_h?
          h.each { |k, v| table[k] = Vars.value_to_s(v) }
        end
        expanded = Vars::Table.new
        table.each { |k, v| expanded[k] = Vars.expand(v, vars) }
        expanded
      end

      private def self.auth_headers(node : JSON::Any?, vars : Vars::Table) : Builder::Headers
        list = Builder::Headers.new
        h = node.try(&.as_h?)
        return list unless h
        type = h["type"]?.to_s
        return list if type.empty? || type == "noauth"
        p = auth_params(h[type]?, vars)
        case type
        when "bearer"
          list << {"Authorization", "Bearer #{p["token"]? || ""}"}
        when "basic"
          list << {"Authorization", "Basic #{Base64.strict_encode("#{p["username"]? || ""}:#{p["password"]? || ""}")}"}
        when "apikey"
          # apikey-in-query would have to be spliced into the URL, which is built and
          # validated before auth is resolved; header is the common case and the only one seeded.
          if (p["in"]? || "header") == "header"
            list << {p["key"]?.presence || "X-API-Key", p["value"]? || ""}
          end
        end
        list
      end

      private def self.unresolved_message(skipped : Int32, missing : Set(String)) : String
        shown = missing.to_a.sort!
        names = shown.first(8).map { |n| "{{#{n}}}" }.join(", ")
        names += ", …" if shown.size > 8
        "no flows imported: #{skipped} #{skipped == 1 ? "entry references" : "entries reference"} " \
        "variables not defined in the collection (#{names}) — define them in the collection's " \
        "\"variable\" list, or re-export with the environment merged in"
      end
    end
  end
end
