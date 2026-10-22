require "../spec_helper"
require "../support/fake_context"

include Gori::Verb

describe Gori::Verb do
  describe "P1: one definition feeds both keymap and palette" do
    it "resolves the same verb id via a chord AND a palette search" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # keybinding path: ctrl-p (Global) -> app.palette
      via_key = keymap.lookup(Chord.new("p", ctrl: true), Gori::Verb::Scope::Body)
      via_key.should eq("app.palette")

      # palette path: the Ctrl-P palette is the Global (app-control) surface
      via_palette = reg.for_scope(Gori::Verb::Scope::Global, FakeExecContext.new, "palette").map(&.id)
      via_palette.should contain("app.palette")
    end
  end

  describe Keymap do
    it "prefers a scope-specific binding then falls back to Global" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # escape in PaletteOpen -> palette.close (scope-specific)
      keymap.lookup(Chord.new("escape"), Gori::Verb::Scope::PaletteOpen).should eq("palette.close")
      # escape in HistoryDetail -> detail.close (different verb, same chord)
      keymap.lookup(Chord.new("escape"), Gori::Verb::Scope::HistoryDetail).should eq("detail.close")
      # ←/→ in HistoryDetail walk the panes (left no longer just closes)
      keymap.lookup(Chord.new("right"), Gori::Verb::Scope::HistoryDetail).should eq("detail.next-pane")
      keymap.lookup(Chord.new("left"), Gori::Verb::Scope::HistoryDetail).should eq("detail.prev-pane")
      keymap.lookup(Chord.new("x"), Gori::Verb::Scope::HistoryDetail).should eq("detail.select-line")
      keymap.lookup(Chord.new("x", ctrl: true), Gori::Verb::Scope::HistoryDetail).should eq("detail.toggle-hex")
      keymap.lookup(Chord.new("u"), Gori::Verb::Scope::HistoryDetail).should eq("detail.toggle-unicode")
      # ^U in the Fuzzer pretty-prints the template (must NOT be intercepted as clear-marks
      # anymore — clear-marks moved to the space menu as fuzz.clear-marks).
      keymap.lookup(Chord.new("u", ctrl: true), Gori::Verb::Scope::Fuzzer).should eq("fuzz.pretty-template")
      # a Global chord (^P palette) resolves from ANY scope
      keymap.lookup(Chord.new("p", ctrl: true), Gori::Verb::Scope::Body).should eq("app.palette")
      # 'q' (back to projects) is bound only on the tab bar (Sidebar), not in a body —
      # as a Global chord it used to dump you to the picker mid-browse.
      keymap.lookup(Chord.new("q"), Gori::Verb::Scope::Sidebar).should eq("app.back-key")
      keymap.lookup(Chord.new("q"), Gori::Verb::Scope::Body).should be_nil
      # an unbound chord
      keymap.lookup(Chord.new("z"), Gori::Verb::Scope::Body).should be_nil
      # scope-specific: the top menu navigates horizontally, the body vertically
      keymap.lookup(Chord.new("right"), Gori::Verb::Scope::Sidebar).should eq("sidebar.next")
      keymap.lookup(Chord.new("down"), Gori::Verb::Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("down"), Gori::Verb::Scope::Body).should eq("body.down")
    end

    it "supports multiple chords per verb" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("j"), Gori::Verb::Scope::Body).should eq("body.down")
      keymap.lookup(Chord.new("down"), Gori::Verb::Scope::Body).should eq("body.down")
    end

    it "binds bare 's' to the scope-lens toggle from any scope (was jump-to-editor)" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("s"), Gori::Verb::Scope::Body).should eq("scope.toggle-lens")
      keymap.lookup(Chord.new("s"), Gori::Verb::Scope::Sitemap).should eq("scope.toggle-lens")

      ctx = FakeExecContext.new
      reg["scope.toggle-lens"].call(ctx)
      ctx.call_names.should contain(:scope_toggle_lens)

      # jumping to the scope rule editor is still reachable, now palette-only (no chord)
      reg["scope.edit"].call(ctx)
      ctx.call_names.should contain(:scope_open)
    end

    it "binds ctrl-n to a new blank repeater in the Repeater scope" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("n", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.new")

      ctx = FakeExecContext.new
      reg["repeater.new"].call(ctx)
      ctx.call_names.should contain(:repeater_new)
    end

    it "descends from the tab menu via enter_content (so sub-tab tabs land on the strip first)" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      # ↓/↵/j on the tab bar resolve to sidebar.enter…
      keymap.lookup(Chord.new("down"), Gori::Verb::Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("enter"), Gori::Verb::Scope::Sidebar).should eq("sidebar.enter")

      # …which descends through enter_content (NOT focus_pane), letting the Runner
      # route Repeater/Notes onto their sub-tab strip before the body.
      ctx = FakeExecContext.new
      reg["sidebar.enter"].call(ctx)
      ctx.call_names.should contain(:enter_content)
      ctx.call_names.should_not contain(:focus_pane)
    end
  end

  describe "migrated tab-local chords resolve in their per-tab scope" do
    it "binds the Repeater request-pane toggles + send in Repeater scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.send")
      km.lookup(Chord.new("x", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.toggle-hex")
      km.lookup(Chord.new("s", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.toggle-sni")
      km.lookup(Chord.new("l", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.toggle-auto-content-length")
      km.lookup(Chord.new("u"), Gori::Verb::Scope::Repeater).should eq("repeater.toggle-unicode")
    end

    it "binds the Fuzzer run/stop/automark chords in Fuzzer scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Gori::Verb::Scope::Fuzzer).should eq("fuzz.run")
      km.lookup(Chord.new("x", ctrl: true), Gori::Verb::Scope::Fuzzer).should eq("fuzz.stop")
      km.lookup(Chord.new("a", ctrl: true), Gori::Verb::Scope::Fuzzer).should eq("fuzz.automark")
      km.lookup(Chord.new("e", shift: true), Gori::Verb::Scope::Fuzzer).should eq("fuzz.save-results")
    end

    it "binds the Intercept catch chords in Intercept scope, shadowing the Global/Body keys" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("c"), Gori::Verb::Scope::Intercept).should eq("intercept.direction")
      km.lookup(Chord.new("/"), Gori::Verb::Scope::Intercept).should eq("intercept.filter")
      # …without breaking capture (`c`) elsewhere or History's `/` filter
      km.lookup(Chord.new("c"), Gori::Verb::Scope::Body).should eq("capture.toggle")
      km.lookup(Chord.new("/"), Gori::Verb::Scope::Body).should eq("history.query")
    end

    it "routes the new Repeater toggle verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      reg["repeater.toggle-hex"].call(ctx)
      reg["repeater.toggle-decoded"].call(ctx)
      reg["repeater.toggle-sni"].call(ctx)
      reg["repeater.toggle-auto-content-length"].call(ctx)
      ctx.call_names.should contain(:repeater_toggle_hex)
      ctx.call_names.should contain(:repeater_toggle_decoded)
      ctx.call_names.should contain(:repeater_toggle_sni)
      ctx.call_names.should contain(:repeater_toggle_auto_content_length)
    end

    it "routes the Round-4 Repeater :subtab/:response verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      reg["repeater.rename-subtab"].call(ctx)
      reg["repeater.close-subtab"].call(ctx)
      reg["repeater.toggle-diff"].call(ctx)
      reg["repeater.toggle-resp-hex"].call(ctx)
      ctx.call_names.should contain(:repeater_rename_subtab)
      ctx.call_names.should contain(:repeater_close_subtab)
      ctx.call_names.should contain(:repeater_toggle_resp_diff)
      ctx.call_names.should contain(:repeater_toggle_resp_hex)
    end

    it "routes the Round-4 Fuzzer :subtab verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      reg["fuzz.rename-subtab"].call(ctx)
      reg["fuzz.close-subtab"].call(ctx)
      ctx.call_names.should contain(:fuzzer_rename_subtab)
      ctx.call_names.should contain(:fuzzer_close_subtab)
    end

    it "routes the palette-only Refresh screen verb (no chord) to refresh_screen" do
      reg = Gori::Verbs.registry
      reg["view.refresh"].chords.empty?.should be_true # palette-only, unbound
      ctx = FakeExecContext.new
      reg["view.refresh"].call(ctx)
      ctx.call_names.should contain(:refresh_screen)
    end
  end

  describe Registry do
    it "gates verbs by availability (P4) and hides cursor verbs from the palette" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new

      # no selection -> open-detail unavailable, copy unavailable
      ids = reg.search("", ctx).map(&.id)
      ids.should_not contain("body.open")
      ids.should_not contain("history.copy")
      ids.should_not contain("body.down") # hidden

      ctx.selected = 5_i64
      ids2 = reg.search("", ctx).map(&.id)
      ids2.should contain("body.open")
      ids2.should contain("history.copy")
    end

    it "fuzzy-ranks results and rejects non-subsequence queries" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      reg.search("quit", ctx).first.id.should eq("app.quit")
      reg.search("zzxq-nope", ctx).should be_empty
    end

    # One membership rule for "what can I do here", read by the space menu and the palette's
    # typed search alike (#1282).
    it "for_view is COMMON, the focused section, and the SUB-TABS bucket when the tab has a strip" do
      reg = Registry.new
      {"common" => :common, "req" => :request, "resp" => :response, "strip" => :subtab, "find" => :tab}.each do |id, section|
        reg.register(Definition.new("demo.#{id}", id, "", Gori::Verb::Scope::Repeater, section: section) { |_| nil })
      end
      reg.register(Definition.new("demo.off", "off", "", Gori::Verb::Scope::Repeater,
        available: ->(_c : ExecContext) { false }) { |_| nil })
      reg.register(Definition.new("demo.other", "other", "", Gori::Verb::Scope::Body) { |_| nil })
      ctx = FakeExecContext.new

      reg.for_view(Gori::Verb::Scope::Repeater, :response, ctx, true).map(&.id)
        .should eq(["demo.common", "demo.resp", "demo.strip", "demo.find"])
      reg.for_view(Gori::Verb::Scope::Repeater, :response, ctx).map(&.id).should eq(["demo.common", "demo.resp"])
      reg.for_view(Gori::Verb::Scope::Repeater, :tab, ctx).map(&.id).should eq(["demo.common", "demo.find"])
    end

    it "for_scope is STRICTLY scope-local — no Global fallback" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      ctx.selected = 5_i64 # so the flow-gated Body actions are available

      body = reg.for_scope(Gori::Verb::Scope::Body, ctx)
      body.each do |v|
        v.hidden?.should be_false
        v.scope.should eq(Gori::Verb::Scope::Body) # strictly Body — Global app-control stays out of ":"
      end
      ids = body.map(&.id)
      ids.should contain("history.repeater") # an area action surfaces
      ids.should_not contain("app.quit")     # app-control belongs to Ctrl-P, not ":"
      ids.should_not contain("nav.next-tab")

      # The palette source is the Global slice (app control) — and it has NO area actions.
      gids = reg.for_scope(Gori::Verb::Scope::Global, ctx).map(&.id)
      gids.should contain("app.quit")
      gids.should contain("nav.next-tab") # tab navigation lives in Ctrl-P
      gids.any?(&.starts_with?("history.")).should be_false

      # fuzzy query narrows within the scope (same ranking as #search)
      reg.for_scope(Gori::Verb::Scope::Body, ctx, "repeater").first.id.should eq("history.repeater")
    end

    it "rejects duplicate ids" do
      reg = Registry.new
      reg.register(Definition.new("dup", "A", "", Gori::Verb::Scope::Global) { |_| nil })
      expect_raises(Gori::Error, /duplicate/) do
        reg.register(Definition.new("dup", "B", "", Gori::Verb::Scope::Global) { |_| nil })
      end
    end

    describe "#register_family_openers (#1295)" do
      it "binds a family's chord once per scope with a non-hidden member, and nothing for a keyless family" do
        reg = Registry.new
        reg.register_family(Gori::Verb::Family.new(:send, "Send to…", '>', :send, [{:to_a, 'a'}], chord: Chord.new(">")))
        reg.register_family(Gori::Verb::Family.new(:show, "Show…", 'Z', :view, [{:to_z, 'z'}]))
        reg.register(Definition.new("b.a", "A", "d", Gori::Verb::Scope::Body, intent: :to_a) { |_| nil })
        reg.register(Definition.new("s.a", "A", "d", Gori::Verb::Scope::Sitemap, intent: :to_a, hidden: true) { |_| nil })
        reg.register(Definition.new("b.z", "Z", "d", Gori::Verb::Scope::Body, intent: :to_z) { |_| nil })
        reg.register_family_openers
        openers = reg.select { |v| reg.opens_family(v.id) }
        openers.map { |v| {v.id, v.scope} }.should eq([{"send.open.body", Gori::Verb::Scope::Body}])
        openers[0].chords.should eq([Chord.new(">")])
        openers[0].hidden?.should be_true
        ctx = FakeExecContext.new
        openers[0].call(ctx)
        ctx.call_names.should eq([:open_space_family])
        reg.opens_family("b.a").should be_nil
      end
    end

    describe "#validate_chords!" do
      it "passes on the shipped registry (the guarantee itself)" do
        Gori::Verbs.registry.validate_chords! # raises on any violation
      end

      it "raises on a chord_of: that its named verb's chord does not reach (#1295)" do
        gated = Definition.new("t.gated", "G", "d", Gori::Verb::Scope::Repeater, [Chord.new("x", ctrl: true)],
          section: :request, chord_sections: [:request]) { |_| nil }
        {
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :response, chord_of: "t.nope") { |_| nil }, /names no registered verb/},
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Fuzzer, chord_of: "t.gated") { |_| nil }, /not Fuzzer/},
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :response, chord_of: "t.gated") { |_| nil }, /not live in response/},
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, [Chord.new("q")], section: :request, chord_of: "t.gated") { |_| nil }, /chords of its own/},
          # A keyless target: the link would advertise nothing.
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :request, chord_of: "t.keyless") { |_| nil }, /t.keyless, which has no chord/},
          # A chain, and a cycle (here onto itself): `Hotkeys.binding_for` would recurse forever.
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :request, chord_of: "t.link") { |_| nil }, /t.link, which has a chord_of/},
          {Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :request, chord_of: "t.row") { |_| nil }, /t.row, which has a chord_of/},
        }.each do |(row, why)|
          reg = Registry.new
          reg.register(gated)
          reg.register(Definition.new("t.keyless", "K", "d", Gori::Verb::Scope::Repeater, section: :request) { |_| nil })
          reg.register(Definition.new("t.link", "L", "d", Gori::Verb::Scope::Repeater, section: :request, chord_of: "t.gated") { |_| nil })
          reg.register(row)
          expect_raises(Gori::Error, why) { reg.validate_chords! }
        end
        ok = Registry.new
        ok.register(gated)
        ok.register(Definition.new("t.row", "R", "d", Gori::Verb::Scope::Repeater, section: :request, chord_of: "t.gated") { |_| nil })
        ok.validate_chords!
      end

      it "raises on two verbs claiming the same chord in the same scope" do
        reg = Registry.new
        reg.register(Definition.new("a", "A", "d", Gori::Verb::Scope::Body, [Chord.new("g")]) { |_| nil })
        reg.register(Definition.new("b", "B", "d", Gori::Verb::Scope::Body, [Chord.new("g")]) { |_| nil })
        expect_raises(Gori::Error, /chord collision.*'g'.*a.*b.*Body/) do
          reg.validate_chords!
        end
      end

      it "allows the SAME chord in DIFFERENT scopes (deliberate shadowing)" do
        reg = Registry.new
        reg.register(Definition.new("a", "A", "d", Gori::Verb::Scope::Body, [Chord.new("g")]) { |_| nil })
        reg.register(Definition.new("b", "B", "d", Gori::Verb::Scope::Sitemap, [Chord.new("g")]) { |_| nil })
        reg.validate_chords! # must not raise — lookup resolves the scope before Global
      end

      it "does NOT skip hidden verbs — a collision on a hidden nav primitive still raises" do
        reg = Registry.new
        reg.register(Definition.new("nav", "Nav", "d", Gori::Verb::Scope::Body,
          [Chord.new("down")], hidden: true) { |_| nil })
        reg.register(Definition.new("other", "Other", "d", Gori::Verb::Scope::Body,
          [Chord.new("down")]) { |_| nil })
        expect_raises(Gori::Error, /chord collision.*'down'/) do
          reg.validate_chords!
        end
      end

      it "catches a collision that only exists on a NON-native OS profile" do
        # The verb's base chords are collision-free, but a Windows override makes two
        # verbs land on the same chord — a check that read only `verb.chords` would miss it.
        reg = Registry.new
        reg.register(Definition.new("a", "A", "d", Gori::Verb::Scope::Body, [Chord.new("g")]) { |_| nil })
        reg.register(Definition.new("b", "B", "d", Gori::Verb::Scope::Body, [Chord.new("h")]) { |_| nil })
        win = Gori::Verb::OsProfile::Os::Windows
        original = Gori::Verb::OsProfile::OVERRIDES[win]
        begin
          Gori::Verb::OsProfile::OVERRIDES[win] = {"b" => [Chord.new("g")]}
          expect_raises(Gori::Error, /chord collision.*'g'.*Windows/) do
            reg.validate_chords!
          end
        ensure
          Gori::Verb::OsProfile::OVERRIDES[win] = original
        end
      end

      it "rejects a dead capital-letter chord (never fires — normalised to shift+lowercase)" do
        reg = Registry.new
        reg.register(Definition.new("cap", "Cap", "d", Gori::Verb::Scope::Body, [Chord.new("X")]) { |_| nil })
        expect_raises(Gori::Error, /dead capital chord.*'X'.*cap/) do
          reg.validate_chords!
        end
      end

      it "accepts the correct spelling of a capital chord (shift + lowercase)" do
        reg = Registry.new
        reg.register(Definition.new("cap", "Cap", "d", Gori::Verb::Scope::Body,
          [Chord.new("x", shift: true)]) { |_| nil })
        reg.validate_chords! # shift-x fires; must not raise
      end
    end
  end

  describe "handler execution" do
    it "runs through Definition#call and returns the handler's status message" do
      ctx = FakeExecContext.new
      verb = Definition.new("t.msg", "T", "", Gori::Verb::Scope::Global) { |_c| "did it" }
      verb.call(ctx).should eq("did it")

      reg = Gori::Verbs.registry
      reg["app.quit"].call(ctx)
      ctx.call_names.should contain(:quit!)
    end
  end
end
