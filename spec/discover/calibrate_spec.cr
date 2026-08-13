require "../spec_helper"

private alias C = Gori::Discover::Calibrate

private def fetched(status : Int32?, len : Int32, sh : UInt64 = 0_u64,
                    loc : String? = nil, ct : String? = "text/html", err : String? = nil) : C::Fetched
  C::Fetched.new(status, len.to_i64, ct, sh, loc, err)
end

describe Gori::Discover::Calibrate do
  it "classifies a clean 404 directory as Normal and flags a divergent status as a hit" do
    base = C.build("http://h/", [fetched(404, 20), fetched(404, 22)], 3)
    base.kind.should eq(C::BaselineKind::Normal)
    hit, conf = C.hit?(base, fetched(200, 500))
    hit.should be_true
    conf.should be > 0.4
  end

  it "classifies 200-everything as WildcardOk and rejects a same-length same-fingerprint probe" do
    fp = Gori::Discover::Fingerprint.simhash("the soft 404 body that comes back for everything".to_slice)
    base = C.build("http://h/", [fetched(200, 100, fp), fetched(200, 101, fp)], 3)
    base.kind.should eq(C::BaselineKind::WildcardOk)
    C.hit?(base, fetched(200, 100, fp))[0].should be_false
  end

  it "classifies 302-to-one-place as WildcardRedirect and only keeps a probe that diverges" do
    base = C.build("http://h/", [fetched(302, 0, loc: "/login"), fetched(302, 0, loc: "/login")], 3)
    base.kind.should eq(C::BaselineKind::WildcardRedirect)
    C.hit?(base, fetched(302, 0, loc: "/login"))[0].should be_false
    C.hit?(base, fetched(200, 300))[0].should be_true
  end

  # The soft-404 FN this exists to close: on a 200-everything origin, a real page that shares
  # the error page's template differs in CONTENT but lands inside the proportional length band
  # (`delta = max(16, max // 20)` — 5% of the page). The old `fp_novel && length_div`
  # conjunction dropped it no matter how different the content was.
  describe "WildcardOk that does not echo the path" do
    soft = Gori::Discover::Fingerprint.simhash("the soft 404 body that comes back for everything".to_slice)
    real = Gori::Discover::Fingerprint.simhash("a completely different real page about accounts".to_slice)
    base = C.build("http://h/", [fetched(200, 1000, soft), fetched(200, 1000, soft)], 3)

    it "reports a content-divergent page that sits INSIDE the length band" do
      base.kind.should eq(C::BaselineKind::WildcardOk)
      base.echoes.should be_false
      hit, conf = C.hit?(base, fetched(200, 1010, real)) # 10 bytes, band is +/-50
      hit.should be_true
      # Content alone, at the weight `status_div` carries — status says nothing on a
      # 200-everything origin. Above the default 0.5 floor with margin, deliberately: the old
      # 0.85 penalty was reverse-engineered to land a two-signal hit at exactly 0.51.
      conf.should be_close(0.55, 0.001)
    end

    it "scores content plus length higher than content alone" do
      C.hit?(base, fetched(200, 5000, real))[1].should be_close(0.80, 0.001)
    end

    it "still rejects a probe whose content is inside the baseline cluster" do
      C.hit?(base, fetched(200, 5000, soft))[0].should be_false
    end
  end

  # The other half, and the reason the relaxation above had to be conditional: an origin that
  # QUOTES the requested path back gives every distinct wordlist entry a distinct fingerprint,
  # so `fp_novel` alone would fire for all ~315 of them. Measured against such an origin before
  # this flag existed: 15,013 findings in one directory.
  describe "WildcardOk that echoes the path" do
    soft = Gori::Discover::Fingerprint.simhash("nothing found at that path on this server".to_slice)
    echoed = Gori::Discover::Fingerprint.simhash("nothing found at swagger v1 json on this server".to_slice)
    base = C.build("http://h/", [fetched(200, 1000, soft), fetched(200, 1000, soft)], 3, echoes: true)

    it "requires length to corroborate content, so a bare echo is not a finding" do
      base.kind.should eq(C::BaselineKind::WildcardOk)
      base.echoes.should be_true
      C.hit?(base, fetched(200, 1010, echoed))[0].should be_false
    end

    it "still reports a page that diverges in length as well" do
      hit, conf = C.hit?(base, fetched(200, 5000, echoed))
      hit.should be_true
      conf.should be_close(0.60, 0.001)
    end

    it "names the echo in the label, since two wildcard-200 dirs behave nothing alike" do
      base.label.should eq("wildcard-200 (echoes path)")
      C.build("http://h/", [fetched(200, 1000, soft), fetched(200, 1000, soft)], 3)
        .label.should eq("wildcard-200")
    end
  end

  # The same storm as the `echoes` case above, arriving by the other door: `calibrate_probes`
  # is 3, and two of them flaking (a timeout, a reset) used to leave ONE response deciding the
  # kind — `cohesive?` and `uniform_redirect` are both unanimous with a single sample, so a
  # lone 200 was promoted to WildcardOk and every wordlist entry against a dynamic miss page
  # came back a finding at 0.55, over the default 0.5 floor. An errored probe shrinks the
  # sample; it must not shorten the calibration.
  describe "a directory where only ONE calibration probe came back" do
    soft = Gori::Discover::Fingerprint.simhash("the soft 404 body that comes back for everything".to_slice)
    real = Gori::Discover::Fingerprint.simhash("a completely different real page about accounts".to_slice)

    it "is Uncalibratable rather than WildcardOk, and reports nothing on a 200-everything dir" do
      base = C.build("http://h/",
        [fetched(200, 1000, soft), fetched(nil, 0, err: "timeout"), fetched(nil, 0, err: "reset")], 3)
      base.kind.should eq(C::BaselineKind::Uncalibratable)
      # Content divergence is all a 200-everything origin can offer, and on one sample it is
      # not evidence — `Uncalibratable` trusts status only, so this whole sweep stays quiet.
      C.hit?(base, fetched(200, 1010, real))[0].should be_false
    end

    it "is Uncalibratable rather than WildcardRedirect, and claims no funnel target" do
      base = C.build("http://h/",
        [fetched(302, 0, loc: "/login"), fetched(nil, 0, err: "timeout"), fetched(nil, 0, err: "reset")], 3)
      base.kind.should eq(C::BaselineKind::Uncalibratable)
      base.redirect_target.should be_nil # one probe is unanimous with itself; that is not a funnel
    end

    it "still calibrates normally once two probes survive (the control)" do
      base = C.build("http://h/",
        [fetched(200, 1000, soft), fetched(200, 1000, soft), fetched(nil, 0, err: "reset")], 3)
      base.kind.should eq(C::BaselineKind::WildcardOk)
      C.hit?(base, fetched(200, 1010, real))[0].should be_true
    end
  end

  it "is uncalibratable when every bogus probe errored, and never fabricates a hit from no signal" do
    base = C.build("http://h/", [fetched(nil, 0, err: "connect failed")], 3)
    base.kind.should eq(C::BaselineKind::Uncalibratable)
    base.statuses.empty?.should be_true
    # With no baseline signal, a real response must NOT be reported as a hit (Bug C).
    C.hit?(base, fetched(200, 500))[0].should be_false
  end
end
