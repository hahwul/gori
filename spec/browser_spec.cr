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

    it "suppresses the bad-flags infobar and keeps traffic on the TCP proxy" do
      args.should contain("--test-type")    # suppress Chrome's spki-list infobar
      args.should contain("--disable-quic") # QUIC/UDP would bypass the CONNECT proxy
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

  # A browser is the one surface that doesn't just PRINT the bind — it dials it. Under a
  # wildcard bind the raw "0.0.0.0" was written straight into the browser's proxy config,
  # which opens a browser that proxies nothing and looks like gori is broken.
  describe "proxy address resolution" do
    wildcard = Gori::Browser::LaunchSpec.new(
      proxy_host: "0.0.0.0", proxy_port: 8070,
      ca_cert_path: "/tmp/root.crt.pem", spki_sha256: "PIN123=",
      profile_root: "/tmp/gori-browser")
    v6_wildcard = Gori::Browser::LaunchSpec.new(
      proxy_host: "::", proxy_port: 8070,
      ca_cert_path: "/tmp/root.crt.pem", spki_sha256: "PIN123=",
      profile_root: "/tmp/gori-browser")
    v6 = Gori::Browser::LaunchSpec.new(
      proxy_host: "::1", proxy_port: 8070,
      ca_cert_path: "/tmp/root.crt.pem", spki_sha256: "PIN123=",
      profile_root: "/tmp/gori-browser")

    it "points Chromium at loopback when the bind is a wildcard" do
      Gori::Browser.chromium_args("/tmp/prof", wildcard)
        .should contain("--proxy-server=http://127.0.0.1:8070")
      # Same-family loopback: a :: listener isn't reliably reachable over 127.0.0.1.
      Gori::Browser.chromium_args("/tmp/prof", v6_wildcard)
        .should contain("--proxy-server=http://[::1]:8070")
    end

    it "brackets an IPv6 proxy host in the Chromium URL" do
      # Bare interpolation yielded "http://::1:8070", which Chromium cannot parse.
      Gori::Browser.chromium_args("/tmp/prof", v6)
        .should contain("--proxy-server=http://[::1]:8070")
    end

    it "points Firefox at loopback when the bind is a wildcard" do
      js = Gori::Browser.firefox_user_js(wildcard)
      js.should contain(%(user_pref("network.proxy.http", "127.0.0.1");))
      js.should contain(%(user_pref("network.proxy.ssl", "127.0.0.1");))
      js.should_not contain("0.0.0.0")
    end

    it "writes a BARE IPv6 host to Firefox's prefs (the port is a separate pref)" do
      js = Gori::Browser.firefox_user_js(v6)
      js.should contain(%(user_pref("network.proxy.http", "::1");))
      js.should contain(%(user_pref("network.proxy.http_port", 8070);))
      js.should_not contain("[::1]")
    end

    it "exposes the resolved authority for the launch status line" do
      wildcard.dial_authority.should eq("127.0.0.1:8070")
      v6.dial_authority.should eq("[::1]:8070")
      SPEC_LAUNCH.dial_authority.should eq("127.0.0.1:8070")
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
