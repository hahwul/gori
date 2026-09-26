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

    # `>` was free before #1295 bound it to Send flow to… on eleven tabs, so an operator could
    # have put a Global verb there. That explicit choice beats the hidden per-tab openers,
    # which the lookup would otherwise answer first on exactly those tabs.
    it "lets a user's Global chord win over a family opener's default" do
      reg = Gori::Verbs.registry
      gt = Chord.new(">")
      km = Keymap.build(reg, OsProfile::Os::Linux, {"nav.next-tab" => [gt]})
      openers = reg.select { |v| reg.opens_family(v.id) }
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

  describe ".parse_overrides" do
    it "parses label strings into chords and drops garbage" do
      parsed = Keymap.parse_overrides({"t.a" => ["ctrl-g", "nope", ""], "t.b" => [] of String})
      parsed["t.a"].should eq([Chord.new("g", ctrl: true)])
      parsed["t.b"].should be_empty # preserved as an unbind
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
    # panes are editors, so the Editor link is walked first there.
    {
      {Gori::Verb::Scope::Repeater, :repeater, Chord.new("p"), "repeater.toggle-pretty", :response, [:request, :target]},
      {Gori::Verb::Scope::Repeater, :repeater, Chord.new("d", shift: true), "repeater.toggle-diff", :response, [:request, :target]},
      {Gori::Verb::Scope::Fuzzer, :fuzzer, Chord.new("v"), "fuzz.dist", :results, [:template, :target, :config]},
      {Gori::Verb::Scope::Fuzzer, :fuzzer, Chord.new("m"), "fuzz.matched", :results, [:template, :target, :config]},
    }.each do |scope, tab, chord, id, home, elsewhere|
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
              ctx.editor_pane = ctx.editor_read_mode = sec != :config
              km.resolve(chord, scope, reg, ctx).should be_nil, "#{where} #{sec}"
            end
          end
        end
      end
    end
  end
end
