require "./types"
require "../../proxy/codec/http1"
require "../../proxy/codec/body"
require "../../repeater/h2_engine"

module Gori
  module Probe
    module Active
      # Active HTTP request-smuggling / desync detector (CL.TE / TE.CL / TE.TE, CL.0, H2.CL / H2.TE).
      #
      # A smuggling vulnerability exists when a front-end and a back-end DISAGREE on where one
      # request's body ends — because they read the Content-Length / Transfer-Encoding framing
      # differently. gori can already *send* deliberate CL/TE conflicts (Repeater "send group",
      # the codec's own rejection paths); this rule is the AUTOMATED detector that was the ironic
      # gap for a framing-centric tool. It is a pure `Active::Rule`: it crafts its OWN synthetic
      # `POST /` bytes (the captured method/body are irrelevant — only host/port/scheme and the
      # framing environment matter) and the analyzer owns the send.
      #
      # SAFETY POSTURE (user-decided, baked in exactly here):
      #   * TIMING is the DEFAULT signal. Each timing probe is an INCOMPLETE request that makes one
      #     framing tier block waiting for bytes that never arrive. It is SELF-DAMAGING: the origin
      #     abandons it on its own idle timeout and the blast radius is our OWN dedicated socket —
      #     nothing is smuggled into anyone else's request. Timing probes ride `followups` (a FRESH
      #     connection each), so the two repeats of a variant confirm INDEPENDENTLY (a shared socket
      #     could not — the first hang would retire it and the second would read as "skipped").
      #   * The DIFFERENTIAL confirm leg sends a COMPLETE smuggled prefix and reads the poisoned
      #     follow-up on the SAME socket (a `pipeline` group). A complete prefix could, in a shared
      #     back-end pool, affect ANOTHER user, so it runs ONLY under `opts.aggressive &&
      #     opts.allow_unsafe` — never in the default automatic scan.
      #   * DISABLED-BY-DEFAULT in the Rules sub-tab (it sends POST bodies): the rule's id is in
      #     `Probe::DEFAULT_DISABLED_RULES`, so the operator must opt in before it ever runs — which
      #     is what keeps the intrusive differential from auto-firing even in AGGRESSIVE mode.
      #   * `opts.allow_unsafe` is required to build a plan at all (synthetic POST bodies), so an
      #     automatic SAFE-method sweep is a strict no-op regardless of the toggle.
      #
      # VERDICT: High for a timing-only lead (a confirmed desync PRIMITIVE — one tier blocks on an
      # incomplete body the other considered complete — but exploitation is unproven); Critical when
      # the differential confirm fires (a smuggled canary demonstrably poisoned a neighbouring
      # request). Two independent repeats per variant plus a fast, reproducible baseline turn
      # endpoint jitter into a DECLINE rather than a finding (the backslash_powered discipline).
      class RequestSmuggling < Rule
        # µs thresholds for the timing verdict. A probe is "hung" when it runs at least
        # DELAY_THRESHOLD longer than the baseline (a real desync makes a tier wait for its whole
        # idle timeout — seconds — not the milliseconds a live endpoint answers in). BASE_FAST
        # gates the whole verdict on a reproducibly FAST baseline: a slow/loaded endpoint cannot
        # support a timing test, so it declines instead of firing on every variant.
        DELAY_THRESHOLD = 4_000_000_i64 # 4s slower than baseline ⇒ a tier blocked
        BASE_FAST       = 1_000_000_i64 # baseline must answer under 1s or we decline
        # Per-probe read bound for the DIFFERENTIAL pipeline (well under the analyzer's
        # ACTIVE_TIMEOUT of 10s): a poisoned follow-up either answers or misframes quickly, and we
        # never want a hung pipeline member to eat the whole per-probe budget. Timing probes ride
        # `followups`, which use the analyzer's Sender timeout — a hang there returns a clean
        # timeout error (the signal) at that bound.
        PROBE_TIMEOUT = 6.seconds

        # Response-head tokens that betray a front-end/back-end split (a CDN, a reverse proxy, a
        # load balancer). A desync can only exist when SOMETHING sits in front re-framing requests,
        # so this is a PRE-FILTER that keeps the intrusive probe off plainly-single-origin targets.
        # It is NEVER a verdict input — the timing/differential evidence is — only a gate on whether
        # to spend the probes at all. Lower-cased compare against the raw response head.
        FRONTEND_HEADER_HINTS = ["via:", "x-cache:", "x-served-by:", "x-varnish:", "cf-ray:",
                                 "x-amz-cf-id:", "x-fastly", "fastly-", "x-envoy"]
        FRONTEND_SERVER_HINTS = ["cloudflare", "cloudfront", "nginx", "awselb", "varnish",
                                 "envoy", "haproxy", "akamai", "fastly"]

        # The timing variants, by TRANSPORT — each a {code, short label, header-combo tag}.
        # `detections_all` reads each variant's two timing probes back at a fixed offset (see the
        # layout below). A flow is probed with EXACTLY ONE of these sets, picked by its transport
        # (`variants_for`): the h1 CL/TE framing ambiguity does not exist on an h2 wire, and the
        # h2-downgrade smuggle has no meaning on an h1 one.
        H1_VARIANTS = [
          {"request_smuggling_clte", "CL.TE", "CL + TE:chunked"},
          {"request_smuggling_tecl", "TE.CL", "TE:chunked + CL"},
          {"request_smuggling_tete", "TE.TE", "TE:chunked + obfuscated TE"},
        ]
        # H2→H1 DOWNGRADE desync. An h2 frontend frames by DATA/END_STREAM and ignores (or rejects)
        # a Content-Length / Transfer-Encoding header, so a pure-h2 origin answers these fast; a
        # frontend that downgrades to HTTP/1.1 forwards that header to a back-end which BLOCKS on
        # the body the frame never carried — the same "one tier blocks, the other does not" timing
        # signal as the h1 set, inverted onto the transport boundary.
        H2_VARIANTS = [
          {"request_smuggling_h2cl", "H2.CL", "h2 body + smuggled Content-Length"},
          {"request_smuggling_h2te", "H2.TE", "h2 body + smuggled Transfer-Encoding"},
        ]
        # CL.0 is DIFFERENTIAL-ONLY (h1): a front-end that treats the request as body-less leaves a
        # Content-Length body the back-end reads as a smuggled request. It has no timing primitive —
        # a Content-Length a single server honours blocks identically whether or not a split exists,
        # so timing cannot tell it apart (unlike CL.TE/TE.CL, whose header CONFLICT a conformant
        # single server rejects fast). It therefore rides the differential pipeline and only ever
        # surfaces as a confirmed poison.
        CL0 = {"request_smuggling_cl0", "CL.0", "front-end ignores Content-Length"}

        # Result layout the analyzer produces for this rule's plan (an h1 flow):
        #   [0] baseline #1 (plan.request)   [1] baseline #2 (stability twin)
        #   [2],[3] CL.TE probes             [4],[5] TE.CL probes    [6],[7] TE.TE probes
        #   [8] CL.TE smuggle   [9] CL.TE benign      [10] CL.0 smuggle   [11] CL.0 benign
        # The four pipeline members ([8..11]) are present under aggressive+unsafe only. An h2 flow
        # lays out [0],[1] baselines then [2..5] H2.CL / H2.TE probes and sends NO pipeline (a
        # same-socket differential needs h1 keep-alive; the h2 engine sends each member fresh).
        BASELINE_COUNT   = 2
        DIFF_SMUGGLE_IDX = BASELINE_COUNT + H1_VARIANTS.size * 2 # 8  — CL.TE smuggle
        DIFF_BENIGN_IDX  = DIFF_SMUGGLE_IDX + 1                  # 9  — CL.TE benign
        CL0_SMUGGLE_IDX  = DIFF_BENIGN_IDX + 1                   # 10 — CL.0 smuggle
        CL0_BENIGN_IDX   = CL0_SMUGGLE_IDX + 1                   # 11 — CL.0 benign

        def info : RuleInfo
          RuleInfo.new("request_smuggling", "HTTP request smuggling / desync (CL.TE/TE.CL/TE.TE, CL.0, H2.CL/H2.TE)",
            "Sends incomplete CL.TE/TE.CL/TE.TE (h1) or H2.CL/H2.TE downgrade (h2) framing probes and " \
            "flags a front-end/back-end desync by a timing hang; CL.0 and the differential confirm run " \
            "under aggressive+unsafe. Off by default; sends POST bodies.",
            Category::ACTIVE)
        end

        # The widest per-flow send count for the Rules sub-tab + manual-run estimate: an h2 flow is
        # 2 baselines + 2×2 timing probes (6); an h1 aggressive flow is 2 baselines + 3×2 timing
        # probes + a 4-member differential pipeline (12).
        def requests_per_flow : Range(Int32, Int32)
          (BASELINE_COUNT + H2_VARIANTS.size * 2)..(CL0_BENIGN_IDX + 1)
        end

        # The flow's transport decides which variant set is even applicable.
        private def http2?(detail : Store::FlowDetail) : Bool
          detail.http_version.starts_with?("HTTP/2")
        end

        # The timing variants this flow is probed with — exactly one set, by transport.
        private def variants_for(detail : Store::FlowDetail) : Array({String, String, String})
          http2?(detail) ? H2_VARIANTS : H1_VARIANTS
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          g = gate(detail, opts) || return nil
          key_string(g[0], g[1], opts, http2?(detail))
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          host, port = gate(detail, opts) || return nil
          hdr = host_header(host, port, detail.row.scheme)
          h2 = http2?(detail)
          baseline = benign_post(hdr)
          followups = [benign_post(hdr)] # baseline #2 — the stability twin (measure-against-itself)
          # Two INDEPENDENT repeats of each variant's timing probe (fresh connection each). Order
          # matches the layout above so detections_all can read them back positionally, and it must
          # mirror `variants_for`'s order for this transport.
          if h2
            followups << h2cl_probe(hdr) << h2cl_probe(hdr)
            followups << h2te_probe(hdr) << h2te_probe(hdr)
          else
            followups << clte_probe(hdr) << clte_probe(hdr)
            followups << tecl_probe(hdr) << tecl_probe(hdr)
            followups << tete_probe(hdr) << tete_probe(hdr)
          end

          pipeline = [] of Bytes
          timeout = nil.as(Time::Span?)
          # The differential leg is h1-only: it rides ONE keep-alive socket so the benign follow-up
          # reads what the smuggle left buffered, and the h2 engine sends each member on a fresh
          # connection. Each COMPLETE smuggled prefix carries a self-attributed random canary; the
          # smuggle's OWN response must come back complete (so `send_pipeline` does not retire the
          # socket first) — `detections_all` only counts a confirm when it did.
          if !h2 && differential_armed?(opts)
            pipeline = [diff_smuggle(hdr, "/gori-smuggle-#{Random::Secure.hex(6)}"), diff_benign(hdr),
                        cl0_smuggle(hdr, "/gori-smuggle-#{Random::Secure.hex(6)}"), cl0_benign(hdr)]
            timeout = PROBE_TIMEOUT
          end
          Plan.new(baseline, canary_params(opts), key_string(host, port, opts, h2), followups,
            pipeline: pipeline, probe_timeout: timeout)
        end

        # results = [baseline1, baseline2, clte×2, tecl×2, tete×2, (smuggle, benign)?]. Fire a
        # variant when BOTH its probes hung against a fast, reproducible baseline; escalate to
        # Critical when the differential leg confirms a real poison. One Detection per fired variant.
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          t_base = stable_baseline(results) || return [] of Detection
          # Per-family differential confirms (h1 only; absent/empty pipeline ⇒ false everywhere).
          clte_confirmed = differential_confirmed?(results, DIFF_SMUGGLE_IDX, DIFF_BENIGN_IDX)
          cl0_confirmed = differential_confirmed?(results, CL0_SMUGGLE_IDX, CL0_BENIGN_IDX)
          out = [] of Detection
          variants_for(detail).each_with_index do |(code, label, combo), i|
            a = results[BASELINE_COUNT + i * 2]?
            b = results[BASELINE_COUNT + i * 2 + 1]?
            next unless a && b
            next unless hung?(a, t_base) && hung?(b, t_base) # BOTH repeats — one alone is jitter
            out << detection(detail, code, label, combo, t_base, clte_confirmed)
          end
          # CL.0 has no timing primitive — it surfaces ONLY as a confirmed poison (Critical).
          out << detection(detail, CL0[0], CL0[1], CL0[2], t_base, true, timing: false) if cl0_confirmed
          # A CL.TE differential that fired but pinned NO timing variant is still a confirmed poison —
          # the smuggle prefix is CL.TE-shaped, so attribute it there rather than silently drop it.
          if clte_confirmed && out.none? { |d| d.code == H1_VARIANTS[0][0] }
            c, l, combo = H1_VARIANTS[0]
            out << detection(detail, c, l, combo, t_base, true)
          end
          out
        rescue
          [] of Detection
        end

        # Single-response fallback (module facade / one-shot caller): the timing test needs the
        # whole probe set, so one response alone yields nothing. The analyzer always calls
        # detections_all with the full result list.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # ── gate ─────────────────────────────────────────────────────────────────────

        # Shared gate for plan + dedup_key (so they cannot drift — the equivalence invariant: nil
        # from exactly the same inputs): {host, port} for a flow, under allow_unsafe, that a front-end
        # appears to sit in front of; nil otherwise. Every branch is a PRE-FILTER, never a verdict input.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, Int32}?
          # OFF-WIRE self-validation — HERE (in the SHARED gate), not in `plan`, precisely so
          # `dedup_key` returns nil in the same cases. The transport decides which craft family is
          # sent, so each self-validates its own: an h1 flow proves the CL.TE/TE.CL crafts still raise
          # the CL+TE rejection and TE.TE still trips obfuscated_header? (`crafts_ok?`); an h2 flow
          # proves the smuggled framing header survives h2 encoding (`h2_crafts_ok?`). A drift either
          # way turns the rule into a NO-OP (declines) rather than shipping a probe whose evidence is
          # no longer true. Both are host-independent + memoized, so they cost nothing per call. (h2
          # used to be declined outright — one framing, no CL/TE ambiguity — but the h2→h1 DOWNGRADE
          # desync is a real class the h2 wire reaches precisely because h2 ignores those headers.)
          return nil unless http2?(detail) ? h2_crafts_ok? : crafts_ok?
          # Synthetic POST bodies — never sent under a safe-method automatic sweep.
          return nil unless opts.allow_unsafe
          return nil unless frontend_present?(detail.response_head)
          host = detail.row.host
          return nil if host.empty?
          {host, detail.row.port}
        end

        # A LIGHT heuristic that something re-frames requests in front of the origin (a desync needs
        # a front-end/back-end disagreement to exist). Pre-filter ONLY — a miss just skips the probe.
        private def frontend_present?(response_head : Bytes?) : Bool
          head = response_head
          return false unless head && !head.empty?
          hay = String.new(head).downcase
          return true if FRONTEND_HEADER_HINTS.any? { |h| hay.includes?(h) }
          # `Server:` naming a known edge/proxy product.
          hay.each_line do |line|
            next unless line.starts_with?("server:")
            return FRONTEND_SERVER_HINTS.any? { |s| line.includes?(s) }
          end
          false
        rescue
          false
        end

        # host:PORT surface key (+`|aggr` when the differential leg is armed — an aggressive scan
        # sends a WIDER probe set than a plain unsafe one, so its key must differ or the
        # ACTIVE↔AGGRESSIVE backfill would skip an already-seen surface and never send the extra
        # leg). Byte-identical between plan and dedup_key for the same opts.
        private def key_string(host : String, port : Int32, opts : Options, http2 : Bool) : String
          # `|h1`/`|h2` because the SAME host:port can serve both transports (ALPN), and each is
          # probed with a different variant set — without the tag an h1 probe would mark the surface
          # seen and the h2 variants (or vice versa) would never be sent. `|aggr` only on h1, where
          # arming WIDENS the probe set (the differential pipeline); an h2 flow sends the same timing
          # probes whether or not it is armed, so tagging it would only re-send on mode escalation.
          # Byte-identical between plan and dedup_key for the same (opts, transport).
          aggr = !http2 && differential_armed?(opts) ? "|aggr" : ""
          "request_smuggling|#{host}:#{port}|#{http2 ? "h2" : "h1"}#{aggr}"
        end

        private def differential_armed?(opts : Options) : Bool
          opts.aggressive && opts.allow_unsafe
        end

        # No canary↔param mapping (this rule tests transport framing, not a parameter); the Param
        # list only carries an `|aggr`-visible marker so the Rules estimate/tooling has a stable row.
        private def canary_params(opts : Options) : Array(Param)
          [] of Param
        end

        # ── verdict helpers ────────────────────────────────────────────────────────────

        # The baseline µs to compare probes against, or nil to DECLINE the whole flow. Both benign
        # baselines must have SENT cleanly, come back COMPLETE, and answer under BASE_FAST — a
        # failed, incomplete, or slow baseline cannot anchor a timing test, so every variant would
        # be a coin flip. Uses the SLOWER of the two, so a single fast fluke can't lower the bar.
        #
        # TRANSPORT NOTE. Probe Active runs on a keep-alive sender, and the two benign baselines
        # are ordinary POSTs, so they ARE poolable: the first is a cold dial and the second rides
        # the socket it parked. The variant probes are not — `ConnPool.reusable_request?` refuses
        # a request whose framing is ambiguous, which is exactly what CL.TE / TE.CL / TE.TE are —
        # so every timing probe still dials fresh, and `max` (effectively the cold first baseline)
        # stays comparable to them. What the pooling DID cost is the twin's independence: the
        # second baseline is now systematically the faster of the two, so it no longer
        # cross-checks the first the way "measure-against-itself" intends. Both halves of that
        # are pinned in spec/probe/request_smuggling_spec.cr, because loosening the pool's
        # predicate would break the comparability silently.
        private def stable_baseline(results : Array(Repeater::Result)) : Int64?
          b1 = results[0]?
          b2 = results[1]?
          return nil unless b1 && b2
          return nil unless b1.ok? && b2.ok?
          return nil if b1.incomplete? || b2.incomplete?
          t = Math.max(b1.duration_us, b2.duration_us)
          t < BASE_FAST ? t : nil
        end

        # A probe "hung" iff it ran at least DELAY_THRESHOLD longer than the baseline (an idle
        # read timing out on a tier that blocked for bytes that never arrived) or the transport
        # reported an idle timeout. A FAST error (a strict 4xx reject, a connection refused, a
        # prompt RST) is deliberately NOT counted — it is not a timing signal, so this can't
        # false-fire on a server that simply rejects the ambiguous framing quickly.
        private def hung?(p : Repeater::Result, t_base : Int64) : Bool
          return true if p.timed_out?
          p.duration_us - t_base > DELAY_THRESHOLD
        end

        # The differential leg confirmed a poison: the COMPLETE smuggle got its own complete
        # response (so the socket was NOT retired and the benign follow-up really rode behind it),
        # AND that benign follow-up came back ANOMALOUS — errored/incomplete after a live smuggle,
        # a malformed/ambiguous head a lenient recipient would reframe, or a body reflecting our
        # own smuggled canary path. Absent/empty pipeline (timing-only) ⇒ false.
        private def differential_confirmed?(results : Array(Repeater::Result),
                                            smuggle_idx : Int32, benign_idx : Int32) : Bool
          smuggle = results[smuggle_idx]?
          benign = results[benign_idx]?
          return false unless smuggle && benign
          # A leg whose head ended on a bare-LF blank line was framed off gori's LENIENT reading,
          # so an odd benign response behind it may be gori's own misframe rather than the
          # back-end's — inconclusive, never a Critical.
          return false if smuggle.lf_framed? || benign.lf_framed?
          # Socket must have survived the smuggle — otherwise `benign` is a "skipped" Result and its
          # error says nothing about a poison.
          return false unless smuggle.ok? && !smuggle.incomplete?
          benign_anomalous?(benign)
        rescue
          false
        end

        # The benign follow-up's half of `differential_confirmed?`: it came back errored or
        # incomplete, with a malformed or ambiguous head, or reflecting the smuggled canary.
        private def benign_anomalous?(benign : Repeater::Result) : Bool
          return true if benign.error || benign.incomplete?
          head = benign.head
          return false if head.empty?
          resp = Proxy::Codec::Http1.parse_response_head(head)
          return true if resp.malformed?
          return true if Proxy::Codec::Http1.framing_ambiguous?(head, resp.headers)
          # The benign GET was for `/`; our smuggled canary path surfacing in ITS response means the
          # back-end served the smuggled request instead — the clearest possible confirmation.
          if body = benign.body
            return String.new(body).includes?("gori-smuggle-")
          end
          false
        end

        private def detection(detail : Store::FlowDetail, code : String, label : String, combo : String,
                              t_base : Int64, confirmed : Bool, timing : Bool = true) : Detection
          base_ms = (t_base / 1000).to_i
          ev = if timing
                 e = "#{label}: #{combo}; baseline #{base_ms}ms → probe hung >#{DELAY_THRESHOLD // 1_000_000}s, 2/2"
                 e += "; differential confirmed" if confirmed
                 e
               else
                 # CL.0: no timing probe — the finding IS the confirmed poison.
                 "#{label}: #{combo}; differential confirmed — smuggled canary surfaced on the follow-up"
               end
          Detection.new(code, Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible HTTP request smuggling / desync (#{label})",
            confirmed ? Store::Severity::Critical : Store::Severity::High,
            ev[0, 120], detail.row.id)
        end

        # ── craft ────────────────────────────────────────────────────────────────────

        # "host[:port]" for the Host header — the port is elided only for the scheme's default.
        private def host_header(host : String, port : Int32, scheme : String) : String
          default = scheme == "https" ? 443 : 80
          port == default ? host : "#{host}:#{port}"
        end

        # A benign, COMPLETE, body-less POST — the timing baseline. CL:0 is unambiguous framing, so
        # every conformant tier answers it fast and identically.
        private def benign_post(hdr : String) : Bytes
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: 0\r\n\r\n".to_slice
        end

        # CL.TE timing probe: front-end honours Content-Length (reads the whole 6-byte body and
        # forwards it), back-end honours Transfer-Encoding (reads chunk `1`=`Z`, then BLOCKS waiting
        # for the terminating `0`-chunk that never comes). CL == the exact body length, so a
        # CL-only server answers fast; only a TE-reading tier hangs.
        private def clte_probe(hdr : String) : Bytes
          body = "1\r\nZ\r\n" # 6 bytes: one 1-byte chunk, no 0-terminator
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: #{body.bytesize}\r\nTransfer-Encoding: chunked\r\n\r\n#{body}".to_slice
        end

        # TE.CL timing probe: front-end honours Transfer-Encoding (the `0`-chunk ends the request),
        # back-end honours Content-Length (waits for 6 body bytes but only 5 — `0\r\n\r\n` — arrive,
        # so it BLOCKS for the missing byte). A TE-only server answers fast; only a CL-reading tier
        # hangs. CL is deliberately one greater than the bytes sent.
        private def tecl_probe(hdr : String) : Bytes
          body = "0\r\n\r\n" # 5 bytes: the terminating chunk only
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: #{body.bytesize + 1}\r\nTransfer-Encoding: chunked\r\n\r\n#{body}".to_slice
        end

        # TE.TE timing probe: an OBFUSCATED Transfer-Encoding (whitespace before the colon) that a
        # lenient tier strips and honours (reads chunked → blocks on the incomplete chunk) while a
        # strict tier cannot match the field name and falls back to Content-Length (reads 6 bytes →
        # complete). `Http1.obfuscated_header?` sees the space-before-colon (self-validated).
        private def tete_probe(hdr : String) : Bytes
          body = "1\r\nZ\r\n"
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nTransfer-Encoding : chunked\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".to_slice
        end

        # The COMPLETE differential smuggle (aggressive+unsafe only): a CL.TE prefix whose
        # Content-Length spans the ENTIRE buffer (so a CL front-end forwards all of it and the outer
        # request gets a normal, complete response), while a TE back-end ends the outer request at
        # the `0`-chunk and leaves the trailing `GET /<canary>` buffered as the START of the next
        # request — poisoning whatever rides the socket next (our benign GET).
        private def diff_smuggle(hdr : String, canary : String) : Bytes
          smuggled = "0\r\n\r\nGET #{canary} HTTP/1.1\r\nX-Gori-Smuggle: 1\r\n"
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: #{smuggled.bytesize}\r\nTransfer-Encoding: chunked\r\n\r\n#{smuggled}".to_slice
        end

        # The benign follow-up that rides the socket right behind the smuggle. On a desyncing
        # back-end it is prefixed by the buffered `GET /<canary>` and answers anomalously.
        private def diff_benign(hdr : String) : Bytes
          "GET / HTTP/1.1\r\nHost: #{hdr}\r\n\r\n".to_slice
        end

        # CL.0 differential smuggle (aggressive+unsafe only, h1): a COMPLETE POST whose
        # Content-Length body IS a self-contained GET for a self-attributed canary. A conformant
        # back-end reads those bytes as the POST body and answers the POST normally (so the socket
        # survives for the follow-up); a front-end that treats this POST as body-less forwards it
        # bare and leaves the smuggled GET to be read as the START of the next request — poisoning
        # the benign GET that rides behind it. Unlike `diff_smuggle` this carries NO framing
        # conflict (just a plain Content-Length), so gori's codec passes it through verbatim — the
        # desync is behavioural, not a malformed-framing one, which is why it has no timing twin.
        private def cl0_smuggle(hdr : String, canary : String) : Bytes
          smuggled = "GET #{canary} HTTP/1.1\r\nHost: #{hdr}\r\nX-Gori-Smuggle: 1\r\n\r\n"
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: #{smuggled.bytesize}\r\n\r\n#{smuggled}".to_slice
        end

        # The benign follow-up behind the CL.0 smuggle — its own socket member, same shape as
        # `diff_benign` (a bare `GET /`). Kept separate so the two differential pairs read back at
        # distinct offsets.
        private def cl0_benign(hdr : String) : Bytes
          "GET / HTTP/1.1\r\nHost: #{hdr}\r\n\r\n".to_slice
        end

        # H2.CL downgrade probe: an h2 request whose Content-Length (6) EXCEEDS the DATA body it
        # actually carries (1 byte). A pure-h2 origin frames by DATA/END_STREAM and ignores (or, per
        # RFC 9113 §8.1.1, rejects) the length — either way it answers fast; a front-end that
        # downgrades to HTTP/1.1 forwards `Content-Length: 6` with the single body byte, and the
        # back-end BLOCKS waiting for the five bytes the frame never held. Sent over the h2 engine,
        # which carries `content-length` as an ordinary header and never re-syncs it (P7 — the
        # mismatch IS the payload).
        private def h2cl_probe(hdr : String) : Bytes
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nContent-Length: 6\r\n\r\nZ".to_slice
        end

        # H2.TE downgrade probe: an h2 request carrying `Transfer-Encoding: chunked` and an
        # INCOMPLETE chunk as the DATA body. h2 has no chunked framing — the field is invalid there
        # (RFC 9113 §8.2.2) — so a conformant origin ignores or rejects it and answers fast; a
        # downgrading front-end forwards the header and the lone chunk, and the HTTP/1.1 back-end
        # BLOCKS on the missing `0`-terminator. The body bytes ARE the chunk, byte-exact.
        private def h2te_probe(hdr : String) : Bytes
          "POST / HTTP/1.1\r\nHost: #{hdr}\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nZ\r\n".to_slice
        end

        # ── off-wire self-validation ───────────────────────────────────────────────────

        # Memoized craft validity (see `gate`). Host-independent — the framing STRUCTURE the codec
        # judges is identical for every host — so it is computed once against a representative host
        # and cached. `@@` (not a const) because it calls instance craft helpers; a class variable
        # keeps it a single evaluation shared across the registry's one rule instance.
        @@crafts_ok : Bool? = nil

        private def crafts_ok? : Bool
          v = @@crafts_ok
          return v unless v.nil?
          @@crafts_ok = crafts_valid?("selfcheck.invalid")
        end

        # Prove the crafts still mean what their evidence claims, against gori's OWN codec. Any drift
        # ⇒ the rule declines (via `gate`) rather than sending a probe whose framing the current
        # codec no longer reads as ambiguous.
        private def crafts_valid?(hdr : String) : Bool
          framing_rejected?(clte_probe(hdr)) &&
            framing_rejected?(tecl_probe(hdr)) &&
            framing_rejected?(diff_smuggle(hdr, "/gori-smuggle-selfcheck")) &&
            obfuscation_rejected?(tete_probe(hdr))
        end

        # `Body.request_framing` RAISES on this craft (the CL+TE / obfuscation rejection). We pass
        # the HEAD only — the boundary the codec parses — mirroring how the proxy holds `raw_head`.
        private def framing_rejected?(req : Bytes) : Bool
          head = head_of(req)
          Proxy::Codec::Body.request_framing(Proxy::Codec::Http1.parse_request_head(head))
          false
        rescue Gori::Error
          true
        rescue
          false
        end

        # The TE.TE craft trips `obfuscated_header?` AND makes `request_framing` raise the
        # obfuscation error — both, so a codec that learned to tolerate one still turns this off.
        private def obfuscation_rejected?(req : Bytes) : Bool
          head = head_of(req)
          Proxy::Codec::Http1.obfuscated_header?(head) && framing_rejected?(req)
        end

        # The h2 analog of `crafts_ok?`: the smuggled framing header must SURVIVE h2 encoding (the
        # send path), or the probe would carry no smuggle and a confirm would be meaningless. If a
        # future encoder strips `content-length`/`transfer-encoding`, the h2 variants decline
        # (NO-OP) rather than ship a probe whose evidence is no longer true. Memoized, host-
        # independent (the field set a given craft produces is the same for every host).
        @@h2_crafts_ok : Bool? = nil

        private def h2_crafts_ok? : Bool
          v = @@h2_crafts_ok
          return v unless v.nil?
          @@h2_crafts_ok = h2_header_survives?(h2cl_probe("sc.invalid"), "content-length") &&
                           h2_header_survives?(h2te_probe("sc.invalid"), "transfer-encoding")
        end

        # Encode the craft exactly as the Sender's h2 path will (`H2Engine.parse_request`) and check
        # the smuggled header is among the fields it will put on the wire. `parse_request` lower-
        # cases field names, so `name` is compared lower-cased.
        private def h2_header_survives?(req : Bytes, name : String) : Bool
          fields, _ = Repeater::H2Engine.parse_request(req, "https", "sc.invalid", 443)
          fields.any? { |(n, _)| n == name }
        rescue
          false
        end

        # The request head up to and including the terminating CRLFCRLF (or the whole buffer if it
        # somehow lacks one), so the codec parses the same boundary the proxy would capture.
        private def head_of(req : Bytes) : Bytes
          s = String.new(req)
          i = s.index("\r\n\r\n")
          i ? req[0, i + 4] : req
        end
      end
    end
  end
end
