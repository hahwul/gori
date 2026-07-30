require "./spec_helper"

# The passthrough INVENTORY (#497): the session-global record of hosts gori relayed without
# MITM, which the TUI's `bypass:N` chip and its drill-down list read.
#
# These examples exist because the obvious implementation — reuse `@@tls_passthrough_noticed`
# — is wrong in two specific, invisible ways. That Set is a LOG-DEDUP marker: it is cleared
# when the pattern list is reassigned, and it stops growing at PASSTHROUGH_NOTICE_MAX. Both
# are correct for "one gori.log line per host" and both destroy a count. The inventory is a
# separate structure precisely so it can behave differently, so what is pinned below is the
# DIFFERENCE, not the happy path.
#
# Every example resets the inventory itself (it is deliberately never cleared in production)
# and restores the pattern list, since both are process-wide class state.
private def with_passthrough(patterns : Array(String), &)
  prev = Gori::Settings.tls_passthrough
  begin
    Gori::Settings.tls_passthrough = patterns
    Gori::Settings.reset_passthrough_inventory
    yield
  ensure
    Gori::Settings.tls_passthrough = prev
    Gori::Settings.reset_passthrough_inventory
  end
end

describe "HostPattern.match" do
  it "returns the winning pattern, not just that one won" do
    compiled = Gori::HostPattern.compile(["*.push.acme.test", "updates.acme.test"])
    Gori::HostPattern.match(compiled, "a.push.acme.test").not_nil!.raw.should eq("*.push.acme.test")
    # A subdomain of the suffix rule: the second pattern is the one that fired, and naming
    # the FIRST would send an operator to delete a rule that has nothing to do with it.
    Gori::HostPattern.match(compiled, "eu.updates.acme.test").not_nil!.raw.should eq("updates.acme.test")
    Gori::HostPattern.match(compiled, "acme.test").should be_nil
  end

  it "answers nil on an empty list without touching the host" do
    Gori::HostPattern.match([] of Gori::HostPattern::Compiled, "acme.test").should be_nil
  end

  it "agrees with matches_any? — the two must never disagree about whether a host matched" do
    compiled = Gori::HostPattern.compile(["*.push.acme.test", "updates.acme.test", "[::1]"])
    ["a.push.acme.test", "updates.acme.test", "eu.updates.acme.test", "::1", "[::1]",
     "acme.test", "push.acme.test", "other.test", "UPDATES.ACME.TEST"].each do |host|
      matched = !Gori::HostPattern.match(compiled, host).nil?
      matched.should eq(Gori::HostPattern.matches_any?(compiled, host)), host
    end
  end
end

describe "Settings passthrough inventory" do
  it "records one entry per HOST, counting connections rather than adding rows" do
    with_passthrough(["*.push.acme.test"]) do
      Gori::Settings.passthrough_count.should eq(0)
      3.times { Gori::Settings.tls_passthrough?("a.push.acme.test").should be_true }
      Gori::Settings.tls_passthrough?("b.push.acme.test").should be_true

      # Constraint (b) from the issue: a push client reconnecting every 30s moves a counter,
      # it does not flood the list.
      Gori::Settings.passthrough_count.should eq(2)
      hosts = Gori::Settings.passthrough_hosts
      hosts.map(&.host).should eq(["a.push.acme.test", "b.push.acme.test"]) # first-seen order
      hosts[0].connections.should eq(3)
      hosts[1].connections.should eq(1)
    end
  end

  it "names the pattern that matched, so the operator can find the rule to remove" do
    with_passthrough(["updates.acme.test", "*.push.acme.test"]) do
      Gori::Settings.tls_passthrough?("eu.updates.acme.test")
      Gori::Settings.tls_passthrough?("a.push.acme.test")
      Gori::Settings.passthrough_hosts.map(&.pattern).should eq(["updates.acme.test", "*.push.acme.test"])
    end
  end

  it "refreshes the pattern when a different rule takes over the same host" do
    # The list is the operator's map to the rule to delete. If the host is STILL being
    # bypassed, the rule doing it now is the useful answer — a stale first-match would point
    # at a rule that may no longer exist.
    with_passthrough(["*.push.acme.test"]) do
      Gori::Settings.tls_passthrough?("a.push.acme.test")
      Gori::Settings.tls_passthrough = ["acme.test"]
      Gori::Settings.tls_passthrough?("a.push.acme.test")
      entry = Gori::Settings.passthrough_hosts.first
      entry.pattern.should eq("acme.test")
      entry.connections.should eq(2) # still ONE host, not a second row
    end
  end

  it "survives a reassignment of the pattern list, unlike the log-notice set" do
    # THE gap this structure exists for. `tls_passthrough=` clears @@tls_passthrough_noticed
    # on purpose (so an edited list re-announces itself to gori.log). If the chip counted
    # that Set, editing the list would drop `bypass:N` to zero at exactly the moment an
    # operator opened the editor to decide what to change.
    with_passthrough(["*.push.acme.test"]) do
      Gori::Settings.tls_passthrough?("a.push.acme.test")
      Gori::Settings.passthrough_count.should eq(1)

      Gori::Settings.tls_passthrough = ["*.push.acme.test", "updates.acme.test"]
      Gori::Settings.passthrough_count.should eq(1)
      Gori::Settings.passthrough_hosts.first.host.should eq("a.push.acme.test")

      # Even removing the rule entirely leaves the record: the connection really did go
      # uncaptured, and "why is this host missing from History?" is asked afterwards.
      Gori::Settings.tls_passthrough = [] of String
      Gori::Settings.tls_passthrough?("a.push.acme.test").should be_false
      Gori::Settings.passthrough_count.should eq(1)
    end
  end

  it "keeps counting past PASSTHROUGH_NOTICE_MAX instead of going quiet" do
    # The other half of the same gap: the notice set stops growing at the cap, so a count
    # taken from it would silently freeze. The inventory has its own cap and reports what it
    # dropped (see the truncation example below).
    with_passthrough(["acme.test"]) do
      n = Gori::Settings::PASSTHROUGH_NOTICE_MAX + 5
      n.times { |i| Gori::Settings.tls_passthrough?("h#{i}.acme.test") }
      Gori::Settings.passthrough_count.should eq(Gori::Settings::PASSTHROUGH_INVENTORY_MAX)
      Gori::Settings.passthrough_over_cap.should eq(n - Gori::Settings::PASSTHROUGH_INVENTORY_MAX)
    end
  end

  it "counts overflow CONNECTs at the cap rather than truncating in silence" do
    with_passthrough(["acme.test"]) do
      Gori::Settings::PASSTHROUGH_INVENTORY_MAX.times { |i| Gori::Settings.tls_passthrough?("h#{i}.acme.test") }
      Gori::Settings.passthrough_over_cap.should eq(0)

      # A host past the cap is not admitted at all — but a host ALREADY in the list keeps
      # counting normally, so the cap never turns an existing row stale.
      Gori::Settings.tls_passthrough?("overflow.acme.test")
      Gori::Settings.tls_passthrough?("overflow.acme.test")
      Gori::Settings.passthrough_over_cap.should eq(2)
      Gori::Settings.passthrough_count.should eq(Gori::Settings::PASSTHROUGH_INVENTORY_MAX)

      Gori::Settings.tls_passthrough?("h0.acme.test")
      Gori::Settings.passthrough_hosts.first.connections.should eq(2)
      Gori::Settings.passthrough_over_cap.should eq(2)
    end
  end

  it "records nothing for a host that was never bypassed" do
    with_passthrough(["updates.acme.test"]) do
      Gori::Settings.tls_passthrough?("acme.test").should be_false
      Gori::Settings.passthrough_count.should eq(0)
      Gori::Settings.passthrough_hosts.should be_empty
    end
  end
end
