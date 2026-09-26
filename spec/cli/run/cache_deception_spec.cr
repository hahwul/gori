require "../../spec_helper"

# `gori run cache-deception` — the CLI adapter over `Gori::CacheDeception`. The engine and its
# verdict are pinned in spec/cache_deception_spec.cr; here it is only the adapter's OUTPUT, the
# text/json shapes an operator or a script reads.
private alias CD = Gori::CacheDeception
private alias AZ = Gori::Authorize

private def cd_trial(name : String, baseline : Bool, status : Int32,
                     verdict : AZ::Verdict, cache_lines : Array(String) = [] of String) : AZ::Trial
  head = ("HTTP/1.1 #{status} OK\r\n" + cache_lines.map { |l| "#{l}\r\n" }.join + "\r\n").to_slice
  meta = Gori::Repeater::ExchangeMeta.of(status, 40_i64, 1_000_i64, nil)
  summary = AZ::ResponseSummary.new(status, 40_i64, 0_u64)
  AZ::Trial.new(name, baseline, meta, verdict, baseline ? nil : "Δ", summary,
    "req".to_slice, head, "body".to_slice)
end

private def cached_report : CD::Report
  authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
  anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT", "Age: 30"])
  control = cd_trial("anonymous-cache-busted", false, 404, AZ::Verdict::Different)
  CD.classify(AZ::Target.new(7_i64, "GET", "https://acme.test/account", [authed, anon]), control)
end

private def control_cache_hit_review_report : CD::Report
  authed = cd_trial("as-captured", true, 200, AZ::Verdict::Baseline)
  anon = cd_trial("anonymous", false, 200, AZ::Verdict::Same, ["X-Cache: HIT"])
  control = cd_trial("anonymous-cache-busted", false, 200, AZ::Verdict::Same, ["X-Cache: HIT"])
  CD.classify(AZ::Target.new(8_i64, "GET", "https://acme.test/account", [authed, anon]), control)
end

private class CliCacheBackend < Gori::Fuzz::Backend
  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    head = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".to_slice
    Gori::Repeater::Result.new(head, "page".to_slice, nil, 1_000_i64)
  end
end

private def cli_cd_flow(store : Gori::Store, host : String, head : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/account", http_version: "HTTP/1.1",
    head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

describe "gori run cache-deception — per-flow failures" do
  it "reports a flow that raises before any send and keeps checking the rest" do
    with_store do |store|
      first = cli_cd_flow(store, "ok.test", "GET /account HTTP/1.1\r\nHost: ok.test\r\n\r\n")
      broken = cli_cd_flow(store, "boom.test", "GET /account HTTP/1.1\r\nHost: boom.test\r\n\r\n")
      pseudo = cli_cd_flow(store, "ok.test", ":method: GET\r\n:path: /account\r\n\r\n")
      last = cli_cd_flow(store, "ok.test", "GET /account HTTP/1.1\r\nHost: ok.test\r\n\r\n")
      store.flush
      engine = AZ::Engine.new(->(origin : Gori::Fuzz::Origin, _http2 : Bool) {
        raise Gori::Error.new("backend unavailable") if origin.host == "boom.test"
        CliCacheBackend.new(origin).as(Gori::Fuzz::Backend)
      })

      reports, checked, sent, failed = Gori::CLI::Run.check_cache_deception_flows_for_spec(
        store, engine, ungated_outbound, [first, broken, pseudo, last])

      reports.map(&.flow_id).should eq([first, last])
      checked.should eq(2)
      sent.should eq(4)
      failed.should eq(1) # the pseudo-header head is a skip, not a failure
    end
  end
end

describe "gori run cache-deception — output" do
  it "renders the text report with the verdict, three trials and the cache signal" do
    text = Gori::CLI::Run.cache_deception_text_for_spec(cached_report)
    text.should contain("[cached]")
    text.should contain("GET https://acme.test/account")
    text.should contain("authenticated:")
    text.should contain("anonymous:")
    text.should contain("cache-busted:")
    text.should contain("cache: hit")
    text.should contain("anonymous cache: hit")
    text.should contain("cache: none")
  end

  it "renders the json report a script can read" do
    json = JSON.parse(Gori::CLI::Run.cache_deception_json_for_spec(cached_report))
    json["flow_id"].as_i.should eq(7)
    json["verdict"].as_s.should eq("cached")
    json["deception"].as_bool.should be_true
    json["cache"].as_s.should eq("hit")
    json["anonymous"]["verdict"].as_s.should eq("same")
    json["authenticated"]["status"].as_i.should eq(200)
    json["cache_busted"]["cache"].as_s.should eq("none")
  end

  it "reports the query-busted control cache hit alongside an inconclusive verdict" do
    report = control_cache_hit_review_report
    text = Gori::CLI::Run.cache_deception_text_for_spec(report)
    text.should contain("[review]")
    text.should contain("cache-busted: 200 40b, cache: hit")

    json = JSON.parse(Gori::CLI::Run.cache_deception_json_for_spec(report))
    json["verdict"].as_s.should eq("review")
    json["deception"].as_bool.should be_false
    json["anonymous"]["cache"].as_s.should eq("hit")
    json["cache_busted"]["cache"].as_s.should eq("hit")
  end

  it "fails a run that checked no flows and uses Outbound's scope remedy" do
    source = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "cache_deception.cr"))
    source.should contain("if checked == 0")
    source.should contain("if sent == 0")
    source.should contain("Outbound.remedy(verdict, \"--allow-unscoped\")")
    source.should_not contain("pass --allow-unscoped to check it")
  end
end
