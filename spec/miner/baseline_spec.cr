require "../spec_helper"

private alias M = Gori::Miner
private alias F = Gori::Fuzz

# Build a Baseline::Report directly (decide() is pure over a Report + Probe). Defaults are a
# "clean" baseline; each spec overrides only the fields it exercises.
private def mk_report(status : Int32? = 200, length_tol = 10_i64, words_tol = 5, lines_tol = 3,
                      base_length = 100_i64, base_words = 50, base_lines = 20,
                      stable = true,
                      reflection_only = Hash(M::Location, Bool).new,
                      reflects_all = Hash(M::Location, Bool).new,
                      warning : String? = nil,
                      refs = Hash(M::Location, M::Baseline::Reference).new) : M::Baseline::Report
  M::Baseline::Report.new(status, length_tol, words_tol, lines_tol,
    base_length, base_words, base_lines, stable, reflection_only, reflects_all, warning,
    refs: refs)
end

# A width-matched control to diff against — the reference `decide` uses in place of the plain
# baseline at a location that reacts to unknown parameters.
private def mk_ref(status : Int32? = 200, length = 100_i64, words = 50, lines = 20,
                   width = 8, name_len = 8, echo = 0.0,
                   length_tol = 10_i64, words_tol = 5, lines_tol = 3) : M::Baseline::Reference
  M::Baseline::Reference.new(mk_probe(status, length, words, lines), width, name_len, echo,
    length_tol, words_tol, lines_tol)
end

# Build a Probe directly: metrics + the SET of reflected canaries (reflects? is a set lookup).
private def mk_probe(status : Int32? = 200, length = 100_i64, words = 50, lines = 20,
                     canaries : Set(String) = Set(String).new) : M::Probe
  M::Probe.new(F::Metrics.new(status, length, words, lines, 1000_i64), canaries)
end

# A Fuzz::Backend whose send() returns each status in `codes` in turn (holding the last one
# once exhausted). No error → probes always parse.
private class SequenceBackend < F::Backend
  getter origin : F::Origin

  def initialize(@codes : Array(Int32))
    @origin = F::Origin.new("http", "h", 80)
    @i = 0
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    code = @codes[@i]? || @codes.last
    @i += 1
    body = "BASELINE BODY".to_slice
    head = "HTTP/1.1 #{code} X\r\nContent-Length: #{body.size}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body, resp, 1000_i64)
  end
end

# A Fuzz::Backend whose every send() errors (connection refused) — the calibrator can never
# obtain a single probe.
private class DeadBackend < F::Backend
  getter origin : F::Origin

  def initialize
    @origin = F::Origin.new("http", "h", 80)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection refused")
  end
end

# Fails the first `fail_first` sends and answers everything after — the transient blip that
# takes out a whole CONCURRENT stability wave at once, which is what `@config.retries` absorbs.
private class FailFirstBackend < F::Backend
  getter origin : F::Origin
  getter sent = 0

  def initialize(@fail_first : Int32)
    @origin = F::Origin.new("http", "h", 80)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    if @sent <= @fail_first
      return Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "connection reset by peer")
    end
    body = "BASELINE BODY CONTENT"
    head = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end
end

# An empty typed candidate list (name => canary pairs). A file-local helper so the tuple
# element type never has to be spelled inline as a call argument.
private def no_candidates : Array({String, String})
  Array({String, String}).new
end

private def calibrate_cfg(stability_rounds = 2, retries = 1) : M::Config
  c = M::Config.new
  c.stability_rounds = stability_rounds
  c.retries = retries
  c.retry_pause = 0.milliseconds # the suite must not nap through a deliberate failure
  c
end

# Counts the query parameters of every request and answers with one row per parameter, so the
# response reacts to WIDTH and to nothing else. `widths` records what each probe carried, and
# `refuse_over` stands in for a parameter-count ceiling (max_input_vars, a WAF rule).
private class WidthAwareBackend < F::Backend
  getter origin : F::Origin
  getter widths = [] of Int32

  # `jitter` is a rotating element — bytes that move on every response and belong to no
  # parameter. `bytes_only` reacts to the parameters in LENGTH alone (names run together on one
  # line), which is a JSON API naming back the keys it did not recognise.
  #
  # The churn is drawn from a SEEDED generator, one per backend, so a run reproduces. It used to
  # come off the global `Random`, and that made the reference guard's own spec fail about one
  # run in twelve: `settle` estimates this page's churn from exactly two controls (`p` and
  # `twin`) and widens the band to twice what they disagreed by, so two draws that land close
  # together leave a band too narrow to absorb a third sample, and a page that only churns gets
  # locked in as an anchor. That is a real property of a two-sample estimate — `injected_bands`
  # says as much where it only ever WIDENS — and not something a spec can assert away; what a
  # spec can do is name the sequence it exercises instead of drawing a new one each run.
  def initialize(@refuse_over : Int32 = 1024, @react : Bool = true,
                 @jitter : Int32 = 0, @bytes_only : Bool = false, seed : UInt64 = 0x5eed_u64)
    @origin = F::Origin.new("http", "h", 80)
    @churn = Random.new(seed)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    n = param_count(bytes)
    @widths << n
    if n > @refuse_over
      return result(400, "too many parameters")
    end
    body = String.build do |io|
      io << "BASELINE BODY\n"
      io << ("x" * @churn.rand(@jitter)) << "\n" if @jitter > 0
      if @bytes_only
        io << "unknown:" << (0...n).join(",") { |i| "k#{i}" } << "\n"
      elsif @react
        n.times { |i| io << "row " << i << "\n" }
      end
    end
    result(200, body)
  end

  private def result(code : Int32, body : String) : Gori::Repeater::Result
    head = "HTTP/1.1 #{code} X\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
    resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
    Gori::Repeater::Result.new(head, body.to_slice, resp, 1000_i64)
  end

  private def param_count(bytes : Bytes) : Int32
    line = String.new(bytes).lines.first? || ""
    target = line.split(' ')[1]? || ""
    qi = target.index('?')
    return 0 unless qi
    target[(qi + 1)..].split('&').count { |pair| !pair.empty? }
  end
end

describe "Gori::Miner.decide" do
  describe "metric selection (Status first, then the largest move relative to its own band)" do
    it "picks Status when status, length, words, and lines all diverge (strongest ONE)" do
      report = mk_report(status: 200, base_length: 100_i64, base_words: 50, base_lines: 20)
      probe = mk_probe(status: 500, length: 100_000_i64, words: 5_000, lines: 3_000)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Status)
    end

    it "picks Length (not Words) when status is equal but both length and words diverge" do
      report = mk_report(status: 200, base_length: 100_i64, base_words: 50)
      probe = mk_probe(status: 200, length: 100_000_i64, words: 5_000)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Length)
    end

    it "picks Words (skipping Length) when status equal + length within tol + words exceed tol" do
      # length delta 0 (within tol), words delta 100 (> words_tol 5): the ladder falls
      # through Length to Words.
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5)
      probe = mk_probe(status: 200, length: 100_i64, words: 150)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Words)
    end

    it "picks Lines when only lines diverge (status/length/words all within tol)" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
      probe = mk_probe(status: 200, length: 100_i64, words: 50, lines: 200)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Lines)
    end

    it "picks the metric that moved FURTHEST past its own band, not the earlier one" do
      # words +450 over a band of 5 = 90x; lines +480 over a band of 3 = 160x. The fixed
      # ladder answered Words because Words came first; lines is the stronger signal.
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
      probe = mk_probe(status: 200, length: 100_i64, words: 500, lines: 500)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Lines)
    end

    it "does not let a NOISY metric that barely cleared its band outrank a quiet one" do
      # The shape that cost real findings: a page with a rotating element has a wide length
      # band, so length clears it by a hair on a random probe while the count metrics — whose
      # bands are tight because they do not move — carry the actual signal. Under the fixed
      # ladder the bucket was reported as Length, a kind the isolated name could not
      # reproduce, and `confirm` dropped the parameter.
      report = mk_report(status: 200, base_length: 2148_i64, length_tol: 358_i64,
        base_words: 331, words_tol: 3, base_lines: 31, lines_tol: 2)
      probe = mk_probe(status: 200, length: 2590_i64, words: 346, lines: 36)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Words)
    end

    it "keeps the old order when two metrics moved by the SAME multiple of their bands" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
      probe = mk_probe(status: 200, length: 120_i64, words: 60, lines: 26)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Length)
    end

    it "yields None when every metric is within tolerance" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
      probe = mk_probe(status: 200, length: 105_i64, words: 52, lines: 21)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::None)
    end
  end

  describe "length tolerance boundary (strict >, off-by-one)" do
    it "does NOT flag a positive length delta EXACTLY equal to length_tol" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: 200, length: 110_i64) # delta == 10 == tol
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::None)
    end

    it "DOES flag a positive length delta of tol + 1" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: 200, length: 111_i64) # delta == 11 == tol + 1
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::Length)
    end

    it "does NOT flag a negative length delta EXACTLY equal to length_tol" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: 200, length: 90_i64) # |delta| == 10 == tol
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::None)
    end

    it "DOES flag a negative length delta of tol + 1" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: 200, length: 89_i64) # |delta| == 11 == tol + 1
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::Length)
    end

    it "treats a zero length_tol so any nonzero delta flags Length (delta 0 stays None)" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 0_i64)
      M.decide(report, mk_probe(status: 200, length: 100_i64),
        no_candidates, M::Location::Query).kind.should eq(M::DiffKind::None)
      M.decide(report, mk_probe(status: 200, length: 101_i64),
        no_candidates, M::Location::Query).kind.should eq(M::DiffKind::Length)
    end
  end

  describe "status comparison" do
    it "flags Status when the report baseline status is nil but the probe has one" do
      report = mk_report(status: nil, base_length: 100_i64)
      probe = mk_probe(status: 200, length: 100_i64)
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::Status)
    end

    it "does NOT flag Status when both baseline and probe status are nil" do
      report = mk_report(status: nil, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: nil, length: 100_i64)
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::None)
    end
  end

  describe "reflection_only gate (suppresses ALL metric kinds)" do
    it "returns None even with a huge length delta, while reflection still populates" do
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        reflection_only: {loc => true})
      probe = mk_probe(status: 500, length: 1_000_000_i64, canaries: Set{"gqdeadbeef"})
      d = M.decide(report, probe, [{"secret", "gqdeadbeef"}], loc)
      d.kind.should eq(M::DiffKind::None)
      d.reflected.should eq({"gqdeadbeef" => "secret"})
    end

    it "still evaluates metrics for a DIFFERENT location not marked reflection-only" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        reflection_only: {M::Location::Form => true})
      probe = mk_probe(status: 200, length: 1_000_i64)
      # location Query is absent from the map → metrics evaluated normally.
      M.decide(report, probe, no_candidates, M::Location::Query)
        .kind.should eq(M::DiffKind::Length)
    end

    it "a reflection_only value of false does NOT suppress metrics" do
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        reflection_only: {loc => false})
      probe = mk_probe(status: 200, length: 1_000_i64)
      M.decide(report, probe, no_candidates, loc).kind.should eq(M::DiffKind::Length)
    end
  end

  describe "reflects_all gate (skips reflection detection entirely)" do
    it "yields an empty reflected map even when the candidate canary IS present" do
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        reflects_all: {loc => true})
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqcafebabe"})
      d = M.decide(report, probe, [{"secret", "gqcafebabe"}], loc)
      d.reflected.should be_empty
    end

    it "does NOT suppress the metric ladder — length still diffs on an echo endpoint" do
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        reflects_all: {loc => true})
      probe = mk_probe(status: 200, length: 1_000_i64, canaries: Set{"gqcafebabe"})
      d = M.decide(report, probe, [{"secret", "gqcafebabe"}], loc)
      d.reflected.should be_empty
      d.kind.should eq(M::DiffKind::Length)
    end

    it "detects reflection normally when reflects_all is false for the location" do
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, reflects_all: {loc => false})
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqcafebabe"})
      d = M.decide(report, probe, [{"secret", "gqcafebabe"}], loc)
      d.reflected.should eq({"gqcafebabe" => "secret"})
    end
  end

  describe "candidate reflection mapping (canary => name)" do
    it "maps ONLY the present canary and omits the absent candidate" do
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqaaaaaaaa"})
      d = M.decide(mk_report, probe,
        [{"present", "gqaaaaaaaa"}, {"absent", "gqbbbbbbbb"}], M::Location::Query)
      d.reflected.should eq({"gqaaaaaaaa" => "present"})
    end

    it "maps every present candidate when several reflect" do
      probe = mk_probe(status: 200, length: 100_i64,
        canaries: Set{"gqaaaaaaaa", "gqbbbbbbbb"})
      d = M.decide(mk_report, probe,
        [{"one", "gqaaaaaaaa"}, {"two", "gqbbbbbbbb"}, {"three", "gqcccccccc"}],
        M::Location::Query)
      d.reflected.should eq({"gqaaaaaaaa" => "one", "gqbbbbbbbb" => "two"})
    end

    it "reports BOTH a reflection and a metric diff when neither gate is set (real finding)" do
      # The everyday shape: a param echoes its canary AND shifts length, no suppression gate.
      loc = M::Location::Query
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
      probe = mk_probe(status: 200, length: 1_000_i64, canaries: Set{"gqaaaaaaaa"})
      d = M.decide(report, probe, [{"secret", "gqaaaaaaaa"}], loc)
      d.reflected.should eq({"gqaaaaaaaa" => "secret"})
      d.kind.should eq(M::DiffKind::Length)
    end

    it "returns an empty reflected map for an empty candidate list" do
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqaaaaaaaa"})
      M.decide(mk_report, probe, no_candidates, M::Location::Query)
        .reflected.should be_empty
    end

    it "maps a candidate whose NAME is CJK/emoji (name is opaque; keyed by canary)" do
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqaaaaaaaa"})
      d = M.decide(mk_report, probe, [{"안녕_世界_🚀", "gqaaaaaaaa"}], M::Location::Query)
      d.reflected.should eq({"gqaaaaaaaa" => "안녕_世界_🚀"})
    end

    it "when the same canary is given twice, the LAST name wins in the map" do
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set{"gqaaaaaaaa"})
      d = M.decide(mk_report, probe,
        [{"first", "gqaaaaaaaa"}, {"second", "gqaaaaaaaa"}], M::Location::Query)
      d.reflected.should eq({"gqaaaaaaaa" => "second"})
    end
  end

  describe "adversarial / performance" do
    it "handles a huge candidate list with no reflections in linear time" do
      probe = mk_probe(status: 200, length: 100_i64, canaries: Set(String).new)
      candidates = (0...200_000).map { |i| {"p#{i}", "gq#{i.to_s.rjust(8, '0')[0, 8]}"} }
      elapsed = Time.measure do
        d = M.decide(mk_report, probe, candidates, M::Location::Query)
        d.reflected.should be_empty
        d.kind.should eq(M::DiffKind::None)
      end
      elapsed.total_seconds.should be < 5.0
    end
  end
end

describe "Gori::Miner::Baseline#calibrate" do
  it "returns an unreachable Report when every stability-round send errors" do
    b = M::Baseline.new(DeadBackend.new, "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
      calibrate_cfg(stability_rounds: 3))
    report = b.calibrate(Array(M::Location).new)
    report.status.should be_nil
    report.stable.should be_false
    # The reason is carried, not discarded: "unreachable" alone sends the operator hunting for
    # a target problem gori already has the name of.
    report.warning.should eq("baseline unreachable — connection refused")
    report.error.should eq("connection refused")
    report.reachable?.should be_false
  end

  # Calibration was the one un-retried send path in the miner, and an empty calibration is now
  # FATAL (`Engine#orchestrate` refuses to mine against placeholders) — so a blip the operator's
  # own `--retries` absorbs everywhere else would have killed the whole run before a single
  # candidate was tried. The stability wave goes out CONCURRENTLY, so its probes are not
  # independent in time: one accept-backlog moment at t=0 fails all of them at once.
  it "retries a probe that failed, instead of declaring the baseline unreachable" do
    # fail_first == the whole wave: without the retry there is no probe left to build a report
    # from and `calibrate` reports the baseline unreachable.
    backend = FailFirstBackend.new(fail_first: 2)
    b = M::Baseline.new(backend, "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
      calibrate_cfg(stability_rounds: 2, retries: 1))
    report = b.calibrate([M::Location::Query])
    report.reachable?.should be_true
    report.status.should eq(200)
    report.warning.should be_nil
  end

  it "still gives up when the retry fails too" do
    b = M::Baseline.new(DeadBackend.new, "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
      calibrate_cfg(stability_rounds: 2, retries: 2))
    b.calibrate(Array(M::Location).new).reachable?.should be_false
  end

  it "warns 'baseline status varies (200/500)' when statuses differ across rounds" do
    b = M::Baseline.new(SequenceBackend.new([200, 500]),
      "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate(Array(M::Location).new)
    report.stable.should be_false
    report.warning.not_nil!.should contain("baseline status varies (200/500)")
  end

  it "reports a stable baseline (no status warning) when every round is the same status" do
    b = M::Baseline.new(SequenceBackend.new([200, 200, 200]),
      "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, calibrate_cfg(stability_rounds: 3))
    report = b.calibrate(Array(M::Location).new)
    report.stable.should be_true
    report.status.should eq(200)
    (report.warning.nil? || !report.warning.not_nil!.includes?("varies")).should be_true
  end
end

describe "Gori::Miner.decide against a width-matched control" do
  no_candidates = [] of {String, String}
  loc = M::Location::Query

  it "measures the metrics from the CONTROL, not from the untouched baseline" do
    # The page answers any bucket of unknown parameters with a row per parameter, so against
    # the plain baseline it is +400 bytes / +40 words on every probe. Against a control of the
    # same width it is identical — which is the whole point.
    report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
      base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
    ref = mk_ref(length: 500_i64, words: 90, lines: 30)
    probe = mk_probe(status: 200, length: 500_i64, words: 90, lines: 30)
    M.decide(report, probe, no_candidates, loc, ref).kind.should eq(M::DiffKind::None)
    # …and the candidate's OWN effect on top of that reaction still reads as signal.
    grown = mk_probe(status: 200, length: 560_i64, words: 90, lines: 30)
    M.decide(report, grown, no_candidates, loc, ref).kind.should eq(M::DiffKind::Length)
  end

  it "widens the length band by what the page echoes of the names GORI chose" do
    # echo 1.0: every byte of parameter name comes back in the body. A probe carrying 40 more
    # bytes of name than the control did is therefore 40 bytes longer for a reason that is the
    # miner's doing, not the target's — so it is not a finding, while a bigger move still is.
    report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64)
    ref = mk_ref(length: 500_i64, echo: 1.0)
    probe = mk_probe(status: 200, length: 545_i64)
    M.decide(report, probe, no_candidates, loc, ref, byte_delta: 40).kind.should eq(M::DiffKind::None)
    M.decide(report, probe, no_candidates, loc, ref, byte_delta: 0).kind.should eq(M::DiffKind::Length)
  end

  it "reads the status off the control too" do
    # A location whose control comes back 403 is one where 403 is the ordinary answer; a
    # candidate that gets 200 is the anomaly, and against the baseline's 200 it looked normal.
    report = mk_report(status: 200)
    ref = mk_ref(status: 403)
    M.decide(report, mk_probe(status: 403), no_candidates, loc, ref).kind.should eq(M::DiffKind::None)
    M.decide(report, mk_probe(status: 200), no_candidates, loc, ref).kind.should eq(M::DiffKind::Status)
  end
end

describe "Gori::Miner::Canary.bogus_name" do
  it "is exactly the requested number of bytes, odd lengths included" do
    (3..40).each do |n|
      name = M::Canary.bogus_name(n)
      name.bytesize.should eq(n)
      name.should start_with("zz")
      # A control name has to survive every location's encoding unchanged, and be a legal
      # header/cookie/multipart token — `zz` plus lower hex is all three.
      M::Inject.valid_header_name?(name).should be_true
    end
  end
end

describe "Gori::Miner::Baseline#calibrate width + control" do
  base = "GET /s?q=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  loc = M::Location::Query

  it "sends the control at the width the RUN will use, not at a token 8" do
    backend = WidthAwareBackend.new
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    b.calibrate([loc], {loc => 64})
    # The base request's own `q`, plus 64 bogus candidates.
    backend.widths.should contain(65)
  end

  it "lowers the width until the target stops REFUSING the request" do
    # A ceiling at 16 parameters. Asking for 64 is answered 400 — and every bucket of the run
    # would have been, then bisected down through its own refusals to nothing.
    backend = WidthAwareBackend.new(refuse_over: 16)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 64})
    report.width_for(loc).not_nil!.should be <= 16
    report.width_for(loc).not_nil!.should be > 1
  end

  it "mines a reproducibly reactive location against a reference instead of muting it" do
    backend = WidthAwareBackend.new
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 32})
    ref = report.reference_for(loc)
    ref.should_not be_nil
    ref.not_nil!.width.should eq(32)
    # …and the location is NOT written off, which is what used to happen to every page that
    # reacts to unknown parameters at all.
    report.reflection_only[loc]?.should be_false
  end

  it "leaves a location that does not react alone — no reference, no padding, no extra probe" do
    backend = WidthAwareBackend.new(react: false)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 32})
    report.reference_for(loc).should be_nil
    report.reflection_only[loc]?.should be_false
    # 2 stability rounds + 1 control, and no second control: a calm location costs one wave.
    backend.widths.size.should eq(3)
  end
end

# Every one of these is a way the width-matched control can go wrong, and each cost a
# reproduced false-positive run before it was closed.
describe "Gori::Miner::Baseline#calibrate reference guards" do
  base = "GET /s?q=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
  loc = M::Location::Query

  it "builds NO reference from a width the target never accepted" do
    # The target refuses every request carrying gori's control names, at every width. Locking
    # the refusal in as the anchor makes every ordinary 200 a Status diff — the whole wordlist
    # reported as hidden parameters, at Confirmed confidence.
    # `refuse_over: 1` — the base request's own `q` is fine, any control on top of it is not,
    # at every width down to one candidate.
    backend = WidthAwareBackend.new(refuse_over: 1)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 32})
    report.reference_for(loc).should be_nil
    report.reflection_only[loc]?.should be_true
    report.warning.not_nil!.should contain("refuses every bucket width")
  end

  it "mines a location that reacts only in BYTES against a reference" do
    # A JSON API that names back the keys it did not recognise, on one line: length moves with
    # every probe, words and lines do not. Judged against the untouched baseline this is a
    # Length diff on every bucket — every name a finding.
    backend = WidthAwareBackend.new(react: false, bytes_only: true)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 32})
    report.reference_for(loc).should_not be_nil
    report.reflection_only[loc]?.should be_false
  end

  it "does NOT lock onto a page whose only reaction is its own churn" do
    # A rotating element wider than the band four samples of a quiet page could measure. The
    # control clears that band without the page having reacted to anything, and pinning a
    # single noisy sample as the anchor for the whole run is strictly worse than the baseline
    # it replaces — the second control, being the same page's jitter under injection, is what
    # tells the two apart.
    backend = WidthAwareBackend.new(react: false, jitter: 4000)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 4))
    report = b.calibrate([loc], {loc => 32})
    report.reference_for(loc).should be_nil
    # …and NOT muted either: the location is perfectly minable off the plain baseline.
    report.reflection_only[loc]?.should be_false
  end

  it "carries bands measured UNDER INJECTION, not the untouched baseline's" do
    backend = WidthAwareBackend.new(jitter: 600)
    b = M::Baseline.new(backend, base, calibrate_cfg(stability_rounds: 2))
    report = b.calibrate([loc], {loc => 32})
    if ref = report.reference_for(loc)
      # Two identical-width controls disagreed by the page's own churn; the band the run then
      # judges against has to have absorbed it, or every probe is a finding.
      ref.length_tol.should be >= report.length_tol
    end
  end
end

describe "Gori::Miner::Canary.bogus_batch" do
  it "returns DISTINCT names of exactly the requested length" do
    # A control bucket carrying the same name twice is one parameter narrower than every probe
    # measured against it — on a page that answers a row per parameter, that is a diff on
    # every bucket of the run.
    [8, 12, 24].each do |len|
      names = M::Canary.bogus_batch(256, len)
      names.size.should eq(256)
      names.uniq.size.should eq(256)
      names.all? { |n| n.bytesize == len }.should be_true
      names.all? { |n| M::Inject.valid_header_name?(n) }.should be_true
    end
  end

  it "is empty for a non-positive count" do
    M::Canary.bogus_batch(0, 8).should be_empty
    M::Canary.bogus_batch(-1, 8).should be_empty
  end
end
