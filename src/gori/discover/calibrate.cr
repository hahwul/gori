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
      distance : Int32

    # Build a baseline from K bogus-path responses. The length band is proportional (a big
    # page churns more), the fingerprint set absorbs dynamic bits, and the kind classifies
    # the server's 404 behavior.
    def self.build(dir : String, bogus : Array(Fetched), distance : Int32) : DirBaseline
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
      kind =
        if rt
          BaselineKind::WildcardRedirect
        elsif statuses == Set{200} && cohesive?(fps, distance)
          BaselineKind::WildcardOk
        elsif ok.size < 2
          BaselineKind::Uncalibratable
        else
          BaselineKind::Normal
        end
      DirBaseline.new(dir, statuses, lo, hi, fps, rt, kind, distance)
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
        in BaselineKind::WildcardOk       then fp_novel && length_div          # content must genuinely differ
        in BaselineKind::Uncalibratable   then status_div                      # only trust status
        in BaselineKind::Normal           then status_div || (length_div && fp_novel)
        end

      conf = 0.0
      conf += 0.50 if status_div
      conf += 0.25 if length_div
      conf += 0.35 if fp_novel
      conf += 0.30 if redir_div
      penalty =
        case b.kind
        in BaselineKind::Normal           then 1.0
        in BaselineKind::WildcardRedirect then 0.8
          # A WildcardOk hit is gated on fp_novel && length_div (0.35 + 0.25 = 0.60); at 0.7 the
          # product 0.42 could never clear the default 0.5 floor, so a genuinely content-divergent
          # page on a 200-everything site was never reported. 0.85 → 0.51 lets a real divergence through.
        in BaselineKind::WildcardOk     then 0.85
        in BaselineKind::Uncalibratable then 0.6
        end
      {hit, (conf * penalty).clamp(0.0, 1.0)}
    end

    # All bogus probes redirected to ONE normalized target ⇒ a login/funnel wildcard.
    private def self.uniform_redirect(fetched : Array(Fetched)) : String?
      redirs = fetched.compact_map { |f| f.redirect_to.try { |l| normalize_redirect(l) } }
      return nil if redirs.empty? || redirs.size < fetched.size
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
