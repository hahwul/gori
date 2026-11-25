require "../spec_helper"
require "../support/fake_context"

include Gori::Verb

private def reg_with(*verbs : Definition) : Registry
  r = Registry.new
  verbs.each { |v| r.register(v) }
  r
end

private def verb(id, scope, *chords : Chord) : Definition
  Definition.new(id, id, "", scope, chords.to_a) { |_| nil }
end

describe Gori::Verb::Keymap do
  describe ".effective_chords (user > OS > base)" do
    it "returns the verb's base chords when there is no override" do
      v = verb("t.a", Gori::Verb::Scope::Body, Chord.new("a"))
      Keymap.effective_chords(v, OsProfile::Os::Linux, Keymap::NO_OVERRIDES).should eq([Chord.new("a")])
    end

    it "lets a user override replace the base chords" do
      v = verb("t.a", Gori::Verb::Scope::Body, Chord.new("a"))
      ov = {"t.a" => [Chord.new("g")]}
      Keymap.effective_chords(v, OsProfile::Os::Linux, ov).should eq([Chord.new("g")])
    end

    it "treats a user override of [] as an explicit unbind" do
      v = verb("t.a", Gori::Verb::Scope::Body, Chord.new("a"))
      ov = {"t.a" => [] of Chord}
      Keymap.effective_chords(v, OsProfile::Os::Linux, ov).should be_empty
    end
  end

  describe ".build with overrides" do
    it "binds the override and unbinds the base chord" do
      r = reg_with(verb("t.a", Gori::Verb::Scope::Body, Chord.new("a")))
      km = Keymap.build(r, OsProfile::Os::Linux, {"t.a" => [Chord.new("g")]})
      km.lookup(Chord.new("g"), Gori::Verb::Scope::Body).should eq("t.a")
      km.lookup(Chord.new("a"), Gori::Verb::Scope::Body).should be_nil # the old default no longer binds
    end

    it "drops a binding entirely on unbind ([])" do
      r = reg_with(verb("t.a", Gori::Verb::Scope::Body, Chord.new("a")))
      km = Keymap.build(r, OsProfile::Os::Linux, {"t.a" => [] of Chord})
      km.lookup(Chord.new("a"), Gori::Verb::Scope::Body).should be_nil
    end

    it "preserves scope-then-Global fallback" do
      r = reg_with(
        verb("g.x", Gori::Verb::Scope::Global, Chord.new("x", ctrl: true)),
        verb("b.x", Gori::Verb::Scope::Body, Chord.new("y")),
      )
      km = Keymap.build(r)
      km.lookup(Chord.new("x", ctrl: true), Gori::Verb::Scope::Body).should eq("g.x") # Global fallback
      km.lookup(Chord.new("y"), Gori::Verb::Scope::Body).should eq("b.x")
    end

    it "can resolve only Global chords for the sub-tab strip" do
      reg = reg_with(
        verb("g.x", Gori::Verb::Scope::Global, Chord.new("x", ctrl: true)),
        verb("b.x", Gori::Verb::Scope::Body, Chord.new("x", ctrl: true)),
      )
      km = Keymap.build(reg)
      ctx = FakeExecContext.new
      km.resolve_global(Chord.new("x", ctrl: true), reg, ctx).should eq("g.x")
      km.resolve_global(Chord.new("x"), reg, ctx).should be_nil
    end

    # `>` was free before #1295 bound it to Send flow to… on eleven tabs, so an operator could
    # have put a Global verb there. That explicit choice beats the hidden per-tab openers,
    # which the lookup would otherwise answer first on exactly those tabs.
    it "lets a user's Global chord win over a family opener's default" do
      reg = Gori::Verbs.registry
      gt = Chord.new(">")
      km = Keymap.build(reg, OsProfile::Os::Linux, {"nav.next-tab" => [gt]})
      openers = reg.select { |v| reg.opens_family(v.id) == :send_flow }
      openers.size.should be > 5
      openers.each do |opener|
        km.lookup(gt, opener.scope).should eq("nav.next-tab"), opener.scope.to_s
      end
      # A tab verb the operator put on `>` still wins in its own scope, and without any
      # override the openers are back.
      km = Keymap.build(reg, OsProfile::Os::Linux, {"nav.next-tab" => [gt], "repeater.send" => [gt]})
      km.lookup(gt, Gori::Verb::Scope::Repeater).should eq("repeater.send")
      km = Keymap.build(reg, OsProfile::Os::Linux)
      openers.each { |opener| km.lookup(gt, opener.scope).should eq(opener.id) }
    end
  end

  describe "the editable surface is conflict-free + reserved-free" do
    # The guards target the REBINDABLE surface (Hotkeys.rebindable?). Hidden nav
    # primitives legitimately reuse structural keys (escape on palette.close), have
    # benign last-wins overlaps (IssuesDetail `left`), and nav-alias verbs carry a
    # structural primary (body.open = enter) — none are editable, so they're excluded.
    it "has no two rebindable verbs claiming the same chord in the SAME scope" do
      reg = Gori::Verbs.registry
      seen = {} of {Gori::Verb::Scope, Chord} => String
      reg.each do |v|
        next unless Gori::Hotkeys.rebindable?(v)
        v.chords.each do |c|
          if prev = seen[{v.scope, c}]?
            fail "#{c.label} double-bound in #{v.scope}: #{prev} and #{v.id}"
          end
          seen[{v.scope, c}] = v.id
        end
      end
    end

    it "has no rebindable default chord that is reserved (terminal or gori-guard)" do
      Gori::Verbs.registry.each do |v|
        next unless Gori::Hotkeys.rebindable?(v)
        v.chords.each do |c|
          if reason = Gori::Hotkeys.reserved?(c)
            fail "#{v.id} default #{c.label} is reserved: #{reason}"
          end
        end
      end
    end

    it "keeps Global bare-letter defaults within the L2 breath set (c/i/s)" do
      # Key-budget policy: only capture / intercept / scope lens may own a Global
      # bare letter by default. New Global bare chords need an explicit justification.
      allowed = Set{"c", "i", "s"}
      Gori::Verbs.registry.each do |v|
        next unless v.scope.global?
        v.chords.each do |c|
          next if c.ctrl || c.alt || c.shift
          next unless c.key.size == 1 && c.key[0].ascii_letter?
          unless allowed.includes?(c.key)
            fail "Global bare '#{c.key}' on #{v.id} — L2 breath is c/i/s only (see docs/guide/hotkeys)"
          end
        end
      end
    end
  end

  # `Runner#resolve_verb_id` is `#resolve` with the live context. A verb's `chord_sections`
  # makes its key a pane-local one: out of those sections the link stands down and the press
  # walks on, exactly like an unavailable verb (#1274 WP2 #3/#4/#13).
  describe "#resolve (the scope chain)" do
    it "fires a pane-gated chord only in its sections, and walks on to Global elsewhere" do
      gated = Definition.new("t.gated", "t.gated", "", Gori::Verb::Scope::Repeater, [Chord.new("c")],
        chord_sections: [:response]) { |_| nil }
      reg = reg_with(gated, verb("t.global", Gori::Verb::Scope::Global, Chord.new("c")))
      km = Keymap.build(reg)
      ctx = FakeExecContext.new
      ctx.focused_section = :response
      km.resolve(Chord.new("c"), Gori::Verb::Scope::Repeater, reg, ctx).should eq("t.gated")
      ctx.focused_section = :request
      # …which is why a gate must never sit on a letter Global binds: this is capture.
      km.resolve(Chord.new("c"), Gori::Verb::Scope::Repeater, reg, ctx).should eq("t.global")
    end

    # A letter the tab claims never reaches Global (DESIGN.md §7, 2026-11-25). Unlike the pane
    # gate above, an `available:` lambda is state the R1 guard cannot see, so this is the check.
    it "holds a tab chord whose verb is unavailable instead of firing Global's" do
      gated = Definition.new("t.gated", "t.gated", "", Gori::Verb::Scope::Evidence, [Chord.new("c")],
        available: ->(_ctx : ExecContext) { false }) { |_| nil }
      reg = reg_with(gated, verb("t.global", Gori::Verb::Scope::Global, Chord.new("c")))
      km = Keymap.build(reg)
      ctx = FakeExecContext.new
      km.resolve(Chord.new("c"), Gori::Verb::Scope::Evidence, reg, ctx).should be_nil
      km.held_from_global(Chord.new("c"), Gori::Verb::Scope::Evidence, reg, ctx).should eq("t.gated")
      # …in an editor pane too: the Editor link is walked first, the tab's claim still holds.
      ctx.editor_pane = ctx.editor_read_mode = true
      km.resolve(Chord.new("c"), Gori::Verb::Scope::Evidence, reg, ctx).should be_nil
      # A tab that does not bind the letter leaves it to Global, as before.
      km.resolve(Chord.new("c"), Gori::Verb::Scope::Probe, reg, ctx).should eq("t.global")
      km.held_from_global(Chord.new("c"), Gori::Verb::Scope::Probe, reg, ctx).should be_nil
    end

    it "names no hold where nothing behind the tab would have fired" do
      gated = Definition.new("t.gated", "t.gated", "", Gori::Verb::Scope::Evidence, [Chord.new("q")],
        available: ->(_ctx : ExecContext) { false }) { |_| nil }
      reg = reg_with(gated)
      km = Keymap.build(reg)
      km.held_from_global(Chord.new("q"), Gori::Verb::Scope::Evidence, reg, FakeExecContext.new).should be_nil
    end

    it "keeps an unavailable Editor verb from blocking the tab behind it" do
      ed = Definition.new("e.x", "e.x", "", Gori::Verb::Scope::Editor, [Chord.new("x")],
        available: ->(_ctx : ExecContext) { false }) { |_| nil }
      reg = reg_with(ed, verb("t.x", Gori::Verb::Scope::Repeater, Chord.new("x")))
      ctx = FakeExecContext.new
      ctx.editor_pane = true
      Keymap.build(reg).resolve(Chord.new("x"), Gori::Verb::Scope::Repeater, reg, ctx).should eq("t.x")
    end

    # The shipped keys, swept rather than listed: every non-Global scope's chord that Global
    # also binds, under every OS profile × keyset, made unavailable. Evidence's `c` on an empty
    # list stopped capture and its `i` on an unlinked snapshot held every request.
    it "never resolves an unavailable tab verb's chord to the Global verb on it" do
      reg = Gori::Verbs.registry
      ctx = FakeExecContext.new
      pairs = Set({String, String}).new
      OsProfile::Os.each do |os|
        Keyset::Kind.each do |ks|
          km = Keymap.build(reg, os, Keymap::NO_OVERRIDES, ks)
          where = "#{Keyset.name_of(ks)}/#{os}"
          reg.each do |v|
            next if v.scope.global? || v.scope.editor?
            Keymap.effective_chords(v, os, Keymap::NO_OVERRIDES, ks).each do |chord|
              next unless km.lookup_in(chord, v.scope) == v.id
              next unless g = km.lookup_in(chord, Gori::Verb::Scope::Global)
              pairs << {v.id, g}
              # The tab verb as it is, but unavailable; the Global one forced live, so only the
              # walk is under test. Out of its `chord_sections` the press still walks on (above).
              off = Definition.new(v.id, v.title, "", v.scope, v.chords, available: ->(_c : ExecContext) { false },
                chord_sections: v.chord_sections) { |_| nil }
              gv = reg[g]
              on = Definition.new(g, gv.title, "", gv.scope, gv.chords) { |_| nil }
              two = reg_with(off, on)
              sec = v.chord_sections.try(&.first?) || :common
              ctx.focused_section = sec
              km.resolve(chord, v.scope, two, ctx).should be_nil, "#{where}: #{chord.label} on #{v.id} fired #{g}"
              km.held_from_global(chord, v.scope, two, ctx).should eq(v.id), "#{where}: #{chord.label} on #{v.id}"
            end
          end
        end
      end
      # The overlaps the defect was found on, so an empty sweep cannot pass.
      pairs.should contain({"evidence.compare", "capture.toggle"})
      pairs.should contain({"evidence.issue", "intercept.toggle"})
      pairs.should contain({"authorize.identities", "intercept.toggle"})
    end

    it "holds Evidence's c and i on an empty list and an unlinked snapshot" do
      reg = Gori::Verbs.registry
      km = Keymap.build(reg, OsProfile::Os::Linux, Keymap::NO_OVERRIDES, Keyset::Kind::Helix)
      ctx = FakeExecContext.new
      ctx.current_tab = :evidence
      ev = Gori::Verb::Scope::Evidence
      km.held_from_global(Chord.new("c"), ev, reg, ctx).should eq("evidence.compare")
      km.held_from_global(Chord.new("i"), ev, reg, ctx).should eq("evidence.issue")
      ctx.selected_evidence = 4_i64
      km.resolve(Chord.new("c"), ev, reg, ctx).should eq("evidence.compare")
      km.resolve(Chord.new("i"), ev, reg, ctx).should be_nil # orphaned: no linked issue
      km.held_from_global(Chord.new("i"), ev, reg, ctx).should eq("evidence.issue")
      ctx.evidence_has_links = true
      km.resolve(Chord.new("i"), ev, reg, ctx).should eq("evidence.issue")
    end

    it "leaves an ungated chord live in every section" do
      reg = reg_with(verb("t.a", Gori::Verb::Scope::Repeater, Chord.new("a")))
      ctx = FakeExecContext.new
      {:request, :response, :target, :subtab}.each do |sec|
        ctx.focused_section = sec
        Keymap.build(reg).resolve(Chord.new("a"), Gori::Verb::Scope::Repeater, reg, ctx).should eq("t.a")
      end
    end

    # The shipped gates. In the pane whose menu spells the same letter for something else the
    # bare key is NOTHING — not the other pane's toggle, and not a Global breath key either.
    # Every OS profile × keyset: vim respells the editor family, and the request/template
    # panes are editors, so the Editor link is walked first there. The last field is what the
    # key answers in those editor panes instead: nothing, or the Editor verb on that letter
    # (`p` pastes in the request pane, and pretty-prints only in the response).
    {
      {Gori::Verb::Scope::Repeater, :repeater, Chord.new("p"), "repeater.toggle-pretty", :response, [:request, :target], "editor.paste"},
      {Gori::Verb::Scope::Repeater, :repeater, Chord.new("d", shift: true), "repeater.toggle-diff", :response, [:request, :target], nil},
      {Gori::Verb::Scope::Fuzzer, :fuzzer, Chord.new("v"), "fuzz.dist", :results, [:template, :target, :config], nil},
      {Gori::Verb::Scope::Fuzzer, :fuzzer, Chord.new("m"), "fuzz.matched", :results, [:template, :target, :config], nil},
    }.each do |scope, tab, chord, id, home, elsewhere, in_editor|
      it "answers #{chord.label} with #{id} only in #{home}" do
        reg = Gori::Verbs.registry
        OsProfile::Os.each do |os|
          Keyset::Kind.each do |ks|
            km = Keymap.build(reg, os, Keymap::NO_OVERRIDES, ks)
            where = "#{Keyset.name_of(ks)}/#{os}"
            km.lookup_in(chord, Gori::Verb::Scope::Global).should be_nil, where
            ctx = FakeExecContext.new
            ctx.current_tab = tab
            ctx.focused_section = home
            km.resolve(chord, scope, reg, ctx).should eq(id), where
            elsewhere.each do |sec|
              ctx.focused_section = sec
              editor = sec != :config
              ctx.editor_pane = ctx.editor_read_mode = editor
              km.resolve(chord, scope, reg, ctx).should eq(editor ? in_editor : nil), "#{where} #{sec}"
            end
          end
        end
      end
    end
  end
end
