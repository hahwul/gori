require "./spec_helper"

# Run `blk` with Settings.command_modifier pinned, restoring it afterwards.
private def with_modifier(mod : String, &)
  prev = Gori::Settings.command_modifier
  begin
    Gori::Settings.command_modifier = mod
    yield
  ensure
    Gori::Settings.command_modifier = prev
  end
end

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

    # The eight Copy verbs declare `y` AND `^Y`, and a raw `chords.size <= 1` counted that as a
    # nav alias — so every tab with a text editor had NO Copy row in the hotkey editor at all,
    # while the single-chord Copy verbs one section away were freely rebindable. The count now
    # ignores `Verb::Keymap.pinned_chords`, which is exactly the `^Y` half.
    it "offers the y + ^Y Copy verbs, whose second chord is pinned rather than an alias" do
      reg = Gori::Verbs.registry
      %w[notes.copy issue.copy decoder.copy rewriter.copy jwt.copy repeater.copy
        fuzzer.copy cookie.copy].each do |id|
        reg[id].chords.size.should eq(2) # the shape this exemption is written for
        Gori::Hotkeys.rebindable?(reg[id]).should be_true
      end
      # …and the single-chord siblings it must not change the answer for.
      Gori::Hotkeys.rebindable?(reg["detail.copy"]).should be_true
      Gori::Hotkeys.rebindable?(reg["intercept.copy"]).should be_true
    end
  end

  # A rebind moves the READ-mode letter and LEAVES `^Y` where it is. Without the pin the
  # override would replace both chords, and the panes where `^Y` is the only way to copy an INS
  # selection (bare `y` types a `y` there) would silently lose it — which is the risk that kept
  # these verbs out of the editor in the first place.
  describe "pinned chords under a rebind" do
    it "moves the bare letter, keeps ^Y, and advertises the new letter" do
      reg = Gori::Verbs.registry
      os = Gori::Verb::OsProfile.resolve("auto")
      override = {"repeater.copy" => [Gori::Verb::Chord.new("u")]}
      effective = Gori::Verb::Keymap.effective_chords(reg["repeater.copy"], os, override)
      effective.should eq([Gori::Verb::Chord.new("u"), Gori::Verb::Chord.new("y", ctrl: true)])
      # `.first?` is what every advertised label reads, so the row/palette/hint show `u`.
      Gori::Hotkeys.binding_for(reg, "repeater.copy", override).should eq(Gori::Verb::Chord.new("u"))

      km = Gori::Verb::Keymap.build(reg, os, override)
      km.lookup(Gori::Verb::Chord.new("u"), Gori::Verb::Scope::Repeater).should eq("repeater.copy")
      km.lookup(Gori::Verb::Chord.new("y", ctrl: true), Gori::Verb::Scope::Repeater).should eq("repeater.copy")
      km.lookup(Gori::Verb::Chord.new("y"), Gori::Verb::Scope::Repeater).should be_nil
    end

    it "keeps ^Y through an explicit unbind — `y` does nothing, INS copy still works" do
      reg = Gori::Verbs.registry
      os = Gori::Verb::OsProfile.resolve("auto")
      override = {"notes.copy" => [] of Gori::Verb::Chord}
      km = Gori::Verb::Keymap.build(reg, os, override)
      km.lookup(Gori::Verb::Chord.new("y"), Gori::Verb::Scope::Notes).should be_nil
      km.lookup(Gori::Verb::Chord.new("y", ctrl: true), Gori::Verb::Scope::Notes).should eq("notes.copy")
    end

    it "pins nothing on a genuine nav alias, so those stay out of the editor" do
      reg = Gori::Verbs.registry
      Gori::Verb::Keymap.pinned_chords(reg["body.open"]).should be_empty
      Gori::Verb::Keymap.pinned_chords(reg["detail.copy"]).should be_empty
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

    # #1297 moved Save results ⇧S → ⇧E, which was free in the Fuzzer before, so an operator
    # may already have put another Fuzzer verb there. That rebind wins the key (`Keymap.build`
    # writes the user layer last); the footer, Help and the palette must not keep saying ⇧E.
    it "does not advertise a default chord a same-scope rebind took" do
      reg = Gori::Verbs.registry
      e = Gori::Verb::Chord.new("e", shift: true)
      Gori::Hotkeys.binding_for(reg, "fuzz.save-results", {} of String => Array(Gori::Verb::Chord)).should eq(e)
      took = {"fuzzer.oast-insert" => [e]}
      km = Gori::Verb::Keymap.build(reg, Gori::Verb::OsProfile::Os::Linux, took)
      km.lookup(e, Gori::Verb::Scope::Fuzzer).should eq("fuzzer.oast-insert")
      Gori::Hotkeys.binding_for(reg, "fuzz.save-results", took).should be_nil
      Gori::Hotkeys.binding_for(reg, "fuzzer.oast-insert", took).should eq(e)
      # The same chord taken in ANOTHER scope displaces nothing: the Fuzzer still answers it.
      elsewhere = {"repeater.send" => [e]}
      Gori::Hotkeys.binding_for(reg, "fuzz.save-results", elsewhere).should eq(e)
    end

    it "names the chord of the verb a keyless one declares `chord_of:`, and follows its rebind (#1295)" do
      reg = Gori::Verbs.registry
      reg["repeater.toggle-resp-hex"].chords.should be_empty
      Gori::Hotkeys.binding_for(reg, "repeater.toggle-resp-hex").should eq(Gori::Verb::Chord.new("x", ctrl: true))
      working = {"repeater.toggle-hex" => [Gori::Verb::Chord.new("j", ctrl: true)]}
      Gori::Hotkeys.binding_for(reg, "repeater.toggle-resp-hex", working).should eq(Gori::Verb::Chord.new("j", ctrl: true))
      # A chord of its own (a rebind of the row itself) wins.
      own = {"repeater.toggle-resp-hex" => [Gori::Verb::Chord.new("o", ctrl: true)]}
      Gori::Hotkeys.binding_for(reg, "repeater.toggle-resp-hex", own).should eq(Gori::Verb::Chord.new("o", ctrl: true))
      # …and its default is the same borrowed chord, not "unbound" (the Hotkeys editor's reset).
      Gori::Hotkeys.default_for(reg, "repeater.toggle-resp-hex", "auto").should eq(Gori::Verb::Chord.new("x", ctrl: true))
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

  describe ".expand" do
    it "resolves every {verb.id} token to the verb's effective chord and leaves the prose alone" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.expand(reg, "{fuzz.run} run · {fuzz.stop} stop · esc back")
        .should eq("^R run · ^X stop · esc back")
      Gori::Hotkeys.expand(reg, "{comparer.pick-a}/{comparer.pick-b} pick").should eq("a/b pick")
    end

    it "follows a user override, and falls back to the default for an unbound verb" do
      reg = Gori::Verbs.registry
      ov = {"fuzz.run" => [Gori::Verb::Chord.new("s", ctrl: true)], "fuzz.stop" => [] of Gori::Verb::Chord}
      Gori::Hotkeys.expand(reg, "{fuzz.run} run · {fuzz.stop} stop", ov).should eq("^S run · ^X stop")
    end

    it "leaves an unknown or keyless token as written, and never touches other braces" do
      reg = Gori::Verbs.registry
      # `oast.copy` is a real verb with no default chord — a token naming it is an authoring
      # error the Help spec would catch, and here it stays visible instead of vanishing.
      Gori::Hotkeys.expand(reg, "{no.such.verb} · {oast.copy} · {\"a\":1} · {}").should eq("{no.such.verb} · {oast.copy} · {\"a\":1} · {}")
      Gori::Hotkeys.expand(reg, "no tokens here").should eq("no tokens here")
    end
  end

  # The menu path is read off the verb's `menu_key` (the letter the space menu itself draws),
  # never from a hand-written literal — the Help sheet printed three wrong ones that way (#1274).
  describe ".menu_path / {space:verb.id}" do
    it "spells a menu-only verb's path from its menu_key, and nil for no menu row" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.menu_path(reg, "sequence.promote").should eq("space → #{reg["sequence.promote"].menu_key}")
      # A SUB-TABS row is inside Sub-tabs… from a pane, at level 1 on the strip (#1274).
      Gori::Hotkeys.menu_path(reg, "repeater.tag-subtab").should eq("space → T g")
      Gori::Hotkeys.menu_path(reg, "repeater.tag-subtab", strip_focus: true).should eq("space → g")
      Gori::Hotkeys.menu_path(reg, "repeater.paste-curl").should eq("space → U") # pinned
      Gori::Hotkeys.menu_path(reg, "sitemap.tag").should eq("space → m")
      Gori::Hotkeys.menu_path(reg, "no.such.verb").should be_nil
      # Hidden navigation verb: its chords are named keys, so it derives no menu letter.
      Gori::Hotkeys.menu_path(reg, "sitemap.toggle").should be_nil
    end

    it "expands inside a hint, next to {verb.id} tokens, and ignores a rebind" do
      reg = Gori::Verbs.registry
      ov = {"fuzz.matched" => [Gori::Verb::Chord.new("q")]}
      Gori::Hotkeys.expand(reg, "{space:fuzz.sort} sort · {fuzz.matched} matched", ov)
        .should eq("space → o sort · q matched")
      Gori::Hotkeys.expand(reg, "{space:fuzz.sort} sort").should eq("space → o sort")
    end

    it "never prints the raw token: no registry or no menu row reads as the space menu" do
      reg = Gori::Verbs.registry
      fallback = Gori::Hotkeys::MENU_PATH_FALLBACK
      Gori::Hotkeys.expand_menu_paths(nil, "set with {space:sitemap.tag}").should eq("set with #{fallback}")
      Gori::Hotkeys.expand(reg, "{space:no.such.verb} · {space:sitemap.toggle}").should eq("#{fallback} · #{fallback}")
      Gori::Hotkeys.expand_menu_paths(nil, "{\"space\":1} · {sitemap.query}").should eq("{\"space\":1} · {sitemap.query}")
    end
  end

  # A palette-only verb (`menu: :palette`, #1282) has no menu path, so a `{space:…}` token or a
  # Help row naming it reads as the route that does exist: its chord, else the palette search.
  describe ".menu_chip" do
    it "spells a menu path compactly from the registry, and a bare ␣ without one (#1295)" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.menu_chip(reg, "repeater.toggle-grpc-reframe").should eq("␣#{reg.menu_keys("repeater.toggle-grpc-reframe").not_nil!.join}")
      Gori::Hotkeys.menu_chip(reg, "sitemap.toggle-static").should eq("␣Zs")
      Gori::Hotkeys.menu_chip(nil, "sitemap.toggle-static").should eq("␣")
      Gori::Hotkeys.menu_chip(reg, "no.such-verb").should eq("␣")
    end
  end

  describe ".route" do
    it "is the menu path for a menu row, the chord or ^P → title for a palette-only verb" do
      reg = Gori::Verbs.registry
      Gori::Hotkeys.route(reg, "sitemap.tag").should eq("space → m")
      Gori::Hotkeys.menu_path(reg, "repeater.minimize").should be_nil
      Gori::Hotkeys.route(reg, "repeater.minimize").should eq("^P → Minimize request")
      Gori::Hotkeys.route(reg, "decoder.save").should eq("^S")
      Gori::Hotkeys.route(reg, "no.such.verb").should be_nil
      Gori::Hotkeys.route(reg, "sitemap.toggle").should be_nil # hidden, no row, not palette-only
    end

    it "follows a rebind of the palette and of the verb" do
      reg = Gori::Verbs.registry
      ov = {"app.palette"  => [Gori::Verb::Chord.new("k", ctrl: true)],
            "decoder.save" => [Gori::Verb::Chord.new("q")]}
      Gori::Hotkeys.route(reg, "repeater.minimize", ov).should eq("^K → Minimize request")
      Gori::Hotkeys.route(reg, "decoder.save", ov).should eq("q")
      Gori::Hotkeys.expand(reg, "with {space:repeater.minimize}", ov).should eq("with ^K → Minimize request")
    end
  end

  describe ".claimed?" do
    it "covers the pre-keymap ctrl letter/digit/punct set" do
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("p", ctrl: true)).should be_true
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("1", ctrl: true)).should be_true
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new(",", ctrl: true)).should be_true # ^, preferences
      Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("c")).should be_false
      Gori::Hotkeys::CLAIMED_CTRL_LETTERS.should contain("g")
      Gori::Hotkeys::CLAIMED_CTRL_LETTERS.should contain("p")
    end

    it "claims the ⌥ twins only while the alias is on" do
      with_modifier("ctrl") do
        Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("p", alt: true)).should be_false
      end
      with_modifier("alt") do
        # Both forms fire the guard under the alias, so both must be refused a binding.
        Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("p", alt: true)).should be_true
        Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("p", ctrl: true)).should be_true
        Gori::Hotkeys.claimed?(Gori::Verb::Chord.new("r", alt: true)).should be_false
      end
    end
  end

  describe ".retag" do
    it "rewrites only the claimed family, and only under the alias" do
      with_modifier("ctrl") do
        Gori::Hotkeys.retag("^P cmds · ^R send").should eq("^P cmds · ^R send")
      end
      with_modifier("alt") do
        Gori::Hotkeys.retag("^P cmds").should eq("⌥P cmds")
        Gori::Hotkeys.retag("^1-9 jump · ^N new · ^W close").should eq("⌥1-9 jump · ⌥N new · ⌥W close")
        Gori::Hotkeys.retag("^, preferences").should eq("⌥, preferences")
        # NOT claimed — these keep their carets or the hints would lie.
        Gori::Hotkeys.retag("^R send · ^S SNI · ^X hex · ^D quit").should eq("^R send · ^S SNI · ^X hex · ^D quit")
      end
    end
  end

  describe ".alias_conflicts" do
    it "names verbs whose own alt binding the alias has just shadowed" do
      reg = Gori::Verbs.registry
      prev = Gori::Settings.keymap_overrides
      begin
        Gori::Settings.keymap_overrides = {"capture.toggle" => ["alt-n"], "scope.edit" => ["alt-r"]}
        with_modifier("ctrl") { Gori::Hotkeys.alias_conflicts(reg).should be_empty }
        with_modifier("alt") do
          # alt-n is a claimed twin (^N new); alt-r is not claimed and survives.
          Gori::Hotkeys.alias_conflicts(reg).should eq(["capture.toggle"])
        end
      ensure
        Gori::Settings.keymap_overrides = prev
      end
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

    it "refuses the ⌥ twin under the alias and names it in the reason" do
      with_modifier("ctrl") { Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("p", alt: true)).should be_nil }
      with_modifier("alt") do
        Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("p", alt: true)).should eq("⌥P is reserved by a gori shortcut")
        Gori::Hotkeys.reserved?(Gori::Verb::Chord.new("s", alt: true)).should be_nil # still not claimed
      end
    end
  end

  describe ".binding_for under the ⌥ alias" do
    it "advertises the alt twin for a claimed FIXED verb, and leaves others alone" do
      reg = Gori::Verbs.registry
      with_modifier("ctrl") do
        Gori::Hotkeys.binding_for(reg, "app.palette").should eq(Gori::Verb::Chord.new("p", ctrl: true))
      end
      with_modifier("alt") do
        Gori::Hotkeys.binding_for(reg, "app.palette").should eq(Gori::Verb::Chord.new("p", alt: true))
        Gori::Hotkeys.binding_label(reg, "app.palette", "∅").should eq("⌥P")
        # ^R (repeater send) is keymap-driven, not claimed — it must not move.
        Gori::Hotkeys.binding_for(reg, "repeater.send").should eq(Gori::Verb::Chord.new("r", ctrl: true))
      end
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

# `expand` runs per frame and is memoized on the keymap revision; the memo must turn over
# the moment a binding changes, or a rebind would keep advertising the old chord until the
# process restarted.
describe "Gori::Hotkeys.expand memo" do
  it "re-expands after Settings.keymap_overrides changes" do
    reg = Gori::Verbs.registry
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Hotkeys.expand(reg, "{fuzz.run} run").should eq("^R run")
      Gori::Settings.keymap_overrides = {"fuzz.run" => ["ctrl-s"]}
      Gori::Hotkeys.expand(reg, "{fuzz.run} run").should eq("^S run")
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Hotkeys.expand(reg, "{fuzz.run} run").should eq("^R run")
    ensure
      Gori::Settings.keymap_overrides = prev
    end
  end

  it "bumps the keymap revision on every keymap setter" do
    r0 = Gori::Settings.keymap_revision
    os, mod = Gori::Settings.keymap_os, Gori::Settings.command_modifier
    begin
      Gori::Settings.keymap_os = os
      Gori::Settings.command_modifier = mod
      Gori::Settings.keymap_overrides = Gori::Settings.keymap_overrides
    ensure
      Gori::Settings.keymap_os = os
      Gori::Settings.command_modifier = mod
    end
    (Gori::Settings.keymap_revision - r0).should be >= 3_u32
  end
end
