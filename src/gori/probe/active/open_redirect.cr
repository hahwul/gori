require "uri"
require "./types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active open-redirect probe. When a redirect endpoint builds its `Location` from a request
      # parameter (`/login?next=https://app.example/…` → `Location: https://app.example/…`), an
      # attacker can point that parameter at their own host and turn the trusted link into an
      # arbitrary redirect (phishing, OAuth token theft). Passive analysis cannot prove the parameter
      # *controls* the target.
      #
      # For one in-scope flow whose captured response was a 3xx AND whose `Location` authority matches
      # one of the request's query-parameter values (i.e. that parameter demonstrably DROVE the
      # redirect), it re-sends ONE request with that parameter replaced by a synthetic external host,
      # and flags High only when the response `Location` redirects to OUR probe host.
      #
      # Low-FP by construction:
      #   * gated to a parameter whose value already equals the captured redirect's authority — a
      #     stray reflected value that doesn't drive the redirect is never probed;
      #   * confirmation parses the response `Location`'s OWN authority (Active.url_authority), so a
      #     relative `Location: /go?next=…probe…` (probe host only in a sub-param) and the
      #     `https://probe@evil.test/` userinfo trick are both correctly rejected;
      #   * the probe host is a reserved `.example` (RFC 2606) that never resolves — only ever a
      #     header value, never dialed.
      class OpenRedirect < Rule
        PROBE_HOST = "gori-redir-probe.example"
        # The probe host as an absolute URL, in two forms. The encoded form is a valid query value a
        # server url-decodes before building its Location; the literal form reaches a server that
        # passes the parameter through verbatim (no decode). `plan` mirrors the captured value's form.
        PROBE_LITERAL = "https://gori-redir-probe.example"
        PROBE_VALUE   = "https%3A%2F%2Fgori-redir-probe.example"

        REDIRECT_STATUSES = {301, 302, 303, 307, 308}

        def info : RuleInfo
          RuleInfo.new("open_redirect", "Open redirect",
            "Replaces a redirect parameter with an external host and flags a Location that follows it.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1], g[4])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path, pairs, idx, name = g
          value = probe_value_for(pairs[idx])
          request = rebuild_query(detail.request_head, detail.request_body, path, with_replaced(pairs, idx, value))
          Plan.new(request, [Param.new("query", name, "")], key_string(detail, method_up, path, name))
        end

        # Mirror the captured value's encoding: a literal `://` in the driving value means the app does
        # not url-decode it, so send the literal probe URL; otherwise send the percent-encoded form.
        private def probe_value_for(pair : String) : String
          eq = pair.index('=')
          raw = eq ? pair[(eq + 1)..] : ""
          raw.includes?("://") ? PROBE_LITERAL : PROBE_VALUE
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          resp = Proxy::Codec::Http1.parse_response_head(result.head)
          return [] of Detection unless REDIRECT_STATUSES.includes?(resp.status)
          loc = resp.headers.get?("Location") || return [] of Detection
          auth = Active.url_authority(loc) || return [] of Detection
          return [] of Detection unless auth[0] == PROBE_HOST
          name = plan.params.first?.try(&.name) || "?"
          [Detection.new("open_redirect", Category::ACTIVE, detail.row.host, detail.row.url,
            "Open redirect (parameter controls Location)", Store::Severity::High,
            "param `#{name}` redirected to #{PROBE_HOST}"[0, 120], detail.row.id)]
        rescue
          [] of Detection
        end

        # Shared gate for plan + dedup_key. Returns {METHOD, path, query pairs, index of the param
        # whose value's authority == the captured Location's authority, that param's DECODED name},
        # or nil. Both paths funnel here so they cannot drift.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, Array(String), Int32, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          return nil unless REDIRECT_STATUSES.includes?(detail.row.status)
          rhead = detail.response_head || return nil
          loc = Proxy::Codec::Http1.parse_response_head(rhead).headers.get?("Location") || return nil
          loc_auth = Active.url_authority(loc) || return nil # captured redirect must be to an absolute host
          path, query = split_target(Active.origin_form(target))
          return nil if query.empty?
          pairs = query.split('&')
          found = first_driving_param(pairs, loc_auth[0]) || return nil
          {method_up, path, pairs, found[0], found[1]}
        end

        # {index, decoded name} of the first query param whose value's authority host == `loc_host`
        # (i.e. that param drove the captured redirect), or nil.
        private def first_driving_param(pairs : Array(String), loc_host : String) : {Int32, String}?
          pairs.each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            raw_name = pair[0...eq]
            next if raw_name.empty?
            raw_value = pair[(eq + 1)..]
            next if raw_value.empty?
            pa = Active.url_authority(decode(raw_value))
            return {i, decode(raw_name)} if pa && pa[0] == loc_host
          end
          nil
        end

        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, name : String) : String
          "open_redirect|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{name.bytesize}:#{name}"
        end

        # A copy of the query pairs with pair `idx`'s value replaced (name kept verbatim).
        private def with_replaced(pairs : Array(String), idx : Int32, value : String) : String
          dup = pairs.dup
          pair = dup[idx]
          if eq = pair.index('=')
            dup[idx] = "#{pair[0...eq]}=#{value}"
          end
          dup.join('&')
        end

        private def decode(s : String) : String
          URI.decode_www_form(s)
        rescue
          s
        end

        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

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
