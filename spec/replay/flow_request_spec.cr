require "../spec_helper"

describe Gori::Replay::FlowRequest do
  describe ".build_target / .parse_target" do
    it "omits the default port and round-trips a normal host" do
      t = Gori::Replay::FlowRequest.build_target("https", "api.test", 443)
      t.should eq("https://api.test")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"https", "api.test", 443})
    end

    it "keeps a non-default port" do
      t = Gori::Replay::FlowRequest.build_target("http", "api.test", 8080)
      t.should eq("http://api.test:8080")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"http", "api.test", 8080})
    end

    it "brackets an IPv6 literal host so it round-trips (was dropped to host=\"\")" do
      t = Gori::Replay::FlowRequest.build_target("http", "::1", 80)
      t.should eq("http://[::1]")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"http", "::1", 80})
    end

    it "brackets an IPv6 literal host with a non-default port" do
      t = Gori::Replay::FlowRequest.build_target("https", "2001:db8::1", 8443)
      t.should eq("https://[2001:db8::1]:8443")
      Gori::Replay::FlowRequest.parse_target(t).should eq({"https", "2001:db8::1", 8443})
    end
  end
end
