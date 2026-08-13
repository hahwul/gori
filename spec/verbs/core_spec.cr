require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/core.cr — the app-wide verbs (quit/palette/capture/CA/settings/scope/
# intercept/tab nav). Two things are asserted per verb: the INTENT it dispatches on the
# recording ExecContext, and its `available?` gate (P4), which had no test at all.
describe "Gori::Verbs.register_core" do
  r = Gori::Verbs.registry

  describe "app lifecycle" do
    it "keeps 'q' → projects on the tab bar only, with the palette entry Global" do
      # The Global entry deliberately carries NO chord: as a Global chord, `q` dumped the
      # user to the picker from mid-browse in Sitemap/Issues (a one-key dead-end).
      r["app.back"].scope.should eq(Gori::Verb::Scope::Global)
      r["app.back"].chords.should be_empty
      r["app.back"].hidden?.should be_false

      key = r["app.back-key"]
      key.scope.should eq(Gori::Verb::Scope::Sidebar)
      key.chords.should eq([Gori::Verb::Chord.new("q")])
      key.hidden?.should be_true # same action, so only one of the two lists in the palette

      verb_intents(r, "app.back").should eq([:leave_project])
      verb_intents(r, "app.back-key").should eq([:leave_project])
    end

    it "leaves Quit palette-only — the keyboard path is a deliberate double ^D/^C" do
      r["app.quit"].chords.should be_empty
      r["app.quit"].category.should eq(Gori::Verb::Category::System)
      verb_intents(r, "app.quit").should eq([:quit!])
    end

    it "binds the palette to ctrl-p and the notification centre to no chord" do
      r["app.palette"].chords.should eq([Gori::Verb::Chord.new("p", ctrl: true)])
      verb_intents(r, "app.palette").should eq([:open_palette])
      r["app.notifications"].chords.should be_empty
      verb_intents(r, "app.notifications").should eq([:open_notifications])
    end

    it "routes capture / reveal-whitespace / refresh to their own intents" do
      verb_intents(r, "capture.toggle").should eq([:toggle_capture])
      verb_intents(r, "view.reveal-ws").should eq([:toggle_reveal])
      verb_intents(r, "view.refresh").should eq([:refresh_screen])
    end

    it "keeps the destructive CA verbs palette-only (no chord to fat-finger)" do
      %w[ca.export ca.regenerate ca.import browser.open].each { |id| r[id].chords.should be_empty }
      verb_intents(r, "ca.export").should eq([:export_ca])
      verb_intents(r, "ca.regenerate").should eq([:regenerate_ca])
      verb_intents(r, "ca.import").should eq([:import_ca])
      verb_intents(r, "browser.open").should eq([:open_browser_picker])
    end
  end

  describe "settings" do
    # Palette entries and the Settings tab's groups both read Tui::SettingsCatalog; a
    # section registered without a verb (or a verb passing the wrong sym) silently makes
    # that section unreachable from Ctrl-P.
    it "registers one Settings verb per catalog section, passing that section's sym" do
      Gori::Tui::SettingsCatalog.all.each do |s|
        verb = r[s.id]
        verb.category.should eq(Gori::Verb::Category::Settings)
        verb.scope.should eq(Gori::Verb::Scope::Global)
        ctx = FakeExecContext.new
        verb.call(ctx)
        ctx.call_names.should eq([:open_settings])
        ctx.args_for(:open_settings).should eq([s.sym.to_s])
      end
    end

    it "opens the unified Preferences modal from settings.open" do
      verb_intents(r, "settings.open").should eq([:open_preferences])
    end
  end

  describe "scope" do
    it "toggles the lens from anywhere with bare 's' and jumps to the editor via the palette" do
      r["scope.toggle-lens"].chords.should eq([Gori::Verb::Chord.new("s")])
      verb_intents(r, "scope.toggle-lens").should eq([:scope_toggle_lens])
      r["scope.edit"].chords.should be_empty
      verb_intents(r, "scope.edit").should eq([:scope_open])
    end

    it "exposes the sandbox gate to the palette as its own Global, chordless verb" do
      verb = r["scope.toggle-sandbox"]
      verb.scope.should eq(Gori::Verb::Scope::Global) # palette-visible
      verb.chords.should be_empty                     # bare-Global budget is c/i/s; a block gate gets no keypress
      verb_intents(r, "scope.toggle-sandbox").should eq([:scope_toggle_sandbox])
      # Distinct intents: the lens filters the view, the sandbox blocks traffic.
      verb_intents(r, "scope.toggle-lens").should_not contain(:scope_toggle_sandbox)
    end

    it "gates scope.add-host on the History tab AND a selected flow" do
      verb = r["scope.add-host"]
      ctx = FakeExecContext.new # :history, nothing selected
      verb.available?(ctx).should be_false
      ctx.selected = 7_i64
      verb.available?(ctx).should be_true
      ctx.current_tab = :repeater
      verb.available?(ctx).should be_false
      verb_intents(r, "scope.add-host").should eq([:scope_add_host])
    end

    it "gates the Body scope toggle on the History tab, selection or not" do
      verb = r["scope.toggle"]
      ctx = FakeExecContext.new
      verb.available?(ctx).should be_true # no selection needed — it filters the whole list
      ctx.current_tab = :sitemap
      verb.available?(ctx).should be_false
    end

    it "gates the Project pane's edit/delete on a selected rule, but not add" do
      ctx = FakeExecContext.new
      r["scope.add-rule"].available?(ctx).should be_true
      r["scope.edit-rule"].available?(ctx).should be_false
      r["scope.delete-rule"].available?(ctx).should be_false
      ctx.scope_has_rule = true
      r["scope.edit-rule"].available?(ctx).should be_true
      r["scope.delete-rule"].available?(ctx).should be_true

      verb_intents(r, "scope.add-rule").should eq([:scope_add_rule])
      verb_intents(r, "scope.edit-rule").should eq([:scope_edit_rule])
      verb_intents(r, "scope.delete-rule").should eq([:scope_delete_rule])
      verb_intents(r, "scope.lens-toggle").should eq([:scope_toggle_lens])
    end
  end

  describe "project description copy" do
    # BARE 'y' stays chordless: ProjectController raw-dispatches it in the description pane and
    # handle_body_key returns true there, so the shared Keymap is never consulted — a bare chord
    # could only ever be dead weight in the rebind editor. The mnemonic mirrors that real key.
    #
    # `^Y` IS registered, because that raw dispatch only covers READ. In INS a bare `y` is a
    # literal character (and typing it over a ⇧arrow selection REPLACES it), so the ctrl form is
    # the only way to copy without leaving the mode.
    it "carries the 'y' menu key with only the ctrl chord, in its own scope, gated on tab AND pane" do
      verb = r["project.copy"]
      verb.chords.should eq([Gori::Verb::Chord.new("y", ctrl: true)])
      verb.menu_key.should eq('y')
      verb.scope.should eq(Gori::Verb::Scope::ProjectDesc) # NOT Body — see the History list
      ctx = FakeExecContext.new
      ctx.current_tab = :project
      verb.available?(ctx).should be_false # neither read mode nor a focused editor
      ctx.project_desc_read_mode = true
      verb.available?(ctx).should be_true
      ctx.current_tab = :history
      verb.available?(ctx).should be_false # pane flag alone must not leak it into History
      verb_intents(r, "project.copy").should eq([:read_copy])
    end

    # The INS half: with the pane in INSERT (read_mode false) the verb must still be available,
    # or `^Y` would be a dead key in exactly the mode that needs it.
    it "is available while the description editor is focused in INS, and still tab-gated" do
      verb = r["project.copy"]
      ctx = FakeExecContext.new
      ctx.current_tab = :project
      ctx.project_desc_read_mode = false
      ctx.editor_focused = true
      verb.available?(ctx).should be_true
      ctx.current_tab = :history
      verb.available?(ctx).should be_false
    end
  end

  describe "intercept" do
    it "binds the Global toggle to bare 'i'" do
      r["intercept.toggle"].chords.should eq([Gori::Verb::Chord.new("i")])
      verb_intents(r, "intercept.toggle").should eq([:intercept_toggle])
    end

    it "gates forward / drop / forward-all on a held message being selected" do
      ctx = FakeExecContext.new # nothing held
      %w[intercept.forward intercept.drop intercept.forward-all].each do |id|
        r[id].available?(ctx).should be_false
        r[id].scope.should eq(Gori::Verb::Scope::Intercept)
      end
      ctx.intercept_selected = 3_i64
      %w[intercept.forward intercept.drop intercept.forward-all].each do |id|
        r[id].available?(ctx).should be_true
      end
      verb_intents(r, "intercept.forward").should eq([:intercept_forward])
      verb_intents(r, "intercept.drop").should eq([:intercept_drop])
      verb_intents(r, "intercept.forward-all").should eq([:intercept_forward_all])
    end

    it "leaves the catch controls ungated (they configure the queue, not a row)" do
      ctx = FakeExecContext.new
      r["intercept.direction"].available?(ctx).should be_true
      r["intercept.filter"].available?(ctx).should be_true
      verb_intents(r, "intercept.direction").should eq([:intercept_cycle_direction])
      verb_intents(r, "intercept.filter").should eq([:intercept_query])
    end

    # Multi-select over the hold queue — the History list's model on the same keys. Marks are
    # pruned the moment a hold leaves the queue, so a mark set always implies a cursor row:
    # the existing `intercept_selected` gate is already the target-set gate.
    describe "marks" do
      it "registers the mark gestures on keys free across Scope::Intercept" do
        r["intercept.mark-toggle"].chords.map(&.label).should eq(["t"])
        r["intercept.mark-toggle"].menu_key.should eq('t')
        # Chord.new("t", shift: true), never Chord.new("T") — Keybind.from_event normalises a
        # typed capital to shift+lowercase, so a "T" chord could never fire.
        r["intercept.mark-all"].chords.should eq([Gori::Verb::Chord.new("t", shift: true)])
        r["intercept.mark-all"].menu_key.should eq('T')
        r["intercept.mark-clear"].chords.should be_empty
        r["intercept.mark-clear"].menu_key.should eq('N')
        %w[intercept.mark-toggle intercept.mark-all intercept.mark-clear].each do |id|
          r[id].scope.should eq(Gori::Verb::Scope::Intercept)
        end
      end

      it "gates toggle/mark-all on a held message, like forward and drop" do
        ctx = FakeExecContext.new # nothing held
        r["intercept.mark-toggle"].available?(ctx).should be_false
        r["intercept.mark-all"].available?(ctx).should be_false
        ctx.intercept_selected = 3_i64
        r["intercept.mark-toggle"].available?(ctx).should be_true
        r["intercept.mark-all"].available?(ctx).should be_true
        verb_intents(r, "intercept.mark-toggle").should eq([:intercept_mark_toggle])
        verb_intents(r, "intercept.mark-all").should eq([:intercept_mark_all])
      end

      it "offers clear-marks only while something is marked" do
        ctx = FakeExecContext.new
        ctx.intercept_selected = 3_i64 # held, but nothing marked yet
        r["intercept.mark-clear"].available?(ctx).should be_false
        ctx.marked_intercept = 2
        r["intercept.mark-clear"].available?(ctx).should be_true
        verb_intents(r, "intercept.mark-clear").should eq([:intercept_mark_clear])
      end

      # ⇧↑/⇧↓ took these over from the read-only preview's vertical scroll (now PgUp/PgDn),
      # so the queue reads ⇧arrow as "extend the selection" like every other list in the TUI.
      it "extends the range on shift+arrows — hidden nav, gated on a held message" do
        {"intercept.mark-extend-up" => "shift-up", "intercept.mark-extend-down" => "shift-down"}.each do |id, label|
          v = r[id]
          v.chords.map(&.label).should eq([label])
          v.hidden?.should be_true # a nav primitive, like body.up/body.down
          v.menu_key.should be_nil # …so it never shows in the space menu
          v.available?(FakeExecContext.new).should be_false
          v.available?(FakeExecContext.new.tap { |c| c.intercept_selected = 1_i64 }).should be_true
        end
        verb_intents(r, "intercept.mark-extend-down").should eq([:intercept_mark_extend])
        FakeExecContext.new.tap { |c| r["intercept.mark-extend-up"].call(c) }
          .args_for(:intercept_mark_extend).should eq(["-1"])
      end
    end
  end

  describe "navigation" do
    it "cycles tabs with the bracket chords" do
      ctx = FakeExecContext.new
      r["nav.next-tab"].call(ctx)
      ctx.args_for(:cycle_tab).should eq(["1"])
      ctx = FakeExecContext.new
      r["nav.prev-tab"].call(ctx)
      ctx.args_for(:cycle_tab).should eq(["-1"])
    end

    it "binds digits 1..9 to the Nth VISIBLE tab, hidden from the palette" do
      (1..9).each do |n|
        verb = r["nav.pos#{n}"]
        verb.hidden?.should be_true
        verb.chords.should eq([Gori::Verb::Chord.new(n.to_s)])
        ctx = FakeExecContext.new
        verb.call(ctx)
        ctx.args_for(:focus_visible_tab).should eq([n.to_s])
      end
    end

    it "keeps a named 'Go to' verb for every catalog tab, including the hidden ones" do
      # focus_tab force-shows a tab hidden in settings:tabs, so these are the only way to
      # reach Miner/Sequencer by command when the user has hidden them.
      %w[project target history intercept repeater fuzzer miner oast sequencer
        decoder jwt comparer probe issues notes rewriter help].each do |tab|
        ctx = FakeExecContext.new
        verb = r["tab.#{tab}"]
        verb.category.should eq(Gori::Verb::Category::Navigation)
        verb.call(ctx)
        ctx.call_names.should eq([:focus_tab])
        ctx.args_for(:focus_tab).should eq([tab])
      end
      r["tab.help"].chords.should eq([Gori::Verb::Chord.new("?")])
      verb_intents(r, "tab.discover").should eq([:goto_discover]) # a Target sub-tab, not a tab
    end

    it "walks the focus ring: sidebar ↔ body, and closes the palette overlay" do
      verb_intents(r, "sidebar.prev").should eq([:menu_left])
      verb_intents(r, "sidebar.next").should eq([:menu_right])
      verb_intents(r, "sidebar.enter").should eq([:enter_content])
      verb_intents(r, "palette.close").should eq([:close_overlay])

      ctx = FakeExecContext.new
      r["body.to-menu"].call(ctx)
      ctx.args_for(:focus_pane).should eq(["menu"])
    end

    it "opens the Rewriter tab from the familiar 'Match & Replace' palette name" do
      r["rules.edit"].title.should eq("Match & Replace")
      ctx = FakeExecContext.new
      r["rules.edit"].call(ctx)
      ctx.args_for(:focus_tab).should eq(["rewriter"])
    end
  end
end
