require "../../spec_helper"
require "../../support/probe_harness"

describe Gori::Probe::Passive::Cors do
  it "requires exactly one case-sensitive credentials value" do
    with_store do |store|
      ["TRUE", "True", "true, true", "true\r\nAccess-Control-Allow-Credentials: true"].each do |value|
        codes = probe_codes_of(probe_analyze(store,
          req_headers: "Origin: https://other.test\r\n",
          resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: https://other.test\r\nAccess-Control-Allow-Credentials: #{value}\r\n\r\n"))
        codes.should_not contain("cors_reflected_origin")
      end
    end
  end

  it "does not treat uppercase NULL as the null origin" do
    with_store do |store|
      probe_codes_of(probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: NULL\r\n\r\n")).should_not contain("cors_null_origin")
    end
  end
end
