require "./spec_helper"

describe Gori::Hotkeys do
  describe ".rebindable?" do
    it "excludes hidden verbs and the FIXED guard-shadowed/keyless ids" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.rebindable?(reg["app.palette"]).should be_true
      Gori::Hotkeys.rebindable?(reg["view.reveal-ws"]).should be_false # guard-shadowed
      Gori::Hotkeys.rebindable?(reg["app.quit"]).should be_false       # deliberately keyless
      Gori::Hotkeys.rebindable?(reg["body.down"]).should be_false      # hidden nav primitive
      Gori::Hotkeys.rebindable?(reg["body.open"]).should be_false      # multi-chord nav alias
    end
  end

  describe ".binding_for / .default_for" do
    it "reports the effective primary chord, honouring a working override" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.binding_for(reg, "rules.edit").should eq(Gori::Verb::Chord.new("m"))
      working = {"rules.edit" => [Gori::Verb::Chord.new("g")]}
      Gori::Hotkeys.binding_for(reg, "rules.edit", working).should eq(Gori::Verb::Chord.new("g"))
      # default_for ignores user overrides
      Gori::Hotkeys.default_for(reg, "rules.edit", "auto").should eq(Gori::Verb::Chord.new("m"))
    end
  end

  describe ".build_keymap" do
    it "applies persisted overrides into the dispatch keymap" do
      prev = Gori::Settings.keymap_overrides
      begin
        Gori::Settings.keymap_overrides = {"rules.edit" => ["g"]}
        km = Gori::Hotkeys.build_keymap(Gori::Verbs.registry)
        km.lookup(Gori::Verb::Chord.new("g"), Gori::Verb::Scope::Global).should eq("rules.edit")
        km.lookup(Gori::Verb::Chord.new("m"), Gori::Verb::Scope::Global).should be_nil
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
        working = {"rules.edit" => Gori::Verb::Chord.new("g"), "scope.edit" => nil}
        Gori::Hotkeys.apply(working, "linux")
        Gori::Settings.keymap_os.should eq("linux")
        Gori::Settings.keymap_overrides["rules.edit"].should eq(["g"])
        Gori::Settings.keymap_overrides["scope.edit"].should eq([] of String)
      ensure
        Gori::Settings.keymap_overrides = prev_ov
        Gori::Settings.keymap_os = prev_os
      end
    end
  end

  describe ".reserved?" do
    it "layers gori guard-claimed chords on top of the terminal-reserved set" do
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("c", ctrl: true)).should_not be_nil # quit
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("g", ctrl: true)).should_not be_nil # goto guard
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("b", ctrl: true)).should_not be_nil # reveal guard
      Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("e", ctrl: true)).should_not be_nil # editor guard
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
