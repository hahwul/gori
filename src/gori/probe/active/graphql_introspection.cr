require "json"
require "./types"
require "../../ascii_bytes"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active GraphQL introspection probe. The passive `graphql_introspection` rule can only flag
      # introspection the browser already triggered; this ACTIVELY asks a GraphQL endpoint for its
      # schema, catching servers that leave introspection enabled even though nothing on the page
      # ever queried it. It folds into the SAME `{code, host}` issue as the passive rule (shared
      # code `graphql_introspection`, category INFOLEAK), so an active confirmation upgrades — rather
      # than duplicates — a passive suspicion.
      #
      # DELIBERATE SAFE_METHODS EXCEPTION. The active scan is GET/HEAD-only by default because
      # re-sending a captured POST could replay a mutation. This rule may send a POST anyway — BUT it
      # NEVER replays the captured body: it substitutes a fixed, side-effect-free introspection query
      # (`{__schema{queryType{name}}}`), so the concrete hazard SAFE_METHODS guards against (a real
      # server-side mutation) does not apply. The probe method MIRRORS the captured one — a captured
      # GET graphql endpoint is probed with GET, a captured GraphQL POST with POST — so a POST-only
      # server (the common production shape) is still covered by the automatic scan. This mirrors the
      # sanctioned AGGRESSIVE-mode auto-unsafe override: a reasoned, documented exception, not a
      # blanket one.
      #
      # Gated to keep it quiet and low-FP: only GraphQL endpoints (a `/graphql` path or a captured
      # JSON body carrying a top-level `"query"` GraphQL document — the same predicate as
      # Passive::Tech), and confirmation is the binary `"__schema":{` anchor (a query echo, where
      # `__schema` is unquoted, never matches). A server with introspection disabled answers with an
      # error and is never flagged.
      class GraphqlIntrospection < Rule
        def info : RuleInfo
          RuleInfo.new("graphql_introspection_active", "GraphQL introspection (active)",
            "Sends an introspection query to a GraphQL endpoint and confirms the schema is exposed.",
            Category::INFOLEAK)
        end

        # Lowercase byte needles for the allocation-free gate (mirrors Passive::Tech).
        GRAPHQL_PATH = "/graphql".to_slice
        JSON_CT      = "json".to_slice
        QUERY_KEY    = "\"query\"".to_slice
        # The two request families the JSON gate excludes and a GraphQL API still accepts: the
        # raw-document / `+json` content-types, and a `query=…` urlencoded body. Same widening
        # as `Passive::Tech#graphql?` — the two predicates are deliberately the same predicate.
        GRAPHQL_CT  = "graphql".to_slice
        FORM_CT     = "x-www-form-urlencoded".to_slice
        QUERY_PARAM = "query=".to_slice

        # The minimal introspection document, as a GET query value (URL-encoded braces) and a POST
        # JSON body. `{__schema{queryType{name}}}` — enough to force the `"__schema":{` result
        # envelope while staying tiny and read-only.
        INTROSPECTION_GET_QUERY = "%7B__schema%7BqueryType%7Bname%7D%7D%7D"
        INTROSPECTION_POST_BODY = %({"query":"{__schema{queryType{name}}}"})

        # The introspection RESULT anchor — a QUOTED `"__schema"` key opening an object, the shape
        # of `{"data":{"__schema":{…}}}`. Mirrors Passive::GraphqlIntrospection::INTROSPECTION_RESULT
        # (kept local so the active rule stays self-contained): it rejects a mere query echo (there
        # `__schema` is unquoted) and sits at the body start, surviving the 64 KiB cap.
        INTROSPECTION_RESULT = /"__schema"\s*:\s*\{/

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          probe_method, path = g
          request = probe_method == "POST" ? build_post(detail.request_head, path) : build_get(detail.request_head, path)
          Plan.new(request, [] of Param, key_string(detail, probe_method, path))
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          return [] of Detection unless (200..299).includes?(probe_status(result))
          return [] of Detection unless introspection_response?(result)
          [Detection.new("graphql_introspection", Category::INFOLEAK, detail.row.host, detail.row.url,
            "GraphQL introspection enabled (confirmed by probe)", Store::Severity::Medium,
            "confirmed by probe", detail.row.id)]
        rescue
          [] of Detection
        end

        # A 2xx JSON-ish (some servers label it application/graphql-response+json) body carrying the
        # `"__schema":{` result envelope. An unknown content type is allowed; HTML/text error pages
        # are gated out.
        private def introspection_response?(result : Repeater::Result) : Bool
          ct = response_content_type(result)
          return false unless ct.empty? || ct.includes?("json") || ct.includes?("graphql")
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return false if bytes.nil? || bytes.empty?
          INTROSPECTION_RESULT.matches?(String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub)
        end

        # The shared gate both `plan` and `dedup_key` funnel through, returning {probe_method,
        # path-without-query} or nil. `probe_method` mirrors the captured method: POST stays POST
        # (the documented read-only exception), GET/HEAD become GET (HEAD returns no body to scan).
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          mu = method.upcase
          return nil unless mu == "GET" || mu == "HEAD" || mu == "POST"
          return nil unless graphql_endpoint?(detail, target)
          probe_method = mu == "POST" ? "POST" : "GET"
          {probe_method, path_only(Active.origin_form(target))}
        end

        # rule + host:PORT + probe-METHOD + path (no query — introspection is per-endpoint). Keying on
        # the PROBE method folds a HEAD and a GET graphql endpoint into one GET probe while keeping a
        # POST endpoint distinct.
        private def key_string(detail : Store::FlowDetail, probe_method : String, path : String) : String
          "graphql_introspection|#{detail.row.host}:#{detail.row.port}|#{probe_method}|#{path}"
        end

        # A GraphQL endpoint: a `/graphql` path, or a captured JSON request whose top-level `"query"`
        # is a string holding a GraphQL document (same predicate as Passive::Tech#graphql?). The
        # string-value requirement keeps Elasticsearch query-DSL bodies (where `query` is an object)
        # out. Cheap path check first, so the common `/graphql` case never parses the body.
        private def graphql_endpoint?(detail : Store::FlowDetail, target : String) : Bool
          return true if AsciiBytes.contains_ci?(target.to_slice, GRAPHQL_PATH)
          graphql_body?(detail)
        end

        # A captured JSON request body whose top-level `"query"` is a string holding a GraphQL
        # document. The string-value requirement keeps Elasticsearch query-DSL bodies (where `query`
        # is an object) out. Cheap byte prefilters before the JSON.parse.
        private def graphql_body?(detail : Store::FlowDetail) : Bool
          body = detail.request_body
          return false if body.nil? || body.empty?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          ct = req.headers.get?("Content-Type")
          return false unless ct
          capped = body[0, {body.size, 256 * 1024}.min]
          # The non-JSON families are decided by `Gori::Graphql` — it already knows every shape
          # a real API exposes, and a second hand-rolled check here would be one more place for
          # the answer to drift from the decoded pane's.
          ctb = ct.to_slice
          unless AsciiBytes.contains_ci?(ctb, JSON_CT)
            return false unless AsciiBytes.contains_ci?(ctb, GRAPHQL_CT) ||
                                (AsciiBytes.contains_ci?(ctb, FORM_CT) &&
                                AsciiBytes.contains_ci?(capped, QUERY_PARAM))
            return !Graphql.from_body(capped, ct).nil?
          end
          return false unless AsciiBytes.contains_ci?(capped, QUERY_KEY)
          q = begin
            JSON.parse(String.new(capped).scrub).as_h?.try(&.["query"]?).try(&.as_s?)
          rescue JSON::ParseException
            nil
          end
          return false unless q
          graphql_document?(q.lstrip)
        end

        private def graphql_document?(doc : String) : Bool
          doc.starts_with?('{') || doc.starts_with?("query") || doc.starts_with?("mutation") ||
            doc.starts_with?("subscription") || doc.starts_with?("fragment")
        end

        # GET <path>?query=<introspection> — drop any body-framing headers (this probe carries none),
        # normalize to origin-form. HEAD collapses to GET here (we need the response body).
        private def build_get(head : Bytes, path : String) : Bytes
          hbytes, _, eol = Miner::Inject.split(head)
          lines = String.new(hbytes).split(eol)
          return head if lines.empty?
          version = request_version(lines[0])
          kept = ["GET #{path}?query=#{INTROSPECTION_GET_QUERY} #{version}"]
          lines[1..].each do |l|
            kept << l unless body_framing_header?(l)
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          Fuzz::ContentLength.sync(io.to_slice, false)
        end

        # POST <path> with a fixed introspection JSON body and a normalized Content-Type; Content-
        # Length is resynced to the new body. NEVER carries the captured body (see the class comment).
        # Drops the captured Transfer-Encoding too: a chunked source request would otherwise keep
        # `Transfer-Encoding: chunked` while we write a flat body (ContentLength.sync no-ops on chunked),
        # producing an unframed probe the origin misparses.
        private def build_post(head : Bytes, path : String) : Bytes
          hbytes, _, eol = Miner::Inject.split(head)
          lines = String.new(hbytes).split(eol)
          return head if lines.empty?
          version = request_version(lines[0])
          kept = ["POST #{path} #{version}"]
          lines[1..].each do |l|
            kept << l unless body_framing_header?(l)
          end
          kept.insert(1, "Content-Type: application/json")
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io << INTROSPECTION_POST_BODY
          Fuzz::ContentLength.sync(io.to_slice, true)
        end

        private def request_version(request_line : String) : String
          parts = request_line.split(' ')
          parts.size == 3 ? parts[2] : "HTTP/1.1"
        end

        private def header_named?(line : String, name : String) : Bool
          (c = line.index(':')) ? line[0...c].strip.downcase == name : false
        end

        # Content-Length / Content-Type / Transfer-Encoding — the framing headers this rule sets or
        # drops itself; keeping a captured one would misframe the fixed probe body.
        private def body_framing_header?(line : String) : Bool
          return false unless c = line.index(':')
          name = line[0...c].strip.downcase
          name == "content-length" || name == "content-type" || name == "transfer-encoding"
        end

        private def path_only(origin_target : String) : String
          qi = origin_target.index('?')
          qi ? origin_target[0...qi] : origin_target
        end

        private def probe_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        private def response_content_type(result : Repeater::Result) : String
          if r = result.response
            return (r.headers.get?("Content-Type") || "").downcase
          end
          (Proxy::Codec::Http1.parse_response_head(result.head).headers.get?("Content-Type") || "").downcase
        rescue
          ""
        end
      end
    end
  end
end
