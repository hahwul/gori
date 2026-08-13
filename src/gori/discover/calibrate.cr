require "./fingerprint"

module Gori::Discover
  # Per-directory soft-404 auto-calibration — the FP-critical core of the brute-forcer.
  # Before probing a directory, K guaranteed-nonexistent paths establish a DirBaseline; a
  # wordlist probe is a "hit" ONLY if it diverges from that baseline. Handles servers that
  # 200-everything (catch-all), 302-everything-to-/login (login funnel), and noisy pages.
  module Calibrate
    enum BaselineKind
      Normal           # 404s the way you'd hope
      WildcardOk       # 200-everything — status useless, must diverge on CONTENT
      WildcardRedirect # 302-everything to one place (e.g. /login) — must escape the funnel
      Uncalibratable   # inconsistent / unreachable — trust status only, penalize confidence

      def label : String
        case self
        in Normal           then "normal"
        in WildcardOk       then "wildcard-200"
        in WildcardRedirect then "wildcard-redirect"
        in Uncalibratable   then "uncalibratable"
        end
      end
    end

    # The distilled response a worker computes (so the orchestrator never re-decodes a body).
    record Fetched,
      status : Int32?,
      length : Int64,
      content_type : String?,
      simhash : UInt64,
      redirect_to : String?,
      error : String?

    record DirBaseline,
      dir : String,
      statuses : Set(Int32),
      length_lo : Int64,
      length_hi : Int64,
      fingerprints : Array(UInt64),
      redirect_target : String?,
      kind : BaselineKind,
      distance : Int32,
      # Does the miss page REFLECT the requested path back into its body? Measured by
      # `Engine#process_calibrate`, which is the only place that still holds a bogus probe's
      # BODY and its NAME at the same time, and passed in — `Fetched` deliberately carries no
      # body, so this cannot be re-derived here.
      #
      # It is the one property that decides whether `fp_novel` carries information on a
      # wildcard-200 baseline, so it rides with the kind rather than being asked per probe.
      echoes : Bool = false

    # The kind as an operator reads it, plus the measured property that changes how a hit on
    # it is judged. `Engine#handle_calibrate` reports THIS, not `kind.label`: two directories
    # both labelled `wildcard-200` behave completely differently under the same wordlist, and
    # the operator has no other way to see which one they got.
    struct DirBaseline
      def label : String
        echoes ? "#{kind.label} (echoes path)" : kind.label
      end
    end

    # Build a baseline from K bogus-path responses. The length band is proportional (a big
    # page churns more), the fingerprint set absorbs dynamic bits, and the kind classifies
    # the server's 404 behavior.
    def self.build(dir : String, bogus : Array(Fetched), distance : Int32,
                   echoes : Bool = false) : DirBaseline
      ok = bogus.select { |f| f.error.nil? }
      if ok.empty?
        return DirBaseline.new(dir, Set(Int32).new, 0_i64, 0_i64, [] of UInt64, nil,
          BaselineKind::Uncalibratable, distance)
      end
      lengths = ok.map(&.length)
      delta = {16_i64, lengths.max // 20}.max
      lo = lengths.min - delta
      hi = lengths.max + delta
      statuses = ok.compact_map(&.status).to_set
      fps = ok.map(&.simhash)
      rt = uniform_redirect(ok)
      # ORDER IS LOAD-BEARING: the sample-size floor is tested FIRST, ahead of both elevated
      # kinds. Each of them relaxes `hit?` on the strength of AGREEMENT between the bogus
      # probes — `WildcardRedirect` trusts one funnel target and scores `redir_div`,
      # `WildcardOk` earns the raised `fp_weight` — yet `ok` is only what survived
      # `f.error.nil?`, and both tests pass trivially on a single sample (`cohesive?` returns
      # true below 2 fingerprints, `uniform_redirect` finds one target unanimous). So two
      # probes flaking on an ordinary timeout or reset left ONE response awarding a weight
      # that the cohesion it names was never measured for, and against a dynamic miss page
      # that turned every wordlist entry into a 0.55 finding — the storm the `echoes` flag
      # exists to stop, arriving by the other door. `Uncalibratable` reports nothing there,
      # which is what its enum comment already promises for a baseline this thin.
      kind =
        if ok.size < 2
          BaselineKind::Uncalibratable
        elsif rt
          BaselineKind::WildcardRedirect
        elsif statuses == Set{200} && cohesive?(fps, distance)
          BaselineKind::WildcardOk
        else
          BaselineKind::Normal
        end
      DirBaseline.new(dir, statuses, lo, hi, fps, rt, kind, distance, echoes)
    end

    # {hit?, confidence 0..1}. Divergence must hold vs the baseline, evaluated per kind.
    def self.hit?(b : DirBaseline, p : Fetched) : {Bool, Float64}
      return {false, 0.0} unless p.error.nil?
      # An empty baseline status set means calibration got NO signal (every bogus probe
      # errored) — treat status as non-divergent so an Uncalibratable dir never fabricates a
      # hit for the whole wordlist. Real baselines always carry ≥1 status.
      status_div = (s = p.status) && !b.statuses.empty? ? !b.statuses.includes?(s) : false
      length_div = p.length < b.length_lo || p.length > b.length_hi
      fp_novel = b.fingerprints.all? { |f| Fingerprint.hamming(p.simhash, f) > b.distance }
      redir_div = (rt = b.redirect_target) ? normalize_redirect(p.redirect_to) != rt : false

      hit =
        case b.kind
        in BaselineKind::WildcardRedirect then p.redirect_to.nil? || redir_div # escaped the funnel
        # Content is the only axis left on a 200-everything origin — UNLESS the origin
        # quotes the path back, in which case content divergence is the echo and not the
        # endpoint, and length has to corroborate it (see `echoes`).
        in BaselineKind::WildcardOk     then b.echoes ? (fp_novel && length_div) : fp_novel
        in BaselineKind::Uncalibratable then status_div # only trust status
        in BaselineKind::Normal         then status_div || (length_div && fp_novel)
        end

      # `fp_novel` earns the weight `status_div` carries on a wildcard-200 baseline that does
      # NOT echo, and stays a corroborating signal everywhere else. The asymmetry is the kind's
      # whole meaning: `WildcardOk` is assigned only when the bogus probes came back 200 AND
      # proved COHESIVE with each other (`build`, which tests its sample-size floor ahead of
      # the kind, so this weight can never rest on a cohesion test that short-circuited on a
      # single surviving probe), a stricter calibration than `Normal` is ever held to —
      # `Normal` needs two non-erroring probes and no cohesion at all — so on that baseline
      # "outside the cluster" is a calibrated verdict rather than a hint, and status has
      # nothing left to say. On an ECHOING one the cluster proves nothing, so the weight and
      # the conjunction both revert.
      fp_weight = b.kind.wildcard_ok? && !b.echoes ? 0.55 : 0.35

      conf = 0.0
      conf += 0.50 if status_div
      conf += 0.25 if length_div
      conf += fp_weight if fp_novel
      conf += 0.30 if redir_div
      penalty =
        case b.kind
        in BaselineKind::Normal           then 1.0
        in BaselineKind::WildcardRedirect then 0.8
          # 1.0, and it moves together with the conjunction now being CONDITIONAL above.
          #
          # Unconditionally, the conjunction scored the same doubt twice on a non-echoing
          # origin: it required a real page to differ from the soft-404 in LENGTH as well as in
          # content, and the band is proportional — `delta = max(16, max // 20)`, i.e. 5% of
          # the page. A real page sharing the error page's template (the same header, sidebar
          # and footer, which is what a CMS or SPA soft-404 always is) lands inside that 5% and
          # was dropped no matter how different its content was: measured, `/soft/admin` at
          # 524 B against a 545 B soft-404 sat inside a [518, 572] band and was never reported.
          #
          # The old 0.85 was itself reverse-engineered from the conjunction (0.35 + 0.25 = 0.60
          # → 0.51, just over the default floor), so keeping it would put a content-only hit at
          # 0.47 and change nothing. A cohesive baseline is not a less trustworthy one, so the
          # penalty goes and the evidence carries its own weight: on a non-echoing origin
          # content alone scores 0.55 and content plus length 0.80, on an echoing one both are
          # required and score 0.60. An operator who wants only the strongest raises
          # `confidence_floor` — which is what that knob is for.
        in BaselineKind::WildcardOk     then 1.0
        in BaselineKind::Uncalibratable then 0.6
        end
      {hit, (conf * penalty).clamp(0.0, 1.0)}
    end

    # All bogus probes redirected to ONE normalized target ⇒ a login/funnel wildcard. "All"
    # means at least two: one probe is unanimous with itself, and `build` stores this as the
    # baseline's `redirect_target`, where `hit?` scores every non-matching Location at +0.30.
    # `build` already routes a single-sample baseline to `Uncalibratable`; this keeps the
    # field it carries from claiming a funnel the probes never agreed on.
    private def self.uniform_redirect(fetched : Array(Fetched)) : String?
      redirs = fetched.compact_map { |f| f.redirect_to.try { |l| normalize_redirect(l) } }
      return nil if redirs.size < 2 || redirs.size < fetched.size
      redirs.uniq.size == 1 ? redirs.first : nil
    end

    private def self.cohesive?(fps : Array(UInt64), distance : Int32) : Bool
      return true if fps.size < 2
      first = fps.first
      fps.all? { |f| Fingerprint.hamming(f, first) <= distance }
    end

    # Normalize a Location for comparison — drop query + fragment so /login?next=a and
    # /login?next=b compare equal (the funnel target is the same).
    private def self.normalize_redirect(loc : String?) : String?
      return nil unless loc
      l = loc.strip
      return nil if l.empty?
      l = l.partition('?')[0]
      l.partition('#')[0]
    end
  end
end
