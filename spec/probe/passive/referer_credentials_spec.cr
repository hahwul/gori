require "../../spec_helper"
require "../../support/probe_harness"

private def referer_detections(store, value : String, *, host : String = "acme.test",
                               scheme : String = "https", target : String = "/asset", extra_headers : String = "")
  detail = probe_capture_flow(store, "HTTP/1.1 200 OK\r\n\r\n", scheme: scheme, host: host,
    target: target, req_headers: "rEfErEr: #{value}\r\n#{extra_headers}")
  Gori::Probe::Passive.analyze(detail).select(&.code.==("secret_in_referer"))
end

describe Gori::Probe::Passive::RefererCredentials do
  it "reports the receiving origin and a fixed label without copying credentials or paths" do
    with_store do |store|
      detections = referer_detections(store, "https://source.test/REF_FIXTURE?Refresh%5FToken=TOKEN_FIXTURE",
        target: "https://target-in-request-line.test/TOKEN_FIXTURE?echo=TOKEN_FIXTURE",
        extra_headers: "Host: header-host.test\r\n")
      detections.size.should eq(1)
      finding = detections.first
      finding.code.should eq("secret_in_referer")
      finding.host.should eq("acme.test")
      finding.url.should eq("https://acme.test/")
      finding.evidence.should eq("Named credential parameter in Referer")
      finding.flow_id.should_not be_nil
    end
  end

  it "compares the scheme, hostname and effective port, including IPv6 spellings" do
    with_store do |store|
      referer_detections(store, "HTTPS://ACME.TEST:443/?access_token=fixture").should be_empty
      referer_detections(store, "https://%61cme.test/?access_token=fixture").should be_empty
      referer_detections(store, "https://[0:0:0:0:0:0:0:1]:443/?access_token=fixture", host: "::1").should be_empty

      referer_detections(store, "http://acme.test/?access_token=fixture").size.should eq(1)
      referer_detections(store, "https://acme.test:8443/?access_token=fixture").size.should eq(1)
      referer_detections(store, "https://login.acme.test/a,b?access_token=fixture").size.should eq(1)
      referer_detections(store, "https://source.test/?redirect_urls=https://a.test/,https://b.test/&access_token=fixture").size.should eq(1)
    end
  end

  it "recognizes known credential values under arbitrary query names" do
    with_store do |store|
      jwt = referer_detections(store, "https://source.test/?context=%65#{PROBE_JWT[1..]}").first
      jwt.evidence.should eq("JSON Web Token")
      provider_key = referer_detections(store, "https://source.test/?context=#{PROBE_AWS_KEY_ID}").first
      provider_key.evidence.should eq("AWS access key id")
    end
  end

  it "ignores empty credentials, generic query names and parameters inside another value" do
    with_store do |store|
      [
        "https://source.test/",
        "https://source.test/?access_token=&refresh_token=+%20&password",
        "https://source.test/?code=ordinary&state=active&token=cursor",
        "https://source.test/?password=false&access_token=null",
        "https://source.test/?note=ordinary;access_token=fixture",
      ].each { |value| referer_detections(store, value).should be_empty }
    end
  end

  it "requires one well-formed absolute HTTP Referer with a bounded value" do
    with_store do |store|
      [
        "//source.test/?access_token=fixture",
        "ftp://source.test/?access_token=fixture",
        "https:///missing-host?access_token=fixture",
        "https://bad host/?access_token=fixture",
        "https://bad\\host/?access_token=fixture",
        "https://[invalid]/?access_token=fixture",
        "https://[::1/?access_token=fixture",
        "https://%3A%3A1/?access_token=fixture",
        "https://%5B%3A%3A1%5D/?access_token=fixture",
        "https://source.test:65536/?access_token=fixture",
        "https://source.test:9999999999999999999999/?access_token=fixture",
        "https://source.test/?access_token=fixture#fragment",
        "https://user:pass@source.test/?access_token=fixture",
        "https://source.test/?access_token=fixture,https://other.test/",
        "https://source.test/?access_token=%GG",
        "https://source.test/?access_token=\xff",
        "https://source.test/?access_token=#{"x" * 8192}",
      ].each { |value| referer_detections(store, value).should be_empty }
      referer_detections(store, "https://source.test/?access_token=fixture",
        extra_headers: "Referer: https://other.test/\r\n").should be_empty
    end
  end
end
