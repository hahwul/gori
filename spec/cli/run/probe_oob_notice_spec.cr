require "../../spec_helper"

# `gori run probe --active` and the out-of-band half.
#
# An OOB rule (ssrf_oast) only plants when the project has an OAST session to mint against, and
# the TUI's OAST tab is the only surface that writes one — `gori run oast listen` and the MCP
# `oast_start` are ad-hoc, their registration dying with the process. So headless the rule can be
# listed `[on]` by `probe rules` and still send nothing, which made an empty active result read
# as "no blind SSRF" rather than "never looked". These pin the sentence that now says so.
#
# The decision is spec'd through the pure helper rather than by driving the scan, the same seam
# spec/cli/run/probe_helpers_spec.cr works at (the scan itself is an active sender).

# Private CLI glue — reopen the module for a bare-call wrapper.
module Gori::CLI::Run
  def self.oob_unreachable_note_for_spec(store : Store, cfg : Probe::Scan::RuleConfig,
                                         active : Bool) : String?
    oob_unreachable_note(store, cfg, active)
  end
end

private def with_store(&)
  path = File.tempname("gori-probe-oob", ".db")
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

private def cfg(disabled : Array(String) = [] of String, degraded = false) : Gori::Probe::Scan::RuleConfig
  Gori::Probe::Scan::RuleConfig.new(disabled.to_set, [] of Gori::Probe::CustomRule, degraded: degraded)
end

describe "gori run probe — out-of-band reachability notice" do
  it "names the enabled OOB rule when the project has no OAST session to mint against" do
    with_store do |store|
      Gori::Probe::OutOfBand.available?(store).should be_false
      note = Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg, true).not_nil!
      note.should contain("ssrf_oast")
      note.should contain("no OAST session")
      note.should contain("not evidence of no blind SSRF")
    end
  end

  it "says nothing once a session exists to mint against" do
    with_store do |store|
      store.insert_oast_session(nil, "interactsh", "https://oast.test", "corr", "sec", nil, nil)
      Gori::Probe::OutOfBand.available?(store).should be_true
      Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg, true).should be_nil
    end
  end

  # `available?` asks StoreMinter.build, not `oast_sessions.empty?`: a row that cannot be rebuilt
  # into a provider is not one a payload can be minted against either, so the notice must still
  # fire — a notice that disagreed with the scan it describes would be worse than none.
  it "still fires on a session row whose provider kind no longer parses" do
    with_store do |store|
      store.insert_oast_session(nil, "not-a-provider", "https://oast.test", "corr", "sec", nil, nil)
      store.oast_sessions.should_not be_empty
      Gori::Probe::OutOfBand.available?(store).should be_false
      Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg, true).should_not be_nil
    end
  end

  it "stays silent on a passive run, on a disabled rule, and under a degraded rule config" do
    with_store do |store|
      # passive: nothing was going to be sent, so there is nothing to warn about
      Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg, false).should be_nil
      # the operator switched the rule off — not a surprise that needs naming
      Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg(["ssrf_oast"]), true).should be_nil
      # degraded: ACTIVE is skipped wholesale and Scan reports that instead
      Gori::CLI::Run.oob_unreachable_note_for_spec(store, cfg(degraded: true), true).should be_nil
    end
  end
end
