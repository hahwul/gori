require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/probe.cr — the Probe scan-issue list, the issue detail, and the Rules
# sub-tab. Triage keys are one-press and destructive-adjacent, so the exact chord each
# action claims is part of the contract.
describe "Gori::Verbs.register_probe" do
  r = Gori::Verbs.registry

  describe "the issue list" do
    it "moves the selection with a signed delta" do
      ctx = FakeExecContext.new
      r["probe.down"].call(ctx)
      ctx.args_for(:probe_move).should eq(["1"])
      ctx = FakeExecContext.new
      r["probe.up"].call(ctx)
      ctx.args_for(:probe_move).should eq(["-1"])
    end

    it "claims one distinct chord per triage action" do
      # A collision here is invisible at runtime (the keymap takes one, the other is dead),
      # so the mapping is asserted key-by-key.
      {"probe.filter"            => "/",
       "probe.mode"              => "m",
       "probe.dismiss-selected"  => "c",
       "probe.toggle-closed"     => "a",
       "probe.open-evidence"     => "o",
       "probe.repeater-evidence" => "r",
       "probe.promote-selected"  => "p",
       "probe.delete-selected"   => "d",
       "probe.clear"             => "x",
      }.each do |id, key|
        r[id].scope.should eq(Gori::Verb::Scope::Probe)
        r[id].chords.should eq([Gori::Verb::Chord.new(key)])
      end
      r["probe.open"].chords.first.should eq(Gori::Verb::Chord.new("enter"))
      r["probe.open"].menu_key.should eq('v') # 'o' is reserved for open-evidence
      r["probe.scope-toggle"].chords.should eq([Gori::Verb::Chord.new("s", shift: true)])
    end

    it "routes each list action to its own intent" do
      {"probe.open"              => :probe_open,
       "probe.filter"            => :probe_query,
       "probe.mode"              => :probe_set_mode,
       "probe.dismiss-selected"  => :probe_dismiss,
       "probe.toggle-closed"     => :probe_toggle_closed,
       "probe.scope-toggle"      => :scope_toggle_lens,
       "probe.dismiss-code"      => :probe_dismiss_code,
       "probe.dismiss-host"      => :probe_dismiss_host,
       "probe.open-evidence"     => :probe_open_flow,
       "probe.repeater-evidence" => :probe_repeater_flow,
       "probe.active-rescan"     => :probe_active_rescan,
       "probe.promote-selected"  => :probe_promote,
       "probe.delete-selected"   => :probe_delete,
       "probe.clear"             => :probe_clear,
      }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
    end

    it "keeps the BULK dismissals menu-only, so no stray key mutes a whole host" do
      %w[probe.dismiss-code probe.dismiss-host probe.active-rescan].each do |id|
        r[id].chords.should be_empty
      end
      r["probe.dismiss-code"].menu_key.should eq('g')
      r["probe.dismiss-host"].menu_key.should eq('h')
      r["probe.active-rescan"].menu_key.should eq('A') # lowercase 'a' is toggle-closed
    end

    it "returns focus to the tab menu on escape" do
      ctx = FakeExecContext.new
      r["probe.leave"].call(ctx)
      ctx.args_for(:focus_pane).should eq(["menu"])
      r["probe.leave"].hidden?.should be_true
    end
  end

  describe "the issue detail" do
    it "mirrors the list's actions on the same keys, in the ProbeDetail scope" do
      {"probe.open-flow"     => {:probe_open_flow, "o"},
       "probe.repeater-flow" => {:probe_repeater_flow, "r"},
       "probe.promote"       => {:probe_promote, "p"},
       "probe.dismiss"       => {:probe_dismiss, "c"},
       "probe.delete"        => {:probe_delete, "d"},
      }.each do |id, (intent, key)|
        r[id].scope.should eq(Gori::Verb::Scope::ProbeDetail)
        r[id].chords.should eq([Gori::Verb::Chord.new(key)])
        verb_intents(r, id).should eq([intent])
      end
      verb_intents(r, "probe.close").should eq([:probe_close])
    end
  end

  describe "the Rules sub-tab" do
    it "leaves toggle and add ungated — every rule can be enabled or disabled" do
      ctx = FakeExecContext.new
      r["probe-rules.toggle"].available?(ctx).should be_true
      r["probe-rules.add"].available?(ctx).should be_true
      r["probe-rules.toggle"].menu_key.should eq('t') # enter/x are its chords
      verb_intents(r, "probe-rules.toggle").should eq([:probe_rule_toggle])
      verb_intents(r, "probe-rules.add").should eq([:probe_rule_add])
    end

    it "gates edit and delete on a CUSTOM rule being selected" do
      # Built-ins can only be toggled; offering Edit/Delete on one would be a dead action.
      ctx = FakeExecContext.new
      r["probe-rules.edit"].available?(ctx).should be_false
      r["probe-rules.delete"].available?(ctx).should be_false
      ctx.probe_has_custom_rule = true
      r["probe-rules.edit"].available?(ctx).should be_true
      r["probe-rules.delete"].available?(ctx).should be_true
      verb_intents(r, "probe-rules.edit").should eq([:probe_rule_edit])
      verb_intents(r, "probe-rules.delete").should eq([:probe_rule_delete])
    end
  end
end
