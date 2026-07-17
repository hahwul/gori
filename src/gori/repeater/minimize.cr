require "json"
require "./engine"
require "../fuzz/engine"
require "../fuzz/matcher"
require "../miner/inject"
require "../miner/fingerprint"

module Gori::Repeater
  # Squash-style request minimizer: strips the noise out of a request (cosmetic headers,
  # tracking-cookie crumbs, query/body params) while keeping the response essentially the
  # same — the equivalent of Caido's "squash" plugin.
  #
  # Pure + TUI/Store-free so it unit-tests without a socket (and the TUI/CLI/MCP could all
  # drive it): the caller injects the network via a `Fuzz::Backend` and the editor-text →
  # wire-bytes translation via a `resolve` proc. HYBRID strategy — a static denylist picks
  # the HEADER candidates (auth/session/custom headers are never touched); then EVERY
  # candidate (denylist headers + Cookie crumbs + query/body params) is ACTIVELY verified:
  # the variant with it removed is re-sent and its response fingerprint compared to a
  # frozen, calibrated baseline. An item is dropped only when the response stays within
  # tolerance.
  module Minimize
    # Well-known request headers that are (almost) always cosmetic — a browser/CDN adds
    # them but the response body rarely depends on them. Only these are HEADER candidates;
    # `authorization` / `cookie` / `x-csrf*` / custom app headers are deliberately excluded
    # so we never strip an identity header just because THIS response happened to ignore it.
    # (Cookie is minimized crumb-by-crumb instead — see cookie_crumbs.) Matched
    # case-insensitively.
    REMOVABLE_HEADERS = %w(
      accept accept-encoding accept-language accept-charset
      user-agent referer origin dnt sec-gpc
      upgrade-insecure-requests cache-control pragma
      if-modified-since if-none-match priority purpose x-requested-with
    )
    # `sec-fetch-*` and `sec-ch-ua*` are whole families of client-hint headers.
    REMOVABLE_PREFIXES = %w(sec-fetch- sec-ch-ua)
    # Headers that are NEVER candidates for removal: the framing / hop-by-hop set (stripping
    # them breaks the request or its wire framing) PLUS `host` — required for virtual-host
    # routing, so removing it can silently change which site answers. `host` is already in the
    # Miner's forbidden set; we union it in explicitly so the guarantee holds even if that set
    # is ever edited. (None of these are in REMOVABLE_HEADERS either — belt and suspenders.)
    PROTECTED_HEADERS = Miner::Inject::FORBIDDEN_HEADERS | Set{"host"}

    # Baseline calibration rounds — enough to observe natural churn (timestamps/CSRF) so a
    # near-static page still gets a non-zero tolerance band. Mirrors Miner's stability_rounds.
    CALIBRATION_ROUNDS = 3

    enum Kind
      Header
      Cookie
      Query
      Param # a form-urlencoded or JSON body param
    end

    record Removed, kind : Kind, label : String

    # Progress ping for a Jobs bar: how many of `total` candidates have been processed.
    record Progress, done : Int32, total : Int32

    record Report,
      minimized_text : String,   # the trimmed request (unchanged from input if nothing dropped/aborted)
      removed : Array(Removed),  # what was stripped, in removal order
      sends : Int32,             # total network sends (calibration + probes)
      aborted : Bool,            # true = calibration failed, request left untouched
      note : String              # human one-liner for the status bar / notification

    # The immutable baseline a variant is judged against (a FROZEN snapshot of the original
    # response — never re-derived from an intermediate working request, so accumulating
    # removals can't drift the target).
    private record Baseline,
      status : Int32?,
      length : Int64, words : Int32, lines : Int32,
      length_tol : Int64, words_tol : Int32, lines_tol : Int32,
      # Behavior-relevant response headers that stayed STABLE across the calibration rounds.
      # A variant that changes any of these is treated as CHANGED (kept), so a param whose
      # only effect is on headers (redirect target, Set-Cookie, CORS, auth) is not false-stripped.
      stable_headers : Hash(String, String)

    # One removable item + how to excise it from the working text (nil = it no longer
    # applies, e.g. an earlier removal already took it). Holding the excision as a closure
    # (built via a helper that takes the value as an argument) sidesteps the loop-variable
    # capture trap.
    private record Candidate, kind : Kind, label : String, remove : Proc(String, String?)

    # Minimize `base_text` (the editor's LF request text, SOURCE form — $ENV kept
    # unexpanded). `resolve` turns a candidate text into the wire bytes to send (env-expand
    # + Content-Length resync); `backend` is the send seam (wrap a Fuzz::Sender in a
    # Fuzz::CappedBackend so a pathological request can't blast the origin). `auto_cl` gates
    # body-param removal: only when Auto-Content-Length is on can we safely re-length the
    # body. Yields Progress as it goes.
    def self.run(base_text : String, *,
                 auto_cl : Bool,
                 resolve : Proc(String, Bytes),
                 backend : Fuzz::Backend,
                 & : Progress ->) : Report
      candidates = candidates_for(base_text, auto_cl: auto_cl)
      return Report.new(base_text, [] of Removed, 0, false, "already minimal — nothing removable") if candidates.empty?

      sends = 0
      # --- calibrate a FROZEN baseline from the original request ---
      metrics = [] of Fuzz::Metrics
      sigs = [] of Hash(String, String)
      CALIBRATION_ROUNDS.times do
        r = backend.send(resolve.call(base_text))
        sends += 1
        if r.error.nil? && !r.incomplete?
          metrics << Miner::Fingerprint.probe(r).metrics
          sigs << behavior_signature(r.head)
        end
      end
      return Report.new(base_text, [] of Removed, sends, true, "baseline unreachable — request left unchanged") if metrics.empty?
      statuses = metrics.compact_map(&.status).uniq!
      unless statuses.size <= 1
        return Report.new(base_text, [] of Removed, sends, true,
          "baseline response unstable (status #{statuses.join("/")}) — request left unchanged")
      end
      baseline = calibrate(metrics, sigs)

      # --- greedy: try each candidate against the CURRENT working text, keep the removal
      # only if the response is still within tolerance of the frozen baseline ---
      working = base_text
      removed = [] of Removed
      total = candidates.size
      candidates.each_with_index do |cand, i|
        yield Progress.new(i, total)
        variant = cand.remove.call(working)
        next if variant.nil? || variant == working # already gone under an earlier removal
        r = backend.send(resolve.call(variant))
        sends += 1
        return Report.new(working, removed, sends, false, cap_note(removed)) if r.error == Fuzz::CappedBackend::CAP_ERROR
        if unchanged?(r, baseline)
          working = variant
          removed << Removed.new(cand.kind, cand.label)
        end
      end
      yield Progress.new(total, total)
      Report.new(working, removed, sends, false, summary_note(removed, sends))
    end

    # ── candidate enumeration ──────────────────────────────────────────────────────────

    private def self.candidates_for(text : String, *, auto_cl : Bool) : Array(Candidate)
      head_lines, body, has_body = split_text(text)
      out = [] of Candidate

      head_lines.each_with_index do |line, i|
        next if i == 0 # request line
        name = header_name(line)
        next if name.empty?
        dn = name.downcase
        if dn == "cookie"
          cookie_crumbs(line).each { |crumb| out << cookie_candidate(crumb) }
        elsif removable_header?(dn)
          out << header_candidate(line)
        end
      end

      query_segments(head_lines[0]?).each { |seg| out << query_candidate(seg) }

      # Body params only when Auto-Content-Length is on (so resolve re-lengths the body) —
      # otherwise a deliberately-wrong CL (a smuggling/CL.TE probe) would be clobbered.
      if has_body && auto_cl && !body.empty?
        ct = (header_value(head_lines, "content-type") || "").downcase
        if ct.includes?("application/json") || (ct.empty? && looks_json?(body))
          json_keys(body).each { |k| out << json_candidate(k) }
        elsif ct.includes?("x-www-form-urlencoded") || (ct.empty? && looks_form?(body))
          form_segments(body).each { |seg| out << form_candidate(seg) }
        end
      end
      out
    end

    private def self.header_candidate(line : String) : Candidate
      Candidate.new(Kind::Header, header_name(line), ->(text : String) {
        hl, body, sep = split_text(text)
        idx = (1...hl.size).find { |k| hl[k] == line }
        return nil unless idx
        hl.delete_at(idx)
        join_text(hl, body, sep)
      })
    end

    private def self.cookie_candidate(crumb : String) : Candidate
      Candidate.new(Kind::Cookie, crumb.split('=', 2).first, ->(text : String) {
        hl, body, sep = split_text(text)
        idx = (1...hl.size).find { |k| header_name(hl[k]).downcase == "cookie" }
        return nil unless idx
        colon = hl[idx].index(':').not_nil!
        prefix = hl[idx][0...colon]
        crumbs = hl[idx][(colon + 1)..].strip.split(/;\s*/).reject(&.empty?)
        return nil unless crumbs.includes?(crumb)
        crumbs.delete(crumb)
        if crumbs.empty?
          hl.delete_at(idx)
        else
          hl[idx] = "#{prefix}: #{crumbs.join("; ")}"
        end
        join_text(hl, body, sep)
      })
    end

    private def self.query_candidate(seg : String) : Candidate
      Candidate.new(Kind::Query, seg.split('=', 2).first, ->(text : String) {
        hl, body, sep = split_text(text)
        return nil if hl.empty?
        method, target, version = split_request_line(hl[0])
        return nil unless target && (q = target.index('?'))
        path = target[0, q]
        segs = target[(q + 1)..].split('&')
        return nil unless segs.includes?(seg)
        segs.delete(seg)
        new_target = segs.empty? ? path : "#{path}?#{segs.join('&')}"
        hl[0] = join_request_line(method, new_target, version)
        join_text(hl, body, sep)
      })
    end

    private def self.form_candidate(seg : String) : Candidate
      Candidate.new(Kind::Param, seg.split('=', 2).first, ->(text : String) {
        hl, body, sep = split_text(text)
        return nil unless sep
        segs = body.split('&')
        return nil unless segs.includes?(seg)
        segs.delete(seg)
        join_text(hl, segs.join('&'), sep)
      })
    end

    private def self.json_candidate(key : String) : Candidate
      Candidate.new(Kind::Param, key, ->(text : String) {
        hl, body, sep = split_text(text)
        return nil unless sep
        parsed = (JSON.parse(body) rescue nil)
        return nil unless parsed
        obj = parsed.as_h?
        return nil unless obj && obj.has_key?(key)
        obj.delete(key)
        join_text(hl, parsed.to_json, sep)
      })
    end

    # ── comparison ─────────────────────────────────────────────────────────────────────

    # Behavior-relevant response headers whose value carries request semantics beyond the
    # body — a param that only moves these (a redirect target, a Set-Cookie, CORS/auth) must
    # not be silently stripped. Set-Cookie is handled separately (by cookie NAME, since its
    # value rotates); the rest compare by value. Only ones stable across calibration are used.
    BEHAVIOR_HEADERS = %w(location content-type content-disposition
      access-control-allow-origin access-control-allow-credentials www-authenticate)

    # Normalized signature of a response's behavior-relevant headers (empty when the head
    # can't be parsed). Set-Cookie reduces to its sorted cookie NAMES so a rotating session/
    # CSRF value doesn't itself read as a change.
    private def self.behavior_signature(head : Bytes) : Hash(String, String)
      sig = {} of String => String
      return sig if head.empty?
      resp = (Proxy::Codec::Http1.parse_response_head(head) rescue nil)
      return sig unless resp
      BEHAVIOR_HEADERS.each do |h|
        if v = resp.headers.get?(h)
          sig[h] = v.strip
        end
      end
      names = resp.headers.get_all("set-cookie").compact_map { |sc| (eq = sc.index('=')) ? sc[0...eq].strip : nil }
      sig["set-cookie-names"] = names.uniq!.sort!.join(",") unless names.empty?
      sig
    end

    # The subset of behavior headers that held an identical value across EVERY calibration
    # round — a naturally-rotating header (per-request token in Location, a Date-y header)
    # varies across rounds and is dropped, so it can't cause a false "changed". Require ≥2
    # successful samples: a single sample would mark EVERY header "stable" (all? is vacuously
    # true), gating a rotating header as changed and regressing minimize to remove-nothing.
    private def self.stable_headers(sigs : Array(Hash(String, String))) : Hash(String, String)
      return {} of String => String if sigs.size < 2
      stable = {} of String => String
      sigs.first.each do |k, v|
        stable[k] = v if sigs.all? { |s| s[k]? == v }
      end
      stable
    end

    private def self.calibrate(metrics : Array(Fuzz::Metrics), sigs : Array(Hash(String, String))) : Baseline
      base = metrics.first
      lengths = metrics.map(&.length)
      words = metrics.map(&.words)
      lines = metrics.map(&.lines)
      # Each band = 2× the observed calibration jitter, floored (size-proportional) so a
      # near-static page still tolerates small natural churn. Same formula as Miner::Baseline.
      length_tol = {(lengths.max - lengths.min) * 2, {8_i64, base.length // 100}.max}.max
      words_tol = {(words.max - words.min) * 2, {3, base.words // 100}.max}.max
      lines_tol = {(lines.max - lines.min) * 2, {2, base.lines // 100}.max}.max
      Baseline.new(base.status, base.length, base.words, base.lines, length_tol, words_tol, lines_tol, stable_headers(sigs))
    end

    # A variant's response is "unchanged" when the status matches, every body metric is within
    # its tolerance band, AND every stable behavior header still holds its baseline value. An
    # errored or truncated send is treated as CHANGED (its metrics are unreliable), so the
    # candidate is kept.
    private def self.unchanged?(r : Result, b : Baseline) : Bool
      return false unless r.error.nil? && !r.incomplete?
      m = Miner::Fingerprint.probe(r).metrics
      return false unless m.status == b.status &&
                          (m.length - b.length).abs <= b.length_tol &&
                          (m.words - b.words).abs <= b.words_tol &&
                          (m.lines - b.lines).abs <= b.lines_tol
      # A variant that moved any stable behavior header (redirect target, Set-Cookie set,
      # CORS/auth) is CHANGED — keep the param even though the body/status matched.
      sig = behavior_signature(r.head)
      b.stable_headers.all? { |k, v| sig[k]? == v }
    end

    # ── text helpers (operate on the LF editor form; resolve() handles CRLF for the wire) ─

    # {head lines (request line at [0]), body, has-separator}. A request with no blank line
    # is all-head with an empty body.
    private def self.split_text(text : String) : {Array(String), String, Bool}
      if sep = text.index("\n\n")
        {text[0, sep].split('\n'), text[(sep + 2)..], true}
      else
        {text.split('\n'), "", false}
      end
    end

    private def self.join_text(head_lines : Array(String), body : String, has_body : Bool) : String
      has_body ? "#{head_lines.join('\n')}\n\n#{body}" : head_lines.join('\n')
    end

    private def self.header_name(line : String) : String
      (c = line.index(':')) ? line[0...c].strip : ""
    end

    private def self.header_value(head_lines : Array(String), name : String) : String?
      dn = name.downcase
      head_lines.each_with_index do |line, i|
        next if i == 0
        return line[(line.index(':').not_nil! + 1)..].strip if header_name(line).downcase == dn
      end
      nil
    end

    private def self.removable_header?(dn : String) : Bool
      return false if PROTECTED_HEADERS.includes?(dn) # Host + framing headers stay, always
      REMOVABLE_HEADERS.includes?(dn) || REMOVABLE_PREFIXES.any? { |p| dn.starts_with?(p) }
    end

    private def self.cookie_crumbs(line : String) : Array(String)
      (c = line.index(':')) ? line[(c + 1)..].strip.split(/;\s*/).reject(&.empty?) : [] of String
    end

    private def self.query_segments(request_line : String?) : Array(String)
      return [] of String unless request_line
      _, target, _ = split_request_line(request_line)
      return [] of String unless target && (q = target.index('?'))
      target[(q + 1)..].split('&').reject(&.empty?)
    end

    # {method, request-target, version}. Split on the FIRST and LAST space (request-targets
    # can, unusually, carry a raw space), mirroring repeater_view's graphql_query_line.
    private def self.split_request_line(line : String) : {String, String?, String?}
      first = line.index(' ')
      return {line, nil, nil} unless first
      last = line.rindex(' ')
      if last && last > first
        {line[0...first], line[(first + 1)...last], line[(last + 1)..]}
      else
        {line[0...first], line[(first + 1)..], nil}
      end
    end

    private def self.join_request_line(method : String, target : String, version : String?) : String
      version ? "#{method} #{target} #{version}" : "#{method} #{target}"
    end

    private def self.form_segments(body : String) : Array(String)
      body.split('&').reject(&.empty?)
    end

    private def self.json_keys(body : String) : Array(String)
      (JSON.parse(body).as_h?.try(&.keys) rescue nil) || [] of String
    end

    private def self.looks_json?(body : String) : Bool
      body.lstrip.starts_with?('{')
    end

    private def self.looks_form?(body : String) : Bool
      body.includes?('=') && !body.lstrip.starts_with?('{') && !body.lstrip.starts_with?('[')
    end

    # ── notes ──────────────────────────────────────────────────────────────────────────

    private def self.summary_note(removed : Array(Removed), sends : Int32) : String
      return "already minimal — nothing removed (#{sends} sends)" if removed.empty?
      counts = {
        "header" => removed.count(&.kind.header?),
        "cookie" => removed.count(&.kind.cookie?),
        "param"  => removed.count { |r| r.kind.query? || r.kind.param? },
      }
      parts = counts.compact_map { |noun, n| n > 0 ? "#{n} #{noun}#{n == 1 ? "" : "s"}" : nil }
      "minimized: removed #{parts.join(", ")} (#{sends} sends)"
    end

    private def self.cap_note(removed : Array(Removed)) : String
      "send cap reached — kept #{removed.size} removal#{removed.size == 1 ? "" : "s"} so far (partial)"
    end
  end
end
