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
