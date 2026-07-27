require "./types"
require "../../miner/inject"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active missing-authorization probe for Next.js Server Actions.
      #
      # A Next.js `"use server"` function is invoked by a POST to its page route carrying a
      # `Next-Action: <hash id>` request header (and a JSON-array body of the arguments). The
      # framework does NOT authenticate or authorize these RPC endpoints for you — every action
      # must gate itself — so an action that reads or mutates privileged data but forgets the
      # check is a broken-access-control hole. Passive analysis can only note whether a *captured*
      # invocation happened to carry a session cookie; it cannot prove the server actually
      # ENFORCES it. (This is the security-relevant core of yassinebk/CaidoNextJSActionsAnalyzer,
      # turned from a passive "no auth headers observed" note into a confirming probe.)
      #
      # For one in-scope flow that invoked an action WITH credentials (Cookie / Authorization) and
      # got a 2xx, this re-sends the SAME request with those credentials stripped. If the action
      # still returns a comparable 2xx — not a login redirect, a 401/403, or an in-band
      # "unauthorized" payload — the authorization check is likely missing. Reported Medium
      # "possible": it is a single-shot test against the captured baseline and a legitimately
      # public action would also answer, so it is a lead to confirm manually — the same framing as
      # ForbiddenBypass, on which this rule's request-rebuild and status-flip logic are modelled.
      #
      # Gated to allow_unsafe because server actions are POST: the automatic scan never re-sends a
      # POST (SAFE_METHODS), so this runs only under the manual per-flow "Run active scan" with
      # unsafe methods ticked, or AGGRESSIVE mode. A rare GET-invoked action is safe to re-send and
      # is probed by default.
      class NextjsActionNoAuth < Rule
        def info : RuleInfo
          RuleInfo.new("nextjs_action_no_auth", "Next.js server action missing authorization",
            "Re-sends a Next.js server action (Next-Action) with the session cookie/Authorization stripped and flags a still-successful 2xx.",
            Category::ACTIVE)
        end

        # The credential headers the probe removes (downcased, for the rebuild filter). Cookie
        # carries the session; Authorization carries a bearer/basic token — either is what a
        # self-gating action would key its authorization decision on.
        CRED_HEADERS = Set{"cookie", "authorization"}

        # A stripped response that reads as an auth challenge is the control WORKING, not a bypass:
        # Next.js frequently answers an unauthenticated action with a 200 whose RSC payload is an
        # in-band "unauthorized / please sign in" notice rather than a 401. Excluding these keeps
        # the automatic Medium finding low-FP (a real bypass returns the privileged payload, which
        # does not read like a rejection). A 3xx login redirect is already excluded by the 2xx gate.
        AUTH_FAIL = /unauthorized|unauthenticated|forbidden|not\s*authenticated|not\s*logged\s*in|please\s*(?:log|sign)\s*in|access\s*denied|authentication\s*required|login\s*required/i

        # A redirect TARGET (X-Action-Redirect / Location value) that points at a login/auth route:
        # the token must sit on a path/query boundary so "/login", "/auth/callback", "?next=/signin"
        # match but a page merely named "/blogin" does not. Header-only, so it never scans body prose.
        LOGIN_PATH = /(?:^|[\/=?&.])(?:log-?in|sign-?in|auth|sso|oauth)(?:[\/?&#=]|$)/i

        # The dedup key WITHOUT rebuilding the probe — same gates as `plan`, same key; nil in
        # exactly the same cases. Parses the full request head (both paths need the Next-Action /
        # Cookie / Authorization headers), so there is no fast-path that could drift from `plan`.
        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless method_allowed?(req.method.upcase, opts)
          aid = action_id(req)
          return nil if aid.nil?
          return nil unless has_credentials?(req)
          return nil unless success_status?(detail.row.status)
          key_string(detail, req.method.upcase, req.target, aid)
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return nil if req.malformed?
          return nil unless method_allowed?(req.method.upcase, opts)
          aid = action_id(req)
          return nil if aid.nil?
          return nil unless has_credentials?(req)
          return nil unless success_status?(detail.row.status)
          request = rebuild_without_credentials(detail.request_head, detail.request_body)
          Plan.new(request, [] of Param, key_string(detail, req.method.upcase, req.target, aid))
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          return [] of Detection unless result.ok?
          # A truncated probe response (the origin closed early, or the body hit the capture
          # ceiling) can't be trusted for the status/size comparison below — treat it as no
          # evidence rather than risk a false positive on a privileged-looking fragment, or a
          # false negative on a body cut short below the baseline. (See Repeater::Result#incomplete?.)
          return [] of Detection if result.incomplete?

          resp = Proxy::Codec::Http1.parse_response_head(result.head)
          status = resp.status
          # The control HELD if the credential-less request no longer succeeds: a 3xx login
          # redirect, a 401/403, or any non-2xx. Only a still-2xx response is a candidate bypass.
          return [] of Detection unless (200..299).includes?(status)
          # …or if the action bounced the anonymous caller to login IN-BAND on a 2xx. A Next.js
          # server action signals redirect() via the X-Action-Redirect response header (not a 3xx),
          # and a plain Location to a login/auth route is the same tell — a data-returning action
          # sets neither. This is the 2xx redirect case AUTH_FAIL's prose scan would miss.
          return [] of Detection if control_redirected?(resp)

          stripped = capped_decoded(result.head, result.body)
          head_text = String.new(result.head).scrub
          body_text = String.new(stripped).scrub
          # In-band rejection (a 200 whose payload is an unauthorized/sign-in notice) → not a bypass.
          return [] of Detection if AUTH_FAIL.matches?("#{head_text}\n#{body_text}")

          # Similarity guard: a real bypass hands back the SAME privileged payload to the
          # credential-less client. Both lengths are RAW decoded byte counts (symmetric — neither
          # scrubbed, so a non-UTF-8 body can't inflate one side), capped identically.
          stripped_len = stripped.size
          return [] of Detection if stripped_len == 0
          orig_len = capped_decoded(detail.response_head, detail.response_body).size
          # No authenticated payload to compare against (a 204 / empty 200): the "same privileged
          # data returned without creds" evidence is absent, so don't flag on an arbitrary body.
          # (An empty-bodied mutation bypass isn't detectable by response diffing — accepted FN.)
          return [] of Detection if orig_len == 0
          return [] of Detection if stripped_len < (orig_len // 2)

          aid = action_id(Proxy::Codec::Http1.parse_request_head(detail.request_head))
          [Detection.new("nextjs_action_no_auth", Category::ACTIVE, detail.row.host, detail.row.url,
            "Possible missing authorization on Next.js server action", Store::Severity::Medium,
            "action #{short_id(aid)}: #{detail.row.status} with creds → #{status} WITHOUT Cookie/Authorization (single-shot; confirm the response is privileged)",
            detail.row.id)]
        rescue
          [] of Detection
        end

        # The Next-Action header value (the server-action hash id), stripped; nil when absent or
        # empty — i.e. the flow is not a server-action invocation, so there is nothing to probe.
        private def action_id(req : Proxy::Codec::RawRequest) : String?
          v = req.headers.get?("Next-Action").try(&.strip)
          (v && !v.empty?) ? v : nil
        end

        # Short id for the evidence line, mirroring the Caido plugin's 8-char label.
        private def short_id(aid : String?) : String
          return "?" unless aid
          aid.size > 8 ? aid[0, 8] : aid
        end

        # There must be a credential to strip: an already-unauthenticated invocation proves
        # nothing (a public action answering an anonymous client is expected).
        private def has_credentials?(req : Proxy::Codec::RawRequest) : Bool
          %w[Cookie Authorization].any? do |h|
            (v = req.headers.get?(h)) && !v.strip.empty?
          end
        end

        # Only a request that SUCCEEDED with credentials is worth stripping: if the authenticated
        # call itself failed, a matching failure without creds is not a finding.
        private def success_status?(status : Int32?) : Bool
          status ? (200..299).includes?(status) : false
        end

        # One probe per (host, method, path, action-id): the query is stripped (authorization is
        # per-action, not per-argument), and the action id is included so distinct actions posted
        # to the same page route are distinct surfaces. host:PORT so another service is distinct.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, target : String, aid : String) : String
          "nextjs_action_no_auth|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path_key(target)}|#{aid}"
        end

        private def path_key(target : String) : String
          t = Active.origin_form(target)
          qi = t.index('?')
          qi ? t[0...qi] : t
        end

        # Whether the response redirected the credential-less caller to a login/auth route — the
        # control working, not a bypass. Checks the header a Next.js server action sets when it
        # calls redirect() (X-Action-Redirect, delivered on a 2xx), and a plain Location, against a
        # login/auth path pattern. Only the redirect TARGET is inspected (a header, not the body),
        # so a privileged payload that merely links to /login can't over-suppress a real finding.
        private def control_redirected?(resp : Proxy::Codec::RawResponse) : Bool
          {resp.headers.get?("X-Action-Redirect"), resp.headers.get?("Location")}.any? do |v|
            v && LOGIN_PATH.matches?(v)
          end
        end

        # Decoded, capped response body BYTES (empty when there is none). One helper for both the
        # stripped probe and the authenticated baseline so their sizes compare symmetrically, and
        # both go through the same content-decode so a gzip'd baseline vs a gzip'd probe is fair.
        private def capped_decoded(head : Bytes?, body : Bytes?) : Bytes
          return Bytes.empty if head.nil? || body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, BODY_CAP)
          bytes = decoded || body
          bytes[0, {bytes.size, BODY_CAP}.min]
        end

        # Rebuild the request with the credential headers removed: split off the head, drop any
        # Cookie / Authorization line, normalize an absolute-form (forward-proxy) request line to
        # origin-form (this goes DIRECT to the origin, like the sibling probes), and rejoin. The
        # body is untouched and no dropped header is Content-Length, so no resync is needed.
        private def rebuild_without_credentials(head : Bytes, body : Bytes?) : Bytes
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
          kept = [] of String
          lines.each_with_index do |l, i|
            next if i > 0 && credential_header?(l) # request line (i == 0) is normalized below
            kept << l
          end
          unless kept.empty?
            rl = kept[0].split(' ')
            kept[0] = "#{rl[0]} #{Active.origin_form(rl[1])} #{rl[2]}" if rl.size == 3
          end
          io = IO::Memory.new
          io << kept.join(eol) << eol << eol
          io.write(bbytes) unless bbytes.empty?
          io.to_slice
        end

        private def credential_header?(line : String) : Bool
          (c = line.index(':')) ? CRED_HEADERS.includes?(line[0...c].strip.downcase) : false
        end
      end
    end
  end
end
