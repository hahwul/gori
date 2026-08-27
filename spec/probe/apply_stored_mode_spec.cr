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

# A store whose writes are all REFUSED, beside a writable one on the same file. `read_only` runs
# without a writer fiber, so `set_setting` answers false exactly as a busy project does — the
# "another instance keeps the old mode" shape, with no lock race to arrange. The writable handle is
# the peer: it is what disk ends up holding.
private def with_refused_writes(&)
  path = File.tempname("gori-probe-refused", ".db")
  peer = Gori::Store.open(path)
  mine = Gori::Store.open(path, read_only: true)
  begin
    yield mine, peer
  ensure
    mine.close
    peer.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
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

  it "reports the DIRECTION it moved, which the caller cannot reconstruct afterwards" do
    # #772: the announcement policy is direction-shaped — an upgrade into an actively-probing mode
    # authorizes THIS session to fire attack payloads, a downgrade can only stop traffic. By the
    # time either caller looks, `@mode` already holds the new value, so the pair has to come back
    # out of the adoption itself.
    with_probe_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Aggressive).should be_true
      a = analyzer(store, Gori::Probe::Mode::Passive)
      a.apply_stored_mode.should eq({Gori::Probe::Mode::Passive, Gori::Probe::Mode::Aggressive})
    end
  end

  it "reports nothing on the no-op tick, so the announcement cannot repeat" do
    # Both pollers run on a cadence — the TUI's is ~1.3×/sec under live capture. A truthy return
    # on an unchanged mode would put a line, and the bell with it, on screen every tick.
    with_probe_store do |store|
      store.set_probe_mode(Gori::Probe::Mode::Passive)
      a = analyzer(store, Gori::Probe::Mode::Passive)
      a.apply_stored_mode.should be_nil
    end
  end

  it "says nothing when the revert is this session's OWN refused write coming back" do
    # `set_mode` raises `@mode` before it persists, on purpose, and the surface reports the failure
    # itself ("scan mode NOT saved — project busy; another instance keeps the old mode"). The poll
    # that then reverts memory to disk must not ALSO announce it as a peer's doing: that is two
    # contradictory sentences about one keypress, 750ms apart.
    with_refused_writes do |mine, peer|
      peer.set_probe_mode(Gori::Probe::Mode::Aggressive).should be_true
      a = analyzer(mine, Gori::Probe::Mode::Aggressive)
      a.set_mode(Gori::Probe::Mode::Off).should be_false
      a.apply_stored_mode.should be_nil
      a.mode.should eq(Gori::Probe::Mode::Aggressive)
    end
  end

  it "keeps the OLDEST outstanding value when a second edit is refused before the poll" do
    # `prev` is only what disk holds for the FIRST refusal; the second one's `prev` is a value that
    # was never persisted either. Overwriting with it makes the revert stop matching, and the
    # operator gets a `:warn` bell about a peer who did nothing.
    with_refused_writes do |mine, peer|
      peer.set_probe_mode(Gori::Probe::Mode::Aggressive).should be_true
      a = analyzer(mine, Gori::Probe::Mode::Aggressive)
      a.set_mode(Gori::Probe::Mode::Off).should be_false
      a.set_mode(Gori::Probe::Mode::Passive).should be_false
      a.apply_stored_mode.should be_nil
      a.mode.should eq(Gori::Probe::Mode::Aggressive)
    end
  end

  it "does not let a stale refusal swallow a LATER genuine peer upgrade" do
    # The dangerous residue. Once memory and disk agree the refusal is settled, and leaving the
    # guard armed makes it match a peer change that happens to land on the same mode — silently
    # adopting `aggressive`, backfill and unsafe methods and all, which is the exact silence this
    # whole feature exists to end.
    with_refused_writes do |mine, peer|
      peer.set_probe_mode(Gori::Probe::Mode::Off).should be_true
      a = analyzer(mine, Gori::Probe::Mode::Aggressive)
      a.set_mode(Gori::Probe::Mode::Off).should be_false # memory and disk now agree, by coincidence
      a.apply_stored_mode.should be_nil                  # the settling tick

      peer.set_probe_mode(Gori::Probe::Mode::Aggressive).should be_true
      a.apply_stored_mode.should eq({Gori::Probe::Mode::Off, Gori::Probe::Mode::Aggressive})
    end
  end

  it "reports nothing when the row cannot be read" do
    # The rescue returns the same "nothing moved" answer as a no-op tick: an unreadable row is not
    # a mode change, and announcing one would be a warning about a peer who did nothing.
    with_probe_store do |store|
      a = analyzer(store, Gori::Probe::Mode::Passive)
      store.close
      a.apply_stored_mode.should be_nil
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
