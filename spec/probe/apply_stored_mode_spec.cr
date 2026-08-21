require "../spec_helper"

# `Analyzer#apply_stored_mode` is the catch-up direction of the probe mode: a PEER
# (`gori run probe mode`, MCP `set_probe_mode`, a second TUI) commits the row and this
# process, whose in-memory `@mode` is what actually authorizes an active probe, has to adopt
# it. It is called from two pollers — the TUI's data_version tick and the headless capture
# reload loop — which is what makes "does not persist" a property and not a detail.

private def with_probe_store(&)
  path = File.tempname("gori-probe-mode", ".db")
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

private def analyzer(store : Gori::Store, mode : Gori::Probe::Mode) : Gori::Probe::Analyzer
  Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
    Channel(Gori::Store::FlowEvent).new(1), mode, true)
end

# The source-reading gate, the way `spec/tui/session_slots_spec.cr` does it. A behavioural
# "did it persist" assertion cannot see this: `PRAGMA data_version` does not move for a commit
# on the SAME connection, and re-reading `probe_mode` after a write of the value we were
# adopting anyway returns exactly what a no-op returns. Comments are stripped first — the one
# above the method names both forbidden calls while explaining why they are forbidden.
private def analyzer_body(name : String) : String
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "probe", "analyzer.cr"))
  src.lines.reject(&.lstrip.starts_with?('#')).join('\n')[/def #{name}.*?\n      end/m].not_nil!
end

describe "Gori::Probe::Analyzer#apply_stored_mode" do
  it "does not write the mode back" do
    body = analyzer_body("apply_stored_mode")
    # Persisting on a poll would re-write the same row on every tick, and — the reason that
    # matters — a stale in-memory mode racing the peer's write would put the OLD mode back,
    # re-authorizing the active probing the peer had just switched off.
    body.should_not contain("set_probe_mode")
    body.should_not contain("set_mode")
    body.should contain("@store.probe_mode")
  end

  it "STOPS active probing when a peer switched the project down" do
    with_probe_store do |store|
      # The direction `Store#set_probe_mode` names: every surface reported the stop as done
      # while a separate live instance kept firing attack payloads at production.
      store.set_probe_mode(Gori::Probe::Mode::Off).should be_true
      a = analyzer(store, Gori::Probe::Mode::Aggressive) # the constructor does not persist
      a.mode.should eq(Gori::Probe::Mode::Aggressive)
      a.apply_stored_mode
      a.mode.should eq(Gori::Probe::Mode::Off)
      a.mode.probes_actively?.should be_false
    end
  end

  it "picks up a peer's upgrade too, and does not re-write the row doing it" do
    with_probe_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Active).should be_true
      a = analyzer(store, Gori::Probe::Mode::Passive)
      a.apply_stored_mode
      a.mode.should eq(Gori::Probe::Mode::Active)
      # The row is the peer's; adopting it must leave it exactly as found.
      store.probe_mode.should eq(Gori::Probe::Mode::Active)
    end
  end

  it "is a no-op when the stored mode already matches (the common tick)" do
    with_probe_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Passive)
      a = analyzer(store, Gori::Probe::Mode::Passive)
      a.apply_stored_mode
      a.mode.should eq(Gori::Probe::Mode::Passive)
    end
  end

  it "leaves the live mode alone when the row cannot be read" do
    # The two callers poll on the UI / capture fiber with no rescue of their own; a raise there
    # would take the frame (or the reload loop) down over a settings read.
    with_probe_store do |store|
      a = analyzer(store, Gori::Probe::Mode::Passive)
      store.close # every read from here on raises
      a.apply_stored_mode
      a.mode.should eq(Gori::Probe::Mode::Passive)
    end
  end
end

describe "the surfaces that poll it" do
  it "is on the TUI's data_version tick, next to the other hot-path reloads" do
    # `Runner#apply_external_change` is the only place the TUI notices another gori's writes.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    tick = src.lines.reject(&.lstrip.starts_with?('#')).join('\n')[/def apply_external_change.*?\n    end/m]
    tick.should_not be_nil
    tick.not_nil!.should contain("probe.apply_stored_mode")
  end

  it "is on the headless capture reload loop, which runs a live analyzer of its own" do
    # `Session.open` starts the analyzer whenever this process holds the capture lock, so
    # `gori run capture` is an actively-probing instance like any other.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "app.cr"))
    loop_body = src.lines.reject(&.lstrip.starts_with?('#')).join('\n')[/def spawn_reload_loop.*?\n      stop\n    end/m]
    loop_body.should_not be_nil
    loop_body.not_nil!.should contain("probe.apply_stored_mode")
  end
end
