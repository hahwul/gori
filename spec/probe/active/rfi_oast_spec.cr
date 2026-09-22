require "../../spec_helper"
require "../../support/probe_harness"

private class RfiMinter < Gori::Probe::OutOfBand::Minter
  getter minted = 0

  def initialize(@payload = "https://oast.example/callback/rfi123", @token = "rfi123456", @session_id = 7_i64)
  end

  def mint : {String, String, Int64}?
    @minted += 1
    {@payload, @token, @session_id}
  end
end

private class RfiBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin = Gori::Fuzz::Origin.new("https", "acme.test", 443)
  getter sent = [] of Bytes

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes.dup
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
  end
end

private def rfi_flow(store, target = "/include?file=views/home.php&keep=1", method = "GET",
                     content_type : String? = nil, body : String? = nil, extra = "")
  probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", method: method, target: target,
    req_headers: "#{content_type ? "Content-Type: #{content_type}\r\n" : ""}#{extra}", req_body: body)
end

describe Gori::Probe::Active::RfiOast do
  rule = Gori::Probe::Active::RfiOast.new

  it "plans nothing without an OAST minter" do
    with_store do |store|
      detail = rfi_flow(store)
      rule.plan(detail).should be_nil
      rule.dedup_key(detail).should be_nil
    end
  end

  it "plants one language-marked URL for an include-shaped query parameter" do
    with_store do |store|
      minter = RfiMinter.new
      opts = Gori::Probe::Active::Options.new(oob: minter)
      detail = rfi_flow(store, "/render?file=views/home.php&lang=en")
      plan = rule.plan(detail, opts).not_nil!

      plan.params.size.should eq(1)
      plan.params.first.location.should eq("query")
      plan.params.first.name.should eq("file")
      plan.oob.size.should eq(1)
      plan.oob.first.code.should eq("rfi_oast")
      plan.oob.first.token.should eq("rfi123456")
      plan.oob.first.severity.should eq(Gori::Store::Severity::High)
      plan.dedup_key.should eq(rule.dedup_key(detail, opts))
      minter.minted.should eq(1)

      wire = String.new(plan.request)
      wire.should contain("rfi123456")
      wire.should contain("gori_rfi_file")
      wire.should contain("%253C%253Fphp")
      wire.should contain(".php") # the original value is not sent; the extension selects PHP
      plan.params.first.canary.should eq("rfi123456")
    end
  end

  it "uses JSP and ASP wrappers from language-shaped values" do
    with_store do |store|
      jsp = rule.plan(rfi_flow(store, "/view?page=home.jsp"),
        Gori::Probe::Active::Options.new(oob: RfiMinter.new)).not_nil!
      String.new(jsp.request).should contain("out.print")
      String.new(jsp.request).should contain(".jsp")

      asp = rule.plan(rfi_flow(store, "/view?template=home.aspx"),
        Gori::Probe::Active::Options.new(oob: RfiMinter.new)).not_nil!
      String.new(asp.request).should contain("Response.Write")
      String.new(asp.request).should contain(".asp")
    end
  end

  it "covers top-level JSON and form slots, preserving the other values and framing the body" do
    with_store do |store|
      json = rfi_flow(store, "/render", "POST", "application/json", %({"page":"views/home.jsp","count":2,"keep":"ok"}),
        "Content-Length: 1\r\n")
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: RfiMinter.new)
      plan = rule.plan(json, opts).not_nil!
      head, body, _ = Gori::Miner::Inject.split(plan.request)
      parsed = JSON.parse(String.new(body))
      parsed["page"].as_s.should contain("gori_rfi_file")
      parsed["count"].as_i.should eq(2)
      parsed["keep"].as_s.should eq("ok")
      String.new(head).should contain("Content-Length: #{body.size}")
      plan.params.first.location.should eq("json")

      form = rfi_flow(store, "/render", "POST", "application/x-www-form-urlencoded",
        "page=views%2Fhome.php&keep=%FF")
      form_plan = rule.plan(form, opts).not_nil!
      String.new(Gori::Miner::Inject.split(form_plan.request)[1]).should contain("keep=%FF")
      form_plan.params.first.location.should eq("form")
    end
  end

  it "selects only the first include-shaped slot and declines ordinary values" do
    with_store do |store|
      minter = RfiMinter.new
      opts = Gori::Probe::Active::Options.new(oob: minter)
      plan = rule.plan(rfi_flow(store, "/x?file=first.txt&page=second.jsp"), opts).not_nil!
      plan.params.first.name.should eq("file")
      minter.minted.should eq(1)

      ["/x?q=hello", "/x?q=123", "/x?file=123", "/x?name=42"].each do |target|
        rule.plan(rfi_flow(store, target), opts).should be_nil
        rule.dedup_key(rfi_flow(store, target), opts).should be_nil
      end
      rule.plan(rfi_flow(store, "/x?name=notes.txt"), opts).should_not be_nil
    end
  end

  it "requires unsafe opt-in for body-bearing methods and rejects ambiguous bodies" do
    with_store do |store|
      detail = rfi_flow(store, "/render", "POST", "application/json", %({"file":"home.php"}))
      minter = RfiMinter.new
      rule.plan(detail, Gori::Probe::Active::Options.new(oob: minter)).should be_nil
      rule.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)).should_not be_nil

      ["Content-Encoding: gzip\r\n", "Transfer-Encoding: chunked\r\n",
       "Content-Encoding: gzip\r\nContent-Encoding: identity\r\n", "Content-Type: text/plain\r\n"].each do |extra|
        bad = rfi_flow(store, "/render", "POST", "application/json", %({"file":"home.php"}), extra)
        rule.plan(bad, Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)).should be_nil
        rule.dedup_key(bad, Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)).should be_nil
      end
    end
  end

  it "promotes only after the OAST callback arrives" do
    with_store do |store|
      detail = rfi_flow(store)
      backend = RfiBackend.new
      disabled = Gori::Probe::Active::RULES.map(&.info.id).reject { |id| id == "rfi_oast" }.to_set
      disabled.delete("request_smuggling")
      Gori::Probe::Active.analyze(detail, outbound: ungated_outbound, overrides: nil,
        backend: backend, disabled: disabled, opts: Gori::Probe::Active::Options.new(oob: RfiMinter.new),
        on_oob: ->(rule_id : String, candidate : Gori::Probe::OutOfBand::Candidate) {
          Gori::Probe::OutOfBand.record(store, rule_id, candidate, detail.row, detail.row.id)
        })
      backend.sent.size.should eq(1)
      Gori::Probe::OutOfBand.sweep(store, 0_i64)[0].should be_empty

      store.insert_oast_callback(7_i64, "callback-rfi", "http", "GET", "192.0.2.1",
        "oast.example/callback/rfi123", "GET /?gori_rfi_marker=gori-rfi-rfi123456 HTTP/1.1".to_slice,
        nil, 2_000_i64)
      findings = Gori::Probe::OutOfBand.sweep(store, 0_i64)[0]
      findings.size.should eq(1)
      findings.first.code.should eq("rfi_oast")
      findings.first.severity.should eq(Gori::Store::Severity::High)
      findings.first.evidence.not_nil!.should contain("HTTP callback")
    end
  end
end
