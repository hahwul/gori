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

  it "is uncalibratable when every bogus probe errored, and never fabricates a hit from no signal" do
    base = C.build("http://h/", [fetched(nil, 0, err: "connect failed")], 3)
    base.kind.should eq(C::BaselineKind::Uncalibratable)
    base.statuses.empty?.should be_true
    # With no baseline signal, a real response must NOT be reported as a hit (Bug C).
    C.hit?(base, fetched(200, 500))[0].should be_false
  end
end
