require "./types"
require "../out_of_band"
require "./insertion_points"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active blind-SSRF probe, OUT-OF-BAND. When a request parameter carries a URL the server
      # fetches on the client's behalf (a webhook target, a link-preview/`url=` fetcher, an
      # image proxy, an `?dest=`/`?feed=` importer), pointing that parameter at an attacker host
      # turns the server into a request forwarder — reachable into the internal network, cloud
      # metadata, localhost admin panels. The tell is not in any response gori can read on the
      # sending socket: a blind SSRF answers by making the TARGET connect to somewhere else. So
      # this rule cannot confirm itself the way the in-band rules do — it plants an OAST payload
      # and leaves the proof to `Probe::OutOfBand.sweep`, which fires when (and only when) the
      # target actually calls the interaction server.
      #
      # Gated to keep the automatic scan quiet and the finding meaningful:
      #   * runs ONLY when the project has a registered OAST listener (`opts.oob`). No listener,
      #     no payload to mint, no plan — the check simply is not there for a project that never
      #     set one up, rather than being a switch to toggle.
      #   * GET by default (a URL parameter is overwhelmingly a query parameter on a fetch
      #     endpoint); `allow_unsafe` widens to body-bearing methods for a deliberate manual /
      #     AGGRESSIVE run, since a webhook target is just as often POSTed.
      #   * the parameter's captured value must ALREADY be a URL (an absolute or scheme-relative
      #     URL — `Active.url_authority` proves it), or the parameter must be one of the
      #     conventional SSRF names carrying a host-shaped value. A parameter that never held a
      #     URL is never rewritten to one.
      #
      # Only the FIRST qualifying parameter is probed per flow: minting more payloads than the
      # one that matters would spend the operator's interaction budget on noise, and a callback
      # attributes to a single parameter anyway.
      class SsrfOast < Rule
        # Query/body parameter names that conventionally carry a fetched URL. Checked only to
        # ADMIT a host-shaped value under a telling name; a value that is already a full URL
        # qualifies under ANY name (see url_shaped?), so this list stays deliberately tight —
        # every name here sends a probe, so a false member is a payload wasted on every hit.
        SSRF_PARAMS = Set{"url", "uri", "link", "dest", "destination", "redirect", "redirect_uri",
                          "callback", "webhook", "fetch", "target", "proxy", "feed", "site",
                          "source", "src", "image_url", "img", "load", "domain", "host", "endpoint"}

        # A bare host: at least one dot, label characters only, no scheme and no path. Admits
        # `internal.example`, rejects `12` (an id) and `a value` (free text). The value has
        # already been percent-decoded when this runs.
        BARE_HOST = /\A[a-z0-9](?:[a-z0-9\-.]*[a-z0-9])?\.[a-z]{2,}\z/i
        # A bare IPv4 literal. The CANONICAL blind-SSRF targets are addresses, not names —
        # cloud metadata `169.254.169.254`, `127.0.0.1`, an internal `10.x` — and every one of
        # them ends in a digit, so `BARE_HOST` (which requires a trailing `.<tld-letters>`)
        # rejects them. Without this the rule never fires on exactly the values worth probing.
        # Octet range is not validated: the value only GATES whether we probe (we rewrite it to
        # our own payload regardless), so a near-miss like `999.1.1.1` costing one probe is
        # cheaper than a regex that has to be right about IP grammar.
        BARE_IPV4 = /\A\d{1,3}(?:\.\d{1,3}){3}\z/
        # Schemeless single-label hosts that are unmistakably SSRF-interesting. A general
        # single-label match (`intranet`, `db`) would fire on ordinary word values, so this is
        # an explicit allowlist of the internal names that actually matter.
        INTERNAL_HOSTS = Set{"localhost"}

        def info : RuleInfo
          RuleInfo.new("ssrf_oast", "Blind SSRF (out-of-band)",
            "Points one query, form, or JSON URL parameter at an OAST payload and flags the finding when the server calls back.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # No minter ⇒ plan returns nil ⇒ this must too (the dedup_key⇔plan equivalence). The
          # check is a nil test on a already-resolved field — it never mints, so the cheap
          # pre-check stays cheap.
          return nil unless opts.oob
          surface, slot = gate(detail, opts) || return nil
          key_string(detail, surface, slot)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          minter = opts.oob || return nil
          surface, slot = gate(detail, opts) || return nil
          payload, token, session_id = minter.mint || return nil
          change = InsertionPoints::Change.new(replace: inject_url(payload))
          request = InsertionPoints.build(detail, [{slot, change}])
          # A body-bearing HTTP/2 capture may have no Content-Length. The generated body
          # still needs framing when replayed over HTTP/1.1; query-only probes keep theirs.
          request = Fuzz::ContentLength.sync(request, true) unless slot.loc.query?
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "ssrf_oast", title: "Blind SSRF (server fetched an attacker-controlled URL)",
            severity: Store::Severity::High,
            evidence: "#{slot.loc.label} param `#{slot.name}` pointed at an OAST payload"[0, 120])
          Plan.new(request, [Param.new(slot.loc.label, slot.name, token)],
            key_string(detail, surface, slot), oob: [candidate])
        end

        # Blind by construction: nothing on the sending socket confirms it. The empty return is
        # not a stub — it is the whole point. Promotion happens in `OutOfBand.sweep` when the
        # payload's callback arrives, possibly minutes later and in another process.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          [] of Detection
        end

        # Wrap a minted payload as a fetchable URL. A provider that already mints a full URL
        # (custom-http / webhook.site / postbin) is used verbatim; a bare-host payload
        # (interactsh / BOAST) gets an `http://` scheme so the fetch does BOTH a DNS lookup and
        # an HTTP request — either callback proves the SSRF.
        private def inject_url(payload : String) : String
          payload.includes?("://") ? payload : "http://#{payload}"
        end

        # Pick ONE existing value across query/form/JSON, in that order. Adding body coverage
        # must not turn one probe into one probe per location or parameter. Only complete,
        # bounded, unencoded bodies are offered: this rule does not decode or reframe chunks.
        private def gate(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, InsertionPoints::Slot}?
          method, _, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed || !method_allowed?(method.upcase, opts)
          locations = body_eligible?(detail) ? InsertionPoints::DEFAULT_LOCATIONS : [Miner::Location::Query]
          surface = InsertionPoints.enumerate(detail, opts, locations) || return nil
          slot = surface.slots.first(opts.max_params).find { |s| ssrf_shaped?(s.name.scrub, s.value.scrub) }
          slot ? {surface, slot} : nil
        end

        private def body_eligible?(detail : Store::FlowDetail) : Bool
          body = detail.request_body || return false
          return false if body.empty? || body.size > BODY_CAP || detail.request_body_truncated?
          return false if Proxy::Codec::Http1.obfuscated_header?(detail.request_head)
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return false if req.malformed? || req.headers.get?("Transfer-Encoding")
          return false unless req.headers.get_all("Content-Encoding").all? { |v| v.strip.downcase == "identity" }
          types = req.headers.get_all("Content-Type")
          return false unless types.size == 1
          injectable_type?(types.first)
        end

        private def injectable_type?(value : String) : Bool
          media = value.split(';', 2).first.strip.downcase
          media == "application/x-www-form-urlencoded" || media == "application/json" ||
            (media.starts_with?("application/") && media.ends_with?("+json"))
        end

        # URL-shaped: the value is itself an absolute/scheme-relative URL (strongest signal, any
        # name), or the name is a known SSRF parameter AND the value is host-shaped (a dotted
        # host, a bare IPv4 — the cloud-metadata / localhost class — or an explicit internal
        # name).
        private def ssrf_shaped?(name : String, value : String) : Bool
          return true if Active.url_authority(value)
          SSRF_PARAMS.includes?(name.downcase) && host_like?(value)
        end

        private def host_like?(value : String) : Bool
          BARE_HOST.matches?(value) || BARE_IPV4.matches?(value) || INTERNAL_HOSTS.includes?(value.downcase)
        end

        private def key_string(detail : Store::FlowDetail, surface : InsertionPoints::Surface,
                               slot : InsertionPoints::Slot) : String
          InsertionPoints.dedup_key("ssrf_oast", detail, surface.method, surface.path, [slot])
        end
      end
    end
  end
end
