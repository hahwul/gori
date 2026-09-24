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
  CD.classify(AZ::Target.new(7_i64, "GET", "https://acme.test/account", [authed, anon]))
end

describe "gori run cache-deception — output" do
  it "renders the text report with the verdict, both trials and the cache signal" do
    text = Gori::CLI::Run.cache_deception_text_for_spec(cached_report)
    text.should contain("[cached]")
    text.should contain("GET https://acme.test/account")
    text.should contain("authenticated:")
    text.should contain("anonymous:")
    text.should contain("cache: hit")
  end

  it "renders the json report a script can read" do
    json = JSON.parse(Gori::CLI::Run.cache_deception_json_for_spec(cached_report))
    json["flow_id"].as_i.should eq(7)
    json["verdict"].as_s.should eq("cached")
    json["deception"].as_bool.should be_true
    json["cache"].as_s.should eq("hit")
    json["anonymous"]["verdict"].as_s.should eq("same")
    json["authenticated"]["status"].as_i.should eq(200)
  end
end
