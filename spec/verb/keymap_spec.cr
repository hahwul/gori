require "../spec_helper"

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
      v = verb("t.a", Scope::Body, Chord.new("a"))
      Keymap.effective_chords(v, OsProfile::Os::Linux, Keymap::NO_OVERRIDES).should eq([Chord.new("a")])
    end

    it "lets a user override replace the base chords" do
      v = verb("t.a", Scope::Body, Chord.new("a"))
      ov = {"t.a" => [Chord.new("g")]}
      Keymap.effective_chords(v, OsProfile::Os::Linux, ov).should eq([Chord.new("g")])
    end

    it "treats a user override of [] as an explicit unbind" do
      v = verb("t.a", Scope::Body, Chord.new("a"))
      ov = {"t.a" => [] of Chord}
      Keymap.effective_chords(v, OsProfile::Os::Linux, ov).should be_empty
    end
  end

  describe ".build with overrides" do
    it "binds the override and unbinds the base chord" do
      r = reg_with(verb("t.a", Scope::Body, Chord.new("a")))
      km = Keymap.build(r, OsProfile::Os::Linux, {"t.a" => [Chord.new("g")]})
      km.lookup(Chord.new("g"), Scope::Body).should eq("t.a")
      km.lookup(Chord.new("a"), Scope::Body).should be_nil # the old default no longer binds
    end

    it "drops a binding entirely on unbind ([])" do
      r = reg_with(verb("t.a", Scope::Body, Chord.new("a")))
      km = Keymap.build(r, OsProfile::Os::Linux, {"t.a" => [] of Chord})
      km.lookup(Chord.new("a"), Scope::Body).should be_nil
    end

    it "preserves scope-then-Global fallback" do
      r = reg_with(
        verb("g.x", Scope::Global, Chord.new("x", ctrl: true)),
        verb("b.x", Scope::Body, Chord.new("y")),
      )
      km = Keymap.build(r)
      km.lookup(Chord.new("x", ctrl: true), Scope::Body).should eq("g.x") # Global fallback
      km.lookup(Chord.new("y"), Scope::Body).should eq("b.x")
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
      seen = {} of {Scope, Chord} => String
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
end
