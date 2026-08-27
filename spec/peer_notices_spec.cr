require "./spec_helper"

# #772 — what a PEER (an MCP agent, `gori run …`, a second TUI) changed under a running session,
# and how loudly the operator hears about it. `PeerNotices` is the whole policy, kept pure and
# outside `Gori::Tui` so the headless capture loop says the same sentence; these examples are the
# policy, and the source-grep block at the bottom pins the two wirings that carry it.

private def notices : Gori::PeerNotices
  Gori::PeerNotices.new
end

# Comments stripped first, the way `spec/tui/session_slots_spec.cr` reads a tick body: the prose
# above these call sites names them while explaining why they are there.
private def peer_src(*parts : String) : String
  File.read(File.join(__DIR__, "..", "src", *parts)).lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def with_event_store(&)
  path = File.tempname("gori-peer-events", ".db")
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

private def probe_note(prev : Gori::Probe::Mode, curr : Gori::Probe::Mode) : Gori::PeerNotices::Notice
  notices.probe_mode(prev, curr)
end

describe Gori::PeerNotices do
  describe "#probe_mode" do
    it "WARNS when a peer raises the mode into one that probes actively" do
      # The whole reason the issue exists: this is not a view setting, it is the authorization for
      # this session to start firing attack payloads at the target. `:warn` is what takes the bell
      # and the toast (Notifications#push rings only above `:info`).
      note = probe_note(Gori::Probe::Mode::Passive, Gori::Probe::Mode::Active)
      note.level.should eq(:warn)
      note.message.should contain("raised to active")
      note.message.should contain("another session")
      note.tab.should eq(:probe)
    end

    it "warns on active → aggressive too, which is a widening and not a re-label" do
      # Aggressive probes UNSAFE methods, so an in-scope endpoint can be state-mutated by the
      # automatic pipeline. A rank comparison, not `probes_actively?`, is what catches this —
      # both modes are already actively probing.
      probe_note(Gori::Probe::Mode::Active, Gori::Probe::Mode::Aggressive).level.should eq(:warn)
    end

    it "is QUIET when a peer lowers the mode out of active probing" do
      # Safe by construction — it can only stop traffic — so no bell and no toast. It still earns
      # a line in the centre, which is what answers "when did the agent turn this off?" later.
      note = probe_note(Gori::Probe::Mode::Aggressive, Gori::Probe::Mode::Passive)
      note.level.should eq(:info)
      note.message.should contain("lowered to passive")
      note.message.should contain("active probing stopped")
    end

    it "is quiet on aggressive → active, which narrows what is already firing" do
      probe_note(Gori::Probe::Mode::Aggressive, Gori::Probe::Mode::Active).level.should eq(:info)
    end

    it "is quiet on a move that never touches active probing at all" do
      probe_note(Gori::Probe::Mode::Off, Gori::Probe::Mode::Passive).level.should eq(:info)
      probe_note(Gori::Probe::Mode::Passive, Gori::Probe::Mode::Off).level.should eq(:info)
    end

    it "names the mode it landed on, in the label the rest of the app uses" do
      # The chip, the CLI and MCP all spell the mode with `Mode#label`; a notification that spelled
      # it any other way would send the operator looking for a setting that does not exist.
      Gori::Probe::Mode.values.reject(&.passive?).each do |m|
        probe_note(Gori::Probe::Mode::Passive, m).message.should contain(m.label)
      end
    end
  end

  describe "#flush" do
    it "holds a change until the quiet window closes, then says it once" do
      # TRAILING edge: an agent writing three rules in a row lands three adoptions on three ticks,
      # and one belled line per tick is the noise this feature exists to avoid.
      t0 = Time.instant
      p = notices
      p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0)
      p.flush(t0).should be_nil
      p.flush(t0 + 1.second).should be_nil
      p.flush(t0 + Gori::PeerNotices::QUIET_WINDOW).should_not be_nil
      # And the hold is over — nothing repeats on the ticks that follow.
      p.flush(t0 + 1.minute).should be_nil
    end

    it "counts the whole burst, not the last write in it" do
      t0 = Time.instant
      p = notices
      p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0)
      p.record_rules(Gori::RuleSetChange.new(changed: 2, reordered: false, enabled: 3), t0 + 1.second)
      note = p.flush(t0 + 5.seconds).not_nil!
      note.message.should contain("3 Match&Replace rules")
      note.level.should eq(:warn)
      note.tab.should eq(:rewriter)
    end

    it "says ONE line when both rule kinds moved, not two" do
      # The Companion speaks the newest note and only that one, so a second push in the same tick
      # is a line the operator never hears — and "the rules changed" is one fact to them anyway.
      t0 = Time.instant
      p = notices
      p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0)
      p.record_extract(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0)
      p.flush(t0 + 5.seconds).not_nil!.message.should contain("Match&Replace and extract rules")
    end

    it "says nothing at all when nothing was recorded" do
      notices.flush(Time.instant).should be_nil
    end

    it "drops the bell for a change that leaves nothing enabled" do
      # Nothing enabled means nothing on the wire moved, whatever just happened to the list.
      t0 = Time.instant
      p = notices
      p.record_rules(Gori::RuleSetChange.new(changed: 2, reordered: false, enabled: 0), t0)
      note = p.flush(t0 + 5.seconds).not_nil!
      note.level.should eq(:info)
      note.message.should contain("none are enabled")
    end

    it "names a pure REORDER as what it is, never as zero rules changed" do
      t0 = Time.instant
      p = notices
      p.record_rules(Gori::RuleSetChange.new(changed: 0, reordered: true, enabled: 2), t0)
      note = p.flush(t0 + 5.seconds).not_nil!
      note.message.should contain("order changed")
      note.message.should_not contain("0 ")
      note.level.should eq(:warn)
    end

    it "names the consequence for extract rules, which is where $KEY comes from" do
      t0 = Time.instant
      p = notices
      p.record_extract(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0)
      p.flush(t0 + 5.seconds).not_nil!.message.should contain("$KEY")
    end
  end
end

describe Gori::RuleSetChange do
  it "is nil when the two snapshots are identical, which is almost every poll" do
    rules = [Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "a", "b")]
    Gori::RuleSetChange.between(rules, rules.dup, ->(r : Gori::Store::MatchRule) { r.id }).should be_nil
  end

  it "counts a rule whose CONTENTS changed under the same id" do
    before = [Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "a", "b")]
    after = [Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "a", "DIFFERENT")]
    change = Gori::RuleSetChange.between(before, after, ->(r : Gori::Store::MatchRule) { r.id }).not_nil!
    change.changed.should eq(1)
    change.reordered.should be_false
  end

  it "counts a removal, which no scan of the new list alone can see" do
    a = Gori::Store::MatchRule.new(1_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "a", "b")
    b = Gori::Store::MatchRule.new(2_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "c", "d")
    change = Gori::RuleSetChange.between([a, b], [a], ->(r : Gori::Store::MatchRule) { r.id }).not_nil!
    change.changed.should eq(1)
    change.enabled.should eq(1)
  end

  it "keys on what the caller says identity is, so two numberings cannot collide" do
    # A global rule and a project rule can both be id 3 — the library and the project table number
    # independently. Keyed on the bare id they read as one rule being edited over and over.
    project = Gori::Store::MatchRule.new(3_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "a", "b", scope: Gori::Store::RuleScope::Project)
    global = Gori::Store::MatchRule.new(3_i64, true, Gori::Store::RuleTarget::Request,
      Gori::Store::RulePart::Head, "c", "d", scope: Gori::Store::RuleScope::Global)
    key = ->(r : Gori::Store::MatchRule) { {r.scope, r.id} }
    change = Gori::RuleSetChange.between([project], [global, project], key).not_nil!
    change.changed.should eq(1) # the global arrived; the project rule is untouched
  end
end

describe "peer-change attribution" do
  it "names an agent when the feed says one made this kind of change" do
    with_event_store do |store|
      store.insert_event("agent", "agent_action", "info", "create_rule ok", payload: "create_rule")
      Gori::PeerNotices.agent_wrote?(store, Gori::PeerNotices::RULE_TOOLS).should be_true
      # And does not credit it for a change of a different kind that it did not make.
      Gori::PeerNotices.agent_wrote?(store, Gori::PeerNotices::PROBE_TOOLS).should be_false
    end
  end

  it "does not credit an agent for a call that FAILED" do
    # `log_agent_action` records refusals too — level "warn", "create_rule failed (PROJECT_BUSY)".
    # A refused call changed nothing, so crediting it names the wrong author for a change some
    # other peer actually made.
    with_event_store do |store|
      store.insert_event("agent", "agent_action", "warn", "create_rule failed (PROJECT_BUSY)", payload: "create_rule")
      Gori::PeerNotices.agent_wrote?(store, Gori::PeerNotices::RULE_TOOLS).should be_false
    end
  end

  it "ignores the rest of the feed, however loud it is" do
    with_event_store do |store|
      store.insert_event("probe", "issue_found", "success", "Probe: something", payload: nil)
      store.insert_event("agent", "agent_action", "info", "send_request ok", payload: "send_request")
      Gori::PeerNotices.agent_wrote?(store, Gori::PeerNotices::RULE_TOOLS).should be_false
    end
  end

  it "reads the NEWEST end of the feed, not the oldest" do
    # An agent that sent three hundred requests before its rule edit would fill any bounded
    # oldest-first page with the sends and never reach the edit — which is the case attribution
    # exists for.
    with_event_store do |store|
      30.times { store.insert_event("agent", "agent_action", "info", "send_request ok", payload: "send_request") }
      store.insert_event("agent", "agent_action", "info", "create_rule ok", payload: "create_rule")
      Gori::PeerNotices.agent_wrote?(store, Gori::PeerNotices::RULE_TOOLS).should be_true
    end
  end

  it "sees nothing outside the window" do
    with_event_store do |store|
      store.insert_event("agent", "agent_action", "info", "create_rule ok", payload: "create_rule")
      future = (Time.utc + 1.hour).to_unix_ms * 1_000
      store.recent_agent_actions(future, 20).should be_empty
    end
  end

  it "swaps only the author into the line, and marks the note as AI-made" do
    t0 = Time.instant
    p = notices
    p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0, by_agent: true)
    note = p.flush(t0 + 5.seconds).not_nil!
    note.message.should contain("by an agent")
    note.message.should_not contain("another session")
    # `source` is what makes the notification centre render it with the AI marker.
    note.source.should eq("agent")
  end

  it "keeps the attribution when the rest of a burst is anonymous" do
    # Otherwise one unattributed write late in the burst erases the one fact worth carrying.
    t0 = Time.instant
    p = notices
    p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 1), t0, by_agent: true)
    p.record_rules(Gori::RuleSetChange.new(changed: 1, reordered: false, enabled: 2), t0 + 1.second)
    p.flush(t0 + 5.seconds).not_nil!.source.should eq("agent")
  end

  it "falls back to another session, which is what every non-MCP peer is" do
    # `gori run …` and a second TUI write no feed row at all. Anonymous is the honest answer.
    probe_note(Gori::Probe::Mode::Passive, Gori::Probe::Mode::Active).message.should contain("another session")
    probe_note(Gori::Probe::Mode::Passive, Gori::Probe::Mode::Active).source.should eq("app")
  end
end

describe "the surfaces that announce a peer change" do
  it "queues the probe-mode line where the TUI ADOPTS the peer's mode" do
    tick = peer_src("gori", "tui", "runner.cr")[/def apply_external_change.*?\n    end/m]
    tick.should_not be_nil
    tick.not_nil!.should contain("probe.apply_stored_mode")
    tick.not_nil!.should contain("peer_notices")
  end

  it "EMITS outside the data_version branch, so a held line still gets out" do
    # The change can only be spotted on a commit, but the emit must keep running after the commits
    # stop: a line the coalescing window is holding would otherwise wait for traffic that may never
    # come. `drain_peer_notices` therefore sits with `refresh_agent_presence` on the bare poll
    # cadence — putting it inside `apply_external_change` is the bug this pins.
    runner = peer_src("gori", "tui", "runner.cr")
    runner.should contain("dirty = true if drain_peer_notices")
    tick = runner[/def apply_external_change.*?\n    end/m].not_nil!
    tick.should_not contain("drain_peer_notices")
  end

  it "takes BOTH rule kinds where it emits, not where the tick noticed" do
    # `Rules`/`Bindings` record the peer delta rather than returning it, so the re-readers cannot
    # eat it — but that only pays off if the take runs on the bare cadence. Taking inside
    # `apply_external_change` would strand a change a tab entry had already adopted.
    runner = peer_src("gori", "tui", "runner.cr")
    drain = runner[/def drain_peer_notices.*?\n    end/m].not_nil!
    drain.should contain("rules.take_peer_change")
    drain.should contain("bindings.take_peer_change")
    drain.should contain("flush")
  end

  it "keeps the factory reset silent, the one local edit that comes in through reload" do
    # Every other local rule edit goes through the private refresh and is silent by construction;
    # this one wipes the global library and reloads, and would announce itself as a peer.
    reset = peer_src("gori", "tui", "runner.cr")[/def apply_factory_reset.*?\n    end/m].not_nil!
    reset.should contain("rules.reload(announce: false)")
  end

  it "says the same thing on the headless capture loop, which adopts the same write" do
    # `gori run capture` runs a live analyzer of its own and has no ring — but it does have the
    # operator's terminal (run_capture binds logging to STDERR). Same policy object, so the two
    # surfaces cannot drift into describing the same event differently.
    loop_body = peer_src("gori", "app.cr")[/def spawn_reload_loop.*?\n      stop\n    end/m]
    loop_body.should_not be_nil
    loop_body.not_nil!.should contain("probe.apply_stored_mode")
    loop_body.not_nil!.should contain("peer_notices.probe_mode")
    loop_body.not_nil!.should contain("announce_peer_rule_changes")
    # And that helper takes BOTH rule sets through the shared policy rather than a second copy of
    # the take/attribute/record sequence the TUI already has.
    helper = peer_src("gori", "app.cr")[/def announce_peer_rule_changes.*?\n    end/m].not_nil!
    helper.should contain("rules.take_peer_change")
    helper.should contain("bindings.take_peer_change")
    helper.should contain("absorb")
  end
end
