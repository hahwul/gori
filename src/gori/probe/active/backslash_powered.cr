require "uri"
require "./types"
require "../../miner/inject"
require "../../fuzz/engine"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Backslash-powered scanning (James Kettle, PortSwigger 2016 —
      # https://portswigger.net/research/backslash-powered-scanning-hunting-unknown-vulnerability-classes).
      # The idea: tell whether a parameter is treated as inert DATA or is fed to a server-side
      # string INTERPRETER (SQL, a template/expression engine, a shell, …) — without relying on a
      # specific error message — by exploiting how a backslash escapes.
      #
      # For each query parameter it sends three requests that carry the param's ORIGINAL value with a
      # suffix appended:
      #   baseline  value          (unchanged)
      #   single    value\         (a lone trailing backslash)
      #   double    value\\        (an escaped, i.e. literal, backslash)
      # A value that is pure data is unaffected by either suffix, so all three responses match. But
      # inside a string interpreter the LONE `\` escapes the next character (often the closing
      # delimiter) and breaks parsing, while the DOUBLED `\\` is just a literal backslash and parses
      # cleanly. So the tell is an ASYMMETRY: `single` differs from `baseline` while `double` matches
      # it. That asymmetry — not any single error string — is what flags a probable injection surface.
      #
      # This is the active scanner's first DIFFERENTIAL (multi-probe) rule: `plan` builds a baseline
      # plus a `\`/`\\` pair per param into `Plan.followups`, the analyzer sends them all, and
      # `detections_all` compares the responses. Gated to GET (the differential compares BODIES, so
      # HEAD is out, and POST/PUT/… are never auto-probed — they mutate state) and capped at
      # MAX_PROBE_PARAMS params so a wide query can't blow up the request count.
      class BackslashPowered < Rule
        # Probe at most this many params per flow (in query order). Bounds the request count and
        # keeps the automatic scan light-touch; a wider query is still covered for its first params.
        MAX_PROBE_PARAMS = 3

        # Appended (URL-encoded, so it decodes to a real backslash server-side) to a param's value.
        SINGLE = "%5C"    # one backslash  →  value\
        DOUBLE = "%5C%5C" # two backslashes →  value\\

        def info : RuleInfo
          RuleInfo.new("backslash_powered", "Backslash-powered scanning",
            "Appends \\ and \\\\ to each query parameter; flags a parameter where the lone backslash " \
            "perturbs the response but the doubled one does not (server-side string interpretation).",
            Category::ACTIVE)
        end

        # baseline + a (`\`, `\\`) pair per probed param: 1 param → 3 requests, MAX_PROBE_PARAMS → 7.
        # Static annotation for the Rules sub-tab + the manual-run estimate (the analyzer sends the
        # exact count for the flow at hand).
        def requests_per_flow : Range(Int32, Int32)
          3..(1 + 2 * MAX_PROBE_PARAMS)
        end

        # Dedup key WITHOUT rebuilding probes — derived from the same `injectables` gate `plan` uses,
        # so it is byte-identical to `plan(detail).dedup_key` and nil in exactly the same cases
        # (verified by the equivalence spec).
        def dedup_key(detail : Store::FlowDetail) : String?
          g = injectables(detail)
          return nil unless g
          method_up, path, pairs, probe = g
          build_dedup_key(detail, method_up, path, probe.map { |i| decode_name(pair_name(pairs[i])) })
        end

        def plan(detail : Store::FlowDetail) : Plan?
          g = injectables(detail)
          return nil unless g
          method_up, path, pairs, probe = g
          body = detail.request_body
          baseline = rebuild_query(detail.request_head, body, path, pairs.join('&'))
          followups = [] of Bytes
          params = [] of Param
          probe.each do |idx|
            pair = pairs[idx]
            eq = pair.index('=').not_nil!
            name = pair[0...eq]
            value = pair[(eq + 1)..]
            # Order matters: single (`\`) then double (`\\`) — detections_all reads them back at
            # results[1 + 2*i] / results[2 + 2*i] for the i-th param.
            followups << rebuild_query(detail.request_head, body, path, with_value(pairs, idx, name, value + SINGLE))
            followups << rebuild_query(detail.request_head, body, path, with_value(pairs, idx, name, value + DOUBLE))
            params << Param.new("query", decode_name(name), value)
          end
          key = build_dedup_key(detail, method_up, path, params.map(&.name))
          Plan.new(baseline, params, key, followups)
        end

        # Compare the responses: for each probed param, fire when the lone `\` changed the response
        # (status or a surfaced interpreter error) AND the doubled `\\` reverted to baseline. One
        # grouped Detection per host, listing the affected params.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          baseline = results.first?
          return [] of Detection unless baseline && baseline.ok?
          base = attrs(baseline)
          hits = [] of String
          plan.params.each_with_index do |param, i|
            single = results[1 + 2 * i]?
            double = results[2 + 2 * i]?
            next unless single && double
            next unless single.ok? && double.ok? # a failed leg ⇒ incomplete comparison, skip
            sa = attrs(single)
            da = attrs(double)
            # The asymmetry that marks an escape being interpreted. A reflecting/echoing endpoint
            # changes for BOTH the `\` and `\\` forms (no asymmetry) and is never flagged here.
            hits << "#{param.name}#{describe_break(base, sa)}" if sa != base && da == base
          end
          return [] of Detection if hits.empty?
          [Detection.new("backslash_powered", Category::ACTIVE, detail.row.host, detail.row.url,
            "Server-side string interpretation (backslash escaping)", Store::Severity::Medium,
            hits.join(", ")[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Single-response fallback (module facade / a one-shot caller): the differential needs the
        # follow-up probes, so one response alone yields nothing. The analyzer always calls
        # detections_all with the full set.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # Shared gate for plan + dedup_key so the two can't drift (equivalence-spec invariant).
        # Returns {METHOD, path, all query pairs verbatim, indices of the first ≤MAX_PROBE_PARAMS
        # pairs that are real k=v params} for a GET carrying ≥1 such param, else nil.
        private def injectables(detail : Store::FlowDetail) : {String, String, Array(String), Array(Int32)}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          # GET only: the differential compares response bodies (HEAD has none) and the active scan
          # never auto-re-sends a state-changing method (SAFE_METHODS is GET/HEAD; we keep GET).
          return nil unless method_up == "GET"
          path, query = split_target(Active.origin_form(target))
          return nil if query.empty?
          pairs = query.split('&')
          probe = [] of Int32
          pairs.each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            next if pair[0...eq].empty?
            probe << i
            break if probe.size >= MAX_PROBE_PARAMS
          end
          return nil if probe.empty?
          {method_up, path, pairs, probe}
        end

        # Key by rule + host:PORT + METHOD + path + sorted (length-prefixed) probed-param names, so
        # the same host on another port/service is a distinct surface and a name containing ','/':'
        # can't collide with a different set. Sorted → a reordered query dedups to one probe.
        private def build_dedup_key(detail : Store::FlowDetail, method_upcase : String, path : String,
                                    names : Array(String)) : String
          sig = names.map { |n| "#{n.bytesize}:#{n}" }.sort!.join(",")
          "backslash_powered|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{sig}"
        end

        private def pair_name(pair : String) : String
          eq = pair.index('=')
          eq ? pair[0...eq] : pair
        end

        # A copy of the query pairs with pair `idx` replaced by "name=value" (every other segment,
        # including bare flags and empties, kept verbatim).
        private def with_value(pairs : Array(String), idx : Int32, name : String, value : String) : String
          dup = pairs.dup
          dup[idx] = "#{name}=#{value}"
          dup.join('&')
        end

        # A comparable response fingerprint: status code + a coarse interpreter-error class (nil when
        # the body shows none). Two responses are "the same" iff both match — deliberately NOT a
        # byte diff, so ordinary dynamic-content jitter doesn't read as a difference.
        private def attrs(result : Repeater::Result) : {Int32, String?}
          {response_status(result), error_signature(result)}
        end

        private def response_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # Known server-side interpreter/parser error fingerprints. Presence is a strong signal, but
        # it only STRENGTHENS the differential (severity/evidence) — the rule fires on the `\` vs
        # `\\` asymmetry whether or not a signature matched (e.g. a bare 200→500 flip).
        ERROR_SIGNATURES = {
          "SQL"    => ["you have an error in your sql syntax", "sqlstate", "unclosed quotation mark",
                       "quoted string not properly terminated", "unterminated quoted string",
                       "warning: mysql", "mysqli", "pg::", "psql", "ora-0", "odbc", "sqlite"],
          "syntax" => ["unterminated string", "unexpected end of", "unexpected token",
                       "syntaxerror", "parse error", "invalid escape", "eol while scanning"],
        }

        private def error_signature(result : Repeater::Result) : String?
          body = decoded_body(result)
          return nil if body.empty?
          hay = body.downcase
          ERROR_SIGNATURES.each do |label, needles|
            return label if needles.any? { |n| hay.includes?(n) }
          end
          nil
        end

        private def decoded_body(result : Repeater::Result) : String
          decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body, BODY_CAP)
          bytes = decoded || result.body
          return "" unless bytes && !bytes.empty?
          String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        rescue
          ""
        end

        # A short human tag for the evidence line: prefer the interpreter-error class, else the
        # status flip, else nothing (a difference the fingerprint can't name).
        private def describe_break(base : {Int32, String?}, single : {Int32, String?}) : String
          if err = single[1]
            " (#{err} error)"
          elsif single[0] != base[0]
            " (#{base[0]}→#{single[0]})"
          else
            ""
          end
        end

        # {path, query-without-'?'} — query is "" when the target has none.
        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

        private def decode_name(name : String) : String
          URI.decode_www_form(name)
        rescue
          name
        end

        # Reassemble the request with a new query on the request line, preserving the original body
        # and re-syncing Content-Length (mirrors ReflectedParam#rebuild; a lone GET has no body, so
        # this just carries any CL through untouched).
        private def rebuild_query(orig_head : Bytes, body : Bytes?, path : String, new_query : String) : Bytes
          head, _, eol = Miner::Inject.split(orig_head)
          lines = String.new(head).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              target = new_query.empty? ? path : "#{path}?#{new_query}"
              lines[0] = "#{parts[0]} #{target} #{parts[2]}"
            end
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          b = body || Bytes.empty
          io.write(b) unless b.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end
      end
    end
  end
end
