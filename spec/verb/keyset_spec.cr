require "../spec_helper"

# src/gori/verb/keyset.cr — the editor KEYSET layer. Four things carry it:
#   1. The override ORDER (user > keyset > OS profile > declared). A keyset is a better
#      DEFAULT, never a ceiling; if it outranked a per-verb rebind, picking `vim` would
#      quietly undo work the operator did in settings:keys.
#   2. `helix` is a NO-OP. It is defined as "today's keys", so the moment its table holds a
#      row, "the default keyset" and "what the verb files declare" are two things to keep in
#      step — and every spec that reads a chord off a verb file starts lying.
#   3. Every keyset boots on every OS profile (`Registry#validate_chords!`), which is where a
#      collision introduced by a bundle-sized substitution has to surface.
#   4. The vim table only ever respells verbs that EXIST. A row for a verb the registry does
#      not have is a key bound to nothing; a select-line verb the table misses is an operator
#      whose `x` moved on fourteen tabs and not the fifteenth.
private alias Chord = Gori::Verb::Chord
private alias Keyset = Gori::Verb::Keyset
private alias Keymap = Gori::Verb::Keymap

describe Gori::Verb::Keyset do
  r = Gori::Verbs.registry

  it "ships helix as a no-op, so the default keymap IS what the verb files declare" do
    Keyset.overrides_for(Keyset::Kind::Helix).should be_empty
    Keyset::DEFAULT.should eq(Keyset::Kind::Helix)
    Gori::Settings::DEFAULT_EDITOR_KEYSET.should eq("helix")
    r.each do |v|
      Keymap.effective_chords(v, Gori::Verb::OsProfile::Os::Linux, Keymap::NO_OVERRIDES,
        Keyset::Kind::Helix).should eq(v.chords)
    end
  end

  it "layers user > keyset > OS profile > declared" do
    os = Gori::Verb::OsProfile::Os::Linux
    verb = r["notes.select-line"]
    verb.chords.should eq([Chord.new("x")]) # 4: what the file says

    # 2: the keyset moves it…
    Keymap.effective_chords(verb, os, Keymap::NO_OVERRIDES, Keyset::Kind::Vim)
      .should eq([Chord.new("v", shift: true)])

    # 1: …and a per-verb rebind moves it again, keyset or no keyset. This is the whole
    # contract: "I want vim keys, except this one" has to be expressible.
    mine = {"notes.select-line" => [Chord.new("z")]}
    Keymap.effective_chords(verb, os, mine, Keyset::Kind::Vim).should eq([Chord.new("z")])
    Keymap.effective_chords(verb, os, mine, Keyset::Kind::Helix).should eq([Chord.new("z")])
  end

  it "keeps a PINNED ^Y through a keyset row, as it does through a user rebind" do
    # Nothing in the vim table moves a Copy verb today. The rule is asserted anyway because
    # the failure is invisible: a keyset that carried `^Y` off with `y` would leave the INS
    # half of that pane with no way to copy at all (Keymap.pinned_chords states why).
    copy = r["notes.copy"]
    copy.chords.should eq([Chord.new("y"), Chord.new("y", ctrl: true)])
    faked = {"notes.copy" => [Chord.new("c", shift: true)]}
    Keymap.effective_chords(copy, Gori::Verb::OsProfile::Os::Linux, faked, Keyset::Kind::Helix)
      .should eq([Chord.new("c", shift: true), Chord.new("y", ctrl: true)])
  end

  it "names a real verb in every vim row, and covers every keyed select-line verb" do
    Keyset::VIM.each_key { |id| r[id]?.should_not be_nil }
    # The sweep the hand-written list exists to be checked against: every SELECT-LINE verb
    # that has a key today must get the vim spelling, or an operator's `x` moves on fourteen
    # panes and not the fifteenth.
    keyed = r.select { |v| v.id.ends_with?("select-line") && v.chords.includes?(Chord.new("x")) }
    keyed.map(&.id).sort!.should eq(Keyset::SELECT_LINE_IDS.sort)
    # `intercept.select-line` is the keyless one, deliberately left out — a keyset respells
    # keys and does not hand one to a pane whose author decided against it.
    r["intercept.select-line"].chords.should be_empty
    Keyset::VIM.has_key?("intercept.select-line").should be_false
  end

  it "has no ENABLE/DISABLE-rule `x` left to leave alone — the letter means one thing" do
    # This example used to name three verbs. Four rule lists spent bare `x` on "turn this rule
    # on/off" rather than on "select this line", which is the split KEY_AUDIT F4 named and has
    # now settled: all four toggles are `t` ("flip this row's flag", which is what `t` means as
    # MARK in History, Issues, the Sitemap and the Intercept queue), and a rule list has no
    # marks for it to collide with.
    #
    # It matters HERE, and not only to the key grammar. The keyset's whole premise is that `x`
    # is one question, so `⇧V` can answer it everywhere: while those three held the letter, a
    # vim operator's ⇧V was a state change on three tabs, and on a fourth — the Rewriter, whose
    # toggle was a CONTROLLER arm because `x` was claimed twice in one scope — `⇧V` fell
    # through to that arm instead of selecting a line at all. F4 removes both, so the sweep
    # below is empty by construction and `Keyset::SELECT_LINE_IDS` covers the letter whole.
    toggles = r.select { |v| v.chords.includes?(Chord.new("x")) && !v.id.ends_with?("select-line") }
    toggles.map(&.id).should be_empty
    # …and the four that gave the letter up are on `t`, with the Rewriter's a real chord now
    # rather than the arm the keymap could not express.
    %w[colormarker.toggle oast.toggle-provider probe-rules.toggle rewriter.toggle].each do |id|
      r[id].chords.should eq([Chord.new("t")]), id
      Keyset::VIM.has_key?(id).should be_false, id
    end
    Keyset::SELECT_LINE_IDS.should contain("rewriter.select-line")
  end

  it "spells the vim table the way the docs say" do
    Keyset::SELECT_LINE_IDS.each do |id|
      Keyset::VIM[id].should eq([Chord.new("v", shift: true)])
    end
    Keyset::VIM["editor.undo"].should eq([Chord.new("u")])
    Keyset::VIM["editor.find"].should eq([Chord.new("/")])
    Keyset::VIM["editor.append"].should eq([Chord.new("a")])
    Keyset::VIM["editor.top"].should eq([Chord.new("g")])
    Keyset::VIM["editor.bottom"].should eq([Chord.new("g", shift: true)])
    # Not moved, and each for a stated reason (see the table's comment + hotkeys.md):
    #   copy — `y` is already vim's letter, and `yy` is a two-key sequence
    #   insert / back-to-READ — gori already spells them `i` and `esc`
    #   goto-line — vim spells it `:N`, and `:` is reserved for the command line
    #   delete-line — there is no delete in a READ-mode pane to bind
    %w[notes.copy editor.insert editor.exit-insert editor.goto-line].each do |id|
      Keyset::VIM.has_key?(id).should be_false
    end
  end

  it "resolves an unknown keyset name to the shipped one rather than to no keys" do
    Keyset.resolve("vim").should eq(Keyset::Kind::Vim)
    Keyset.resolve("helix").should eq(Keyset::Kind::Helix)
    Keyset.resolve("emacs").should eq(Keyset::Kind::Helix)
    Keyset.resolve("").should eq(Keyset::Kind::Helix)
    Gori::Settings.normalize_editor_keyset("emacs").should eq("helix")
  end

  it "boots every keyset on every OS profile" do
    # `validate_chords!` sweeps the matrix itself; this asserts the matrix is actually built
    # (a keymap per cell, with no same-scope collision raised) and that `vim` is not somehow
    # producing the same table as `helix`.
    Gori::Verb::OsProfile::Os.each do |os|
      Keyset::Kind.each do |ks|
        km = Keymap.build(r, os, Keymap::NO_OVERRIDES, ks)
        km.lookup_in(Chord.new("i"), Gori::Verb::Scope::Editor).should eq("editor.insert")
      end
      helix = Keymap.build(r, os, Keymap::NO_OVERRIDES, Keyset::Kind::Helix)
      vim = Keymap.build(r, os, Keymap::NO_OVERRIDES, Keyset::Kind::Vim)
      helix.lookup_in(Chord.new("x"), Gori::Verb::Scope::Repeater).should eq("repeater.select-line")
      vim.lookup_in(Chord.new("x"), Gori::Verb::Scope::Repeater).should be_nil
      vim.lookup_in(Chord.new("v", shift: true), Gori::Verb::Scope::Repeater).should eq("repeater.select-line")
    end
  end

  it "puts the vim keys where a Repeater READ pane and a Notes pane will find them" do
    # The two panes named in the decision. `Scope::Editor` is consulted ahead of the tab's own
    # scope while a text pane holds focus, so an editor pane resolves BOTH tables.
    vim = Keymap.build(r, Gori::Verb::OsProfile::Os::Darwin, Keymap::NO_OVERRIDES, Keyset::Kind::Vim)
    ed = Gori::Verb::Scope::Editor
    vim.lookup_in(Chord.new("u"), ed).should eq("editor.undo")
    vim.lookup_in(Chord.new("/"), ed).should eq("editor.find")
    vim.lookup_in(Chord.new("a"), ed).should eq("editor.append")
    vim.lookup_in(Chord.new("g"), ed).should eq("editor.top")
    vim.lookup_in(Chord.new("g", shift: true), ed).should eq("editor.bottom")
    vim.lookup_in(Chord.new("i"), ed).should eq("editor.insert") # unmoved
    vim.lookup_in(Chord.new("escape"), ed).should eq("editor.exit-insert")

    [Gori::Verb::Scope::Repeater, Gori::Verb::Scope::Notes].each do |scope|
      vim.lookup_in(Chord.new("v", shift: true), scope).should eq(
        scope.repeater? ? "repeater.select-line" : "notes.select-line")
      vim.lookup_in(Chord.new("y"), scope).should eq(scope.repeater? ? "repeater.copy" : "notes.copy")
    end
  end

  it "leaves the SUB-TABS bucket's nine letters alone" do
    # #1055 put the strip's bucket into EVERY pane view of a tab that has a strip, so its nine
    # letters are reserved across those menus. A keyset writes to the KEYMAP and never to
    # `menu_key` (which reads a verb's DECLARED chords), so the two namespaces cannot collide
    # — but that is a property worth pinning rather than re-deriving, because the day a keyset
    # row lands on a strip verb it would move a letter that must read the same on all nine.
    strip = r.select { |v| {:subtab, :tab}.includes?(v.section) && v.menu_key }
    strip.size.should be > 50 # the bucket really is registered per tab
    strip.each { |v| Keyset::VIM.has_key?(v.id).should be_false }
    # …and the menu letter a keyset-moved verb shows is unchanged by the keyset.
    r["notes.select-line"].menu_key.should eq('x')
  end

  it "does not displace a tab-scope key in any editor pane" do
    # The Editor scope sits AHEAD of the tab's scope, which `validate_chords!` cannot see — it
    # sweeps one scope at a time. So the vim bare letters are checked BY HAND here against the
    # eight scopes an editor pane can belong to. A hit is not a bug in itself (the keyset wins
    # in that pane, by design) but it is a DISPLACEMENT that has to be listed in the docs, so
    # it must not appear by accident.
    editor_scopes = [
      Gori::Verb::Scope::Repeater, Gori::Verb::Scope::Notes, Gori::Verb::Scope::Decoder,
      Gori::Verb::Scope::Jwt, Gori::Verb::Scope::Cookie, Gori::Verb::Scope::Fuzzer,
      Gori::Verb::Scope::IssuesDetail, Gori::Verb::Scope::ProjectDesc,
    ]
    vim = Keymap.build(r, Gori::Verb::OsProfile::Os::Linux, Keymap::NO_OVERRIDES, Keyset::Kind::Vim)
    bare = [Chord.new("u"), Chord.new("/"), Chord.new("a"), Chord.new("g"), Chord.new("g", shift: true)]
    editor_scopes.each do |scope|
      bare.each do |c|
        if hit = vim.lookup_in(c, scope)
          fail "vim keyset chord #{c.label} is shadowed onto #{hit} in #{scope} — list it as a displacement"
        end
      end
    end
  end
end
