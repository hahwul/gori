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
      ov.connect_address("example.com").should be_nil
    end
  end

  it "adds an override and resolves the host (case-insensitive) to its IP" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("Staging.ACME.test", "10.0.0.1").should be_true
      ov.size.should eq(1)
      # Host is stored lowercased; lookup is case-insensitive.
      ov.entries.first.host.should eq("staging.acme.test")
      ov.connect_address("staging.acme.test").should eq("10.0.0.1")
      ov.connect_address("STAGING.acme.TEST").should eq("10.0.0.1")
      ov.connect_address("other.test").should be_nil
    end
  end

  # A trailing root dot names the SAME host: `SelfPage.magic_host?` has always chomped one,
  # so leaving the override lookup byte-exact meant the two disagreed about what a request
  # for "gori.proxy." was. Both directions have to fold — the request spelling and the
  # stored one — or an operator gets a dead entry whose only symptom is silence.
  it "folds a trailing root dot on both the stored host and the looked-up one" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("Staging.acme.test.", "10.0.0.1").should be_true
      ov.entries.first.host.should eq("staging.acme.test") # stored without the dot
      ov.connect_address("staging.acme.test").should eq("10.0.0.1")
      ov.connect_address("staging.acme.test.").should eq("10.0.0.1") # fully-qualified request
      # …and the dotted spelling is therefore the SAME entry, not a second one.
      ov.add("staging.acme.test", "10.0.0.2").should be_false
      ov.size.should eq(1)
    end
  end

  # Rows written BEFORE the key form existed still have to resolve. The store is written
  # directly here, which is the only way to produce one now that every writer folds.
  it "folds a row that predates the key form, rather than leaving it dead in the list" do
    with_store do |store|
      store.add_host_override("Legacy.test.", "10.0.0.1")
      ov = Gori::HostOverrides.load(store)
      ov.entries.first.host.should eq("legacy.test")
      ov.connect_address("legacy.test").should eq("10.0.0.1")
      ov.connect_address("legacy.test.").should eq("10.0.0.1")
      # …and `add`'s dedupe sees it, so the old row cannot be shadowed by a live duplicate.
      ov.add("legacy.test", "10.0.0.2").should be_false
      ov.size.should eq(1)
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
      ov.connect_address("example.com").should eq("10.0.0.1")
    end
  end

  it "updates an override in place (self-edit of the IP is allowed)" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "10.0.0.1").should be_true
      id = ov.entries.first.id
      ov.update(id, "example.com", "10.0.0.9").should be_true
      ov.connect_address("example.com").should eq("10.0.0.9")
    end
  end

  it "refuses an update that collides with another host" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("a.test", "10.0.0.1").should be_true
      ov.add("b.test", "10.0.0.2").should be_true
      bid = ov.entries.find { |e| e.host == "b.test" }.not_nil!.id
      ov.update(bid, "a.test", "10.0.0.3").should be_false # would duplicate a.test
      ov.connect_address("b.test").should eq("10.0.0.2")
    end
  end

  it "removes an override" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("example.com", "10.0.0.1").should be_true
      id = ov.entries.first.id
      ov.remove(id)
      ov.size.should eq(0)
      ov.connect_address("example.com").should be_nil
    end
  end

  it "persists across a reload (lives in the project store)" do
    with_store do |store|
      Gori::HostOverrides.load(store).add("example.com", "127.0.0.1").should be_true
      reopened = Gori::HostOverrides.load(store)
      reopened.connect_address("example.com").should eq("127.0.0.1")
    end
  end

  # The mutex `connect_address` takes on EVERY proxied request must never be held across a
  # store round-trip. `exec_task` parks the calling fiber on its reply channel, and with
  # `busy_timeout=5000` a peer process holding the write lock parks it for up to five
  # seconds — so `add`/`update`/`remove`/`reload` doing their store work inside that lock
  # stalled every dial in a project that has any override at all, for as long as the peer
  # held it. The writers serialise on a SECOND mutex the read path never touches.
  #
  # Pinned at source level because the failure is a stall, not a wrong answer: reproducing it
  # needs a peer process holding a SQLite write lock, and a timing assertion around that is a
  # flaky spec rather than a proof. What CAN be stated exactly is the invariant that removes
  # it — every `@mutex` critical section is one expression on one line, and none of them
  # touches the store.
  it "never holds the read-path mutex across a store round-trip" do
    src = File.read(File.join(__DIR__, "..", "src", "gori", "host_overrides.cr"))
    sections = src.lines.select(&.includes?("@mutex.synchronize"))
    sections.should_not be_empty # the guard is worthless if the mutex was renamed away

    sections.each do |line|
      # One-line brace form, so the whole critical section is visible on the line asserted.
      line.should match(/@mutex\.synchronize\s*\{[^}]*\}/)
      line.should_not contain("@store")
      line.should_not contain("load_entries")
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

    # Judged on the KEY, so the answer matches what the lookup will actually do with it: a
    # fully-qualified spelling is fine, but a host that is NOTHING but dots folds to empty
    # and is the dead override HOST_RE exists to refuse.
    it "judges the folded key, so a root dot passes and a dot-only host does not" do
      Gori::HostOverrides.valid?("example.com.", "10.0.0.1").should be_true
      Gori::HostOverrides.valid?(".", "10.0.0.1").should be_false
      Gori::HostOverrides.valid?("...", "10.0.0.1").should be_false
    end

    # The LEADING dot is the half the fold deliberately leaves alone, so HOST_RE has to be
    # the one that refuses it — `.api.test` is how a cookie domain is written, and it
    # validated, stored and rendered while matching no request Host that can exist.
    it "refuses a leading dot, but not the leading _ and - real setups use" do
      Gori::HostOverrides.valid?(".api.test", "10.0.0.1").should be_false
      Gori::HostOverrides.valid?("api.test", "10.0.0.1").should be_true
      Gori::HostOverrides.valid?("_dmarc.test", "10.0.0.1").should be_true
      Gori::HostOverrides.valid?("-odd.test", "10.0.0.1").should be_true
    end

    # The port half: an override used to be able to say WHICH MACHINE and never WHICH PORT.
    it "accepts an address that also names a port" do
      Gori::HostOverrides.valid?("api.test", "127.0.0.1:8443").should be_true
      Gori::HostOverrides.valid?("api.test", "[::1]:8443").should be_true
      Gori::HostOverrides.valid?("api.test", "127.0.0.1:0").should be_false     # 0 can never complete a dial
      Gori::HostOverrides.valid?("api.test", "127.0.0.1:99999").should be_false # out of range
    end
  end

  # The grammar both override layers share. Split out because `Settings` deliberately does not
  # depend on the proxy model, so a spelling accepted by one layer and rejected by the other
  # would be invisible from either side alone.
  describe Gori::DialAddress do
    it "reads a bare address as 'keep the request's port'" do
      a = Gori::DialAddress.parse("10.0.0.1").not_nil!
      a.ip.should eq("10.0.0.1")
      a.port.should be_nil
      b = Gori::DialAddress.parse("::1").not_nil!
      b.ip.should eq("::1")
      b.port.should be_nil
    end

    it "reads a port when one is named" do
      a = Gori::DialAddress.parse("10.0.0.1:8443").not_nil!
      a.ip.should eq("10.0.0.1")
      a.port.should eq(8443)
      b = Gori::DialAddress.parse("[::1]:8443").not_nil!
      b.ip.should eq("::1")
      b.port.should eq(8443)
    end

    # A bare IPv6 literal's own colons are not a port separator — "::1:8443" is the ADDRESS
    # 0:0:0:0:0:0:1:8443, and splitting it on the last colon would silently dial a different
    # machine. Brackets are what make a v6 port sayable.
    it "keeps a bare IPv6 literal whole rather than splitting a port off it" do
      a = Gori::DialAddress.parse("::1:8443").not_nil!
      a.ip.should eq("::1:8443")
      a.port.should be_nil
    end

    it "rejects a hostname, which TCPSocket would re-resolve" do
      Gori::DialAddress.parse("example.org").should be_nil
      Gori::DialAddress.parse("example.org:8443").should be_nil
      Gori::DialAddress.parse("").should be_nil
    end
  end

  # The KEY half of the same shared grammar, and split out for the same reason.
  describe Gori::OverrideHost do
    it "folds case and a trailing root dot, and nothing else" do
      Gori::OverrideHost.key("Example.COM").should eq("example.com")
      Gori::OverrideHost.key("example.com.").should eq("example.com")
      Gori::OverrideHost.key("  example.com.  ").should eq("example.com")
      Gori::OverrideHost.key("example.com..").should eq("example.com") # not just the last one
      Gori::OverrideHost.key(".").should eq("")
      # A LEADING dot is not a root dot and stays — it makes the host garbage, which is
      # HOST_RE's job to refuse, not this one's to quietly repair into a different name.
      Gori::OverrideHost.key(".example.com").should eq(".example.com")
    end
  end

  describe ".parse_line" do
    it "parses \"IP host\" (collapses whitespace, lowercases the host)" do
      Gori::HostOverrides.parse_line("10.0.0.1 Example.COM").should eq({"example.com", "10.0.0.1"})
      Gori::HostOverrides.parse_line("10.0.0.1   api.test").should eq({"api.test", "10.0.0.1"})
      Gori::HostOverrides.parse_line("10.0.0.1 api.test.").should eq({"api.test", "10.0.0.1"})
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
  describe ".host_override_address" do
    it "resolves a global override case-insensitively, nil otherwise" do
      Gori::Settings.hostname_overrides = [{"staging.acme.test", "10.0.0.1"}]
      Gori::Settings.host_override_address("STAGING.acme.test").should eq("10.0.0.1")
      Gori::Settings.host_override_address("staging.acme.test.").should eq("10.0.0.1")
      Gori::Settings.host_override_address("other.test").should be_nil
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
    end

    it "is nil when no global overrides are configured" do
      Gori::Settings.hostname_overrides = [] of {String, String}
      Gori::Settings.host_override_address("example.com").should be_nil
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

  # The two-layer chain, as ONE method. `connect_target` asked both layers and
  # `ClientConn#reserved_self_host?` asked only the project one, so the escape hatch that
  # takes a reserved name out of the self-page set could not see a settings.json override at
  # all. Both callers go through this now, so they cannot disagree again.
  describe ".override_address" do
    it "prefers the project layer, falls back to the global one, and folds the key" do
      with_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("both.test", "10.0.0.1").should be_true
        Gori::Settings.hostname_overrides = [{"both.test", "10.9.9.9"}, {"global.test", "10.0.0.2"}]

        Gori::Proxy::Upstream.override_address("both.test", ov).should eq("10.0.0.1")   # project wins
        Gori::Proxy::Upstream.override_address("global.test", ov).should eq("10.0.0.2") # global fills in
        Gori::Proxy::Upstream.override_address("global.test.", ov).should eq("10.0.0.2")
        Gori::Proxy::Upstream.override_address("neither.test", ov).should be_nil
        # No project layer at all (the shape every active-send path without a store has).
        Gori::Proxy::Upstream.override_address("global.test", nil).should eq("10.0.0.2")
      end
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
    end
  end

  it "does not redirect a host without an override (so the override is what connects)" do
    Gori::Settings.hostname_overrides = [] of {String, String}
    # No override → the unresolvable host is dialed as-is → connect fails (nil).
    Gori::Proxy::Upstream.dial("nonexistent.invalid", 80, connect_timeout: 1.second).should be_nil
  end

  # The whole of F7: the dialled PORT, not just the dialled IP. Asserted by WHICH of two live
  # listeners accepted, because "the dial succeeded" alone cannot tell them apart — the old
  # code connected to `decoy` on the URL's port every time and looked just as successful.
  #
  # Both listeners are accepted from concurrently and report into one channel, rather than
  # blocking on the one that is expected to win: under the reverted behaviour that shape hangs
  # forever instead of failing, which is useless as a control run.
  it "dials the override's PORT when the value names one" do
    decoy = TCPServer.new("127.0.0.1", 0)
    real = TCPServer.new("127.0.0.1", 0)
    who = Channel(String).new(2)
    spawn { decoy.accept?.try(&.close); who.send("url-port") }
    spawn { real.accept?.try(&.close); who.send("override-port") }
    begin
      Gori::Settings.hostname_overrides = [{"nonexistent.invalid", "127.0.0.1:#{real.local_address.port}"}]
      sock = Gori::Proxy::Upstream.dial("nonexistent.invalid", decoy.local_address.port, connect_timeout: 2.seconds)
      sock.should_not be_nil
      who.receive.should eq("override-port")
      sock.try(&.close)
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
      decoy.close
      real.close
    end
  end

  # Regression pin for the half that must NOT change: an entry written before ports existed
  # still means "same port as the request".
  it "keeps the request's port when the override names none" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    begin
      Gori::Settings.hostname_overrides = [{"nonexistent.invalid", "127.0.0.1"}]
      sock = Gori::Proxy::Upstream.dial("nonexistent.invalid", port, connect_timeout: 2.seconds)
      sock.should_not be_nil
      server.accept?.try(&.close)
      sock.try(&.close)
    ensure
      Gori::Settings.hostname_overrides = [] of {String, String}
      server.close
    end
  end

  # The self-loop guard asks its port question AFTER the override resolves, so an override
  # that MOVES the port onto gori's own bind is still caught. Before ports existed the guard
  # could test the request's port first and be right; it no longer can.
  it "sees a self-loop an override's port creates" do
    with_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("evil.test", "127.0.0.1:8070").should be_true
      # Request names port 443; the override moves it onto the listener's own 8070.
      Gori::Proxy::Upstream.loops_to_self?("evil.test", 443, ov, {"127.0.0.1", 8070}).should be_true
      # …and the reverse: a request already on 8070 that the override moves AWAY is not a loop.
      ov.update(ov.entries.first.id, "evil.test", "127.0.0.1:9999").should be_true
      Gori::Proxy::Upstream.loops_to_self?("evil.test", 8070, ov, {"127.0.0.1", 8070}).should be_false
    end
  end

  # Scope and Rules both expose `reload` and are pulled by the TUI's data_version poll
  # (Runner#apply_external_change) and headless capture's reload fiber (App#spawn_reload_loop);
  # HostOverrides — read on the SAME dial path, written by the SAME external surfaces
  # (`gori run project host-override`, MCP add/update/delete_host_override) — had no such
  # method, so a running session kept dialing the old address for the rest of its life while
  # the writing surface reported success. `peer` here stands in for that other process.
  describe "#reload (external writes by a peer process against the same db)" do
    it "picks up an add, an update and a delete a peer made" do
      with_store do |store|
        live = Gori::HostOverrides.load(store) # the running session's proxy + Project pane
        peer = Gori::HostOverrides.load(store) # `gori run project host-override …`

        peer.add("staging.acme.test", "10.0.0.1").should be_true
        live.connect_address("staging.acme.test").should be_nil # stale: the whole bug
        live.reload
        live.connect_address("staging.acme.test").should eq("10.0.0.1")
        live.size.should eq(1)

        peer.update(peer.entries.first.id, "staging.acme.test", "10.0.0.2:8443").should be_true
        live.reload
        live.connect_address("staging.acme.test").should eq("10.0.0.2:8443")

        peer.remove(peer.entries.first.id).should be_true
        live.reload
        live.connect_address("staging.acme.test").should be_nil
        live.size.should eq(0)
      end
    end

    # The stale list also broke the WRITE path, not just lookups: `add` dedupes against its own
    # in-memory entries, so against a stale list it issued an INSERT the store's
    # `UNIQUE(host)` + `INSERT OR IGNORE` silently dropped — and the post-write reload then
    # surfaced the PEER's address under an "override added" toast. Reloading first turns that
    # into the honest duplicate answer the caller already knows how to report.
    it "reports a peer-created host as the duplicate it is instead of claiming the write landed" do
      with_store do |store|
        live = Gori::HostOverrides.load(store)
        peer = Gori::HostOverrides.load(store)
        peer.add("staging.acme.test", "10.0.0.1").should be_true

        # Even WITHOUT a reload first — the in-memory dedupe can't see the peer's row, so the
        # INSERT OR IGNORE is dropped by UNIQUE(host). `add` used to return true anyway and the
        # caller announced an override at 10.9.9.9 that the proxy would never dial.
        live.add("staging.acme.test", "10.9.9.9").should be_false
        live.connect_address("staging.acme.test").should eq("10.0.0.1") # peer's value, unclaimed

        live.reload
        live.add("staging.acme.test", "10.9.9.9").should be_false
        live.connect_address("staging.acme.test").should eq("10.0.0.1")
      end
    end
  end
end
