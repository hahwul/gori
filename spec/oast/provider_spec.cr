require "../spec_helper"

describe Gori::Oast::Provider do
  describe ".endpoint_error" do
    it "accepts a bare host[:port] and an http(s) URL" do
      ["oast.pro", "oast.internal:8443", "https://oast.internal", "http://127.0.0.1:18731/x",
       "https://odiss.eu:2096/events"].each do |h|
        Gori::Oast::Provider.endpoint_error(h).should be_nil
      end
    end

    it "refuses what can never be a host, naming it" do
      ["not a url", "ftp://x", "x:99999999999999999999"].each do |h|
        Gori::Oast::Provider.endpoint_error(h).not_nil!.should start_with("invalid host #{h.inspect}")
      end
    end
  end
end
