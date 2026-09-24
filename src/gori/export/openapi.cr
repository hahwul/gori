require "json"
require "yaml"
require "http/status"
require "../entity"
require "../media_type"
require "../params"
require "../param_inventory"
require "../proto"
require "../ql"
require "../redact"
require "../redact/headers"
require "../sitemap"
require "../store"
require "../url"
require "./openapi/schema"
require "./openapi/template"

module Gori
  module Export
    # An OpenAPI 3.0.3 document inferred from captured traffic (#1241) — the most portable
    # hand-off a recon pass has: Postman, Burp, ZAP, schemathesis and gori's own `--oas` import
    # all read it.
    #
    # Pure and core, in the shape of `Issues::Export.sarif`: it takes the store and options and
    # returns a document plus a report, and knows no surface. Recomputed ON DEMAND and never on
    # the capture path (P6); the flow walk is `ParamInventory.each_flow`, the same newest-first
    # pager the parameter inventory reads with, and parameters come from `Params` (#1231).
    #
    # What the document claims is what the samples PROVE, nothing more:
    #
    #   * paths are templated per path (`Template`), and endpoints whose templates collide merge
    #     into one operation — `/users/1` and `/users/2` are `/users/{userId}`;
    #   * a parameter is `required` only when EVERY sample of its operation carried it;
    #   * request and response bodies get a schema inferred from every sample (`Schema`);
    #   * credentials become SECURITY SCHEMES (`Authorization: Bearer` → http/bearer, an API-key
    #     header → apiKey, a session cookie → apiKey in cookie), never parameters, and their
    #     values are never emitted.
    #
    # No `example` appears unless asked for; with `examples` each value passes the redaction
    # profile first (see `Options#redactor`). The output is DETERMINISTIC — sorted paths,
    # methods, parameters, properties, statuses and media types, no timestamps — so exporting the
    # same flow set twice gives the same bytes, and a diff between two exports is a change in
    # the API.
    module OpenApi
      extend self

      VERSION = "3.0.3"

      # The operations a Path Item can hold, in the order the OpenAPI text lists them. Any other
      # method (CONNECT, WebDAV's PROPFIND, a custom verb) has no place to go and is skipped.
      METHODS = %w[get put post delete options head patch trace]

      # The `responses` slot for a status OpenAPI has no key for (see `OpAcc#odd_statuses`).
      DEFAULT_STATUS = -1

      # Largest example one media type carries, serialized. A 2 MiB JSON response pasted into a
      # spec is not an example, it is a capture.
      EXAMPLE_MAX = 16 * 1024

      DESCRIPTION = "Inferred by gori from captured traffic. Types, `required` flags and " \
                    "response codes reflect the samples that were captured, not a contract."

      # `filter` is the flow set (a QL filter; scope and the static-asset lens are joined in by
      # the caller). `host` is exact and case-insensitive. `path_prefix` is a plain prefix of the
      # endpoint path, as `sitemap params --path` reads it. `targets` narrows to a set the TUI
      # picked: host → the endpoint paths wanted under it, or nil for the whole host.
      #
      # `max_flows` bounds the flows READ (a row that is skipped or whose operation is already
      # full costs a row read, not a flow read); `max_samples` is the per-operation sample cap;
      # `body_max` the decoded bytes one body may have for its schema to be inferred.
      #
      # `examples` turns on `example` values, and `redactor` is the profile they pass through —
      # resolved by the SURFACE (`Redact::Policy.resolve` mints the placeholder salt, a side
      # effect this engine does not take on). With examples on and no redactor, the built-in
      # default profile is used; there is no way to ask this engine for unredacted examples.
      record Options,
        filter : QL::Filter = QL::EMPTY,
        host : String? = nil,
        path_prefix : String? = nil,
        targets : Hash(String, Set(String)?)? = nil,
        max_flows : Int32 = 5000,
        max_endpoints : Int32 = 1000,
        max_samples : Int32 = 20,
        body_max : Int32 = Params::DECODE_MAX,
        examples : Bool = false,
        redactor : Redact::Matcher? = nil

      # Why a flow in the set contributed nothing.
      enum Skip
        WebSocket
        Grpc
        Sse
        Incomplete
        Method
        Target

        # The stable machine key (MCP's `skipped` object).
        def key : String
          case self
          in WebSocket  then "websocket"
          in Grpc       then "grpc"
          in Sse        then "sse"
          in Incomplete then "incomplete"
          in Method     then "method"
          in Target     then "target"
          end
        end

        def label : String
          case self
          in WebSocket  then "WebSocket"
          in Grpc       then "gRPC"
          in Sse        then "SSE"
          in Incomplete then "no complete response"
          in Method     then "method OpenAPI cannot hold"
          in Target     then "not an origin-form path"
          end
        end
      end

      # Everything a surface has to SAY about an export: its size, what was left out and why,
      # and which caps were hit. The document never carries any of it (no timestamps, no counts
      # that would make two exports of one API differ).
      class Report
        getter skipped = {} of Skip => Int32
        property operations = 0
        property paths = 0
        property hosts = [] of String
        property flows_read = 0
        # `max_flows` stopped the walk with older matching flows left unread.
        property? flows_truncated = false
        # Distinct operations left out because `max_endpoints` was reached.
        property endpoints_dropped = 0
        # Flows not read because their operation already had `max_samples`.
        property samples_capped = 0
        # Bodies whose schema was not inferred: over `body_max`, or declared JSON and not JSON.
        property bodies_too_large = 0
        property bodies_unparsed = 0
        # Paths dropped by a byte cap (`fit`).
        property paths_dropped = 0
        # Example values replaced by a placeholder, and examples left out for size.
        property redacted = 0
        property examples_omitted = 0

        def skip(reason : Skip) : Nil
          @skipped[reason] = @skipped.fetch(reason, 0) + 1
        end

        # Any cap cut the document short.
        def truncated? : Bool
          flows_truncated? || endpoints_dropped > 0 || paths_dropped > 0
        end

        # The sentences for the caps that cut the document short — what `truncated?` means.
        def cap_notes : Array(String)
          out = [] of String
          out << "read the newest #{flows_read} flows (max flows); older flows are not in the document" if flows_truncated?
          out << "#{count(endpoints_dropped, "operation")} left out (max endpoints)" if endpoints_dropped > 0
          out << "#{count(paths_dropped, "path")} left out (byte cap)" if paths_dropped > 0
          out
        end

        def summary : String
          "#{count(operations, "operation")} on #{count(paths, "path")} from #{count(flows_read, "flow")}" \
          "#{hosts.size > 1 ? " across #{hosts.size} hosts" : ""}"
        end

        # One sentence per fact worth stating, in a fixed order: what was skipped, which caps cut
        # the document short, then what was read but not fully used.
        def notes : Array(String)
          out = [] of String
          unless @skipped.empty?
            parts = Skip.values.compact_map { |s| (n = @skipped[s]?) ? "#{n} #{s.label}" : nil }
            out << "skipped #{parts.join(", ")}"
          end
          out.concat(cap_notes)
          out.concat(read_notes)
        end

        private def read_notes : Array(String)
          out = [] of String
          out << "#{count(samples_capped, "flow")} not read: operation already had max samples" if samples_capped > 0
          out << "#{count(bodies_too_large, "body", "bodies")} over the size cap or cut short had no schema inferred" if bodies_too_large > 0
          out << "#{count(bodies_unparsed, "body", "bodies")} declared JSON but did not parse" if bodies_unparsed > 0
          out << "#{count(redacted, "example value")} redacted" if redacted > 0
          out << "#{count(examples_omitted, "example")} over #{EXAMPLE_MAX // 1024} KiB left out" if examples_omitted > 0
          out
        end

        private def count(n : Int32, one : String, many : String = "#{one}s") : String
          "#{n} #{n == 1 ? one : many}"
        end
      end

      # `doc` is the OpenAPI document as a JSON value (object keys already in output order).
      record Result, doc : JSON::Any, report : Report

      # How a body's media type is described.
      private enum BodyKind
        Json
        Form
        Multipart
        Text
        Binary
      end

      # One parameter of one operation, across its samples.
      private class ParamAcc
        getter schema = Schema.new
        property present = 0
        property? repeated = false
        property example : String? = nil
      end

      # One media type of a request body or of one response status.
      private class BodyAcc
        getter kind : BodyKind
        getter schema = Schema.new
        getter fields = {} of String => Schema
        getter field_counts = {} of String => Int32
        property forms = 0
        property example : JSON::Any? = nil

        def initialize(@kind : BodyKind)
        end
      end

      # One (templated path, method) across its samples.
      private class OpAcc
        getter template : Template::Result
        getter method : String
        property samples = 0
        getter path_kinds : Array(Set(Template::Kind))
        getter path_examples : Array(String?)
        getter params = {} of {String, String} => ParamAcc
        getter bodies = {} of String => BodyAcc
        property body_samples = 0
        getter responses = {} of Int32 => Hash(String, BodyAcc)
        # Statuses outside 100–599 (LinkedIn's 999, a broken origin's 0-padded 7): OpenAPI's
        # response keys are `1XX`–`5XX` only, so these share the `default` response (key
        # DEFAULT_STATUS) and are named in its description.
        getter odd_statuses = Set(Int32).new
        getter security = Set(Array(String)).new
        getter origins = Set(String).new
        getter hosts = Set(String).new

        def initialize(@template : Template::Result, @method : String)
          @path_kinds = @template.params.map { Set(Template::Kind).new }
          @path_examples = @template.params.map { nil.as(String?) }
        end
      end

      # The per-build state threaded through the sample readers.
      private class Build
        getter opts : Options
        getter report = Report.new
        getter ops = {} of {String, String} => OpAcc
        getter schemes = {} of String => JSON::Any
        getter hits = [] of Redact::Hit
        getter dropped = Set({String, String}).new
        getter matcher : Redact::Matcher?

        def initialize(@opts : Options)
          @matcher = @opts.examples ? (@opts.redactor || Redact::Matcher.new(Redact::DEFAULT_PROFILE)) : nil
        end
      end

      # Build the document.
      def build(store : Store, opts : Options = Options.new) : Result
        b = Build.new(opts)
        pending = {"", ""}
        # The key `admit` computed rides from the row check to the flow read, so a row's path is
        # templated once on the way in rather than again inside the block.
        keep = ->(row : Store::FlowRow) do
          key = admit(b, row)
          pending = key if key
          !key.nil?
        end
        read, truncated = ParamInventory.each_flow(store, sql_filter(opts), opts.max_flows, keep, -> { false }) do |row|
          next unless detail = store.get_flow(row.id)
          key = pending
          op = b.ops[key] ||= OpAcc.new(Template.of(endpoint_path(row.target)), key[1])
          add_sample(b, op, detail)
        end
        b.report.flows_read = read
        b.report.flows_truncated = truncated
        b.report.endpoints_dropped = b.dropped.size
        b.report.redacted = b.hits.size
        Result.new(render(b), b.report)
      end

      # The endpoint key a target lands on: the Sitemap's node path with the query cut.
      def endpoint_path(target : String) : String
        ParamInventory.endpoint_path(target)
      end

      # The document as JSON text (two-space indent, trailing newline).
      def to_json(doc : JSON::Any) : String
        "#{doc.to_pretty_json}\n"
      end

      def to_yaml(doc : JSON::Any) : String
        doc.to_yaml
      end

      # The document cut to at most `max_bytes` of compact JSON by dropping whole paths from the
      # END of the sorted path list — for a surface that returns the document inline (MCP). The
      # paths that stay are complete; a half-written operation would be worse than a missing
      # one. Returns the document and how many paths were dropped.
      def fit(doc : JSON::Any, max_bytes : Int32) : {JSON::Any, Int32}
        h = doc.as_h
        paths = h["paths"]?.try(&.as_h?) || return {doc, 0}
        return {doc, 0} if doc.to_json.bytesize <= max_bytes
        rest = h.dup
        rest["paths"] = JSON::Any.new({} of String => JSON::Any)
        budget = max_bytes - rest.to_json.bytesize
        kept = {} of String => JSON::Any
        paths.each do |k, v|
          cost = k.to_json.bytesize + 1 + v.to_json.bytesize + 1 # key, colon, value, comma
          break if cost > budget
          budget -= cost
          kept[k] = v
        end
        rest["paths"] = JSON::Any.new(kept)
        {JSON::Any.new(rest), paths.size - kept.size}
      end

      # --- admission (row-level, before any body is read) -------------------------------

      # The flow set as SQL: the caller's filter, AND an exact host when one is named (QL's
      # `host:` is a substring — "api.test" must not also read "sub.api.test"), AND the target
      # hosts when the TUI named some.
      private def sql_filter(opts : Options) : QL::Filter
        f = opts.filter
        if h = opts.host.try(&.strip).presence
          f = QL.and(f, QL::Filter.new("host = ? COLLATE NOCASE", [h] of DB::Any))
        end
        if (t = opts.targets) && !t.empty?
          marks = Array.new(t.size, "?").join(", ")
          f = QL.and(f, QL::Filter.new("host IN (#{marks})", t.keys.map { |k| k.as(DB::Any) }))
        end
        f
      end

      # The operation key a row lands on, or nil when it contributes nothing (counted in the
      # report when that is a SKIP; a row outside the selection is simply not in the set).
      private def admit(b : Build, row : Store::FlowRow) : {String, String}?
        opts = b.opts
        path = endpoint_path(row.target)
        if t = opts.targets
          return nil unless t.has_key?(row.host)
          if (wanted = t[row.host]) && !wanted.includes?(path)
            return nil
          end
        end
        if (prefix = opts.path_prefix.presence) && !path.starts_with?(prefix)
          return nil
        end
        if reason = skip_reason(row)
          b.report.skip(reason)
          return nil
        end
        key = {Template.of(path).path, row.method.downcase}
        if op = b.ops[key]?
          if op.samples >= opts.max_samples
            b.report.samples_capped += 1
            return nil
          end
        elsif b.ops.size >= opts.max_endpoints
          b.dropped << key
          return nil
        end
        key
      end

      # Classified on the ROW (`Proto.classify`, the History PROTO column's own answer), so a
      # skipped flow costs no body read. gRPC has its own schema path (`grpc_reflect`), and a
      # socket or a stream is not a request/response pair an operation can describe.
      private def skip_reason(row : Store::FlowRow) : Skip?
        case Proto.classify(row.status, row.content_type, row.request_content_type, row.connect_protocol)
        in .ws?   then return Skip::WebSocket
        in .grpc? then return Skip::Grpc
        in .sse?  then return Skip::Sse
        in .http?
        end
        return Skip::Incomplete unless row.state.complete? && (s = row.status) && s > 0
        return Skip::Method unless METHODS.includes?(row.method.downcase)
        return Skip::Target unless Sitemap.normalize_path(row.target).starts_with?('/')
        nil
      end

      # --- one sample -------------------------------------------------------------------

      private def add_sample(b : Build, op : OpAcc, detail : Store::FlowDetail) : Nil
        row = detail.row
        op.samples += 1
        op.origins << origin(row)
        op.hosts << row.host
        tpl = Template.of(endpoint_path(row.target))
        tpl.params.each_with_index do |p, i|
          next unless i < op.path_kinds.size
          op.path_kinds[i] << p.kind
          if b.matcher && op.path_examples[i].nil? && path_example?(p)
            op.path_examples[i] = p.raw
          end
        end
        fields = add_inputs(b, op, detail)
        add_request_body(b, op, detail, fields)
        add_response(b, op, detail)
      end

      # Whether a path value may be shown as an example. An opaque id (uuid/hex/token) is
      # indistinguishable from a credential in a path, so only a short counter or a date is — and
      # not one filed under a secret-sounding segment (`/otp/482913`). Past nine digits a number
      # is an account, card or phone number more often than a row id.
      private def path_example?(p : Template::Param) : Bool
        return false if (prev = p.prev) && secret_name?(prev)
        p.kind.date? || (p.kind.integer? && p.raw.size <= 9)
      end

      # Query, header and cookie parameters, and the security schemes the credentials imply.
      # Returns the urlencoded/multipart BODY fields, which the request-body pass reads: one
      # `Params` walk per sample, not one per question.
      private def add_inputs(b : Build, op : OpAcc, detail : Store::FlowDetail) : Array(Params::Param)
        head = detail.request_head
        # A JSON body is read by the schema pass, not as parameters, so it is not handed to
        # `Params` (which would walk and decode it for nothing).
        body = MediaType.json?(MediaType.of(head)) ? nil : detail.request_body
        seen = {} of {String, String} => Array(String)
        schemes = Set(String).new
        fields = [] of Params::Param
        Params.each(head, body) do |p|
          case p.loc
          when .form?, .multipart?
            fields << p
          when .query?
            (seen[{"query", p.name}] ||= [] of String) << p.value
          when .headers?
            if name = header_scheme(b, p.name, p.value)
              schemes << name
            else
              (seen[{"header", p.name}] ||= [] of String) << p.value
            end
          when .cookies?
            if session_cookie?(p.name)
              schemes << cookie_scheme(b, p.name)
            else
              (seen[{"cookie", p.name}] ||= [] of String) << p.value
            end
          end
        end
        seen.each do |key, values|
          acc = op.params[key] ||= ParamAcc.new
          acc.present += 1
          acc.repeated = true if values.size > 1
          values.each { |v| acc.schema.observe_text(v) }
          if b.matcher && acc.example.nil?
            acc.example = key[0] == "cookie" ? placeholder(b, key[1], values[0]) : redact_named(b, key[1], values[0])
          end
        end
        op.security << schemes.to_a.sort!
        fields
      end

      private def add_request_body(b : Build, op : OpAcc, detail : Store::FlowDetail,
                                   fields : Array(Params::Param)) : Nil
        head = detail.request_head
        entity, whole = entity_of(head, detail.request_body, b.opts.body_max)
        return if entity.nil? || entity.empty?
        op.body_samples += 1
        ctype = MediaType.of(head)
        media = MediaType.essence(ctype) || "application/octet-stream"
        kind = body_kind(media)
        acc = op.bodies[media] ||= BodyAcc.new(kind)
        case kind
        when .form?, .multipart?
          observe_form(b, acc, fields, kind)
        else
          observe_body(b, acc, entity, whole, ctype)
        end
      end

      private def add_response(b : Build, op : OpAcc, detail : Store::FlowDetail) : Nil
        status = detail.row.status || return
        key = status
        unless 100 <= status <= 599
          op.odd_statuses << status
          key = DEFAULT_STATUS
        end
        content = op.responses[key] ||= {} of String => BodyAcc
        return if op.method == "head" || status < 200 || status == 204 || status == 304
        head = detail.response_head
        entity, whole = entity_of(head, detail.response_body, b.opts.body_max)
        return if entity.nil? || entity.empty?
        ctype = MediaType.of(head)
        media = MediaType.essence(ctype) || "application/octet-stream"
        kind = body_kind(media)
        # A form or multipart RESPONSE is rare enough, and `Params` reads request forms only.
        kind = BodyKind::Text if kind.form?
        kind = BodyKind::Binary if kind.multipart?
        acc = content[media] ||= BodyAcc.new(kind)
        observe_body(b, acc, entity, whole, ctype)
      end

      # The entity behind a stored body (`Entity`'s reading), and whether it is WHOLE: false
      # when a content coding stopped early — the body was cut at the capture cap, or inflating
      # it hit `max` — so a JSON body that then fails to parse is reported as too large rather
      # than as "declared JSON but not JSON", which would be a claim about the origin.
      private def entity_of(head : Bytes?, body : Bytes?, max : Int32) : {Bytes?, Bool}
        return {body, true} if body.nil? || body.empty?
        decoded, _, complete = Proxy::Codec::ContentDecode.decode_full(head, body, max)
        decoded ? {decoded, complete} : {body, true}
      end

      # A JSON, text or binary entity. Only JSON has a shape to infer; the other two are named
      # by their media type alone.
      private def observe_body(b : Build, acc : BodyAcc, entity : Bytes, whole : Bool, ctype : String?) : Nil
        return unless acc.kind.json?
        if !whole || entity.size > b.opts.body_max
          b.report.bodies_too_large += 1
          return
        end
        text = String.new(entity)
        unless acc.schema.observe_json(text)
          b.report.bodies_unparsed += 1
          return
        end
        return unless (m = b.matcher) && acc.example.nil?
        result = m.body(entity, ctype)
        return unless result.shape.json?
        if result.text.bytesize > EXAMPLE_MAX
          b.report.examples_omitted += 1
          return
        end
        b.hits.concat(result.hits)
        acc.example = JSON.parse(result.text)
      end

      # An urlencoded or multipart request body, from the fields `Params` reads off it (the
      # PARAMS pane's projection — entity-aware, so a chunked or gzip'd form is not garbage).
      private def observe_form(b : Build, acc : BodyAcc, fields : Array(Params::Param), kind : BodyKind) : Nil
        acc.forms += 1
        present = Set(String).new
        example = b.matcher && acc.example.nil? ? {} of String => JSON::Any : nil
        fields.each do |p|
          schema = acc.fields[p.name] ||= Schema.new
          if p.note
            schema.observe_binary
          else
            schema.observe_text(p.value)
          end
          acc.field_counts[p.name] = acc.field_counts.fetch(p.name, 0) + 1 if present.add?(p.name)
          if example && !example.has_key?(p.name.scrub)
            # A file part has no value to show; its name is enough.
            example[p.name.scrub] = JSON::Any.new(p.note ? "" : redact_named(b, p.name, p.value).scrub)
          end
        end
        acc.example = JSON::Any.new(example) if example && kind.form?
      end

      private def body_kind(media : String) : BodyKind
        return BodyKind::Json if MediaType.json?(media)
        return BodyKind::Form if MediaType.form_urlencoded?(media)
        return BodyKind::Multipart if MediaType.multipart?(media)
        return BodyKind::Text if media.starts_with?("text/") || media.ends_with?("/xml") || media.ends_with?("+xml")
        BodyKind::Binary
      end

      # --- credentials → security schemes -------------------------------------------------

      # The scheme a request header implies, registered on first sight, or nil for an ordinary
      # header parameter. `Authorization` by its scheme word; any other credential header
      # (`Redact::SENSITIVE_HEADERS`) as an apiKey carried in that header.
      private def header_scheme(b : Build, name : String, value : String) : String?
        if name == "authorization"
          word = value.strip.split(' ', 2)[0].downcase
          case word
          when "bearer"
            return scheme(b, "bearerAuth", {"type" => "http", "scheme" => "bearer"})
          when "basic"
            return scheme(b, "basicAuth", {"type" => "http", "scheme" => "basic"})
          when "digest"
            return scheme(b, "digestAuth", {"type" => "http", "scheme" => "digest"})
          else
            return scheme(b, "authorizationHeader", {"type" => "apiKey", "in" => "header", "name" => "Authorization"})
          end
        end
        return nil unless Redact.sensitive_header?(name)
        scheme(b, "header.#{scheme_key(name)}", {"type" => "apiKey", "in" => "header", "name" => name.scrub})
      end

      private def cookie_scheme(b : Build, name : String) : String
        scheme(b, "cookie.#{scheme_key(name)}", {"type" => "apiKey", "in" => "cookie", "name" => name.scrub})
      end

      private def scheme(b : Build, key : String, fields : Hash(String, String)) : String
        b.schemes[key] ||= JSON::Any.new(fields.transform_values { |v| JSON::Any.new(v) })
        key
      end

      # A components key must match `^[a-zA-Z0-9.\-_]+$`.
      private def scheme_key(name : String) : String
        name.scrub.gsub(/[^A-Za-z0-9._-]/, "_")
      end

      # A cookie that carries a session rather than a preference: a name the built-in redaction
      # profile lists (`sid`, `session`, `jsessionid`, …) or the framework spellings of the same
      # (`PHPSESSID`, `laravel_session`, `connect.sid`, `auth_token`). Anti-CSRF cookies are
      # left as parameters: they are not what authenticates the request.
      private def session_cookie?(name : String) : Bool
        n = name.downcase
        return false if n.includes?("csrf") || n.includes?("xsrf")
        ParamInventory::SENSITIVE_NAMES.includes?(n) || n.includes?("sess") || n.includes?("auth") ||
          n.includes?("token") || n.ends_with?("sid") || n.ends_with?("jwt")
      end

      # --- examples ------------------------------------------------------------------------

      # An example value for a named input. Three nets, widest last: the fixed credential
      # headers, a NAME that sounds like a secret (`secret_name?` — the profile's lists are
      # exact underscore spellings, and `X-Access-Token`, `Private-Token`, `?key=`, `?api-key=`,
      # `?sig=` are none of them), then the profile itself, names and value patterns.
      # Over-redacting an example costs a placeholder; under-redacting one publishes a key.
      private def redact_named(b : Build, name : String, value : String) : String
        m = b.matcher || return value
        return placeholder(b, name, value, "sensitive name") if Redact.sensitive_header?(name) || secret_name?(name)
        m.named_value(name, value, b.hits)
      end

      # Words that make a parameter NAME a credential wherever they appear as a word of it, and
      # the few that do even run into another word (`accesstoken`, `apikey`).
      SECRET_WORDS = Set{"token", "key", "secret", "signature", "sig", "auth", "session", "sessid",
                         "password", "passwd", "pwd", "pass", "csrf", "xsrf", "credential",
                         "credentials", "code", "otp", "pin", "jwt", "bearer", "cookie"}
      SECRET_INFIXES = {"token", "secret", "passw", "signature", "apikey", "sessid", "session", "authoriz"}

      # `X-Access-Token`, `private_token`, `apiKey`, `X-Amz-Signature`, `sig` — by the words of
      # the name (split on punctuation AND on a lower→upper case change), case-insensitively.
      def secret_name?(name : String) : Bool
        n = name.scrub
        words = n.gsub(/([a-z0-9])([A-Z])/, "\\1 \\2").downcase.split(/[^a-z0-9]+/)
        words.any? { |w| SECRET_WORDS.includes?(w) } || SECRET_INFIXES.any? { |s| n.downcase.includes?(s) }
      end

      # A cookie value always travels as a placeholder, like every cookie value any
      # sanitized surface prints: which cookies carry the session is not knowable from a name.
      private def placeholder(b : Build, name : String, value : String, rule : String = "cookie") : String
        ph = Redact.placeholder(value)
        b.hits << Redact::Hit.new(name, rule, ph)
        ph
      end

      # --- rendering -----------------------------------------------------------------------

      private def origin(row : Store::FlowRow) : String
        Gori::Url.request_url(row.scheme, row.host, "/", row.port).chomp('/').scrub
      end

      private def render(b : Build) : JSON::Any
        report = b.report
        by_path = {} of String => Array(OpAcc)
        b.ops.each_value { |op| (by_path[op.template.path] ||= [] of OpAcc) << op }
        paths = by_path.keys.sort!
        origins = Set(String).new
        hosts = Set(String).new
        b.ops.each_value do |op|
          origins.concat(op.origins)
          hosts.concat(op.hosts)
        end
        report.hosts = hosts.to_a.sort!
        report.paths = paths.size
        report.operations = b.ops.size
        multi_host = hosts.size > 1
        ids = Set(String).new

        doc = {} of String => JSON::Any
        doc["openapi"] = JSON::Any.new(VERSION)
        doc["info"] = JSON::Any.new({
          "title"       => JSON::Any.new(hosts.size == 1 ? hosts.first.scrub : "Captured API"),
          "description" => JSON::Any.new(DESCRIPTION),
          "version"     => JSON::Any.new("captured"),
        })
        doc["servers"] = servers(origins) unless origins.empty?
        doc["paths"] = JSON::Any.new(paths.to_h do |path|
          ops = by_path[path].sort_by! { |op| METHODS.index(op.method) || METHODS.size }
          item = {} of String => JSON::Any
          if multi_host
            item["servers"] = servers(ops.each_with_object(Set(String).new) { |op, s| s.concat(op.origins) })
          end
          ops.each { |op| item[op.method] = operation(op, operation_id(op, ids)) }
          {path, JSON::Any.new(item)}
        end)
        unless b.schemes.empty?
          doc["components"] = JSON::Any.new({
            "securitySchemes" => JSON::Any.new(b.schemes.keys.sort!.to_h { |k| {k, b.schemes[k]} }),
          })
        end
        sanitize(JSON::Any.new(doc))
      end

      # Every string in the document — keys and values — as valid UTF-8. Each site above already
      # scrubs what it emits; this is the net under them, because one raw byte that slips
      # through is not a cosmetic fault: the YAML emitter aborts the PROCESS on invalid UTF-8
      # (no exception to rescue), and that process may be the TUI or an MCP server.
      private def sanitize(any : JSON::Any) : JSON::Any
        case raw = any.raw
        when String
          raw.valid_encoding? ? any : JSON::Any.new(raw.scrub)
        when Array(JSON::Any)
          JSON::Any.new(raw.map { |v| sanitize(v) })
        when Hash(String, JSON::Any)
          clean = {} of String => JSON::Any
          raw.each { |k, v| clean[k.scrub] ||= sanitize(v) }
          JSON::Any.new(clean)
        else
          any
        end
      end

      private def servers(origins : Set(String)) : JSON::Any
        JSON::Any.new(origins.to_a.sort!.map { |o| JSON::Any.new({"url" => JSON::Any.new(o)}) })
      end

      private def operation(op : OpAcc, id : String) : JSON::Any
        h = {} of String => JSON::Any
        h["operationId"] = JSON::Any.new(id)
        params = parameters(op)
        h["parameters"] = JSON::Any.new(params) unless params.empty?
        request_body(op).try { |rb| h["requestBody"] = rb }
        h["responses"] = responses(op)
        security(op).try { |s| h["security"] = s }
        JSON::Any.new(h)
      end

      # Path parameters in path order, then query, header and cookie parameters by name.
      private def parameters(op : OpAcc) : Array(JSON::Any)
        out = [] of JSON::Any
        op.template.params.each_with_index do |p, i|
          h = {
            "name"     => JSON::Any.new(p.name),
            "in"       => JSON::Any.new("path"),
            "required" => JSON::Any.new(true),
            "schema"   => path_schema(op.path_kinds[i]),
          }
          op.path_examples[i].try { |ex| h["example"] = JSON::Any.new(ex.scrub) }
          out << JSON::Any.new(h)
        end
        {"query", "header", "cookie"}.each do |loc|
          keys = op.params.keys.select { |k| k[0] == loc }.sort_by!(&.[1])
          # Two raw names that scrub to one (`a%FF`, `a%FE`) would be a duplicate (name, in),
          # which the spec forbids; the first in sorted order stands for both.
          shown = Set(String).new
          keys.each do |key|
            next unless shown.add?(key[1].scrub)
            acc = op.params[key]
            h = {"name" => JSON::Any.new(key[1].scrub), "in" => JSON::Any.new(loc)}
            h["required"] = JSON::Any.new(true) if acc.present == op.samples
            scalar = acc.schema.to_any(text: true)
            h["schema"] = if acc.repeated?
                            JSON::Any.new({"type" => JSON::Any.new("array"), "items" => scalar})
                          else
                            scalar
                          end
            acc.example.try { |ex| h["example"] = JSON::Any.new(ex.scrub) }
            out << JSON::Any.new(h)
          end
        end
        out
      end

      private def path_schema(kinds : Set(Template::Kind)) : JSON::Any
        h = {} of String => JSON::Any
        if kinds.size == 1
          case kinds.first
          when .integer? then h["type"] = JSON::Any.new("integer")
          when .uuid?    then h["type"] = JSON::Any.new("string"); h["format"] = JSON::Any.new("uuid")
          when .date? then h["type"] = JSON::Any.new("string"); h["format"] = JSON::Any.new("date")
          # uuid/hex/token and anything mixed: an opaque string
          else h["type"] = JSON::Any.new("string")
          end
        else
          h["type"] = JSON::Any.new("string")
        end
        JSON::Any.new(h)
      end

      private def request_body(op : OpAcc) : JSON::Any?
        return nil if op.bodies.empty?
        h = {} of String => JSON::Any
        h["required"] = JSON::Any.new(true) if op.body_samples == op.samples
        h["content"] = content(op.bodies)
        JSON::Any.new(h)
      end

      # Numeric statuses in order, then `default` for the ones OpenAPI cannot key.
      private def responses(op : OpAcc) : JSON::Any
        keys = op.responses.keys.sort_by! { |k| k == DEFAULT_STATUS ? Int32::MAX : k }
        JSON::Any.new(keys.to_h do |status|
          desc = if status == DEFAULT_STATUS
                   "Non-standard status #{op.odd_statuses.to_a.sort!.join(", ")}"
                 else
                   HTTP::Status.new(status).description || "Status #{status}"
                 end
          h = {"description" => JSON::Any.new(desc)}
          media = op.responses[status]
          h["content"] = content(media) unless media.empty?
          {status == DEFAULT_STATUS ? "default" : status.to_s, JSON::Any.new(h)}
        end)
      end

      private def content(bodies : Hash(String, BodyAcc)) : JSON::Any
        JSON::Any.new(bodies.keys.sort!.to_h do |media|
          acc = bodies[media]
          h = {"schema" => body_schema(acc)}
          acc.example.try { |ex| h["example"] = ex }
          {media.scrub, JSON::Any.new(h)}
        end)
      end

      private def body_schema(acc : BodyAcc) : JSON::Any
        case acc.kind
        in .json?
          acc.schema.to_any
        in .form?, .multipart?
          h = {"type" => JSON::Any.new("object")}
          unless acc.fields.empty?
            names = acc.fields.keys.sort!
            h["properties"] = JSON::Any.new(names.to_h { |n| {n.scrub, acc.fields[n].to_any(text: true)} })
            required = names.select { |n| acc.field_counts.fetch(n, 0) == acc.forms }.map(&.scrub).uniq!
            h["required"] = JSON::Any.new(required.map { |n| JSON::Any.new(n) }) unless required.empty?
          end
          JSON::Any.new(h)
        in .text?
          JSON::Any.new({"type" => JSON::Any.new("string")})
        in .binary?
          JSON::Any.new({"type" => JSON::Any.new("string"), "format" => JSON::Any.new("binary")})
        end
      end

      # The alternatives a caller authenticated with, one requirement per distinct set of schemes
      # seen together; `{}` (no credentials) is listed too when some samples had none. Absent
      # when no sample carried any.
      private def security(op : OpAcc) : JSON::Any?
        return nil if op.security.all?(&.empty?)
        sets = op.security.to_a.sort_by! { |s| {s.empty? ? 1 : 0, s.join(',')} }
        JSON::Any.new(sets.map do |s|
          JSON::Any.new(s.to_h { |name| {name, JSON::Any.new([] of JSON::Any)} })
        end)
      end

      # `get /users/{userId}/orders` → `getUsersByUserIdOrders`. Unique across the document:
      # two paths that differ only in punctuation (`/a-b`, `/a_b`) get a numeric suffix, in
      # sorted path order, so the id a path gets is stable.
      private def operation_id(op : OpAcc, used : Set(String)) : String
        base = String.build do |io|
          io << op.method
          segments = op.template.path.split('/').reject(&.empty?)
          io << "Root" if segments.empty?
          segments.each do |seg|
            if seg.starts_with?('{') && seg.ends_with?('}')
              io << "By" << camel(seg[1...-1])
            else
              io << camel(seg)
            end
          end
        end
        id = base
        n = 1
        while used.includes?(id)
          n += 1
          id = "#{base}#{n}"
        end
        used << id
        id
      end

      private def camel(s : String) : String
        String.build do |io|
          s.split(/[^A-Za-z0-9]+/).each do |w|
            next if w.empty?
            io << w[0].upcase << w[1..]
          end
        end
      end
    end
  end
end
