require "../spec_helper"

private alias F = Gori::Fuzz

# A response that took `us` microseconds. `fuzz_spec.cr`'s own `ok_result` pins 1234µs,
# which is the whole reason this file has its own: a TIME dimension needs to move it.
private def timed_result(status : Int32, body : String, us : Int64) : Gori::Repeater::Result
  head = "HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(head)
  Gori::Repeater::Result.new(head, body.to_slice, resp, us)
end

# The shape `Repeater::Engine` now builds when the origin went silent and the read timed out
# (`timed_out: true`), as opposed to any other failed send.
private def timeout_result(us : Int64) : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.new(0), nil, nil, us, "Read timed out", timed_out: true)
end

private def dead_result(us : Int64) : Gori::Repeater::Result
  Gori::Repeater::Result.new(Bytes.new(0), nil, nil, us, "connect failed: h:80")
end

private def job : F::Job
  F::Job.new(0_i64, ["x"], nil, "".to_slice)
end

# One calibration sample with the metrics a body of `len` bytes / `words` words / `lines`
# lines would produce, tagged with the payload length that produced it.
private def sample(len : Int64, words : Int32, lines : Int32, payload_len : Int32,
                   status : Int32 = 200) : F::BaselineSample
  F::BaselineSample.new(F::Metrics.new(status, len, words, lines, 0_i64), payload_len)
end

describe "Fuzz::Matcher time dimension" do
  it "matches and filters on the ROUND TRIP in milliseconds — the one dimension a time-based " \
     "blind payload moves (status, size, words and body are identical whether the sleep fired)" do
    m = F::Matcher.new
    m.match_time = ">=5000"
    # The same 200 with the same body twice; only the clock differs.
    m.build(job, timed_result(200, "ok", 40_000_i64)).matched?.should be_false    # 40ms
    m.build(job, timed_result(200, "ok", 5_100_000_i64)).matched?.should be_true  # 5.1s
    m.build(job, timed_result(200, "ok", 4_999_000_i64)).matched?.should be_false # 4.999s

    f = F::Matcher.new
    f.filter_time = ">=5000"
    f.build(job, timed_result(200, "ok", 5_100_000_i64)).matched?.should be_false
    f.build(job, timed_result(200, "ok", 40_000_i64)).matched?.should be_true
  end

  it "truncates to whole milliseconds rather than rounding, so a threshold is a threshold" do
    m = F::Matcher.new
    m.match_time = ">=5"
    m.build(job, timed_result(200, "ok", 4_999_i64)).matched?.should be_false # 4.999ms
    m.build(job, timed_result(200, "ok", 5_000_i64)).matched?.should be_true
  end

  it "counts a TIMED-OUT send as a time match — the loudest form of the same signal, and the " \
     "one a payload that WORKED produces (it was discarded as an error, so `--mt` reported " \
     "exactly the sleeps that did nothing)" do
    m = F::Matcher.new
    m.match_time = ">=5000"
    r = m.build(job, timeout_result(10_000_000_i64)) # timed out after 10s
    r.matched?.should be_true
    r.timed_out?.should be_true

    # …and only a TIMEOUT. A dead target is not a slow response.
    m.build(job, dead_result(10_000_000_i64)).matched?.should be_false
  end

  it "leaves every run without a time matcher exactly as it was: a timeout is not a result" do
    plain = F::Matcher.new
    plain.build(job, timeout_result(10_000_000_i64)).matched?.should be_false
    # A filter-only time spec does not resurrect it either — `filter_time` REMOVES rows.
    only_filter = F::Matcher.new
    only_filter.filter_time = ">=1"
    only_filter.build(job, timeout_result(10_000_000_i64)).matched?.should be_false
  end

  it "a timeout still has to satisfy the OTHER dimensions, which it cannot — 'slow AND 200' " \
     "is not answered by a response that never came" do
    m = F::Matcher.new
    m.match_time = ">=5000"
    m.match_status = "200"
    m.build(job, timeout_result(10_000_000_i64)).matched?.should be_false
  end

  it "counts as a constraint, so a race run's nudge and every other `constrained?` reader " \
     "sees a --mt-only run as constrained" do
    F::Matcher.new.constrained?.should be_false
    m = F::Matcher.new
    m.match_time = ">=5000"
    m.constrained?.should be_true
    f = F::Matcher.new
    f.filter_time = ">=5000"
    f.constrained?.should be_true
  end

  it "treats a blank spec as absent, like every other dimension" do
    m = F::Matcher.new
    m.match_time = ""
    m.constrained?.should be_false
    m.build(job, timed_result(200, "ok", 1_i64)).matched?.should be_true
  end
end

describe "Fuzz::Matcher.tolerance" do
  it "is 0 for a single sample and for samples that did not move — so a stable target's " \
     "calibration is the exact comparison it always was" do
    F::Matcher.tolerance([100_i64], 16_i64).should eq(0_i64)
    F::Matcher.tolerance([100_i64, 100_i64, 100_i64], 16_i64).should eq(0_i64)
  end

  it "is the observed spread while that spread is small — gori can only ever suppress what " \
     "the target's own noise could have produced" do
    F::Matcher.tolerance([1000_i64, 1006_i64, 1003_i64], 16_i64).should eq(6_i64)
  end

  it "is CAPPED once the spread stops looking like jitter, so a rotating baseline's shapes " \
     "stay separate instead of merging into one blanket" do
    # 100..250 spans 150; 2% of 250 is 5, so the floor (16) decides.
    F::Matcher.tolerance([100_i64, 250_i64], 16_i64).should eq(16_i64)
    # A big body scales: 2% of 100_000 is 2000, which beats the floor.
    F::Matcher.tolerance([98_000_i64, 100_000_i64], 16_i64).should eq(2000_i64)
  end
end

describe "Fuzz::Matcher auto-calibration bands" do
  it "suppresses a target whose response length JITTERS per request (an embedded request id / " \
     "timestamp / CSRF token) — the continuous case no finite exact-length sample set can " \
     "cover, where --ac used to suppress nothing and report every row as a hit" do
    m = F::Matcher.new(auto_calibrate: true)
    # Six samples of the same page, each carrying a differently-sized nonce: 1 word, 0 lines
    # every time, length wandering over 9 bytes.
    m.baseline = [
      sample(1000_i64, 1, 0, 6), sample(1004_i64, 1, 0, 11), sample(1002_i64, 1, 0, 16),
      sample(1009_i64, 1, 0, 21), sample(1001_i64, 1, 0, 26), sample(1006_i64, 1, 0, 31),
    ]
    m.reflects_length?.should be_false # the wander does not track payload length
    m.len_tol.should eq(9_i64)

    # A length NEVER sampled, inside the target's demonstrated wander — noise.
    m.build(job, timed_result(200, "a" * 1005, 1000_i64)).matched?.should be_false
    m.build(job, timed_result(200, "a" * 1008, 1000_i64)).matched?.should be_false
    # Just outside it — reported.
    m.build(job, timed_result(200, "a" * 1020, 1000_i64)).matched?.should be_true
    # And a status flip is never suppressed, at any width.
    m.build(job, timed_result(500, "a" * 1005, 1000_i64)).matched?.should be_true
  end

  it "keeps a ROTATING baseline's shapes separate: an anomaly whose length falls BETWEEN two " \
     "sampled shapes still flags (the cap is what stops the band from swallowing it)" do
    m = F::Matcher.new(auto_calibrate: true)
    m.baseline = [sample(100_i64, 1, 0, 6), sample(250_i64, 1, 0, 11)]
    m.len_tol.should eq(16_i64) # capped, NOT the 150-byte spread
    m.build(job, timed_result(200, "a" * 100, 1000_i64)).matched?.should be_false
    m.build(job, timed_result(200, "a" * 250, 1000_i64)).matched?.should be_false
    m.build(job, timed_result(200, "a" * 175, 1000_i64)).matched?.should be_true # between them
    m.build(job, timed_result(200, "a" * 400, 1000_i64)).matched?.should be_true
  end

  it "is byte-identical to exact matching on a stable target — a one-byte difference from the " \
     "single sampled shape is still reported" do
    m = F::Matcher.new(auto_calibrate: true)
    m.baseline = [sample(100_i64, 1, 0, 6), sample(100_i64, 1, 0, 11)]
    m.len_tol.should eq(0_i64)
    m.build(job, timed_result(200, "a" * 100, 1000_i64)).matched?.should be_false
    m.build(job, timed_result(200, "a" * 101, 1000_i64)).matched?.should be_true
  end

  it "widens the word/line comparison by the same demonstrated jitter on a length-REFLECTING " \
     "target, where length is already out of the comparison" do
    m = F::Matcher.new(auto_calibrate: true)
    # Length tracks payload length exactly (reflection), and the page's word count wanders by
    # one — a reflected nonce that sometimes lands beside whitespace.
    m.baseline = [
      F::BaselineSample.new(F::Metrics.new(200, 106_i64, 10, 1, 0_i64), 6),
      F::BaselineSample.new(F::Metrics.new(200, 111_i64, 11, 1, 0_i64), 11),
      F::BaselineSample.new(F::Metrics.new(200, 116_i64, 10, 1, 0_i64), 16),
    ]
    m.reflects_length?.should be_true
    m.word_tol.should eq(1_i64)
    # 10 words / 1 line, at a length no sample could have covered — still noise.
    m.build(job, timed_result(200, ("aa " * 10) + "\n", 1000_i64)).matched?.should be_false
    # A genuinely different shape is not.
    m.build(job, timed_result(200, ("aa " * 40) + "\n", 1000_i64)).matched?.should be_true
  end
end
