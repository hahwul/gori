require "./rule"
require "./body_leaks"

module Gori
  module Probe
    module Passive
      # Internal network names disclosed in RESPONSE HEADERS (category "infoleak"). `BodyLeaks`
      # already scans the response BODY for RFC 1918 addresses; the header block was the half
      # nobody read, and it is where a reverse proxy actually leaks its topology:
      # `X-Backend-Server: web03.corp`, `Via: 1.1 cache01.internal`, `Location: http://10.2.0.7:8080/…`,
      # a CSP naming a build-time host. Each one hands an attacker a map of the estate behind the
      # edge — hostnames to try in an SSRF, ranges to aim a pivot at — that they cannot otherwise see.
      #
      # Distinct code from `private_ip_leak` on purpose. A header is emitted by the INFRASTRUCTURE
      # and is on every response the route touches, where a body hit is emitted by the application
      # and is usually one page; folding them into one issue would bury a single leaked address in a
      # host-wide "the proxy tags everything" group, and the two have different owners and fixes.
      class InternalHostLeak < Rule
        def info : RuleInfo
          RuleInfo.new("internal_host_leak", "Internal host disclosed in a response header",
            "Scans response headers for RFC 1918 addresses and internal-only hostnames (.local, .internal, .corp, …).",
            Category::INFOLEAK)
        end

        # The private-IP shape, from its one home in `BodyLeaks` — same ranges, same guards against
        # matching inside a version string, and no second spelling to drift.
        PRIVATE_IP = BodyLeaks::PRIVATE_IP

        # A hostname whose last label is a name that only resolves inside a network: mDNS `.local`,
        # the `.internal` / `.intranet` / `.lan` / `.corp` / `.localdomain` conventions.
        #
        # The trailing guard is `(?![\w.-])`, NOT `\b`: a `\b` is satisfied by the hyphen in
        # `api.internal-tools.example.com`, which is an ordinary public name and would have been a
        # standing false positive. The leading guard is the mirror, so `x.corp.example.com` (where
        # `corp` is not the last label) stays out too.
        INTERNAL_HOST = /(?<![\w.-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:local|internal|intranet|lan|corp|localdomain)(?![\w.-])/i

        # Distinct (header, value) leaks reported per response. A proxy chain can stamp the same
        # address into half a dozen headers; the group accumulates evidence across flows anyway, so
        # a few per response is plenty and keeps one chatty route from filling the row.
        MAX_REPORTED = 3

        # Hop-by-hop / forwarding headers that name the CLIENT, not the estate behind the edge.
        # A tester on 10/8 would otherwise raise this finding on every captured response the
        # origin (or a CDN) stamped X-Forwarded-For onto.
        CLIENT_IP_HEADERS = Set{
          "x-forwarded-for", "x-real-ip", "x-client-ip", "forwarded",
          "cf-connecting-ip", "true-client-ip", "x-cluster-client-ip",
        }

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          head = ctx.response_head_text
          return if head.nil? || head.empty?
          # One pass over the head — ~1 KiB, already materialised and memoised on Context — decides
          # whether it is worth splitting into lines at all. Iterating the parsed HeaderList instead
          # would run two PCRE calls per header (~30 on an ordinary response) where this runs two.
          return unless PRIVATE_IP.matches?(head) || INTERNAL_HOST.matches?(head)
          reported = 0
          seen = Set(String).new
          # Skip the status line: it is the only line that is not a header, and a reason phrase
          # carries no host.
          head.each_line.skip(1).each do |line|
            break if reported >= MAX_REPORTED
            colon = line.index(':')
            next if colon.nil? || colon == 0
            name = line[0...colon].strip
            next if name.empty? || gori_marker?(name)
            next if CLIENT_IP_HEADERS.includes?(name.downcase)
            value = line[(colon + 1)..].strip
            next if value.empty?
            token = (PRIVATE_IP.match(value).try(&.[0])) || (INTERNAL_HOST.match(value).try(&.[0])) || next
            evidence = "#{safe(name)}: #{safe(token)}"
            next unless seen.add?(evidence)
            acc << Detection.new("internal_host_leak", Category::INFOLEAK, ctx.host, ctx.url,
              "Internal host disclosed in a response header", Store::Severity::Low,
              evidence, ctx.fid)
            reported += 1
          end
        end

        # gori writes its own `X-Gori-*` marker lines into a stored head (the h2 pseudo-header
        # projection, a short-circuit stamp, a Discover provenance tag). Reporting on them would be
        # reporting on our own bytes as if they were the target's — the refusal `Passive.analyze`
        # already makes for a short-circuited flow, applied at header granularity.
        private def gori_marker?(name : String) : Bool
          name.size >= 7 && name[0, 7].compare("x-gori-", case_insensitive: true) == 0
        end

        # Header names and matched hosts land in stored evidence and in the TUI. Both are ASCII by
        # construction here, so the scrub is a guard rather than a lossy step; the cap keeps a
        # hostile header from bloating the row. Contains no ", ", so the evidence survives the
        # accumulate-across-flows merge (`Store.merge_evidence`) intact.
        private def safe(s : String) : String
          cleaned = s.scrub.gsub(/[^\x20-\x7e]/, "").gsub(", ", " ")
          cleaned.size > 64 ? cleaned[0, 64] : cleaned
        end
      end
    end
  end
end
