require "../spec_helper"

# The out-of-band (OAST) active bridge: the SsrfOast rule plants a payload, `OutOfBand.sweep`
# promotes it when the target calls back. Both halves are driven here without a socket or a live
# interaction server — a deterministic minter stands in for a registered provider.

# A minter that hands out a fixed token so the plant/promote round trip is reproducible. The
# payload embeds the token as a host label the way a real provider's does.
private class FakeMinter < Gori::Probe::OutOfBand::Minter
  getter minted = 0

  def initialize(@token : String = "abc123deadbeef", @session_id : Int64 = 7_i64)
  end

  def mint : {String, String, Int64}?
    @minted += 1
    {"#{@token}.oast.example", @token, @session_id}
  end
end

# Records what the analyzer would persist, so a bare `Active.analyze` (no store) can assert the
# candidate it planted.
private class OobCollector
  getter seen = [] of {String, Gori::Probe::OutOfBand::Candidate}

  def call(rule_id : String, c : Gori::Probe::OutOfBand::Candidate) : Nil
    @seen << {rule_id, c}
  end
end

private class OkBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin
  getter sent = 0

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent += 1
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
  end
end

private def oob_store(&)
  path = File.tempname("gori-oast", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def ssrf_flow(store, target : String, method = "GET") : Gori::Store::FlowDetail
  head = "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice,
    body: "ok".to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Simulate a provider callback landing in the store for `token`, so the sweep can match it.
private def land_callback(store, session_id : Int64, token : String, source : String = "10.1.2.3")
  store.insert_oast_callback(session_id, "uid-#{token}", "http", "GET", source,
    "#{token}.oast.example", "GET / HTTP/1.1\r\nHost: #{token}.oast.example\r\n\r\n".to_slice, nil, 2_000_i64)
end

describe Gori::Probe::Active::SsrfOast do
  rule = Gori::Probe::Active::SsrfOast.new

  it "plans NOTHING without an OAST minter (the capability gate)" do
    oob_store do |store|
      detail = ssrf_flow(store, "/fetch?url=https://good.example/x")
      rule.plan(detail).should be_nil
      rule.dedup_key(detail).should be_nil
    end
  end

  it "plans a probe for a URL-valued parameter when a minter is present" do
    oob_store do |store|
      minter = FakeMinter.new
      opts = Gori::Probe::Active::Options.new(oob: minter)
      detail = ssrf_flow(store, "/fetch?url=https://good.example/x")
      plan = rule.plan(detail, opts).not_nil!
      plan.oob.size.should eq(1)
      cand = plan.oob.first
      cand.token.should eq("abc123deadbeef")
      cand.code.should eq("ssrf_oast")
      cand.session_id.should eq(7_i64)
      # the payload host must ride in the rewritten request line
      String.new(plan.request).should contain("abc123deadbeef")
      # dedup_key must match the plan's, and be non-nil in exactly this case (equivalence)
      rule.dedup_key(detail, opts).should eq(plan.dedup_key)
    end
  end

  it "admits a bare host only under a conventional SSRF param name" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      # `q=` with a bare host is ordinary text — not probed
      rule.plan(ssrf_flow(store, "/s?q=internal.corp"), opts).should be_nil
      # `webhook=` with the same host is SSRF-shaped
      rule.plan(ssrf_flow(store, "/s?webhook=internal.corp"), opts).should_not be_nil
    end
  end

  it "admits the canonical blind-SSRF address targets under an SSRF param name" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      # cloud metadata / loopback / internal address — the whole point of an SSRF probe
      rule.plan(ssrf_flow(store, "/fetch?url=169.254.169.254"), opts).should_not be_nil
      rule.plan(ssrf_flow(store, "/fetch?url=127.0.0.1"), opts).should_not be_nil
      rule.plan(ssrf_flow(store, "/fetch?url=localhost"), opts).should_not be_nil
      # a numeric id under a URL-ish name is NOT host-shaped
      rule.plan(ssrf_flow(store, "/fetch?url=1234"), opts).should be_nil
    end
  end

  it "does not probe a non-URL parameter" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      rule.plan(ssrf_flow(store, "/s?page=2&name=John"), opts).should be_nil
    end
  end

  it "records a candidate through Active.analyze only after the probe is sent" do
    oob_store do |store|
      detail = ssrf_flow(store, "/fetch?url=https://good.example/x")
      backend = OkBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
      collector = OobCollector.new
      Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.waived(nil, Gori::Outbound::Reason::Operator),
        backend: backend, opts: Gori::Probe::Active::Options.new(oob: FakeMinter.new),
        on_oob: ->(rid : String, c : Gori::Probe::OutOfBand::Candidate) { collector.call(rid, c); nil })
      collector.seen.size.should eq(1)
      collector.seen.first[0].should eq("ssrf_oast")
    end
  end
end

describe Gori::Probe::OutOfBand do
  it "promotes an outstanding probe to a Detection when its callback lands" do
    oob_store do |store|
      store.insert_probe_oast_probe("tok-match", "tok-match.oast.example", 7_i64, "ssrf_oast",
        "ssrf_oast", Gori::Probe::Category::ACTIVE, "Blind SSRF", Gori::Store::Severity::High,
        "acme.test", "https://acme.test/fetch", "param `url`", 42_i64)
      land_callback(store, 7_i64, "tok-match")

      dets, watermark = Gori::Probe::OutOfBand.sweep(store, 0_i64)
      dets.size.should eq(1)
      dets.first.code.should eq("ssrf_oast")
      dets.first.host.should eq("acme.test")
      dets.first.flow_id.should eq(42_i64)
      dets.first.evidence.not_nil!.should contain("HTTP callback")
      watermark.should be > 0_i64

      # idempotent: a second sweep over the same callback promotes nothing (the row is claimed)
      dets2, _ = Gori::Probe::OutOfBand.sweep(store, 0_i64)
      dets2.should be_empty
      store.probe_oast_pending.should be_empty
    end
  end

  it "mints against the most-recently-polled session, not merely the newest row" do
    oob_store do |store|
      old_id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corrold", "s", nil, nil)
      new_id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corrnew", "s", nil, nil)
      # With neither session polled yet, the newest row wins (the old default).
      Gori::Probe::OutOfBand::StoreMinter.build(store).not_nil!.session_id.should eq(new_id)
      # But once the OLDER session is the one being polled (a live listener's heartbeat), the
      # minter follows it — so its payloads land where a callback will actually be read, instead
      # of against the newer row that was started and stopped.
      store.touch_oast_session(old_id)
      Gori::Probe::OutOfBand::StoreMinter.build(store).not_nil!.session_id.should eq(old_id)
    end
  end

  it "leaves an unanswered probe outstanding (no callback ⇒ no finding)" do
    oob_store do |store|
      store.insert_probe_oast_probe("tok-lonely", "tok-lonely.oast.example", 7_i64, "ssrf_oast",
        "ssrf_oast", Gori::Probe::Category::ACTIVE, "Blind SSRF", Gori::Store::Severity::High,
        "acme.test", "https://acme.test/fetch", "param `url`", 42_i64)
      dets, _ = Gori::Probe::OutOfBand.sweep(store, 0_i64)
      dets.should be_empty
      store.probe_oast_pending.size.should eq(1)
    end
  end

  it "caps outstanding (un-promoted) probes so the table cannot grow without bound" do
    oob_store do |store|
      cap = Gori::Store::PROBE_OAST_PENDING_CAP
      (cap + 25).times do |i|
        store.insert_probe_oast_probe("tok-#{i}", "p#{i}", 1_i64, "ssrf_oast", "ssrf_oast",
          Gori::Probe::Category::ACTIVE, "Blind SSRF", Gori::Store::Severity::High,
          "acme.test", "https://acme.test/", nil, nil)
      end
      pending = store.probe_oast_pending
      pending.size.should eq(cap)
      # eviction drops the OLDEST — the newest token must survive
      pending.map(&.token).should contain("tok-#{cap + 24}")
      pending.map(&.token).should_not contain("tok-0")
    end
  end

  it "matches case-insensitively (DNS 0x20 / mixed-case echo)" do
    oob_store do |store|
      store.insert_probe_oast_probe("tok-case", "tok-case.oast.example", 7_i64, "ssrf_oast",
        "ssrf_oast", Gori::Probe::Category::ACTIVE, "Blind SSRF", Gori::Store::Severity::High,
        "acme.test", "https://acme.test/fetch", nil, nil)
      store.insert_oast_callback(7_i64, "uid-x", "dns", nil, "9.9.9.9",
        "TOK-CASE.OAST.EXAMPLE", "".to_slice, nil, 2_000_i64)
      dets, _ = Gori::Probe::OutOfBand.sweep(store, 0_i64)
      dets.size.should eq(1)
    end
  end
end
