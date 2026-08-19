require "./spec_helper"

# Every example closes the store itself — that is the lever for a failed commit — so the
# helper must not close it again. `Store#close` is idempotent, but this file should fail on
# its own subject, not on teardown.
private def with_store(&)
  path = File.tempname("gori-commit", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# One class, four sites: a mutation whose store answered "did this COMMIT" threw the answer
# away, and the surface above it reported success regardless. A closed store is the cheap
# stand-in for the busy/locked/closing case those answers exist for — `exec_task_ok` returns
# false rather than raising.
#
# The same class again on the three repeater-metadata writes (#210). These ran through
# `exec_task`, whose Int64 reply is `last_insert_rowid` — meaningless for an UPDATE/DELETE —
# so no caller could learn whether the batch committed: MCP `update_repeater` reported a name
# and a `ws_out_message_count` for a batch that rolled back, and the TUI cleared a tab's dirty
# flag over frames the store never took. The callers are pinned where they live
# (spec/mcp/agent_surface_spec.cr, spec/cli/run_spec.cr,
# spec/tui/repeater_refusal_inline_spec.cr); this is the answer they all act on.
describe "commit confirmation" do
  describe "Scope sandbox setters" do
    # The sandbox is a BLOCKING gate, and one Scope instance is shared by the Interceptor and
    # every Outbound built from it. A dropped write is therefore not just "does not survive
    # restart": `reload` re-reads the persisted value and reverts the gate a surface already
    # announced as on.
    it "reports whether the flag committed" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.enable_sandbox.should be_true
        scope.disable_sandbox.should be_true
        scope.toggle_sandbox.should be_true

        store.close
        scope.enable_sandbox.should be_false
      end
    end

    it "matches the enabled-flag sibling beside it" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.enable.should be_true
        store.close
        scope.enable.should be_false
        scope.enable_sandbox.should be_false
      end
    end
  end

  describe "Store#set_probe_mode" do
    # Lowering the mode to stop active probing is the direction that matters: every surface
    # reported it done while a separate live instance kept the persisted mode and kept firing.
    it "reports whether the mode committed" do
      with_store do |store|
        store.set_probe_mode(Gori::Probe::Mode::Active).should be_true
        store.probe_mode.should eq(Gori::Probe::Mode::Active)

        store.close
        store.set_probe_mode(Gori::Probe::Mode::Off).should be_false
      end
    end
  end

  describe "Store#update_probe_custom_rule" do
    # A custom probe rule IS a detection, and this write is the whole rule body — pattern
    # included. `set_probe_custom_rule_enabled` right beside it already answered; this one ran
    # through `exec_task`, whose Int64 reply is `last_insert_rowid` and so says nothing about an
    # UPDATE. So an operator (TUI) or an agent (MCP `update_probe_rule`) who widened a pattern
    # was told the rule was updated over a batch that rolled back, and kept scanning with the
    # OLD pattern — a false negative they had been told not to expect.
    it "reports whether the edited rule body committed" do
      with_store do |store|
        id = store.insert_probe_custom_rule("leaky", "finds a debug header", "response",
          "header", "string", "X-Debug", Gori::Store::Severity::Info)
        id.should be > 0

        store.update_probe_custom_rule(id, "leaky", "finds a debug header", "response",
          "header", "string", "X-Debug-Token", Gori::Store::Severity::High).should be_true
        row = store.probe_custom_rules.first
        row.pattern.should eq("X-Debug-Token")
        row.severity.should eq(Gori::Store::Severity::High)

        store.close
        store.update_probe_custom_rule(id, "leaky", "finds a debug header", "response",
          "header", "string", "X-Debug-Token|X-Trace", Gori::Store::Severity::High).should be_false
      end
    end
  end

  describe "Rules#add / #update" do
    it "reports whether the write committed" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "B").should be_true
        id = rules.rules.first.id
        rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "C").should be_true

        store.close
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "X", "Y").should be_false
        rules.update(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "A", "D").should be_false
      end
    end

    # An empty pattern is refused before any write, and the caller cannot tell that apart
    # from a failure — both mean "no rule was added", which is what the surfaces report.
    it "refuses an empty pattern without claiming a write" do
      with_store do |store|
        rules = Gori::Rules.load(store)
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "", "B").should be_false
        rules.rules.should be_empty
      end
    end
  end

  describe "the repeater metadata writes (#210)" do
    # All three at once, because they are one class and one lever: a label, a tag set and the
    # outbound frame list, each its own narrow UPDATE beside `update_repeater` (which already
    # answered). The frame list is the one that costs bytes on the wire — its batch opens with
    # `DELETE FROM ws_messages`, so a rollback leaves the session on its PREVIOUS frames while
    # the caller has already reported the new count.
    it "answers false when the store can no longer be written" do
      with_store do |store|
        id = store.insert_repeater("https://a.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
        id.should be > 0

        store.set_repeater_name(id, "login").should be_true
        store.set_repeater_tags(id, "auth").should be_true
        store.update_repeater_ws_messages(id, [Gori::Store::WsOutMessage.text("hi")]).should be_true

        store.close # every write from here answers false

        store.set_repeater_name(id, "renamed").should be_false
        store.set_repeater_tags(id, "idor").should be_false
        store.update_repeater_ws_messages(id, [Gori::Store::WsOutMessage.text("bye")]).should be_false
      end
    end
  end

  # `@done` is unbuffered and the writer fiber sends exactly one value as it exits, so a
  # second `close` used to park forever waiting for a sender that no longer existed. Asserted
  # with a deadline rather than by just calling it twice: a regression here HANGS, and a spec
  # that hangs wedges the suite instead of reporting a failure.
  describe "Store#close" do
    it "is idempotent instead of parking on an exhausted channel" do
      path = File.tempname("gori-close", ".db")
      begin
        store = Gori::Store.open(path)
        store.close

        returned = Channel(Nil).new(1)
        spawn do
          store.close
          store.close
          returned.send(nil)
        end

        select
        when returned.receive
          # closed again without blocking
        when timeout(5.seconds)
          fail "Store#close blocked on a second call"
        end
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end
end
