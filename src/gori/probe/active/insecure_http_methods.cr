require "./types"
require "../../miner/types"
require "../../miner/inject"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active insecure-HTTP-methods probe. Two long-standing server misconfigurations:
      #   * TRACE enabled — the classic Cross-Site Tracing (XST) primitive: TRACE echoes the request
      #     (headers, cookies) back in the response body, so script that can force a TRACE reads
      #     headers a victim's browser would otherwise keep from it.
      #   * OPTIONS advertising write / otherwise-dangerous verbs (PUT, DELETE, CONNECT, PATCH,
      #     TRACE) in its Allow list — a signpost for an unlocked WebDAV / upload surface.
      #
      # The rule sends ONLY OPTIONS and TRACE — both safe, idempotent, body-less — so it never
      # mutates state regardless of the captured method, and runs by default. It self-attributes the
      # TRACE finding with a random header the request carries and the server echoes back, so a
      # static page that merely contains the word "TRACE" cannot false-fire. Deduped per (host,
      # PATH): TRACE is server-wide, but the OPTIONS Allow list is per-resource — a write surface
      # like /api/upload advertising PUT/DELETE would be missed if only one path per host were
      # probed — so each captured path is checked once.
      class InsecureHttpMethods < Rule
        # A random header the TRACE request carries; a reflecting server echoes it into the body,
        # proving the echo is OURS.
        TRACE_HEADER = "X-Gori-Trace"

        # Methods whose presence in an Allow / Public list is worth reporting.
        DANGEROUS = %w[PUT DELETE CONNECT PATCH TRACE]

        def info : RuleInfo
          RuleInfo.new("insecure_http_methods", "Insecure HTTP methods",
            "Sends OPTIONS and TRACE to flag Cross-Site Tracing (TRACE) and dangerous methods " \
            "advertised in the Allow header.",
            Category::ACTIVE)
        end

        # OPTIONS probe + TRACE probe.
        def requests_per_flow : Range(Int32, Int32)
          2..2
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          _, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          key_string(detail, target)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          _, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          canary = Miner::Canary.fresh
          options_req = rebuild(detail.request_head, "OPTIONS", nil)
          trace_req = rebuild(detail.request_head, "TRACE", canary)
          # The TRACE canary rides a Param so detections_all can read it back positionally; the
          # location "trace" is a label, not an injection surface.
          Plan.new(options_req, [Param.new("trace", "trace", canary)], key_string(detail, target), [trace_req])
        end

        private def key_string(detail : Store::FlowDetail, target : String) : String
          "insecure_http_methods|#{detail.row.host}:#{detail.row.port}|#{path_only(Active.origin_form(target))}"
        end

        # results = [OPTIONS, TRACE]. Up to two independent detections.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          acc = [] of Detection
          if (opt = results[0]?) && opt.ok?
            dangerous = advertised_dangerous(opt)
            unless dangerous.empty?
              acc << Detection.new("dangerous_methods_allowed", Category::ACTIVE, detail.row.host, detail.row.url,
                "Dangerous HTTP methods advertised", Store::Severity::Low,
                "Allow: #{dangerous.join(", ")}"[0, 120], detail.row.id)
            end
          end
          if (tr = results[1]?) && tr.ok? && trace_reflected?(tr, plan.params.first?.try(&.canary))
            acc << Detection.new("trace_enabled", Category::ACTIVE, detail.row.host, detail.row.url,
              "HTTP TRACE enabled (Cross-Site Tracing)", Store::Severity::Medium,
              "TRACE echoed the request", detail.row.id)
          end
          acc
        rescue
          [] of Detection
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # The DANGEROUS methods listed in the response's Allow / Public headers, upcased.
        private def advertised_dangerous(result : Repeater::Result) : Array(String)
          resp = result.response || Proxy::Codec::Http1.parse_response_head(result.head)
          listed = (resp.headers.get_all("Allow") + resp.headers.get_all("Public")).join(",")
          methods = listed.upcase.split(',').map(&.strip).reject(&.empty?)
          DANGEROUS.select { |m| methods.includes?(m) }
        rescue
          [] of String
        end

        # A 2xx TRACE response whose body echoes our canary header proves TRACE is enabled (XST).
        private def trace_reflected?(result : Repeater::Result, canary : String?) : Bool
          return false unless canary
          status = (result.response || Proxy::Codec::Http1.parse_response_head(result.head)).status
          return false unless (200..299).includes?(status)
          body = result.body
          return false unless body && !body.empty?
          String.new(body).includes?(canary)
        rescue
          false
        end

        # Rebuild the captured request as `method_up` on the origin-form path, body dropped (so no
        # Content-Length / Transfer-Encoding is sent), optionally adding the TRACE reflection canary.
        private def rebuild(head : Bytes, method_up : String, canary : String?) : Bytes
          hbytes, _, eol = Miner::Inject.split(head)
          lines = String.new(hbytes).split(eol)
          out = [] of String
          lines.each_with_index do |l, i|
            if i == 0
              rl = l.split(' ')
              out << (rl.size == 3 ? "#{method_up} #{Active.origin_form(rl[1])} #{rl[2]}" : l)
              next
            end
            next if drop_header?(l) # no body is sent
            out << l
          end
          out << "#{TRACE_HEADER}: #{canary}" if canary
          io = IO::Memory.new
          io << out.join(eol) << eol << eol
          io.to_slice
        end

        private def drop_header?(line : String) : Bool
          c = line.index(':') || return false
          name = line[0...c].strip.downcase
          name == "content-length" || name == "transfer-encoding"
        end

        private def path_only(origin_target : String) : String
          qi = origin_target.index('?')
          qi ? origin_target[0...qi] : origin_target
        end
      end
    end
  end
end
