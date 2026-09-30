require "../../spec_helper"
require "../../support/probe_harness"

private def analyze_head(store, head : String)
  probe_analyze(store, resp_head: head, content_type: "text/plain", body: "hello", scheme: "http")
end

describe Gori::Probe::Passive::BareLfResponse do
  it "flags a response head that a bare LF ends" do
    with_store do |store|
      dets = analyze_head(store, "HTTP/1.1 200 OK\nContent-Type: text/plain\n\n")
      det = dets.find { |d| d.code == "bare_lf_response" }.should_not be_nil
      det.severity.should eq(Gori::Store::Severity::Low)
      det.evidence.not_nil!.should contain("bare-LF blank line")
    end
  end

  it "flags a bare LF inside a CRLF-terminated head too" do
    with_store do |store|
      dets = analyze_head(store, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\nX-A: 1\r\n\r\n")
      det = dets.find { |d| d.code == "bare_lf_response" }.should_not be_nil
      det.evidence.not_nil!.should contain("inside a CRLF-terminated head")
    end
  end

  it "stays quiet on an ordinary CRLF head" do
    with_store do |store|
      probe_codes_of(analyze_head(store, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"))
        .should_not contain("bare_lf_response")
    end
  end

  it "is registered, documented, and mapped to a CWE" do
    Gori::Probe::Passive::RULES.map(&.info.id).should contain("bare_lf_response")
    Gori::Probe.remediation("bare_lf_response").should_not be_empty
    Gori::Probe.cwe_id("bare_lf_response").should eq("CWE-444")
  end
end
