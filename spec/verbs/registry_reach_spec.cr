require "../spec_helper"

# Every registered verb must be reachable from SOME keyboard surface. `sequence.export-json`
# was not: no chord, no `mnemonic:`, so `Definition#menu_key` returned nil, `SpaceMenu#open`
# filters on `menu_key`, and the palette only queries `Scope::Global`. A shipped export with
# a handler, an `ExecContext` method and no way to invoke it.
#
# The three surfaces, and the whole rule:
#   • a chord      → the keymap fires it
#   • a menu_key   → the space menu lists it (explicit `mnemonic:`, else a plain 1-char chord)
#   • Scope::Global → the palette lists it regardless
describe "verb reachability" do
  it "leaves no verb without a keyboard path" do
    unreachable = [] of String
    Gori::Verbs.registry.each do |v|
      next if v.hidden?                            # a gesture, not a listed command
      next if v.scope == Gori::Verb::Scope::Global # the palette lists these by scope alone
      next unless v.chords.empty?
      next if v.menu_key
      unreachable << v.id
    end
    unreachable.should be_empty
  end

  it "keeps a hidden verb's chord, since hidden means unlisted rather than unbound" do
    # The exemption above is only safe while `hidden: true` implies a chord — a hidden verb
    # with neither would be just as unreachable, and the check would wave it through.
    Gori::Verbs.registry.each do |v|
      v.chords.should_not be_empty if v.hidden?
    end
  end
end

# A rule list's actions belong to the KEYMAP, not to a hand-rolled `case` in its controller.
# Four of the six deferred (Scope, Env, Host overrides, Probe rules); Rewriter and Colormarker
# hardcoded `a / ↵,e / d / x / ⇧X / s / ⇧J / ⇧K` and registered every verb with `[] of Chord`,
# so those two lists alone could not be rebound and their keys never met the `available?` gate
# the space menu uses.
describe "rule-list keys" do
  it "are real chords on the verbs, for every rule list" do
    r = Gori::Verbs.registry
    {
      "scope.add-rule", "env.add-var", "hostoverride.add-entry", "probe-rules.add",
      "colormarker.add",
    }.each do |id|
      r[id].chords.should_not be_empty
    end
  end

  it "gives Colormarker the same key set its controller used to hardcode" do
    r = Gori::Verbs.registry
    plain = ->(k : String) { typed_chord(k) }
    shift = ->(k : String) { typed_chord(k, shift: true) }
    r["colormarker.add"].chords.should contain(plain.call("a"))
    r["colormarker.edit"].chords.should contain(plain.call("e"))
    r["colormarker.edit"].chords.should contain(plain.call("enter"))
    r["colormarker.delete"].chords.should contain(plain.call("d"))
    r["colormarker.toggle"].chords.should contain(plain.call("x"))
    r["colormarker.scope"].chords.should contain(plain.call("s"))
    r["colormarker.toggle-default"].chords.should contain(shift.call("x"))
    r["colormarker.move-down"].chords.should contain(shift.call("j"))
    r["colormarker.move-up"].chords.should contain(shift.call("k"))
    # …and the menu letter now names the key. It was 'g', which matched neither the verb
    # ("Enable/disable everywhere") nor its ⇧X binding.
    r["colormarker.toggle-default"].menu_key.should eq('X')
  end
end

# `b` is the whitespace letter across the app: the global reveal is ^B (`view.reveal-ws`) and
# the History detail binds bare `b` to `detail.toggle-ws`. The Repeater's space menu spent it
# on hex — one keystroke away from a pane where the same letter reveals whitespace — while its
# own chord for hex was ^X all along.
describe "hex and whitespace letters" do
  r = Gori::Verbs.registry

  it "never spends `b` on hex" do
    r.each do |v|
      next unless v.id.includes?("hex")
      v.menu_key.should_not eq('b')
    end
  end

  it "keeps hex on ^X wherever it has a chord at all" do
    ctrl_x = typed_chord("x", ctrl: true)
    r.each do |v|
      next unless v.id.includes?("hex")
      next if v.chords.empty? # the response-pane dump is menu-only; ^X reaches it pane-dispatched
      v.chords.should contain(ctrl_x)
    end
  end

  it "leaves the two that CANNOT take `x`, and says why" do
    # Not drift — a real collision in each displayable view:
    #   HistoryDetail   `x` is `detail.select-line`      → `detail.toggle-hex` stays 'e'
    #   Repeater :response `x` is `repeater.select-line` → `repeater.toggle-resp-hex` stays 'h'
    r["repeater.toggle-hex"].menu_key.should eq('x')
    r["detail.toggle-hex"].menu_key.should eq('e')
    r["detail.select-line"].menu_key.should eq('x')
    r["repeater.toggle-resp-hex"].menu_key.should eq('h')
  end
end

# Every multi-session tab's sub-tab strip supports rename and close — `Runner#renameable_subtabs?`
# and `#subtab_close` list :miner and :sequencer alongside the rest. Only the VERBS were
# missing, so Miner's `:subtab` menu group held Duplicate alone and the Sequencer had no
# `:subtab` group at all, and neither key could be rebound in either.
describe "sub-tab verbs" do
  r = Gori::Verbs.registry

  # {tab prefix, close verb id} — Decoder and JWT spell theirs `*.close` in `:common` while
  # the rest use `*.close-subtab` in `:subtab`. NOT unified here on purpose: a verb id is what
  # a saved keybinding stores, so renaming one silently drops the operator's binding. The
  # split is a naming inconsistency worth its own migration, not a drive-by rename.
  {
    {"repeater", "repeater.close-subtab"},
    {"fuzz", "fuzz.close-subtab"},
    {"comparer", "comparer.close-subtab"},
    {"decoder", "decoder.close"},
    {"jwt", "jwt.close"},
    {"mine", "mine.close-subtab"},
    {"sequence", "sequence.close-subtab"},
  }.each do |(prefix, close_id)|
    it "gives #{prefix} both a rename and a close" do
      r["#{prefix}.rename-subtab"]?.should_not be_nil
      r["#{prefix}.rename-subtab"].menu_key.should_not be_nil
      r[close_id]?.should_not be_nil
      r[close_id].menu_key.should eq('w')
    end
  end

  # WHERE close lands in the menu. `SpaceMenu#open` renders COMMON ∪ the focused pane's
  # section, so a `:subtab` close is invisible from the body — an operator editing in a pane
  # has to move focus to the strip first. Decoder and JWT fixed that for themselves ("Round 4",
  # decoder_spec) and the rest inherited the old placement, which read as the majority.
  it "files close under COMMON, so it is reachable from the body" do
    {"decoder.close", "jwt.close", "comparer.close-subtab",
     "mine.close-subtab", "sequence.close-subtab"}.each do |id|
      r[id].section.should eq(:common)
    end
  end

  it "leaves Repeater and Fuzzer out, because `w` is taken in their editor sections" do
    # NOT drift: `repeater.mark-word` / `fuzz.mark-word` own 'w' in `:request` / `:template`,
    # and a COMMON entry renders alongside them — `Registry#validate_menu_keys!` would raise
    # at boot. `^W` still closes from anywhere; only the menu row is strip-only there.
    r["repeater.close-subtab"].section.should eq(:subtab)
    r["fuzz.close-subtab"].section.should eq(:subtab)
    r["repeater.mark-word"].menu_key.should eq('w')
    r["repeater.mark-word"].section.should eq(:request)
    r["fuzz.mark-word"].menu_key.should eq('w')
    r["fuzz.mark-word"].section.should eq(:template)
  end

  it "puts rename on `e` everywhere it can" do
    # One letter across the family. JWT is the documented exception: `jwt.toggle-mode` owns
    # 'e' in its COMMON group, and the menu shows COMMON plus the focused section.
    {"repeater", "fuzz", "comparer", "decoder", "mine", "sequence"}.each do |prefix|
      r["#{prefix}.rename-subtab"].menu_key.should eq('e')
    end
    r["jwt.rename-subtab"].menu_key.should eq('r')
    r["jwt.toggle-mode"].menu_key.should eq('e')
  end
end

# The Rewriter's rule list moved onto the keymap — with ONE key held back, for a structural
# reason worth pinning so nobody "fixes" it later.
describe "Rewriter rule keys" do
  r = Gori::Verbs.registry

  it "binds every rule action except toggle" do
    plain = ->(k : String) { typed_chord(k) }
    r["rewriter.add"].chords.should contain(plain.call("a"))
    r["rewriter.edit"].chords.should contain(plain.call("e"))
    r["rewriter.delete"].chords.should contain(plain.call("d"))
    r["rewriter.scope"].chords.should contain(plain.call("s"))
    r["rewriter.move-up"].chords.should contain(typed_chord("k", shift: true))
    r["rewriter.toggle-default"].chords.should contain(typed_chord("x", shift: true))
  end

  it "leaves `x` to the controller, because the KEYMAP has no focus dimension" do
    # `rewriter.select-line` binds bare `x` in this same SCOPE for the preview pane. Two
    # `section:`s never render together so the space menu is fine with `x` meaning two
    # things — but `Keymap#lookup` is keyed by scope alone and returns ONE id, so a chord on
    # `rewriter.toggle` would shadow one of them. `RewriterController#handle_list_key` runs
    # only when the LIST has focus, which is the disambiguation the keymap cannot express.
    r["rewriter.toggle"].chords.should be_empty
    r["rewriter.select-line"].chords.should contain(typed_chord("x"))
    r["rewriter.toggle"].menu_key.should eq('x') # still the letter, in its own section
    r["rewriter.select-line"].section.should eq(:preview)
    r["rewriter.toggle"].section.should eq(:rules)
    # Colormarker COULD take the chord: it has no read pane, so nothing else claims `x`.
    r["colormarker.toggle"].chords.should contain(typed_chord("x"))
  end
end

# `^E` is `Hotkeys::CLAIMED_CTRL_LETTERS` — the shell's open-in-$EDITOR, claimed before any
# tab sees it. JWT hardcoded it for its lens switch, which WORKED (the shell's ^E branch has
# no `:jwt` arm and falls through) but could never be a registered chord: `keymap_spec`'s
# "no rebindable default chord that is reserved" check refuses it, and did. So the key was
# unbindable, and it spent the letter that would one day give this tab's INPUT pane an
# external editor.
#
# That reserved rule lives in `keymap_spec` and is not repeated here — it already exempts the
# four verbs that ARE the claimed handlers (`app.palette` ^P, `view.reveal-ws` ^B, the two
# `*.new` ^N) via `Hotkeys.rebindable?`. This pins only where JWT landed.
describe "JWT's lens switch" do
  it "is on ^T, the Repeater's letter for the same gesture" do
    r = Gori::Verbs.registry
    ctrl_t = typed_chord("t", ctrl: true)
    r["jwt.toggle-mode"].chords.should contain(ctrl_t)
    # `repeater.toggle-decoded` is "switch which representation this pane shows" — the same
    # question, and it has held ^T all along.
    r["repeater.toggle-decoded"].chords.should contain(ctrl_t)
  end

  it "no longer claims a letter the shell reserves" do
    Gori::Verbs.registry["jwt.toggle-mode"].chords.each do |c|
      Gori::Hotkeys::CLAIMED_CTRL_LETTERS.should_not contain(c.key) if c.ctrl
    end
  end
end

# A letter that changes meaning one `↵` into a drill-in is the sharpest kind of drift: the
# list and its detail are the same workflow, and nothing on screen says the vocabulary moved.
describe "list vs drill-in letters" do
  r = Gori::Verbs.registry

  it "keeps `O` meaning OAST payload, and only that" do
    # Three scopes agree; HistoryDetail carries no OAST verb, so its `O` (Copy flow) was the
    # letter re-pointing under the operator between the History list and its own detail.
    %w(history.oast-copy repeater.oast-insert fuzzer.oast-insert).each do |id|
      r[id].menu_key.should eq('O')
    end
    r.each do |v|
      next if v.id.includes?("oast")
      v.menu_key.should_not eq('O')
    end
  end

  # NOT asserted, and deliberately — two more the audit surfaced where the KEYS already agree
  # and only the menu letter differs, each with its reasoning already in the source:
  #
  #   `t`  Issues list = mark, Issues detail = edit title (issues.cr:73 — the detail is a modal
  #        drill-in and `t` = mark is the cross-tab convention across four list tabs, so that
  #        one wins; the detail's rename is reversible and marks are meaningless there).
  #   `o`  Issues menu = open row, Probe menu = open EVIDENCE flow (probe.cr:18 — `probe.open`
  #        keeps the family's enter/l/right chords, so the keys an operator presses agree;
  #        only the menu letter moved, to 'v').
  #
  # Both are judgement calls that were made once with a written reason. Pinning them here
  # would freeze the reason as a rule, which is not the same thing.
end
