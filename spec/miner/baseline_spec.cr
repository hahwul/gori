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
                      warning : String? = nil) : M::Baseline::Report
  M::Baseline::Report.new(status, length_tol, words_tol, lines_tol,
    base_length, base_words, base_lines, stable, reflection_only, reflects_all, warning)
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

# An empty typed candidate list (name => canary pairs). A file-local helper so the tuple
# element type never has to be spelled inline as a call argument.
private def no_candidates : Array({String, String})
  Array({String, String}).new
end

private def calibrate_cfg(stability_rounds = 2) : M::Config
  c = M::Config.new
  c.stability_rounds = stability_rounds
  c
end

describe "Gori::Miner.decide" do
  describe "metric precedence ladder (Status > Length > Words > Lines)" do
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

    it "picks Words over Lines when both exceed but length/status are within tol" do
      report = mk_report(status: 200, base_length: 100_i64, length_tol: 10_i64,
        base_words: 50, words_tol: 5, base_lines: 20, lines_tol: 3)
      probe = mk_probe(status: 200, length: 100_i64, words: 500, lines: 500)
      d = M.decide(report, probe, no_candidates, M::Location::Query)
      d.kind.should eq(M::DiffKind::Words)
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
    report.warning.should eq("baseline unreachable")
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
