require "../spec_helper"

# The out-of-band (OAST) blind OS command-injection rule: `CmdInjectionOast` plants a shell-
# breakout payload, `OutOfBand.sweep` promotes it when the target's shell calls back. Both halves
# are driven here without a socket or a live interaction server — a deterministic minter stands
# in for a registered provider (same harness as oast_bridge_spec.cr).

# A minter that hands out a fixed token so the plant/promote round trip is reproducible. The
# payload embeds the token as a host label the way a real provider's does (interactsh / BOAST).
private class FakeMinter < Gori::Probe::OutOfBand::Minter
  getter minted = 0

  def initialize(@token : String = "abc123deadbeef", @session_id : Int64 = 7_i64)
  end

  def mint : {String, String, Int64}?
    @minted += 1
    {"#{@token}.oast.example", @token, @session_id}
  end
end

# URL-minting provider (webhook.site / postbin / custom-http): the unique nonce lives in the
# path, so `nslookup <payload>` cannot uniquely confirm — the plant must fetch the URL.
private class FakeUrlMinter < Gori::Probe::OutOfBand::Minter
  def initialize(@token : String = "whnonce12ab", @session_id : Int64 = 7_i64)
  end

  def mint : {String, String, Int64}?
    {"https://webhook.site/11111111-2222-3333-4444-555555555555/#{@token}", @token, @session_id}
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
  path = File.tempname("gori-cmdi", ".db")
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

private def cmdi_flow(store, target : String, method = "GET") : Gori::Store::FlowDetail
  head = "#{method} #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n"
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice,
    body: "ok".to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

private def land_dns_callback(store, session_id : Int64, token : String, source : String = "9.9.9.9")
  store.insert_oast_callback(session_id, "uid-#{token}", "dns", nil, source,
    "#{token}.oast.example", "".to_slice, nil, 2_000_i64)
end

describe Gori::Probe::Active::CmdInjectionOast do
  rule = Gori::Probe::Active::CmdInjectionOast.new

  it "plans NOTHING without an OAST minter (the capability gate)" do
    oob_store do |store|
      detail = cmdi_flow(store, "/ping?host=8.8.8.8")
      rule.plan(detail).should be_nil
      rule.dedup_key(detail).should be_nil
    end
  end

  it "plans a probe for a command/diagnostic parameter when a minter is present" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      detail = cmdi_flow(store, "/ping?host=8.8.8.8")
      plan = rule.plan(detail, opts).not_nil!
      plan.oob.size.should eq(1)
      cand = plan.oob.first
      cand.token.should eq("abc123deadbeef")
      cand.code.should eq("cmd_injection_oast")
      cand.session_id.should eq(7_i64)
      cand.severity.should eq(Gori::Store::Severity::Critical)
      # the payload host must ride in the rewritten request line, alongside the original value
      wire = String.new(plan.request)
      wire.should contain("abc123deadbeef")
      wire.should contain("8.8.8.8")        # original value preserved as prefix
      wire.should contain("nslookup")       # DNS-capable providers (percent-encoded space)
      wire.should contain("%3Bnslookup%20") # ';nslookup ' encoded (space_to_plus:false)
      # host-shaped payload is also fetched as http:// so an HTTP callback proves it too
      wire.should contain("curl")
      wire.should contain("%22http%3A%2F%2Fabc123deadbeef.oast.example%22")
      # dedup_key must match the plan's, and be non-nil in exactly this case (equivalence)
      rule.dedup_key(detail, opts).should eq(plan.dedup_key)
    end
  end

  it "plants a curl of the URL for a URL-minting provider, not nslookup of the URL" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeUrlMinter.new)
      plan = rule.plan(cmdi_flow(store, "/ping?host=8.8.8.8"), opts).not_nil!
      wire = String.new(plan.request)
      cand = plan.oob.first
      cand.token.should eq("whnonce12ab")
      wire.should contain("whnonce12ab")
      wire.should contain("curl")
      # the unique nonce rides in the path — curl must fetch the full URL, quoted
      wire.should contain("%22https%3A%2F%2Fwebhook.site%2F11111111-2222-3333-4444-555555555555%2Fwhnonce12ab%22")
      # nslookup of the apex cannot carry the path nonce; must not nslookup the URL itself
      wire.should contain("nslookup%20webhook.site")
      wire.should_not contain("nslookup%20https")
    end
  end

  it "probes only the FIRST command-shaped parameter per flow" do
    oob_store do |store|
      minter = FakeMinter.new
      opts = Gori::Probe::Active::Options.new(oob: minter)
      # both `host` and `cmd` qualify; only one payload is minted
      plan = rule.plan(cmdi_flow(store, "/x?page=2&host=a.test&cmd=ls"), opts).not_nil!
      plan.oob.size.should eq(1)
      plan.params.first.name.should eq("host")
      minter.minted.should eq(1)
    end
  end

  it "does not probe a parameter with an ordinary (non-command) name" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      rule.plan(cmdi_flow(store, "/s?q=hello&name=John"), opts).should be_nil
    end
  end

  it "declines a command-named parameter with an empty value" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      rule.plan(cmdi_flow(store, "/s?cmd="), opts).should be_nil
    end
  end

  it "does not probe an unsafe method by default, but does under allow_unsafe" do
    oob_store do |store|
      minter = FakeMinter.new
      rule.plan(cmdi_flow(store, "/run?cmd=id", method: "POST"),
        Gori::Probe::Active::Options.new(oob: minter)).should be_nil
      rule.plan(cmdi_flow(store, "/run?cmd=id", method: "POST"),
        Gori::Probe::Active::Options.new(oob: minter, allow_unsafe: true)).should_not be_nil
    end
  end

  it "confirms nothing on the sending socket (blind by construction)" do
    oob_store do |store|
      opts = Gori::Probe::Active::Options.new(oob: FakeMinter.new)
      detail = cmdi_flow(store, "/ping?host=8.8.8.8")
      plan = rule.plan(detail, opts).not_nil!
      result = Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
      rule.detections(plan, result, detail).should be_empty
    end
  end

  it "records a candidate through Active.analyze only after the probe is sent" do
    oob_store do |store|
      detail = cmdi_flow(store, "/ping?host=8.8.8.8")
      backend = OkBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
      collector = OobCollector.new
      Gori::Probe::Active.analyze(detail, outbound: Gori::Outbound.waived(nil, Gori::Outbound::Reason::Operator), overrides: nil,
        backend: backend, opts: Gori::Probe::Active::Options.new(oob: FakeMinter.new),
        on_oob: ->(rid : String, c : Gori::Probe::OutOfBand::Candidate) { collector.call(rid, c); nil })
      collector.seen.map(&.first).should contain("cmd_injection_oast")
    end
  end

  it "promotes to a Critical Detection when the shell's DNS callback lands" do
    oob_store do |store|
      store.insert_probe_oast_probe("tok-cmdi", "tok-cmdi.oast.example", 7_i64, "cmd_injection_oast",
        "cmd_injection_oast", Gori::Probe::Category::ACTIVE,
        "Blind OS command injection (server executed an injected command)",
        Gori::Store::Severity::Critical, "acme.test", "https://acme.test/ping", "param `host`", 42_i64)
      land_dns_callback(store, 7_i64, "tok-cmdi")

      dets, watermark = Gori::Probe::OutOfBand.sweep(store, 0_i64)
      dets.size.should eq(1)
      dets.first.code.should eq("cmd_injection_oast")
      dets.first.severity.should eq(Gori::Store::Severity::Critical)
      dets.first.flow_id.should eq(42_i64)
      dets.first.evidence.not_nil!.should contain("DNS callback")
      watermark.should be > 0_i64
    end
  end
end
