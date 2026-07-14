require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

describe Gori::Tui::SpaceMenu do
  it "lists ONLY the focused area's own verbs that carry a menu key" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64 # flow-gated Body actions available
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.body?).should be_true         # strictly scope-local
    menu.entries.all?(&.menu_key).should be_true            # every shown entry has a key
    menu.entries.map(&.id).should contain("history.repeater") # an area action
    menu.entries.map(&.id).should_not contain("app.quit")   # NOT the app-control (palette) surface
  end

  it "resolves a mnemonic key to its verb (and nil for an unmapped key)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx)

    menu.verb_for('y').try(&.id).should eq("history.copy")
    menu.verb_for('r').try(&.id).should eq("history.repeater")
    menu.verb_for('Q').should be_nil # no entry bound to this key
  end

  it "moves the selection within entries (clamped both ends)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx)

    menu.move(-5)
    menu.selected.should eq(0)
    menu.move(99)
    menu.selected.should eq(menu.entries.size - 1)
  end

  it "lists the open flow's actions in the History detail scope (mirrors the list menu)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::HistoryDetail, :common, ctx) # detail drill-in is navigable now

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.history_detail?).should be_true # strictly scope-local
    ids = menu.entries.map(&.id)
    ids.should contain("detail.repeater")     # flow action carried over from the list
    ids.should contain("detail.toggle-hex") # a detail-only view toggle
    menu.verb_for('r').try(&.id).should eq("detail.repeater")
    menu.verb_for('x').try(&.id).should eq("detail.toggle-hex")
  end

  it "lists the scope-rule actions in the Project scope pane (space replaced the lens toggle)" do
    ctx = FakeExecContext.new
    ctx.scope_has_rule = true # edit/delete are gated on a selected rule
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Project, :common, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("scope.lens-toggle") # the lens toggle is now a menu item, not a bare space key
    ids.should contain("scope.add-rule")
    ids.should contain("scope.edit-rule")
    ids.should contain("scope.delete-rule")
    menu.verb_for('s').try(&.id).should eq("scope.lens-toggle")
    menu.verb_for('a').try(&.id).should eq("scope.add-rule")
  end

  it "lists env-var actions (not scope rules) in the Project ENV pane, with change-prefix" do
    ctx = FakeExecContext.new
    ctx.env_has_var = true # edit/delete are gated on a selected var
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Env, :common, ctx)

    menu.entries.all?(&.scope.env?).should be_true # strictly scope-local — no scope-rule bleed
    menu.entries.all?(&.menu_key).should be_true
    ids = menu.entries.map(&.id)
    ids.should contain("env.add-var")
    ids.should contain("env.edit-var")
    ids.should contain("env.delete-var")
    ids.should contain("env.edit-prefix")
    ids.should_not contain("scope.add-rule") # the old, wrong menu is gone
    menu.verb_for('a').try(&.id).should eq("env.add-var")
    menu.verb_for('p').try(&.id).should eq("env.edit-prefix")
  end

  it "hides the env-var edit/delete entries when no var is selected" do
    ctx = FakeExecContext.new # env_has_var defaults to false
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Env, :common, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("env.add-var")     # always available
    ids.should contain("env.edit-prefix") # always available
    ids.should_not contain("env.edit-var")
    ids.should_not contain("env.delete-var")
  end

  it "lists the Notes tab's actions in the Notes scope (reachable from the sub-tab strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :notes
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Notes, :common, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.notes?).should be_true
    menu.entries.all?(&.menu_key).should be_true
    ids = menu.entries.map(&.id)
    ids.should contain("notes.new")
    ids.should contain("notes.close")
    ids.should contain("notes.copy")
    ids.should contain("notes.select-line")
    menu.verb_for('y').try(&.id).should eq("notes.copy")
    menu.verb_for('x').try(&.id).should eq("notes.select-line")
    menu.verb_for('n').try(&.id).should eq("notes.new")
    menu.verb_for('w').try(&.id).should eq("notes.close")
  end

  it "lists the Probe list's detail-parity actions (promote, evidence, delete)" do
    ctx = FakeExecContext.new
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Probe, :common, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("probe.promote-selected")
    ids.should contain("probe.open-evidence")
    ids.should contain("probe.repeater-evidence")
    ids.should contain("probe.delete-selected")
    menu.verb_for('p').try(&.id).should eq("probe.promote-selected")
    menu.verb_for('o').try(&.id).should eq("probe.open-evidence")
    menu.verb_for('r').try(&.id).should eq("probe.repeater-evidence")
    menu.verb_for('d').try(&.id).should eq("probe.delete-selected")
    menu.verb_for('v').try(&.id).should eq("probe.open")
    menu.verb_for('g').try(&.id).should eq("probe.dismiss-code")
  end

  it "lists the Decoder tab's actions in the Decoder scope (reachable from the sub-tab strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :decoder   # the Decoder verbs gate on the active tab
    ctx.decoder_read_mode = true # so COMMON's Copy is available too
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Decoder, :common, ctx)

    menu.entries.size.should be > 0
    menu.entries.all?(&.scope.decoder?).should be_true # strictly scope-local
    menu.entries.all?(&.menu_key).should be_true       # every shown entry has a key
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.copy") # the single smart Copy (copy-all is gone)
    menu.verb_for('y').try(&.id).should eq("decoder.copy")
  end

  it "keeps Decoder's New/Close in COMMON (Round 4) so they show from every context, not just the tab bar/strip" do
    ctx = FakeExecContext.new
    ctx.current_tab = :decoder
    ctx.decoder_read_mode = true # so COMMON's Copy shows too, for a fuller COMMON+CONTEXT picture
    menu = SpaceMenu.new(Gori::Verbs.registry)

    # Tab-bar focus (@focus == :menu): Round 5 moved Save/Load to :tab (session-level),
    # so this is now COMMON + a real TAB group — New/Close/Copy/Save/Load all present.
    menu.open(Gori::Verb::Scope::Decoder, :tab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.copy")
    ids.should contain("decoder.new")
    ids.should contain("decoder.close")
    ids.should contain("decoder.save")
    ids.should contain("decoder.load")
    menu.verb_for('n').try(&.id).should eq("decoder.new")
    menu.verb_for('w').try(&.id).should eq("decoder.close")
    menu.verb_for('s').try(&.id).should eq("decoder.save")
    menu.verb_for('o').try(&.id).should eq("decoder.load")

    # Sub-tab strip focus (@focus == :subtabs): Decoder now has its OWN :subtab verbs
    # (rename + duplicate, mirroring Repeater/Fuzzer) — COMMON + SUBTAB, New/Close/Copy/
    # Rename/Duplicate all reachable from the strip.
    menu.open(Gori::Verb::Scope::Decoder, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.copy")
    ids.should contain("decoder.new")
    ids.should contain("decoder.close")
    ids.should contain("decoder.rename-subtab")
    ids.should contain("decoder.duplicate-subtab")
    menu.verb_for('e').try(&.id).should eq("decoder.rename-subtab")
    menu.verb_for('d').try(&.id).should eq("decoder.duplicate-subtab")
    ids.should_not contain("decoder.save") # :tab-only, not :subtab — no bleed

    # Body-pane focus: OUTPUT gets Cycle output mode + COMMON's New/Close/Copy —
    # the whole point of Round 4 is New/Close now show INSIDE the body panes too.
    menu.open(Gori::Verb::Scope::Decoder, :output, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.mode")
    ids.should contain("decoder.new")
    ids.should contain("decoder.close")
    ids.should_not contain("decoder.save") # a DIFFERENT group (:tab) — no bleed

    # CHAIN pane: Round 5 moved Save/Load OUT of :chain (into :tab), so CHAIN has no
    # actions of its own left — falls back to a flat COMMON-only render (the
    # single-group-omits-header rule), same as a single-region tab.
    menu.open(Gori::Verb::Scope::Decoder, :chain, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.new")
    ids.should contain("decoder.close")
    ids.should_not contain("decoder.save")
    ids.should_not contain("decoder.mode")
  end

  it "yields COMMON + the focus-area's own group when opened with a non-common section (Repeater), and a single flat group for :common" do
    ctx = FakeExecContext.new
    ctx.current_tab = :repeater
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Repeater, :request, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("repeater.send")           # COMMON
    ids.should contain("repeater.insert-marker")  # :request
    ids.should_not contain("repeater.toggle-sni") # a DIFFERENT section (:target) — no bleed
    menu.verb_for('i').try(&.id).should eq("repeater.insert-marker")

    backend = MemoryBackend.new(100, 30)
    menu.render(Screen.new(backend), Rect.new(0, 0, 100, 28))
    backend.contains?("SPACE · REQUEST").should be_true # card title carries the section label
    backend.contains?("COMMON").should be_true          # dim group header
    backend.contains?("REQUEST").should be_true

    # :common alone → single flat group: no header, no :request bleed.
    menu.open(Gori::Verb::Scope::Repeater, :common, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("repeater.send")
    ids.should_not contain("repeater.insert-marker")

    backend2 = MemoryBackend.new(100, 30)
    menu.render(Screen.new(backend2), Rect.new(0, 0, 100, 28))
    backend2.contains?("SPACE · COMMON").should be_false # flat render — no section suffix
  end

  it "yields COMMON + the focus-area's own group when opened with a non-common section (Fuzzer)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :fuzzer
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Fuzzer, :template, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("fuzz.run")      # COMMON
    ids.should contain("fuzz.new")      # Round 5: New moved into COMMON, so it's here too
    ids.should contain("fuzz.automark") # :template
    menu.verb_for('m').try(&.id).should eq("fuzz.automark")

    # Round 5: fuzz.new moved :tab → :common, so Fuzzer no longer has any :tab-only
    # verbs — the tab bar now falls back to a flat COMMON-only render (same rule that
    # already covered Decoder's tab bar pre-Round-5), New/Run/Stop/Copy all present.
    menu.open(Gori::Verb::Scope::Fuzzer, :tab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("fuzz.run")
    ids.should contain("fuzz.new")
    ids.should_not contain("fuzz.automark") # :template-only — no bleed
    menu.verb_for('n').try(&.id).should eq("fuzz.new")
  end

  it "populates Repeater's :subtab group with rename/close/duplicate (Round 4 — was raw key-dispatch)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :repeater
    ctx.repeater_tab_count = 1 # gate duplicate availability
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Repeater, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("repeater.send")              # COMMON
    ids.should contain("repeater.rename-subtab")     # :subtab
    ids.should contain("repeater.close-subtab")      # :subtab
    ids.should contain("repeater.duplicate-subtab")  # :subtab
    ids.should_not contain("repeater.insert-marker") # a DIFFERENT section (:request) — no bleed
    menu.verb_for('e').try(&.id).should eq("repeater.rename-subtab")
    menu.verb_for('w').try(&.id).should eq("repeater.close-subtab")
    menu.verb_for('d').try(&.id).should eq("repeater.duplicate-subtab")
  end

  it "populates Repeater's :response group with diff/hex alongside pretty (Round 4 — was raw key-dispatch)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :repeater
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Repeater, :response, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("repeater.send")            # COMMON
    ids.should contain("repeater.toggle-pretty")   # :response
    ids.should contain("repeater.toggle-diff")     # :response
    ids.should contain("repeater.toggle-resp-hex") # :response
    menu.verb_for('p').try(&.id).should eq("repeater.toggle-pretty")
    menu.verb_for('d').try(&.id).should eq("repeater.toggle-diff")
    menu.verb_for('x').try(&.id).should eq("repeater.toggle-resp-hex")
  end

  it "populates Fuzzer's :subtab group with rename/close/duplicate (Round 4 — was raw key-dispatch)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :fuzzer
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Fuzzer, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("fuzz.run")              # COMMON
    ids.should contain("fuzz.rename-subtab")    # :subtab
    ids.should contain("fuzz.close-subtab")     # :subtab
    ids.should contain("fuzz.duplicate-subtab") # :subtab
    ids.should_not contain("fuzz.automark")     # a DIFFERENT section (:template) — no bleed
    menu.verb_for('e').try(&.id).should eq("fuzz.rename-subtab")
    menu.verb_for('w').try(&.id).should eq("fuzz.close-subtab")
    menu.verb_for('d').try(&.id).should eq("fuzz.duplicate-subtab")
  end

  it "populates Decoder's :subtab group with rename/duplicate (asymmetry fix — was flat COMMON, no way to rename from the strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :decoder
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Decoder, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("decoder.new")              # COMMON
    ids.should contain("decoder.rename-subtab")    # :subtab
    ids.should contain("decoder.duplicate-subtab") # :subtab
    ids.should_not contain("decoder.save")         # a DIFFERENT section (:tab) — no bleed
    ids.should_not contain("decoder.mode")         # a DIFFERENT section (:output) — no bleed
    menu.verb_for('e').try(&.id).should eq("decoder.rename-subtab")
    menu.verb_for('d').try(&.id).should eq("decoder.duplicate-subtab")
  end

  it "populates Notes' :subtab group with duplicate (content-only clone from the strip)" do
    ctx = FakeExecContext.new
    ctx.current_tab = :notes
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Notes, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("notes.new")              # COMMON
    ids.should contain("notes.duplicate-subtab") # :subtab
    menu.verb_for('d').try(&.id).should eq("notes.duplicate-subtab")
  end

  it "populates Miner's :subtab group with duplicate" do
    ctx = FakeExecContext.new
    ctx.current_tab = :miner
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Miner, :subtab, ctx)
    ids = menu.entries.map(&.id)
    ids.should contain("mine.run")              # COMMON
    ids.should contain("mine.duplicate-subtab") # :subtab
    menu.verb_for('d').try(&.id).should eq("mine.duplicate-subtab")
  end

  it "offers Send to Repeater on Miner when a finding is selected" do
    ctx = FakeExecContext.new
    ctx.current_tab = :miner
    menu = SpaceMenu.new(Gori::Verbs.registry)

    menu.open(Gori::Verb::Scope::Miner, :common, ctx)
    menu.entries.map(&.id).should_not contain("mine.repeater") # no finding yet

    ctx.miner_has_issue = true
    menu.open(Gori::Verb::Scope::Miner, :common, ctx)
    menu.entries.map(&.id).should contain("mine.repeater")
    menu.verb_for('p').try(&.id).should eq("mine.repeater")
  end

  it "hides the scope rule edit/delete entries when no rule is selected" do
    ctx = FakeExecContext.new # scope_has_rule defaults to false
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Project, :common, ctx)

    ids = menu.entries.map(&.id)
    ids.should contain("scope.lens-toggle") # always available
    ids.should contain("scope.add-rule")    # always available
    ids.should_not contain("scope.edit-rule")
    ids.should_not contain("scope.delete-rule")
  end

  it "no-ops (empty entries) for a scope with only hidden nav verbs" do
    ctx = FakeExecContext.new
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Sidebar, :common, ctx) # tab-bar nav verbs are all hidden
    menu.entries.empty?.should be_true
  end

  it "renders a bottom-right SPACE popup with the mnemonic key + title" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx)

    backend = MemoryBackend.new(80, 24)
    menu.render(Screen.new(backend), Rect.new(0, 3, 80, 20))
    backend.contains?("SPACE").should be_true     # the card title
    backend.contains?("Copy flow").should be_true # an entry title
  end

  it "scrolls to keep the selection on-screen when the popup is shorter than the list" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx)
    menu.entries.size.should be > 4 # Body has ~10 entries

    last = menu.entries.last.title
    first = menu.entries.first.title
    menu.move(menu.entries.size) # clamp to the last entry

    backend = MemoryBackend.new(40, 8)
    menu.render(Screen.new(backend), Rect.new(0, 0, 40, 6)) # short body → only ~4 rows fit
    backend.contains?(last).should be_true                  # scrolled into view
    backend.contains?(first).should be_false                # the top entries scrolled off
  end

  it "grows past the old 12-row cap to fit a busy scope without scrolling (History Body has 13)" do
    # ctx-independent: 15 synthetic entries on a tall body. Old MAX_ROWS=12 clamped the
    # popup to 14 rows (scrolling 3 off); now it grows to fit all 15 (cap 16).
    reg = Gori::Verb::Registry.new
    15.times do |i|
      reg.register(Gori::Verb::Definition.new(
        "demo.#{i}", "Item #{i}", "x", Gori::Verb::Scope::Body, mnemonic: ('a'.ord + i).unsafe_chr) { |_| nil })
    end
    menu = SpaceMenu.new(reg)
    menu.open(Gori::Verb::Scope::Body, :common, FakeExecContext.new)
    menu.entries.size.should eq(15)

    b = menu.box(Rect.new(0, 0, 60, 40)) # tall body — height is entry-bound, not body-bound
    b.h.should eq(15 + 2)                # all 15 rows + frame; the old cap would have clamped to 14

    backend = MemoryBackend.new(60, 40)
    menu.render(Screen.new(backend), Rect.new(0, 0, 60, 40))
    backend.contains?("Item 0").should be_true  # first entry shown
    backend.contains?("Item 14").should be_true # AND the last — nothing clipped
    backend.contains?("▼").should be_false      # so no scroll marker
  end

  it "still draws the scroll marker when the boundary viewport row lands on a group header" do
    reg = Gori::Verb::Registry.new
    2.times do |i|
      reg.register(Gori::Verb::Definition.new(
        "demo.common.#{i}", "Common #{i}", "x", Gori::Verb::Scope::Body,
        mnemonic: ('a'.ord + i).unsafe_chr) { |_| nil }) # default section: :common
    end
    5.times do |i|
      reg.register(Gori::Verb::Definition.new(
        "demo.section.#{i}", "Section #{i}", "x", Gori::Verb::Scope::Body,
        mnemonic: ('k'.ord + i).unsafe_chr, section: :demo) { |_| nil })
    end
    menu = SpaceMenu.new(reg)
    menu.open(Gori::Verb::Scope::Body, :demo, FakeExecContext.new)

    # display_rows: [header COMMON, Common 0, Common 1, header DEMO, Section 0..4]
    # (9 rows). A 6-row body clamps the box to h=6 → viewport=4, so the visible
    # window is rows 0..3 — row 3 (the LAST visible row) is the DEMO header, and
    # "more below" is true (5 more rows past it). The ▼ affordance must still show
    # there — it was previously swallowed by the header branch's early `next`.
    backend = MemoryBackend.new(40, 8)
    menu.render(Screen.new(backend), Rect.new(0, 0, 40, 6))
    backend.contains?("─ DEMO ─").should be_true # confirms the header IS at that row
    backend.contains?("▼").should be_true
  end

  it "draws a ▼ scroll marker when entries are hidden below (short terminal)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Body, :common, ctx) # selection at the top → list clipped at the bottom

    backend = MemoryBackend.new(40, 8)
    menu.render(Screen.new(backend), Rect.new(0, 0, 40, 6)) # ~4 rows fit, 13 entries
    backend.contains?("▼").should be_true                   # "more below" affordance is visible
    backend.contains?("▲").should be_false                  # nothing hidden above at the top
  end

  # Per menu scope, any verb with NO chord at all must carry a mnemonic (else it's
  # unreachable by ANY single key — the oversight this guards). A verb whose only
  # chord is ctrl/shift (e.g. Repeater's ^X/^S/^L toggles, rebindable since the
  # hotkeys feature) legitimately has no single-key handle and is just excluded
  # from the menu. Reads the registry directly to bypass the ctx-gated available?,
  # so coverage is exhaustive.
  #
  # Key collisions are checked PER DISPLAYABLE VIEW (COMMON ∪ one section) rather
  # than scope-wide: sections never render together (SpaceMenu#open shows at most
  # COMMON + one context group), so two DIFFERENT sections may legitimately reuse a
  # key (e.g. Repeater's :target 's' and :tab 's') — only a clash WITHIN a view is a
  # real collision. Mirrors Registry#validate_menu_keys! (registry.cr) as an
  # independent spec-level check.
  it "gives every chordless menu verb a mnemonic, and never collides keys within a displayable view (COMMON ∪ one section)" do
    registry = Gori::Verbs.registry
    menu_scopes = [
      Gori::Verb::Scope::Body, Gori::Verb::Scope::Repeater, Gori::Verb::Scope::Issues,
      Gori::Verb::Scope::Comparer, Gori::Verb::Scope::Fuzzer, Gori::Verb::Scope::Intercept,
      Gori::Verb::Scope::HistoryDetail, Gori::Verb::Scope::IssuesDetail,
      Gori::Verb::Scope::Project, Gori::Verb::Scope::Decoder, Gori::Verb::Scope::Notes,
      Gori::Verb::Scope::Sitemap,
      Gori::Verb::Scope::Miner, Gori::Verb::Scope::Probe, Gori::Verb::Scope::ProbeDetail,
    ]
    no_collision = ->(view : Array(Gori::Verb::Definition)) {
      keys = view.compact_map(&.menu_key)
      keys.uniq.size.should eq(keys.size) # no two entries in this view collide on one key
    }
    menu_scopes.each do |scope|
      verbs = registry.select { |v| v.scope == scope && !v.hidden? }
      verbs.select(&.chords.empty?).all?(&.menu_key).should be_true # chordless ⇒ keyed

      common = verbs.select { |v| v.section == :common }
      no_collision.call(common)
      sections = verbs.map(&.section).uniq.reject { |s| s == :common }
      sections.each { |section| no_collision.call(common + verbs.select { |v| v.section == section }) }
    end
  end

  # Registry#validate_menu_keys! turns the convention above into a BOOT-TIME invariant:
  # Verbs.registry calls it, so a colliding menu key crashes at startup instead of
  # silently shadowing a verb (SpaceMenu#verb_for is a first-match find).
  describe "Registry#validate_menu_keys!" do
    it "passes on the shipped registry" do
      Gori::Verbs.registry.validate_menu_keys! # builds + re-checks; must not raise
    end

    it "raises on two verbs sharing a menu key WITHIN one scope" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "first",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.b", "demo:b", "second",
        Gori::Verb::Scope::Body, mnemonic: 'z') { |_| nil }) # derives the same 'z'
      expect_raises(Gori::Error, /space-menu key collision/) { reg.validate_menu_keys! }
    end

    it "allows the same menu key across DIFFERENT scopes (scoped menu, deliberate reuse)" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "first",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.b", "demo:b", "second",
        Gori::Verb::Scope::Repeater, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.validate_menu_keys! # cross-scope reuse must not raise
    end

    it "ignores hidden verbs (not shown in the menu, so their key can't collide)" do
      reg = Gori::Verb::Registry.new
      reg.register(Gori::Verb::Definition.new("demo.a", "demo:a", "shown",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")]) { |_| nil })
      reg.register(Gori::Verb::Definition.new("demo.hidden", "demo:hidden", "hidden",
        Gori::Verb::Scope::Body, [Gori::Verb::Chord.new("z")], hidden: true) { |_| nil })
      reg.validate_menu_keys! # the hidden verb never fronts a menu key
    end
  end
end
