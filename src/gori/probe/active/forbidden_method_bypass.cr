require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active access-control bypass via HTTP METHOD manipulation (sibling of ForbiddenBypass /
      # PathNormalizationBypass — those forge client-IP headers / mangle the path; this one varies
      # the method). A gateway ACL is often keyed on the exact method token or one verb: it denies
      # `GET /admin` but a case-insensitive backend still serves `gET /admin`, or a front-end that
      # never inspects a method-override header lets the backend re-dispatch the request to the
      # denied method. Passive analysis cannot tell such a control apart from any 401/403.
      #
      # For one in-scope flow whose captured response was 401/403 it re-sends the SAME resource:
      #   * default (safe): a CASE VARIANT of the captured method (`gET`), which a case-sensitive
      #     method ACL misses while a case-insensitive server routes it as the original — safe (same
      #     read semantics) and low-FP (a served case variant is a genuine ACL/server mismatch,
      #     never a HEAD-answers-200 coincidence);
      #   * under allow_unsafe: alternate WIRE methods (POST/PUT — state-mutating, opt-in), and the
      #     real method-override probe — an allowed wire verb carrying `X-HTTP-Method-Override:
      #     <the denied method>`, which a backend that honors the override serves as the denied
      #     method though the front-end saw an allowed one.
      # A CONTROL (the request exactly as captured, sent LAST) makes any 2xx flip attributable: a
      # transient/rate-limited 403 that cleared answers 2xx there too and the finding is suppressed
      # (the ForbiddenBypass / PathNormalizationBypass discipline). One grouped Detection per host,
      # naming which legs worked.
      class ForbiddenMethodBypass < Rule
        # Method-override headers a backend may honor over the wire method the front-end ACL saw.
        OVERRIDE_HEADERS = %w[X-HTTP-Method-Override X-HTTP-Method X-Method-Override]
        OVERRIDE_DROP    = OVERRIDE_HEADERS.map(&.downcase).to_set

        def info : RuleInfo
          RuleInfo.new("forbidden_method_bypass", "Access-control bypass (HTTP method)",
            "Re-requests a denied (401/403) resource with a method case variant, and — under unsafe " \
            "— alternate methods and method-override headers, flagging a 2xx bypass.",
            Category::ACTIVE)
        end

        # case leg + control (safe); + POST/PUT + override leg + control (allow_unsafe).
        def requests_per_flow : Range(Int32, Int32)
          2..5
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1], opts)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path = g
          legs = [] of {String, Bytes}

          cv = case_variant(method_up)
          legs << {"case", rebuild_method(detail.request_head, detail.request_body, cv)} if cv != method_up

          if opts.allow_unsafe
            %w[POST PUT].each do |m|
              legs << {m, rebuild_method(detail.request_head, detail.request_body, m)} unless m == method_up
            end
            # The real method-override probe: an allowed wire verb (POST) carrying the DENIED method
            # in the override headers, so a backend that honors the override serves it.
            legs << {"override", rebuild_override(detail.request_head, detail.request_body, "POST", method_up)}
          end

          return nil if legs.empty?
          params = legs.map { |(label, _)| Param.new("method", label, "") }
          requests = legs.map { |(_, bytes)| bytes }
          # The control is the request EXACTLY as captured, appended LAST: it lands at
          # results[params.size].
          requests << rebuild_method(detail.request_head, detail.request_body, method_up)
          Plan.new(requests.first, params, key_string(detail, method_up, path, opts), requests[1..])
        end

        # results = [leg…, control]. Flag when a leg flipped the denied status to 2xx AND the
        # control (captured request) is still denied.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          control = results[plan.params.size]?
          # No usable control ⇒ no attribution. Refuse rather than fall back to the captured status.
          return [] of Detection unless control && control.ok?
          # The captured request serves 2xx now too ⇒ the gate is simply open (a transient/rate-
          # limited 403 that cleared), and every leg "flip" below is that clearing, not a bypass.
          return [] of Detection unless denied_status?(probe_status(control))
          orig = detail.row.status
          hits = [] of String
          plan.params.each_with_index do |param, i|
            r = results[i]?
            next unless r && r.ok?
            next unless (200..299).includes?(probe_status(r))
            hits << param.name
          end
          return [] of Detection if hits.empty?
          [Detection.new("forbidden_method_bypass", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible access-control bypass via HTTP method", Store::Severity::Medium,
            "#{orig} → 2xx via #{hits.join(", ")}; control still denied"[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # {METHOD, path-no-query} for an eligible-method 401/403, else nil.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          return nil unless denied_status?(detail.row.status)
          {method_up, path_only(Active.origin_form(target))}
        end

        private def denied_status?(status : Int32?) : Bool
          status == 401 || status == 403
        end

        # Flip the case of the first ASCII letter: "GET" -> "gET". A case-sensitive method ACL
        # misses it; a server that upper-cases the method still routes it as the original.
        private def case_variant(method_up : String) : String
          method_up.each_char_with_index do |c, i|
            next unless c.ascii_letter?
            flipped = c.ascii_uppercase? ? c.downcase : c.upcase
            return "#{method_up[0, i]}#{flipped}#{method_up[(i + 1)..]}"
          end
          method_up
        end

        # host:PORT + METHOD + path, plus an `|unsafe` tag when allow_unsafe adds legs, so the
        # ACTIVE↔unsafe backfill re-arm does not skip an already-seen surface before the wider set ran.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, opts : Options) : String
          "forbidden_method_bypass|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}#{opts.allow_unsafe ? "|unsafe" : ""}"
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

        # Rebuild with a new request-line method (headers/body untouched), origin-form target.
        private def rebuild_method(head : Bytes, body : Bytes?, method_up : String) : Bytes
          rebuild(head, body) do |lines|
            rl = lines[0].split(' ')
            lines[0] = "#{method_up} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
          end
        end

        # Rebuild with `wire` on the request line and the override headers valued at `override_method`
        # (dropping any override copies the browser sent, so exactly one authoritative copy remains).
        private def rebuild_override(head : Bytes, body : Bytes?, wire : String, override_method : String) : Bytes
          rebuild(head, body) do |lines|
            kept = [lines[0]]
            lines[1..].each { |l| kept << l unless override_header?(l) }
            lines.clear
            lines.concat(kept)
            rl = lines[0].split(' ')
            lines[0] = "#{wire} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
            OVERRIDE_HEADERS.each_with_index { |name, i| lines.insert(1 + i, "#{name}: #{override_method}") }
          end
        end

        private def override_header?(line : String) : Bool
          (c = line.index(':')) ? OVERRIDE_DROP.includes?(line[0...c].strip.downcase) : false
        end

        private def rebuild(head : Bytes, body : Bytes?, &) : Bytes
          combined = if body && !body.empty?
                       io = IO::Memory.new(head.size + body.size)
                       io.write(head)
                       io.write(body)
                       io.to_slice
                     else
                       head
                     end
          hbytes, bbytes, eol = Miner::Inject.split(combined)
          lines = String.new(hbytes).split(eol)
          yield lines unless lines.empty?
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end
      end
    end
  end
end
