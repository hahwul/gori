require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/issues.cr — the Issues list, the issue detail, and the two export verbs.
describe "Gori::Verbs.register_issues" do
  r = Gori::Verbs.registry

  describe "creating from a flow" do
    it "gates issue.create on the History tab AND a selected flow" do
      verb = r["issue.create"]
      ctx = FakeExecContext.new
      verb.available?(ctx).should be_false
      ctx.selected = 5_i64
      verb.available?(ctx).should be_true
      ctx.current_tab = :issues
      verb.available?(ctx).should be_false
      verb.chords.should eq([Gori::Verb::Chord.new("f", shift: true)])
      verb_intents(r, "issue.create").should eq([:issue_create])
    end
  end

  describe "the issues list" do
    it "moves the selection with a signed delta" do
      ctx = FakeExecContext.new
      r["issues.down"].call(ctx)
      ctx.args_for(:issues_move).should eq(["1"])
      ctx = FakeExecContext.new
      r["issues.up"].call(ctx)
      ctx.args_for(:issues_move).should eq(["-1"])
    end

    it "keeps open/new/delete visible so they front the list's space menu" do
      # The palette is Global-only, so a non-hidden Issues-scope verb cannot leak there.
      %w[issues.open issues.new issues.delete issues.export-key].each do |id|
        r[id].hidden?.should be_false
        r[id].scope.should eq(Gori::Verb::Scope::Issues)
      end
      # open's primary chord is enter/l — 'l' would front the menu unintuitively, so it
      # carries an explicit 'o'.
      r["issues.open"].menu_key.should eq('o')
      verb_intents(r, "issues.open").should eq([:issues_open])
      verb_intents(r, "issues.new").should eq([:issues_new])
      verb_intents(r, "issues.delete").should eq([:issues_delete])
      verb_intents(r, "issues.filter").should eq([:issues_query])
    end

    it "returns focus to the tab menu on escape only (← was a tab-bar overshoot)" do
      verb = r["issues.leave"]
      verb.chords.should eq([Gori::Verb::Chord.new("escape")])
      ctx = FakeExecContext.new
      verb.call(ctx)
      ctx.args_for(:focus_pane).should eq(["menu"])
    end
  end

  describe "the issue detail" do
    it "cycles severity and status with signed deltas on the bracket/brace chords" do
      {"issue.severity-up"   => {:issue_severity, "1", "]"},
       "issue.severity-down" => {:issue_severity, "-1", "["},
       "issue.status-up"     => {:issue_status, "1", "}"},
       "issue.status-down"   => {:issue_status, "-1", "{"},
      }.each do |id, (intent, delta, key)|
        verb = r[id]
        verb.hidden?.should be_true # power shortcut; the pickers are the discoverable path
        verb.chords.should eq([Gori::Verb::Chord.new(key)])
        ctx = FakeExecContext.new
        verb.call(ctx)
        ctx.args_for(intent).should eq([delta])
      end
    end

    it "puts the severity/status PICKERS on the space menu with no chord" do
      # Chordless on purpose: arrows must never change triage state by accident.
      r["issue.set-severity"].chords.should be_empty
      r["issue.set-severity"].menu_key.should eq('s')
      r["issue.set-status"].chords.should be_empty
      r["issue.set-status"].menu_key.should eq('c')
      verb_intents(r, "issue.set-severity").should eq([:issue_set_severity])
      verb_intents(r, "issue.set-status").should eq([:issue_set_status])
    end

    it "gates Copy on the notes pane being in read mode" do
      ctx = FakeExecContext.new
      r["issue.copy"].available?(ctx).should be_false
      ctx.issues_notes_read_mode = true
      r["issue.copy"].available?(ctx).should be_true
      verb_intents(r, "issue.copy").should eq([:read_copy])
    end

    it "scrolls a long notes line with SHIFT+←/→, leaving plain ← to close" do
      # issue.close owns plain ←/h; the h-scroll chords carry shift, so they don't collide.
      r["issue.hscroll-right"].chords.should eq([Gori::Verb::Chord.new("right", shift: true)])
      r["issue.hscroll-left"].chords.should eq([Gori::Verb::Chord.new("left", shift: true)])
      r["issue.close"].chords.should contain(Gori::Verb::Chord.new("left"))
      ctx = FakeExecContext.new
      r["issue.hscroll-right"].call(ctx)
      ctx.args_for(:issue_hscroll).should eq(["1"])
      ctx = FakeExecContext.new
      r["issue.hscroll-left"].call(ctx)
      ctx.args_for(:issue_hscroll).should eq(["-1"])
    end

    it "routes the detail actions to their own intents" do
      {"issue.close"         => :issue_close,
       "issue.edit-notes"    => :issue_edit_notes,
       "issue.edit-title"    => :issue_edit_title,
       "issue.open-flow"     => :issue_open_flow,
       "issue.repeater-flow" => :issue_repeater_flow,
       "issue.delete"        => :issues_delete,
       "issue.links"         => :issue_links,
       "issue.open-link"     => :issue_open_link,
      }.each { |id, intent| verb_intents(r, id).should eq([intent]) }

      ctx = FakeExecContext.new
      r["issue.link-down"].call(ctx)
      ctx.args_for(:issue_link_move).should eq(["1"])
      ctx = FakeExecContext.new
      r["issue.link-up"].call(ctx)
      ctx.args_for(:issue_link_move).should eq(["-1"])
    end
  end

  describe "export" do
    it "passes the right format symbol per export verb" do
      {"issues.export-md" => "markdown", "issues.export-json" => "json"}.each do |id, format|
        r[id].scope.should eq(Gori::Verb::Scope::Global) # palette-reachable from anywhere
        ctx = FakeExecContext.new
        r[id].call(ctx)
        ctx.call_names.should eq([:issues_export])
        ctx.args_for(:issues_export).should eq([format])
      end
    end

    it "defaults the Issues-scope export key to the human-readable Markdown report" do
      verb = r["issues.export-key"]
      verb.scope.should eq(Gori::Verb::Scope::Issues)
      ctx = FakeExecContext.new
      verb.call(ctx)
      ctx.args_for(:issues_export).should eq(["markdown"])
    end

    it "binds export to ⇧E — the SAME key Notes uses — and leaves 'x' to Select line" do
      # 'x' means "Select line" in all nine read_edit.cr scopes, including the Issues DETAIL
      # one ↵ away; the list's old 'x' export was the lone exception and collided with its
      # own tab. Sharing 'E' with notes.export makes export one key across tabs.
      verb = r["issues.export-key"]
      verb.menu_key.should eq('E')
      verb.menu_key.should eq(r["notes.export"].menu_key)
      verb.hidden?.should be_false

      # Chord.new("E") would be DEAD: Keybind.from_event normalises a typed capital to
      # shift + lowercase, so the stored chord has to be the shift form.
      verb.chords.should eq([Gori::Verb::Chord.new("e", shift: true)])
      verb.chords.map(&.key).should_not contain("x")

      # …and nothing in the Issues list scope claims 'x' any more.
      r.select(&.scope.issues?).compact_map(&.menu_key).should_not contain('x')
    end

    it "keeps all three entries on the SAME intent now that the path comes from a popup" do
      # The destination moved from a hardcoded <project dir>/issues.{md,json} to an
      # ExportOverlay prompt, but that is purely a shell concern: the verb ids, scopes,
      # chords and the issues_export(format) signature all had to stay put, so anything
      # bound to them (palette entries, user keybindings, the MCP/CLI surfaces) is untouched.
      %w[issues.export-md issues.export-json issues.export-key].each do |id|
        ctx = FakeExecContext.new
        r[id].call(ctx)
        ctx.call_names.should eq([:issues_export])
      end
    end
  end
end
