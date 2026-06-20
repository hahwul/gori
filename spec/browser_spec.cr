require "./spec_helper"
require "./support/fake_context"

private SPEC_LAUNCH = Gori::Browser::LaunchSpec.new(
  proxy_host: "127.0.0.1", proxy_port: 8070,
  ca_cert_path: "/tmp/root.crt.pem", spki_sha256: "PIN123=",
  profile_root: "/tmp/gori-browser")

describe Gori::Browser do
  describe ".chromium_args" do
    args = Gori::Browser.chromium_args("/tmp/prof", SPEC_LAUNCH)

    it "isolates the profile and sets the proxy" do
      args.should contain("--user-data-dir=/tmp/prof")
      args.should contain("--proxy-server=http://127.0.0.1:8070")
    end

    it "pins exactly the CA via the SPKI list (not the unsafe ignore-all flag)" do
      args.should contain("--ignore-certificate-errors-spki-list=PIN123=")
      args.includes?("--ignore-certificate-errors").should be_false
    end

    it "routes loopback targets through the proxy too" do
      args.should contain("--proxy-bypass-list=<-loopback>")
    end
  end

  describe ".firefox_args" do
    it "launches a fresh isolated profile" do
      Gori::Browser.firefox_args("/tmp/ffp").should eq(["--no-remote", "--profile", "/tmp/ffp"])
    end
  end

  describe ".firefox_user_js" do
    js = Gori::Browser.firefox_user_js(SPEC_LAUNCH)

    it "configures the manual proxy for http + https" do
      js.should contain(%(user_pref("network.proxy.type", 1);))
      js.should contain(%(user_pref("network.proxy.http", "127.0.0.1");))
      js.should contain(%(user_pref("network.proxy.http_port", 8070);))
      js.should contain(%(user_pref("network.proxy.share_proxy_settings", true);))
    end
  end

  describe ".detect" do
    it "only returns browsers of a known kind (env-dependent, may be empty)" do
      Gori::Browser.detect.each do |f|
        {Gori::Browser::Kind::Chromium, Gori::Browser::Kind::Firefox}.includes?(f.kind).should be_true
        f.path.empty?.should be_false
      end
    end
  end

  it "registers browser.open as a visible palette verb" do
    r = Gori::Verb::Registry.new
    Gori::Verbs.register_core(r)
    verb = r["browser.open"]
    verb.hidden?.should be_false
    verb.available?(FakeExecContext.new).should be_true
  end
end
