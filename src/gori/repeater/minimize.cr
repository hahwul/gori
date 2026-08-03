require "json"
require "./engine"
require "../env"
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

    # Total network sends one minimize run may make, across calibration AND probes. Lives here,
    # on the engine that owns the algorithm, so the TUI/CLI/MCP cannot advertise a cap different
    # from the one they enforce (all three wrap their sender in a Fuzz::CappedBackend with it).
    SEND_CAP = 250_i64

    # Baseline calibration rounds — enough to observe natural churn (timestamps/CSRF) so a
    # near-static page still gets a non-zero tolerance band. Mirrors Miner's stability_rounds.
    CALIBRATION_ROUNDS = 3

    # The Repeater's group separator: a lone line of exactly this splits a request buffer
    # into the requests `space ▸ g` pipelines over one connection.
    #
    # THE definition, for every surface. It was briefly duplicated in
    # `Tui::RepeaterView::PIPELINE_SEP` because nothing in `cli/` or `mcp/` may reach into
    # `tui/`; the dependency runs the other way, so that copy is now an alias of this one and
    # there is a single spelling again. Change it here.
    GROUP_SEP = "%%%"

    # True when `text` is SEVERAL requests rather than one — it holds a lone `%%%` line.
    #
    # `run` below reads its base text structurally as ONE request (head/body split, then
    # header / cookie / param candidates), so on a group buffer it strips lines out of the
    # operator's SECOND request and reports them as removals from the first. Measured on a
    # saved two-request session through `gori run repeater minimize --apply`:
    #
    #     minimized: removed 2 cookies, 3 params (8 sends)
    #       - [param] %%%\nGET /g2?other      ← the entire second request, as a body PARAM
    #     saved back to session #1
    #     GET /g1 HTTP/1.1 …                  ← request 2 gone from the store, exit 0
    #
    # i.e. operator material destroyed irreversibly and reported as a clean optimisation.
    # The TUI refuses it via `RepeaterView#minimize_refusal`; this is the predicate its two
    # headless siblings refuse on, and it lives here so all three cannot drift about what
    # "several requests" means.
    #
    # Deliberately NOT provenance-aware, unlike the TUI's `group_document?`: a stored row
    # carries no record of how many separators it was seeded with, so a CAPTURED body whose
    # own bytes contain a lone `%%%` line is refused here too. That is the same exposure the
    # `§fuzz§` guard beside each call site already accepts, and a named refusal of a run that
    # would otherwise destroy the session is the cheaper error by a wide margin.
    def self.group_document?(text : String) : Bool
      text.split('\n').any? { |l| l.strip(" \t\r") == GROUP_SEP }
    end

    # Cooperative cancel token for one `run`. The caller keeps it, hands a copy to `run`, and
    # calls `#stop` from another fiber; `run` reads `stopped?` immediately before every network
    # send and returns a partial Report instead of issuing it.
    #
    # A cap is not a stop. `SEND_CAP` bounds a run, but "bounded" is not "over": an operator who
    # closes the repeater tab or leaves the project believes they disconnected from the target,
    # and up to SEND_CAP further probes against that origin is the one thing a pentest tool must
    # not do behind their back. The shape is `DiscoverRun#request_stop` → `Engine#stop`, one
    # layer down because the minimizer is a module function rather than an engine object.
    #
    # WHAT IT CANNOT DO: interrupt a send already on the socket. `Fuzz::Sender` owns that
    # timeout, so the guarantee is "at most one more request completes", not "zero" — which is
    # still the difference between 1 and SEND_CAP. A plain Bool matches `DiscoverRun`'s
    # `@stop_requested` and `Discover::Engine#stop`: fibers here are cooperative and the flag is
    # only ever written by the stopper and read by the run.
    class Stop
      def initialize
        @stopped = false
      end

      def stop : Nil
        @stopped = true
      end

      def stopped? : Bool
        @stopped
      end
    end

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
      minimized_text : String,  # the trimmed request (unchanged from input if nothing dropped/aborted)
      removed : Array(Removed), # what was stripped, in removal order
      sends : Int32,            # total network sends (calibration + probes)
      aborted : Bool,           # true = calibration failed, request left untouched
      note : String             # human one-liner for the status bar / notification

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
    #
    # `stop` (optional — a caller with no way to cancel passes nothing) is checked immediately
    # before EVERY send, so a run the operator abandoned stops reaching the origin instead of
    # riding SEND_CAP out. See `Stop`.
    def self.run(base_text : String, *,
                 auto_cl : Bool,
                 resolve : Proc(String, Bytes),
                 backend : Fuzz::Backend,
                 stop : Stop? = nil,
                 & : Progress ->) : Report
      # Every text helper below documents itself as operating on the LF editor form, and the
      # TUI does feed LF (`TextArea#set_text` strips CR). The CLI and MCP feed the STORED
      # bytes, which are CRLF — and `split_text`'s `index("\n\n")` finds nothing in a CRLF
      # request, so `has_body` came back false and body-param candidates were never
      # enumerated. The same session minimized further from the TUI than from `gori run
      # repeater minimize` on identical bytes. Normalise once here so the file's stated
      # assumption is actually true, and put the operator's line endings back on the way out.
      #
      # HEAD ONLY, both ways. In a header block a 0x0A is a line ending; in a BODY it is a
      # byte, and the round-trip used to run over the whole request: `\r\n`→`\n` on the way in
      # flattened a multipart body's CRLF boundaries, and `restore_eol`'s blanket `\n`→`\r\n`
      # on the way out promoted a body's bare LF, so a captured body ending in one came back
      # a byte longer in `minimized_text` — i.e. in `minimized_request`, in `minimized_source`,
      # and in what `--apply` STORES over the session. The CLI's send path patched that for
      # the bytes it sent and printed; leaving the body untouched end to end fixes the stored
      # form too, and is the rule every other site on this branch now follows.
      crlf = head_crlf?(base_text)
      base_text = normalize_head_lf(base_text) if crlf
      candidates = candidates_for(base_text, auto_cl: auto_cl)
      return Report.new(restore_eol(base_text, crlf), [] of Removed, 0, false, "already minimal — nothing removable") if candidates.empty?

      sends = 0
      # --- calibrate a FROZEN baseline from the original request ---
      metrics = [] of Fuzz::Metrics
      sigs = [] of Hash(String, String)
      CALIBRATION_ROUNDS.times do
        # Before the send, not after: a stop arriving mid-calibration must cost the origin
        # nothing further, and there is no partial result worth one more round-trip.
        break if stop.try(&.stopped?)
        r = backend.send(resolve.call(base_text))
        sends += 1
        if r.error.nil? && !r.incomplete?
          metrics << Miner::Fingerprint.probe(r).metrics
          sigs << behavior_signature(r.head)
        end
      end
      # Stopped before a baseline existed → nothing was verified, so the request is untouched
      # and `aborted` says so (same shape as an unreachable baseline, different sentence).
      if stop.try(&.stopped?)
        return Report.new(restore_eol(base_text, crlf), [] of Removed, sends, true,
          "stopped before the baseline was calibrated — request left unchanged")
      end
      return Report.new(restore_eol(base_text, crlf), [] of Removed, sends, true, "baseline unreachable — request left unchanged") if metrics.empty?
      statuses = metrics.compact_map(&.status).uniq!
      unless statuses.size <= 1
        return Report.new(restore_eol(base_text, crlf), [] of Removed, sends, true,
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
        # Exactly the cap's early exit, for exactly the cap's reason — the run ends here with
        # what it has. Every removal in `removed` was individually verified against the frozen
        # baseline, so keeping them (aborted: false) is as sound as the capped partial.
        return Report.new(restore_eol(working, crlf), removed, sends, false, stop_note(removed, sends)) if stop.try(&.stopped?)
        r = backend.send(resolve.call(variant))
        sends += 1
        return Report.new(restore_eol(working, crlf), removed, sends, false, cap_note(removed)) if r.error == Fuzz::CappedBackend::CAP_ERROR
        if unchanged?(r, baseline)
          working = variant
          removed << Removed.new(cand.kind, cand.label)
        end
      end
      yield Progress.new(total, total)
      Report.new(restore_eol(working, crlf), removed, sends, false, summary_note(removed, sends))
    end

    # Put CRLF back on the HEAD of a report built from head-LF-normalised text, leaving the
    # BODY byte for byte as it arrived. Split on `Env.head_body_boundary` — the same boundary,
    # and for the same reason, as `Env.expand_wire` and `gori run intercept edit`.
    #
    # Public, and IDEMPOTENT (`Env.normalize_crlf` never produces `\r\r\n`), because a
    # `--verbatim` resolver has to apply the same restoration to the two different forms
    # `run` hands it: the LF-headed working text during the search, and this method's own
    # already-CRLF output when a surface re-resolves the finished report.
    def self.restore_eol(text : String, crlf : Bool) : String
      return text unless crlf
      bytes = text.to_slice
      boundary = Env.head_body_boundary(bytes)
      head = Env.normalize_crlf(bytes[0, boundary])
      return String.new(head) if boundary >= bytes.size
      body = bytes[boundary..]
      io = IO::Memory.new(head.size + body.size)
      io.write(head)
      io.write(body)
      String.new(io.to_slice)
    end

    # Does the HEAD carry CRLF terminators? Head only, for `restore_eol`'s reason: a lone
    # 0x0D 0x0A inside a multipart body says nothing about how the header lines were written,
    # and treating it as if it did would re-terminate an LF head the operator wrote. Public
    # so a surface's `--verbatim` resolver asks the SAME question `run` asked.
    def self.head_crlf?(text : String) : Bool
      bytes = text.to_slice
      String.new(bytes[0, Env.head_body_boundary(bytes)]).includes?("\r\n")
    end

    # `\r\n` → `\n` over the HEAD alone, body copied through byte for byte.
    private def self.normalize_head_lf(text : String) : String
      bytes = text.to_slice
      boundary = Env.head_body_boundary(bytes)
      head = String.new(bytes[0, boundary]).gsub("\r\n", "\n")
      return head if boundary >= bytes.size
      body = bytes[boundary..]
      io = IO::Memory.new(head.bytesize + body.size)
      io << head
      io.write(body)
      String.new(io.to_slice)
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
      # BYTE-SPLICE the target key out of the AUTHORED body, never `JSON.parse(body).to_json`:
      # re-encoding canonicalizes the operator's bytes — it drops duplicate keys, unescapes
      # `\/` and `\uXXXX`, reformats `1.50`→`1.5`, and strips interior whitespace — which would
      # rewrite BOTH the probe requests AND `--apply`'s stored `minimized_text`, corrupting the
      # very framing/encoding a smuggling or WAF-bypass probe is testing. Mirrors form_candidate
      # / query_candidate, which splice the original substrings rather than re-serialize. Removes
      # EVERY top-level occurrence so a duplicated target key is fully gone (matching the old
      # parse→delete→reserialize semantics), while every OTHER byte survives verbatim.
      Candidate.new(Kind::Param, key, ->(text : String) {
        hl, body, sep = split_text(text)
        return nil unless sep
        new_body = body
        removed = false
        loop do
          spliced, hit = json_splice_key(new_body, key)
          break unless hit
          new_body = spliced
          removed = true
        end
        return nil unless removed
        join_text(hl, new_body, sep)
      })
    end

    # Removes the FIRST top-level member whose (decoded) key equals `key` from a JSON object
    # `body`, splicing the ORIGINAL bytes so everything kept — duplicate keys, `\/`, `\uXXXX`,
    # `1.50`, interior whitespace — is preserved byte-for-byte. Returns {new_body, true} on a
    # removal, {body, false} when the object is malformed or the key is absent (caller then
    # keeps the candidate, the safe direction). Parses ONLY to find the member's byte range.
    private def self.json_splice_key(body : String, key : String) : {String, Bool}
      bytes = body.to_slice
      n = bytes.size
      i = json_skip_ws(bytes, 0, n)
      return {body, false} unless i < n && bytes[i] == 0x7B_u8 # not a `{` object
      i += 1
      prev_comma = -1 # byte index of the comma before the current member, if any
      first = true
      while i < n
        i = json_skip_ws(bytes, i, n)
        break if i < n && bytes[i] == 0x7D_u8 # end of object, key not found
        return {body, false} unless i < n
        unless first
          return {body, false} unless bytes[i] == 0x2C_u8 # members are comma-separated
          prev_comma = i
          i = json_skip_ws(bytes, i + 1, n)
        end
        first = false
        return {body, false} unless i < n && bytes[i] == 0x22_u8 # a key is a `"`-string
        key_start = i
        key_end = json_string_end(bytes, i, n)
        return {body, false} unless key_end
        this_key = (String.from_json(body.byte_slice(key_start, key_end - key_start)) rescue nil)
        i = json_skip_ws(bytes, key_end, n)
        return {body, false} unless i < n && bytes[i] == 0x3A_u8 # `:` between key and value
        i = json_skip_ws(bytes, i + 1, n)
        value_end = json_value_end(bytes, i, n)
        return {body, false} unless value_end
        if this_key == key
          # Cut the member plus exactly ONE adjacent comma so the survivors stay valid JSON
          # and untouched. A trailing comma (there's a next member) is preferred; else the
          # leading comma (this is the last member); else it was the sole member.
          k = json_skip_ws(bytes, value_end, n)
          if k < n && bytes[k] == 0x2C_u8
            return {body.byte_slice(0, key_start) + body.byte_slice(k + 1, n - (k + 1)), true}
          elsif prev_comma >= 0
            return {body.byte_slice(0, prev_comma) + body.byte_slice(value_end, n - value_end), true}
          else
            return {body.byte_slice(0, key_start) + body.byte_slice(value_end, n - value_end), true}
          end
        end
        i = value_end
      end
      {body, false}
    end

    # JSON insignificant whitespace (RFC 8259 §2): space, tab, LF, CR.
    private def self.json_ws?(b : UInt8) : Bool
      b == 0x20_u8 || b == 0x09_u8 || b == 0x0A_u8 || b == 0x0D_u8
    end

    # First byte offset at or after `i` that is not JSON whitespace (or `n` if none).
    private def self.json_skip_ws(bytes : Bytes, i : Int32, n : Int32) : Int32
      while i < n && json_ws?(bytes[i])
        i += 1
      end
      i
    end

    # Byte offset just PAST the JSON string that starts at `bytes[i] == '"'`, honoring `\"`
    # (and every other `\`-escape by skipping the escaped byte). nil if it is unterminated.
    private def self.json_string_end(bytes : Bytes, i : Int32, n : Int32) : Int32?
      j = i + 1
      while j < n
        c = bytes[j]
        if c == 0x5C_u8 # backslash: the next byte is escaped, skip both
          j += 2
          next
        end
        return j + 1 if c == 0x22_u8 # closing quote
        j += 1
      end
      nil
    end

    # Byte offset just PAST the JSON value beginning at the first non-ws byte `bytes[i]`. Skips
    # a string (escape-aware), balances an object/array while honoring nested strings, or reads
    # a literal (number/true/false/null) up to the next structural byte or whitespace. nil when
    # the value is malformed/unterminated. Only structural ASCII bytes are inspected, so
    # multi-byte UTF-8 inside a string passes through opaquely.
    private def self.json_value_end(bytes : Bytes, i : Int32, n : Int32) : Int32?
      return nil unless i < n
      case bytes[i]
      when 0x22_u8 # string
        json_string_end(bytes, i, n)
      when 0x7B_u8, 0x5B_u8 # object `{` or array `[`
        depth = 0
        j = i
        while j < n
          c = bytes[j]
          if c == 0x22_u8
            e = json_string_end(bytes, j, n)
            return nil unless e
            j = e
            next
          elsif c == 0x7B_u8 || c == 0x5B_u8
            depth += 1
          elsif c == 0x7D_u8 || c == 0x5D_u8
            depth -= 1
            return j + 1 if depth == 0
          end
          j += 1
        end
        nil
      else # number / true / false / null — up to a structural byte or whitespace
        j = i
        while j < n
          c = bytes[j]
          break if c == 0x2C_u8 || c == 0x7D_u8 || c == 0x5D_u8 || json_ws?(c)
          j += 1
        end
        j == i ? nil : j
      end
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

    # A stop reports the SENDS as well as the removals, unlike `cap_note`: the cap's count is
    # already known (it is the cap), while "how many requests did the origin actually get
    # before it stopped" is the whole question the operator pressed stop to ask.
    private def self.stop_note(removed : Array(Removed), sends : Int32) : String
      "stopped — kept #{removed.size} removal#{removed.size == 1 ? "" : "s"} (#{sends} sends)"
    end
  end
end
