require "json"
require "../store"
require "../host_overrides"
require "../proxy/codec/content_decode"
require "../repeater/flow_request"
require "../repeater/plan"
require "../repeater/ws_engine"
require "./introspection"

module Gori
  module Graphql
    # A GraphQL endpoint's schema as an agent reads it: the introspection RESULT turned into a
    # compact SDL-like text (root operations first, then the types reachable from them, builtins
    # left out). The headless sibling of the TUI's introspection insert — `graphql_schema` on MCP
    # and `gori run graphql schema` are its two adapters.
    #
    # The result comes from one of two places, and only the second sends anything: a captured
    # flow whose response already IS an introspection result, or a re-send of a captured GraphQL
    # request rewritten by `Introspection.rewrite_request` (`plan_options`), which the surface
    # builds into a `Repeater::Plan` with its own `Outbound`, so the scope gate is the usual one.
    # Nothing is stored: the summary is derived on every call.
    module Schema
      extend self

      # Never part of the summary: the spec's own scalars and the `__` introspection types.
      BUILTIN_SCALARS = {"String", "Int", "Float", "Boolean", "ID"}

      # The compact rendering, the counts that say how much of the schema it covers, and the
      # root type names. `truncated` means the budget cut it; `filter` narrows `types_shown`.
      # `note` says why a schema reads emptier than the endpoint is (`fieldless_note`).
      record Summary, sdl : String, query_type : String?, mutation_type : String?,
        subscription_type : String?, types_total : Int32, types_shown : Int32, truncated : Bool,
        note : String? = nil do
        # The fields both surfaces answer with, after their own `flow_id`/`source`/`status`.
        # Scrubbed: every name in here is the server's bytes, and `JSON::Builder` does not check.
        def emit(j : JSON::Builder) : Nil
          j.field "query_type", query_type.try(&.scrub)
          j.field "mutation_type", mutation_type.try(&.scrub)
          j.field "subscription_type", subscription_type.try(&.scrub)
          j.field "types_total", types_total
          j.field "types_shown", types_shown
          j.field "truncated", truncated
          note.try { |n| j.field "note", n.scrub }
          j.field "sdl", sdl.scrub
        end
      end

      # The `__schema` object of an introspection response, or why the response is not one.
      # `head`/`body` are the stored (or received) response: decoded here, so a gzip answer reads.
      def parse(head : Bytes?, body : Bytes?) : JSON::Any | String
        return "the response has no body" if body.nil? || body.empty?
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        json = begin
          JSON.parse(String.new(decoded || body))
        rescue JSON::ParseException
          return "the response is not JSON"
        end
        if (schema = at(at(json, "data"), "__schema")) && schema.as_h?
          return schema
        end
        # Introspection switched off answers `{"errors":[{"message":…}]}`: say what the server said.
        if msg = at(at(json, "errors").try(&.as_a?).try(&.first?), "message").try(&.as_s?)
          return "#{SERVER_ERROR}#{msg}"
        end
        "the response has no data.__schema"
      end

      private SERVER_ERROR = "the server answered with an error: "

      # Whether `parse`'s refusal is a server that REJECTED the introspection query, the one
      # answer the legacy query (no subscriptionType/directives) can change. A non-JSON answer
      # (a 501 HTML page) is not, and suggesting legacy there sends the agent on an errand.
      def rejected?(reason : String) : Bool
        reason.starts_with?(SERVER_ERROR)
      end

      # The options that re-send `detail`'s request as an introspection query to the same
      # endpoint, with the same session (headers) as captured. The rewritten bytes go out as the
      # capture's do on a flow replay: `evidence` (no `$NAME` expansion of captured headers) and
      # no Content-Length resync, since `rewrite_request` already framed the new body. Raises
      # `Gori::Error` when the stored request has no request line to rewrite, or is a WebSocket
      # handshake: its Upgrade headers would ride the rewritten POST and the send would be spent.
      def plan_options(detail : Store::FlowDetail, *, legacy : Bool = false, verify : Bool = true,
                       timeout : Time::Span? = nil,
                       overrides : HostOverrides? = nil) : Repeater::PlanOptions
        flow = Repeater::FlowRequest.build(detail)
        if Repeater::WsEngine.replayable?(String.new(flow.bytes))
          raise Gori::Error.new("flow #{detail.row.id} is a WebSocket handshake; pick the HTTP GraphQL flow")
        end
        text = Introspection.rewrite_request(String.new(flow.bytes), legacy)
        Repeater::PlanOptions.new([text.to_slice], default_target: flow.target,
          expand_request: false, evidence: true, auto_content_length: false,
          http2: flow.http2, sni: flow.sni, verify: verify, timeout: timeout, overrides: overrides)
      end

      # `schema` as SDL-like text within `max_bytes`. A case-insensitive `filter` keeps a root
      # whose own name contains it whole, the fields of the other roots whose name contains it,
      # and the other types whose name, or one of whose field names, contains it. The cut is by line, so a root type with thousands of fields still
      # answers with as many as fit rather than nothing. A malformed entry (a type with no name,
      # a field that is not an object) is skipped, not raised: the schema is the server's bytes.
      def summarize(schema : JSON::Any, filter : String? = nil, max_bytes : Int32 = 64 * 1024) : Summary
        types = {} of String => JSON::Any
        each_list(schema, "types") do |t|
          name = name_of(t)
          types[name] = t if name && !builtin?(name)
        end
        roots = ["queryType", "mutationType", "subscriptionType"].map { |k| name_of(at(schema, k)) }
        needle = filter.try(&.downcase).presence
        lines = [] of String
        starts = [] of Int32 # the line each shown type opens on
        reachable(types, roots.compact).each do |name|
          t = types[name]
          root = roots.includes?(name)
          next if needle && !root && !matches?(t, needle)
          field_filter = root && needle && !name.downcase.includes?(needle) ? needle : nil
          block = render(t, name, field_filter)
          # A root with no matching field is only its braces.
          next if block.nil? || (field_filter && block.size <= 2)
          starts << lines.size
          lines.concat(block)
        end
        kept = fit(lines, max_bytes)
        # A type counts as shown when the cut left at least its first line.
        Summary.new(lines.first(kept).join('\n'), roots[0], roots[1], roots[2], types.size,
          starts.count(&.< kept), kept < lines.size, fieldless_note(types, roots.compact))
      end

      # A root the introspection lists with no `fields` renders as `type Query {` + `}`, which
      # reads as "this endpoint has no operations". It is usually a narrower query than the
      # full introspection one (`types { name kind }`), so say so.
      private def fieldless_note(types : Hash(String, JSON::Any), roots : Array(String)) : String?
        bare = roots.select { |name| at(types[name]?, "fields").try(&.as_a?).try(&.empty?) != false }
        return nil if bare.empty?
        "the introspection carried no fields for root type #{bare.join(", ")}: the query that produced " \
        "it did not select them, so this is not the endpoint's whole schema; ask again with the full introspection query"
      end

      private def builtin?(name : String) : Bool
        name.starts_with?("__") || BUILTIN_SCALARS.includes?(name)
      end

      # `JSON::Any#[]?` raises on a non-object; the server shaped this document, so never ask it.
      private def at(any : JSON::Any?, key : String) : JSON::Any?
        any.try(&.as_h?).try(&.[key]?)
      end

      private def name_of(any : JSON::Any?) : String?
        at(any, "name").try(&.as_s?)
      end

      private def each_list(any : JSON::Any?, key : String, &) : Nil
        at(any, key).try(&.as_a?).try &.each { |x| yield x if x.as_h? }
      end

      # Every type name reachable from the roots, roots first, then breadth-first through field
      # return types, argument and input-field types, interfaces and possible types.
      private def reachable(types : Hash(String, JSON::Any), roots : Array(String)) : Array(String)
        seen = Set(String).new
        queue = Deque(String).new
        roots.each { |r| queue << r if types.has_key?(r) && seen.add?(r) }
        order = [] of String
        while name = queue.shift?
          order << name
          t = types[name]
          refs = [] of JSON::Any?
          each_list(t, "fields") do |f|
            refs << at(f, "type")
            each_list(f, "args") { |a| refs << at(a, "type") }
          end
          each_list(t, "inputFields") { |f| refs << at(f, "type") }
          each_list(t, "interfaces") { |i| refs << i }
          each_list(t, "possibleTypes") { |i| refs << i }
          refs.each do |ref|
            n = named(ref)
            queue << n if n && types.has_key?(n) && seen.add?(n)
          end
        end
        order
      end

      # The named type under a NON_NULL/LIST wrapper chain.
      private def named(ref : JSON::Any?) : String?
        while ref && ref.as_h?
          if n = name_of(ref)
            return n
          end
          ref = at(ref, "ofType")
        end
        nil
      end

      # `[User!]!` from a TypeRef. Iterative, so a deep wrapper chain cannot recurse.
      private def type_ref(ref : JSON::Any?) : String
        prefix = ""
        suffix = ""
        while ref && ref.as_h?
          case at(ref, "kind").try(&.as_s?)
          when "NON_NULL" then suffix = "!" + suffix
          when "LIST"
            prefix += "["
            suffix = "]" + suffix
          else
            return "#{prefix}#{name_of(ref) || "?"}#{suffix}"
          end
          ref = at(ref, "ofType")
        end
        "#{prefix}?#{suffix}"
      end

      private def matches?(t : JSON::Any, needle : String) : Bool
        return true if name_of(t).try(&.downcase.includes?(needle))
        found = false
        each_list(t, "fields") { |f| found ||= name_of(f).try(&.downcase.includes?(needle)) || false }
        each_list(t, "inputFields") { |f| found ||= name_of(f).try(&.downcase.includes?(needle)) || false }
        found
      end

      # One type as SDL lines, nil for a kind the spec does not have. `field_filter` (roots
      # only) keeps the matching fields.
      private def render(t : JSON::Any, name : String, field_filter : String?) : Array(String)?
        case kind = at(t, "kind").try(&.as_s?)
        when "SCALAR" then ["scalar #{name}"]
        when "ENUM"
          values = [] of String
          each_list(t, "enumValues") { |v| name_of(v).try { |n| values << n } }
          ["enum #{name} { #{values.join(' ')} }"]
        when "UNION"
          members = [] of String
          each_list(t, "possibleTypes") { |p| named(p).try { |n| members << n } }
          ["union #{name} = #{members.join(" | ")}"]
        when "INPUT_OBJECT"
          body = [] of String
          each_list(t, "inputFields") { |f| input_value(f).try { |v| body << "  #{v}" } }
          ["input #{name} {"] + body + ["}"]
        when "OBJECT", "INTERFACE"
          ifaces = [] of String
          each_list(t, "interfaces") { |i| named(i).try { |n| ifaces << n } }
          head = "#{kind == "OBJECT" ? "type" : "interface"} #{name}"
          head += " implements #{ifaces.join(" & ")}" unless ifaces.empty?
          ["#{head} {"] + fields(t, field_filter) + ["}"]
        end
      end

      # An object or interface type's fields, one `  name(args): Type` line each.
      private def fields(t : JSON::Any, field_filter : String?) : Array(String)
        body = [] of String
        each_list(t, "fields") do |f|
          fname = name_of(f) || next
          next if field_filter && !fname.downcase.includes?(field_filter)
          args = [] of String
          each_list(f, "args") { |a| input_value(a).try { |v| args << v } }
          line = "  #{fname}#{args.empty? ? "" : "(#{args.join(", ")})"}: #{type_ref(at(f, "type"))}"
          line += " @deprecated" if at(f, "isDeprecated").try(&.as_bool?)
          body << line
        end
        body
      end

      private def input_value(v : JSON::Any) : String?
        name = name_of(v) || return nil
        s = "#{name}: #{type_ref(at(v, "type"))}"
        (d = at(v, "defaultValue").try(&.as_s?)) ? "#{s} = #{d}" : s
      end

      # How many of `lines`, joined with newlines, fit `max_bytes`.
      private def fit(lines : Array(String), max_bytes : Int32) : Int32
        used = 0
        kept = 0
        lines.each do |line|
          break if used + line.bytesize + 1 > max_bytes
          used += line.bytesize + 1
          kept += 1
        end
        kept
      end
    end
  end
end
