require "../../spec_helper"
require "../../support/probe_harness"

private class BodyMinter < Gori::Probe::OutOfBand::Minter
  getter minted = 0

  def mint : {String, String, Int64}?
    @minted += 1
    {"https://oast.example/callback?token=body123&source=probe", "body123", 7_i64}
  end
end

private def body_flow(store, body, content_type = "application/json", target = "/fetch", extra = "")
  probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", method: "POST", target: target,
    req_headers: "Content-Type: #{content_type}\r\n#{extra}", req_body: body)
end

describe Gori::Probe::Active::SsrfOast do
  rule = Gori::Probe::Active::SsrfOast.new

  it "probes one JSON string, preserves other values, and frames the new body" do
    with_store do |store|
      minter = BodyMinter.new
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)
      detail = body_flow(store, %({"url":"https://good.test/","webhook":"https://other.test/","count":2,"enabled":true,"nested":{"$ref":"keep"}}))
      rule.dedup_key(detail, opts).should_not be_nil
      minter.minted.should eq(0)
      plan = rule.plan(detail, opts).not_nil!
      plan.dedup_key.should eq(rule.dedup_key(detail, opts))
      plan.params.map(&.location).should eq(["json"])
      plan.params.map(&.name).should eq(["url"])
      minter.minted.should eq(1)
      plan.followups.should be_empty
      plan.pipeline.should be_empty
      plan.oob.size.should eq(1)
      head, body, _ = Gori::Miner::Inject.split(plan.request)
      parsed = JSON.parse(String.new(body))
      parsed["url"].as_s.should eq("https://oast.example/callback?token=body123&source=probe")
      parsed["webhook"].as_s.should eq("https://other.test/")
      parsed["count"].as_i.should eq(2)
      parsed["enabled"].as_bool.should be_true
      parsed["nested"]["$ref"].as_s.should eq("keep")
      String.new(head).should contain("Content-Length: #{body.size}")
      plan.oob.first.evidence.not_nil!.should contain("json param `url`")
    end
  end

  it "encodes only the selected form value and resynchronizes Content-Length" do
    with_store do |store|
      detail = body_flow(store, "keep=%ff+%2f&webhook=internal.test&flag&&other=%24TOKEN",
        "application/x-www-form-urlencoded", extra: "Content-Length: 1\r\n")
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: BodyMinter.new)
      plan = rule.plan(detail, opts).not_nil!
      head, body, _ = Gori::Miner::Inject.split(plan.request)
      String.new(body).should eq("keep=%ff+%2f&webhook=https%3A%2F%2Foast.example%2Fcallback%3Ftoken%3Dbody123%26source%3Dprobe&flag&&other=%24TOKEN")
      String.new(head).should contain("Content-Length: #{body.size}")
      plan.params.first.location.should eq("form")
      plan.dedup_key.should eq(rule.dedup_key(detail, opts))
    end
  end

  it "keeps the one-request budget when both the query and body qualify" do
    with_store do |store|
      body = %({ "url": "https://body.test/" })
      detail = body_flow(store, body, target: "https://acme.test/fetch?url=https://query.test/&keep=%FF")
      minter = BodyMinter.new
      plan = rule.plan(detail, Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)).not_nil!
      plan.params.size.should eq(1)
      plan.params.first.location.should eq("query")
      plan.followups.should be_empty
      plan.pipeline.should be_empty
      minter.minted.should eq(1)
      String.new(plan.request).should start_with("POST /fetch?")
      String.new(plan.request).should contain("&keep=%FF")
      String.new(Gori::Miner::Inject.split(plan.request)[1]).should eq(body)
    end
  end

  it "requires both the listener and unsafe method opt-in for body POSTs" do
    with_store do |store|
      detail = body_flow(store, %({"url":"https://good.test/"}))
      [Gori::Probe::Active::Options::DEFAULT,
       Gori::Probe::Active::Options.new(allow_unsafe: true),
       Gori::Probe::Active::Options.new(oob: BodyMinter.new)].each do |opts|
        rule.plan(detail, opts).should be_nil
        rule.dedup_key(detail, opts).should be_nil
      end
    end
  end

  it "declines non-string, nested, malformed and non-URL body values without minting" do
    with_store do |store|
      minter = BodyMinter.new
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: minter)
      [%({"url":123}), %({"url":"123"}), %({"q":"internal.test"}),
       %({"nested":{"url":"https://good.test/"}}), %(["https://good.test/"]), "{"].each do |body|
        detail = body_flow(store, body)
        rule.plan(detail, opts).should be_nil
        rule.dedup_key(detail, opts).should be_nil
      end
      minter.minted.should eq(0)
    end
  end

  it "accepts JSON suffix media types but skips encoded, ambiguous and oversized bodies" do
    with_store do |store|
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: BodyMinter.new)
      body = %({"url":"https://good.test/"})
      rule.plan(body_flow(store, body, "application/problem+json; charset=utf-8"), opts).should_not be_nil
      ["Content-Encoding: gzip\r\n", "Transfer-Encoding: chunked\r\n",
       "Content-Encoding: gzip\r\nContent-Encoding: identity\r\n",
       "Content-Type: text/plain\r\n", "Content-Encoding : gzip\r\n"].each do |extra|
        detail = body_flow(store, body, extra: extra)
        rule.plan(detail, opts).should be_nil
        rule.dedup_key(detail, opts).should be_nil
      end
      rule.plan(body_flow(store, body, "text/not-json"), opts).should be_nil
      rule.plan(body_flow(store, body + " " * Gori::Probe::Active::BODY_CAP), opts).should be_nil
      detail = body_flow(store, body)
      partial = Gori::Store::FlowDetail.new(detail.row, detail.http_version, detail.request_head,
        detail.request_body, detail.response_head, detail.response_body, request_body_truncated: true)
      rule.plan(partial, opts).should be_nil
    end
  end

  it "separates same-named query and body slots in the dedup key" do
    with_store do |store|
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true, oob: BodyMinter.new)
      query = body_flow(store, "{}", target: "/fetch?url=https://good.test/")
      body = body_flow(store, %({"url":"https://good.test/"}))
      rule.dedup_key(query, opts).should_not eq(rule.dedup_key(body, opts))
    end
  end
end
