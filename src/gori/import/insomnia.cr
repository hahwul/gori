require "json"
require "uri"
require "base64"
require "./builder"
require "./vars"

module Gori
  module Import
    # Insomnia's v4 JSON export (Application → Preferences → Data → Export Data → Insomnia
    # v4 JSON). Like Postman this describes requests rather than captured traffic, so every
    # entry lands as a response-less template via `Builder.pending_request`.
    #
    # Same bounds as `Postman`: auth seeds only bearer / basic / apikey-in-header, a
    # `file`-typed form part is dropped, and a binary body (`fileName` with no `text`) is
    # skipped rather than read off the exporter's disk.
    module Insomnia
      # Only HTTP requests. `websocket_request` and `grpc_request` are separate resource
      # types that History has no request-shaped representation for.
      REQUEST_TYPE = "request"

      def self.parse_file(path : String, prov : Provenance = Provenance.none) : ParseResult
        raw = File.read(path).lchop('\u{FEFF}')
        # v5 (Insomnia 9+) exports YAML with a different tree entirely. Detect it by shape
        # AND by extension so a mis-named file still gets the actionable message instead of
        # "not valid JSON".
        if v5?(raw) || File.extname(path).downcase.in?(".yaml", ".yml")
          raise Gori::Error.new("this looks like an Insomnia v5 (YAML) export — re-export as \"Insomnia v4 (JSON)\"")
        end
        doc = begin
          JSON.parse(raw)
        rescue ex : JSON::ParseException
          raise Gori::Error.new("Insomnia export is not valid JSON: #{ex.message}")
        end
        root = doc.as_h? || raise Gori::Error.new("Insomnia export is not a JSON object")
        resources = root["resources"]?.try(&.as_a?)
        raise Gori::Error.new("Insomnia export has no `resources` array — is this an Insomnia v4 export?") unless resources

        vars = environment_table(resources)
        groups = request_groups(resources)
        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        missing = Set(String).new
        skipped = 0
        found = 0
        resources.each do |res|
          h = res.as_h?
          next unless h
          next unless h["_type"]?.to_s == REQUEST_TYPE
          found += 1
          # One bad request skips; the rest of the export still imports.
          begin
            pairs << Vars.per_entry { resource_to_flow(now, h, folder_vars(h, groups, vars), missing, prov) }
          rescue
            skipped += 1
          end
        end
        raise Gori::Error.new("Insomnia export has no request resources") if found == 0
        # Same reasoning as Postman: a workspace whose `{{ _.base_url }}` lives in an
        # environment that was not exported must not be reported as "malformed".
        raise Gori::Error.new(unresolved_message(skipped, missing)) if pairs.empty? && !missing.empty?
        ParseResult.new(pairs, skipped)
      end

      private def self.v5?(raw : String) : Bool
        raw.includes?("collection.insomnia.rest/5") || raw.lstrip.starts_with?("type: collection")
      end

      # Insomnia keeps variables in `environment` resources: one BASE environment parented to
      # the workspace, plus sub-environments parented to that base. Merge base first, then the
      # first sub-environment — merging every sub would make the winner depend on export
      # order, which is worse than picking one deterministically.
      private def self.environment_table(resources : Array(JSON::Any)) : Vars::Table
        envs = resources.compact_map do |res|
          h = res.as_h?
          next unless h
          next unless h["_type"]?.to_s == "environment"
          h
        end
        ids = envs.compact_map(&.["_id"]?.to_s.presence).to_set
        base, subs = envs.partition { |h| !ids.includes?(h["parentId"]?.to_s) }
        table = Vars::Table.new
        (base + subs.first(1)).each do |h|
          data = h["data"]?.try(&.as_h?)
          next unless data
          flatten_into(table, data)
        end
        table
      end

      # Nunjucks resolves `{{ _.api.host }}` through nested objects, so a nested value is also
      # filed under its dotted path. A later environment REPLACES an object wholesale, so the
      # dotted keys an earlier one filed under that name go first.
      private def self.flatten_into(table : Vars::Table, data : Hash(String, JSON::Any), prefix : String = "") : Nil
        data.each do |k, v|
          key = prefix.empty? ? k : "#{prefix}.#{k}"
          table.reject! { |name, _| name.starts_with?("#{key}.") }
          table[key] = Vars.value_to_s(v)
          v.as_h?.try { |nested| flatten_into(table, nested, key) }
        end
      end

      # The `request_group` (folder) resources by id, for `folder_vars` to walk.
      private def self.request_groups(resources : Array(JSON::Any)) : Hash(String, Hash(String, JSON::Any))
        resources.compact_map { |r| (h = r.as_h?) && h["_type"]?.to_s == "request_group" ? {h["_id"]?.to_s, h} : nil }.to_h
      end

      # Insomnia layers each enclosing folder's `environment` over the workspace's, outermost
      # first, so a request's `{{ _.base_url }}` may be defined on its folder alone.
      private def self.folder_vars(res : Hash(String, JSON::Any), groups : Hash(String, Hash(String, JSON::Any)),
                                   vars : Vars::Table) : Vars::Table
        chain = [] of Hash(String, JSON::Any)
        seen = Set(String).new
        id = res["parentId"]?.to_s
        while (group = groups[id]?) && seen.add?(id) # `seen`: a parentId cycle ends the walk
          chain << group
          id = group["parentId"]?.to_s
        end
        return vars if chain.empty?
        table = vars.dup
        chain.reverse_each { |g| g["environment"]?.try(&.as_h?).try { |env| flatten_into(table, env) } }
        table
      end

      private def self.resource_to_flow(now : Int64, res : Hash(String, JSON::Any),
                                        vars : Vars::Table, missing : Set(String),
                                        prov : Provenance) : Builder::FlowPair
        method = res["method"]?.to_s.presence || "GET"
        url = resolve_url(res, vars, missing)
        headers = header_list(res["headers"]?, vars)
        body, content_type = body_of(res["body"]?, vars)
        if content_type
          if i = headers.index { |(k, _)| k.compare("content-type", case_insensitive: true) == 0 }
            # Insomnia writes its own `multipart/form-data` header and frames the parts with a
            # boundary it picks when it sends; the body here is framed with gori's, so the
            # header must name that one, whatever boundary (if any) it was exported with.
            name, value = headers[i]
            if value.downcase.starts_with?("multipart/form-data") && content_type.includes?("boundary=")
              headers[i] = {name, content_type}
            end
          else
            headers << {"Content-Type", content_type}
          end
        end
        # Insomnia adds its auth header only when the request does not already carry one.
        auth_headers(res["authentication"]?, vars).each do |pair|
          headers << pair unless headers.any? { |(k, _)| k.compare(pair[0], case_insensitive: true) == 0 }
        end
        Builder.pending_request(now, url, method, headers, body,
          source_surface: prov.surface, source_ref: prov.ref)
      end

      # `url` plus the separate `parameters` array (Insomnia's query-param editor). Both are
      # variable-expanded; a leftover `{{ … }}` in the URL rejects the entry HERE so the
      # message names the unset variable — `Builder::HOST_VALID` would refuse
      # `{{ _.base_url }}` as a host as well, but only as a generic bad-host skip.
      private def self.resolve_url(res : Hash(String, JSON::Any),
                                   vars : Vars::Table, missing : Set(String)) : String
        url = Vars.expand(res["url"]?.to_s.strip, vars)
        query = query_string(res["parameters"]?, vars)
        Vars.checked_url(Builder.append_query(url, query), missing)
      end

      private def self.query_string(node : JSON::Any?, vars : Vars::Table) : String
        URI::Params.build { |f| named(node, vars).each { |(k, v)| f.add(k, v) } }
      end

      # Insomnia's rows are `{name, value, disabled}` (Postman uses `key`); `Vars.merge!`
      # already accepts either, but headers and params must keep their ORDER and may repeat,
      # so they are collected as a list rather than a table.
      private def self.named(node : JSON::Any?, vars : Vars::Table) : Array({String, String})
        arr = node.try(&.as_a?)
        return [] of {String, String} unless arr
        arr.compact_map do |item|
          h = item.as_h?
          next unless h
          next if h["disabled"]?.try(&.as_bool?) == true
          name = h["name"]?.to_s
          next if name.empty?
          {Vars.expand(name, vars), Vars.expand(Vars.value_to_s(h["value"]?), vars)}
        end
      end

      private def self.header_list(node : JSON::Any?, vars : Vars::Table) : Builder::Headers
        list = Builder::Headers.new
        named(node, vars).each { |pair| list << pair }
        list
      end

      private def self.body_of(node : JSON::Any?, vars : Vars::Table) : {Bytes?, String?}
        h = node.try(&.as_h?)
        return {nil, nil} unless h
        mime = h["mimeType"]?.to_s
        case mime
        when "application/x-www-form-urlencoded"
          pairs = named(h["params"]?, vars)
          return {nil, nil} if pairs.empty?
          {URI::Params.build { |f| pairs.each { |(k, v)| f.add(k, v) } }.to_slice, mime}
        when "multipart/form-data"
          Vars.form_data(h["params"]?) { |rows| named(rows, vars) }
        else
          # Everything else is stored as `text` — JSON, XML, GraphQL (already a JSON
          # `{query, variables}` document), plain text. A body with only `fileName` names a
          # path on the exporter's disk and yields no body at all.
          text = Vars.expand(Vars.value_to_s(h["text"]?), vars)
          return {nil, nil} if text.empty?
          {text.to_slice, mime.presence}
        end
      end

      private def self.auth_headers(node : JSON::Any?, vars : Vars::Table) : Builder::Headers
        list = Builder::Headers.new
        h = node.try(&.as_h?)
        return list unless h
        return list if h["disabled"]?.try(&.as_bool?) == true
        field = ->(key : String) { Vars.expand(Vars.value_to_s(h[key]?), vars) }
        case h["type"]?.to_s
        when "bearer"
          prefix = field.call("prefix").presence || "Bearer"
          list << {"Authorization", "#{prefix} #{field.call("token")}"}
        when "basic"
          list << {"Authorization", "Basic #{Base64.strict_encode("#{field.call("username")}:#{field.call("password")}")}"}
        when "apikey"
          # `addTo` is "header" (default) or "queryParams"; only the header form is seeded,
          # for the same reason as Postman — the URL is already built and validated by here.
          if field.call("addTo").presence.in?(nil, "header")
            list << {field.call("key").presence || "X-API-Key", field.call("value")}
          end
        end
        list
      end

      private def self.unresolved_message(skipped : Int32, missing : Set(String)) : String
        shown = missing.to_a.sort!
        names = shown.first(8).map { |n| "{{#{n}}}" }.join(", ")
        names += ", …" if shown.size > 8
        "no flows imported: #{skipped} #{skipped == 1 ? "request references" : "requests reference"} " \
        "variables not present in the exported environments (#{names}) — export the workspace with " \
        "its environment, or define them in the base environment"
      end
    end
  end
end
