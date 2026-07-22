require "./spec_helper"

describe Gori::Hotkeys do
  describe ".rebindable?" do
    it "excludes hidden verbs and the FIXED guard-shadowed/keyless ids" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.rebindable?(reg["capture.toggle"]).should be_true
      Gori::Hotkeys.rebindable?(reg["rules.edit"]).should be_true      # keyless but assignable
      Gori::Hotkeys.rebindable?(reg["view.reveal-ws"]).should be_false # guard-shadowed (^B)
      Gori::Hotkeys.rebindable?(reg["app.palette"]).should be_false    # ^P hardcoded in controllers
      Gori::Hotkeys.rebindable?(reg["repeater.new"]).should be_false   # ^N hardcoded in the runner
      Gori::Hotkeys.rebindable?(reg["app.quit"]).should be_false       # deliberately keyless FIXED
      Gori::Hotkeys.rebindable?(reg["body.down"]).should be_false      # hidden nav primitive
      Gori::Hotkeys.rebindable?(reg["body.open"]).should be_false      # multi-chord nav alias
    end
  end

  describe ".binding_for / .default_for" do
    it "reports the effective primary chord, honouring a working override" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.binding_for(reg, "capture.toggle").should eq(Gori::Verb::Chord.new("c"))
      working = {"capture.toggle" => [Gori::Verb::Chord.new("g")]}
      Gori::Hotkeys.binding_for(reg, "capture.toggle", working).should eq(Gori::Verb::Chord.new("g"))
      # default_for ignores user overrides
      Gori::Hotkeys.default_for(reg, "capture.toggle", "auto").should eq(Gori::Verb::Chord.new("c"))
      # Demoted L4 verbs ship with no default chord (palette / badge only).
      Gori::Hotkeys.binding_for(reg, "rules.edit").should be_nil
      Gori::Hotkeys.binding_for(reg, "app.notifications").should be_nil
    end
  end

  describe ".display_label / .binding_label" do
    it "renders compact status/Help tokens" do
      Gori::Hotkeys.display_label(Gori::Verb::Chord.new("r", ctrl: true)).should eq("^R")
      Gori::Hotkeys.display_label(Gori::Verb::Chord.new("i", shift: true)).should eq("⇧I")
      Gori::Hotkeys.display_label(Gori::Verb::Chord.new("f")).should eq("f")
      reg = Gori::Verbs.registry
      Gori::Hotkeys.binding_label(reg, "history.repeater", "?").should eq("^R")
      Gori::Hotkeys.binding_label(reg, "repeater.send", "?").should eq("^R")
      Gori::Hotkeys.binding_label(reg, "no.such.verb", "∅").should eq("∅")
    end
  end

  describe ".claimed?" do
    it "covers the pre-keymap ctrl letter/digit set" do
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("p", ctrl: true)).should be_true
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("1", ctrl: true)).should be_true
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("c")).should be_false
      Gori::Hotkeys::CLAIMED_CTRL_LETTERS.should contain("g")
      Gori::Hotkeys::CLAIMED_CTRL_LETTERS.should contain("p")
    end
  end

  describe ".build_keymap" do
    it "applies persisted overrides into the dispatch keymap" do
      prev = Gori::Settings.keymap_overrides
      begin
        Gori::Settings.keymap_overrides = {"capture.toggle" => ["g"]}
        km = Gori::Hotkeys.build_keymap(Gori::Verbs.registry)
        km.lookup(Gori::Verb::Chord.new("g"), Gori::Verb::Scope::Global).should eq("capture.toggle")
        km.lookup(Gori::Verb::Chord.new("c"), Gori::Verb::Scope::Global).should be_nil
      ensure
        Gori::Settings.keymap_overrides = prev
      end
    end

    it "drops a hand-edited reserved/garbage override instead of installing it (falls back to default)" do
      prev = Gori::Settings.keymap_overrides
      begin
        # capture.toggle bound to escape (reserved) + a garbage label → both dropped, so it
        # keeps its default `c`; scope.edit's explicit [] unbind is preserved.
        Gori::Settings.keymap_overrides = {"capture.toggle" => ["escape", "nope"], "scope.edit" => [] of String}
        ov = Gori::Hotkeys.chord_overrides
        ov.has_key?("capture.toggle").should be_false # malformed → default, not installed
        ov["scope.edit"].should be_empty              # genuine unbind kept
        km = Gori::Hotkeys.build_keymap(Gori::Verbs.registry)
        km.lookup(Gori::Verb::Chord.new("c"), Gori::Verb::Scope::Global).should eq("capture.toggle") # default intact
        km.lookup(Gori::Verb::Chord.new("escape"), Gori::Verb::Scope::Global).should be_nil          # never bound
      ensure
        Gori::Settings.keymap_overrides = prev
      end
    end

    it "installs a rebind on a keyless default (rules.edit / notifications)" do
      prev = Gori::Settings.keymap_overrides
      begin
        Gori::Settings.keymap_overrides = {"rules.edit" => ["m"]}
        km = Gori::Hotkeys.build_keymap(Gori::Verbs.registry)
        km.lookup(Gori::Verb::Chord.new("m"), Gori::Verb::Scope::Global).should eq("rules.edit")
      ensure
        Gori::Settings.keymap_overrides = prev
      end
    end
  end

  describe ".apply" do
    it "writes the working copy into Settings (Chord → label, nil → unbind [])" do
      prev_ov = Gori::Settings.keymap_overrides
      prev_os = Gori::Settings.keymap_os
      begin
        working = {"capture.toggle" => Gori::Verb::Chord.new("g"), "scope.edit" => nil}
        Gori::Hotkeys.apply(working, "linux")
        Gori::Settings.keymap_os.should eq("linux")
        Gori::Settings.keymap_overrides["capture.toggle"].should eq(["g"])
        Gori::Settings.keymap_overrides["scope.edit"].should eq([] of String)
      ensure
        Gori::Settings.keymap_overrides = prev_ov
        Gori::Settings.keymap_os = prev_os
      end
    end
  end

  describe ".reserved?" do
    it "layers the hardcoded-before-keymap chords on top of the terminal-reserved set" do
      {"c", "g", "b", "e", "p", "n", "w"}.each do |k| # quit + global guards + controller-claimed
        Gori::Hotkeys.reserved?(Gori::Verb::Chord.new(k, ctrl: true)).should_not be_nil
      end
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("1", ctrl: true)).should_not be_nil # ^1 sub-tab
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("9", ctrl: true)).should_not be_nil # ^9 sub-tab
    end

    it "allows ^S (shipped SNI default) and ordinary chords" do
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("s", ctrl: true)).should be_nil
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("g")).should be_nil
    end
  end

  describe ".profile_label" do
    it "labels named profiles and resolves auto to the platform" do
      Gori::Hotkeys.profile_label("linux").should eq("Linux")
      Gori::Hotkeys.profile_label("darwin").should eq("macOS")
      Gori::Hotkeys.profile_label("windows").should eq("Windows")
      Gori::Hotkeys.profile_label("auto").should start_with("auto (")
    end
  end
end
