require "uri"
require "./types"
require "../out_of_band"
require "../../miner/inject"
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
            "Points a URL parameter at an OAST payload and flags the finding when the server calls back.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # No minter ⇒ plan returns nil ⇒ this must too (the dedup_key⇔plan equivalence). The
          # check is a nil test on a already-resolved field — it never mints, so the cheap
          # pre-check stays cheap.
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
          value = inject_url(payload)
          request = rebuild_query(detail.request_head, detail.request_body, path,
            with_replaced(pairs, idx, encode_value(value)))
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "ssrf_oast", title: "Blind SSRF (server fetched an attacker-controlled URL)",
            severity: Store::Severity::High,
            evidence: "param `#{name}` pointed at an OAST payload"[0, 120])
          Plan.new(request, [Param.new("query", name, token)],
            key_string(detail, method_up, path, name), oob: [candidate])
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

        # Percent-encode the injected URL so `://`, `/` and `&` in the payload cannot break out
        # of the parameter value and corrupt the query. `URI.encode_www_form` is what the
        # capture would have carried for a URL-valued parameter.
        private def encode_value(url : String) : String
          URI.encode_www_form(url)
        end

        # Shared gate for plan + dedup_key. Returns {METHOD, path, query pairs, index of the
        # first SSRF-shaped param, its DECODED name}, or nil. Both paths funnel here.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, Array(String), Int32, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless method_allowed?(method_up, opts)
          path, query = split_target(Active.origin_form(target))
          return nil if query.empty?
          pairs = query.split('&')
          found = first_ssrf_param(pairs) || return nil
          {method_up, path, pairs, found[0], found[1]}
        end

        # {index, decoded name} of the first query pair whose value is URL-shaped (or whose name
        # is a conventional SSRF param carrying a host-shaped value), else nil.
        private def first_ssrf_param(pairs : Array(String)) : {Int32, String}?
          pairs.each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            raw_name = pair[0...eq]
            next if raw_name.empty?
            raw_value = pair[(eq + 1)..]
            next if raw_value.empty?
            dname = decode(raw_name)
            dvalue = decode(raw_value)
            return {i, dname} if ssrf_shaped?(dname, dvalue)
          end
          nil
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

        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, name : String) : String
          "ssrf_oast|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{name.bytesize}:#{name}"
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

        # Percent-decoded AND scrubbed: `ssrf_shaped?` runs PCRE (`BARE_HOST`) over the value and
        # `Active.url_authority` scans chars, both of which raise on invalid UTF-8 that `%FF`
        # decodes to. Mirrors lfi_param_traversal#decode (same reasoning, stated there in full).
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
        # re-syncing Content-Length (mirrors OpenRedirect#rebuild_query / LfiParamTraversal).
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
