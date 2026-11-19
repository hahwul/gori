require "../../spec_helper"
require "../../support/probe_harness"

describe Gori::Probe::Passive::Secrets do
  it "recognizes classic and routable GitLab tokens and both pipeline trigger lengths" do
    with_store do |store|
      {
        {"glpat-" + "a" * 20, "GitLab token"},
        {"glpat-" + "a" * 19 + "-", "GitLab token"},
        {"glpat-" + "a" * 27 + ".0r03gxo7s", "GitLab token"},
        {"acme-glpat-" + "a" * 300 + ".01.0r03gxo7s", "GitLab token"},
        {"glptt-" + "a" * 19 + "-", "GitLab pipeline trigger token"},
        {"glptt-" + "a" * 40, "GitLab pipeline trigger token"},
      }.each do |token, label|
        findings = probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
          content_type: "application/json", body: %({"credential":"#{token}"}))
        findings.select(&.code.==("secret_in_body")).map(&.evidence).should eq([label])
      end
    end
  end

  it "rejects near misses at the GitLab token boundaries" do
    [
      "glpat-" + "a" * 20 + "-",
      "glpat-" + "a" * 26 + ".0r03gxo7s",
      "glpat-" + "a" * 301 + ".01.0r03gxo7s",
      "glpat-" + "a" * 27 + ".01.0r03gxo7ss",
      "glpat-" + "a" * 27 + ".1.0r03gxo7s",
      "glptt-" + "a" * 19,
      "glptt-" + "a" * 20 + "-",
      "glptt-" + "a" * 40 + "_",
      "pre_glptt-" + "a" * 40,
    ].each do |text|
      Gori::Probe::Passive::Secrets.patterns.none? { |pattern, _| pattern.matches?(text) }.should be_true
    end
  end

  it "reports the GitLab credential type in WebSocket payloads" do
    with_store do |store|
      detail = probe_capture_flow(store, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        target: "/ws", status: 101, content_type: nil, req_headers: "Upgrade: websocket\r\nConnection: Upgrade\r\n")
      payload = "glptt-" + "a" * 40
      messages = [Gori::Store::WsMessage.new(1_i64, detail.row.id, nil, 1_i64, "in", 1, payload.to_slice)]
      findings = Gori::Probe::Passive.analyze(detail, messages)
      findings.select(&.code.==("secret_in_ws")).map(&.evidence).should eq(["GitLab pipeline trigger token"])
    end
  end
end
