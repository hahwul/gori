require "./spec_helper"
require "file_utils"

private def with_store(&)
  path = File.tempname("gori-hostov", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::HostOverrides do
  it "starts empty and resolves nothing" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.size.should eq(0)
      ov.connect_ip("example.com").should be_nil
    end
  end

  it "adds an override and resolves the host (case-insensitive) to its IP" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("Staging.ACME.test", "10.0.0.1").should be_true
      ov.size.should eq(1)
      # Host is stored lowercased; lookup is case-insensitive.
      ov.entries.first.host.should eq("staging.acme.test")
      ov.connect_ip("staging.acme.test").should eq("10.0.0.1")
      ov.connect_ip("STAGING.acme.TEST").should eq("10.0.0.1")
      ov.connect_ip("other.test").should be_nil
    end
  end

  it "rejects an invalid pair (bad IP, blank host)" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "not-an-ip").should be_false   # IP must be a literal
      ov.add("example.com", "example.org").should be_false # a hostname is not an IP
      ov.add("", "10.0.0.1").should be_false
      ov.size.should eq(0)
    end
  end

  it "rejects a duplicate host (edit it instead)" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "10.0.0.1").should be_true
      ov.add("EXAMPLE.com", "10.0.0.2").should be_false # same host, different IP
      ov.size.should eq(1)
      ov.connect_ip("example.com").should eq("10.0.0.1")
    end
  end

  it "updates an override in place (self-edit of the IP is allowed)" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "10.0.0.1").should be_true
      id = ov.entries.first.id
      ov.update(id, "example.com", "10.0.0.9").should be_true
      ov.connect_ip("example.com").should eq("10.0.0.9")
    end
  end

  it "refuses an update that collides with another host" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("a.test", "10.0.0.1").should be_true
      ov.add("b.test", "10.0.0.2").should be_true
      bid = ov.entries.find { |e| e.host == "b.test" }.not_nil!.id
      ov.update(bid, "a.test", "10.0.0.3").should be_false # would duplicate a.test
      ov.connect_ip("b.test").should eq("10.0.0.2")
    end
  end

  it "removes an override" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "10.0.0.1").should be_true
      id = ov.entries.first.id
      ov.remove(id)
      ov.size.should eq(0)
      ov.connect_ip("example.com").should be_nil
    end
  end

  it "persists across a reload (lives in the project store)" do
    with_store do |store|
      Gori::HostOverrides.load(store).add("example.com", "127.0.0.1").should be_true
      reopened = Gori::HostOverrides.load(store)
      reopened.connect_ip("example.com").should eq("127.0.0.1")
    end
  end

  describe ".valid?" do
    it "accepts an IPv4/IPv6 literal with a non-empty host" do
      Gori::HostOverrides.valid?("example.com", "10.0.0.1").should be_true
      Gori::HostOverrides.valid?("example.com", "::1").should be_true
    end

    it "rejects a non-literal IP or a blank host" do
      Gori::HostOverrides.valid?("example.com", "example.org").should be_false
      Gori::HostOverrides.valid?("", "10.0.0.1").should be_false
      Gori::HostOverrides.valid?("example.com", "").should be_false
    end

    it "rejects a host with embedded whitespace or garbage (silent dead override)" do
      Gori::HostOverrides.valid?("foo bar", "10.0.0.1").should be_false
      Gori::HostOverrides.valid?("ex ample.com", "10.0.0.1").should be_false
    end
  end

  describe ".parse_line" do
    it "parses \"IP host\" (collapses whitespace, lowercases the host)" do
      Gori::HostOverrides.parse_line("10.0.0.1 Example.COM").should eq({"example.com", "10.0.0.1"})
      Gori::HostOverrides.parse_line("10.0.0.1   api.test").should eq({"api.test", "10.0.0.1"})
    end

    it "returns nil for a missing host, a bad IP, or a host with spaces" do
      Gori::HostOverrides.parse_line("10.0.0.1").should be_nil            # no host
      Gori::HostOverrides.parse_line("notanip example.com").should be_nil # ip not a literal
      Gori::HostOverrides.parse_line("10.0.0.1 foo bar").should be_nil    # host has a space
      Gori::HostOverrides.parse_line("   ").should be_nil
    end
  end
end

describe Gori::Settings do
  describe ".host_override_ip" do
    it "resolves a global override case-insensitively, nil otherwise" do
      Gori::Settings.hostname_overrides = [{"staging.acme.test", "10.0.0.1"}]
      Gori::Settings.host_override_ip("STAGING.acme.test").should eq("10.0.0.1")
      Gori::Settings.host_override_ip("other.test").should be_nil
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
    end

    it "is nil when no global overrides are configured" do
      Gori::Settings.hostname_overrides = [] of {String, String}
      Gori::Settings.host_override_ip("example.com").should be_nil
    end
  end

  it "round-trips hostname_overrides through settings.json" do
    dir = File.tempname("gori-settings-hostov")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.hostname_overrides = [{"a.test", "10.0.0.1"}, {"b.test", "10.0.0.2"}]
      Gori::Settings.save.should be_true

      Gori::Settings.hostname_overrides = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.hostname_overrides.should eq([{"a.test", "10.0.0.1"}, {"b.test", "10.0.0.2"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.hostname_overrides = [] of {String, String}
    end
  end

  it "drops a hand-edited entry whose ip is not a literal (no DNS re-resolution)" do
    dir = File.tempname("gori-settings-hostov-badip")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      File.write(Gori::Settings.path,
        %({"hostname_overrides":[{"host":"api.test","ip":"evil.example.com"},{"host":"ok.test","ip":"10.0.0.1"}]}))
      Gori::Settings.hostname_overrides = [] of {String, String}
      Gori::Settings.load
      # The bogus "ip" (a hostname) is dropped; the literal-IP entry survives.
      Gori::Settings.hostname_overrides.should eq([{"ok.test", "10.0.0.1"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.hostname_overrides = [] of {String, String}
    end
  end

  it "omits hostname_overrides from settings.json when empty" do
    dir = File.tempname("gori-settings-hostov-empty")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.hostname_overrides = [] of {String, String}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should_not contain("hostname_overrides")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
    end
  end
end

# End-to-end proof that the override actually redirects the TCP connect target: dialing a
# host that NEVER resolves (.invalid is reserved, RFC 2606) succeeds ONLY because the
# override points it at a real local listener — the original host is never resolved.
describe Gori::Proxy::Upstream do
  it "dials the override IP for an otherwise-unresolvable host (global override)" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    begin
      Gori::Settings.hostname_overrides = [{"nonexistent.invalid", "127.0.0.1"}]
      sock = Gori::Proxy::Upstream.dial("nonexistent.invalid", port, connect_timeout: 2.seconds)
      sock.should_not be_nil      # connected — via the override IP
      server.accept?.try(&.close) # the local listener received the redirected connection
      sock.try(&.close)
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
      server.close
    end
  end

  it "does not redirect a host without an override (so the override is what connects)" do
    Gori::Settings.hostname_overrides = [] of {String, String}
    # No override → the unresolvable host is dialed as-is → connect fails (nil).
    Gori::Proxy::Upstream.dial("nonexistent.invalid", 80, connect_timeout: 1.second).should be_nil
  end
end
