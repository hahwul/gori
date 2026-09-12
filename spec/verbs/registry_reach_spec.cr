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
    r["colormarker.toggle"].chords.should contain(plain.call("t")) # F4: `t` flips a row flag
    # F7: menu-only, so the Global `s` (scope lens) is not shadowed on this tab.
    r["colormarker.scope"].chords.should be_empty
    r["colormarker.scope"].menu_key.should eq('s')
    r["colormarker.toggle-default"].chords.should be_empty # menu-only: ⇧X is the wipe chord elsewhere
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

  # WHERE the strip's verbs land. They no longer have to choose: `SpaceMenu#open` draws
  # `:subtab` ∪ `:tab` as ONE "SUB-TABS" bucket on every view of a tab that has a strip
  # (#1055), so a `:subtab` tag is reachable from the body panes, from the strip, and from
  # the tab bar alike. Half the family used to sit in COMMON purely to escape the old rule;
  # now the whole family is filed where it belongs.
  it "files every strip verb under :subtab, and the strip's search/filter under :tab" do
    {"decoder.close", "jwt.close", "comparer.close-subtab", "mine.close-subtab",
     "sequence.close-subtab", "repeater.close-subtab", "fuzz.close-subtab",
     "repeater.new", "fuzz.new", "decoder.new", "jwt.new", "cookie.new",
     "notes.new", "comparer.new"}.each do |id|
      r[id].section.should eq(:subtab)
    end
    {"repeater.find-subtab", "fuzz.find-subtab", "notes.find-subtab",
     "repeater.filter-subtabs"}.each do |id|
      r[id].section.should eq(:tab)
    end
  end

  it "hands `w` to close, and moves the two editors' mark-word to `W`" do
    # The collision the old placement could not solve: `repeater.mark-word` / `fuzz.mark-word`
    # owned 'w' in `:request` / `:template`, and the bucket now renders alongside them, so
    # `Registry#validate_menu_keys!` would raise at boot. The PANE letter moved, not the
    # strip's — `w` close is one of the nine letters that must read the same on all nine
    # strips, and `W` is the same letter one shift away.
    r["repeater.mark-word"].menu_key.should eq('W')
    r["repeater.mark-word"].section.should eq(:request)
    r["fuzz.mark-word"].menu_key.should eq('W')
    r["fuzz.mark-word"].section.should eq(:template)
  end

  it "puts rename on `e` on every strip that has one" do
    # One letter across the family, with no exception left. The key audit reached for the `r`
    # the STRIP binds, which is the better answer wherever it is available — and it is
    # available on only four of the nine. On the other four, COMMON's 'r' is `*.run` /
    # `repeater.send`, the menu echo of `^R`, and COMMON renders inside the :subtab view: a
    # rename does not displace the Run letter. Two spellings for one action across the nine
    # strips is precisely what the SUB-TABS bucket exists to end, so rename is 'e' on all of
    # them and the strip's raw `r` chord is untouched.
    {"repeater", "fuzz", "comparer", "decoder", "mine", "sequence", "jwt", "cookie"}.each do |prefix|
      r["#{prefix}.rename-subtab"].menu_key.should eq('e'), prefix
    end
    # The four that could not have taken 'r', and why — pinned so the reason outlives the memo.
    {"repeater" => "repeater.send", "fuzz" => "fuzz.run",
     "mine" => "mine.run", "sequence" => "sequence.run"}.each do |_prefix, runner|
      r[runner].menu_key.should eq('r'), runner
      r[runner].section.should eq(:common), runner
    end
    # JWT and Cookie held 'e' for their lens toggle and put rename on 'r'; both toggles moved
    # to 'm' (Mode — the Decoder's letter for the same gesture).
    r["jwt.toggle-mode"].menu_key.should eq('m')
    r["cookie.toggle-mode"].menu_key.should eq('m')
    # Notes derives its chip label from the body text, so it has no rename — which is why
    # `notes.edit` may keep 'e'.
    r["notes.rename-subtab"]?.should be_nil
    r["notes.edit"].menu_key.should eq('e')
  end

  it "gives the strip the SAME nine letters on all nine tabs" do
    # The whole point of the bucket: one table to learn, not nine. A tab that lacks an
    # intent simply omits the row — it never spends that letter on something else.
    {"new" => 'n', "close" => 'w', "duplicate" => 'd', "rename" => 'e', "tag" => 't',
     "find" => 'f', "filter" => '/', "mark-all" => 'T', "mark-clear" => 'N'}.each do |intent, key|
      r.each do |v|
        next unless Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(v.section)
        next unless v.id.ends_with?(intent) || v.id.ends_with?("#{intent}-subtab") ||
                    v.id.ends_with?("#{intent}-subtabs") || v.id.ends_with?("subtab-#{intent}")
        v.menu_key.should eq(key)
      end
    end
  end

  it "puts sub-tab search on the `f` the strip binds, in every tab that has a strip" do
    # `f` on the strip opens this picker in all of them; the menu said 's' on Repeater and
    # Notes, which is a letter the strip does not answer to. It is also one of the nine the
    # SUB-TABS bucket now reserves in EVERY view of those tabs, so what held 'f' had to move
    # whatever else was true: `repeater.fuzz` → 'F' (joining `C` Send to Comparer in that
    # scope's capital send family) and `notes.find` → 's', the letter `notes.find-subtab`
    # vacated, so the pair is a straight swap.
    {"repeater", "fuzz", "mine", "sequence", "comparer", "decoder", "jwt", "cookie", "notes"}
      .each do |prefix|
        r["#{prefix}.find-subtab"].menu_key.should eq('f'), prefix
      end
    r["repeater.fuzz"].menu_key.should eq('F')
    r["notes.find"].menu_key.should eq('s')
    # `history.fuzz` keeps 'z' for the same act in the BODY scope: cross-scope reuse is legal
    # and the two menus never render together.
    r["history.fuzz"].menu_key.should eq('z')
  end
end

# `Verbs.registry` calls `validate_menu_keys!` and `validate_chords!` on its way out, so the
# shipped key set is checked at BOOT. This pins that it stays checked, and pins what the chord
# sweep covers: every OS profile, not just the one this binary was built for. `OVERRIDES` ships
# empty today, so all three resolve to the same keymap — the point is that a future per-OS
# substitution cannot introduce a collision on a profile nobody runs the suite on.
describe "the shipped key set boots clean on every OS profile" do
  it "has no space-menu collision and no chord collision or dead capital" do
    r = Gori::Verbs.registry
    r.validate_menu_keys!
    r.validate_chords!
  end

  it "resolves the same effective chords on macOS, Linux and Windows" do
    r = Gori::Verbs.registry
    per_os = Gori::Verb::OsProfile::Os.values.map do |os|
      keys = {} of String => Array(String)
      r.each { |v| keys[v.id] = Gori::Verb::Keymap.effective_chords(v, os).map(&.label) }
      keys
    end
    per_os.each(&.should(eq(per_os.first)))
    # …and every keymap they build is loadable, which is what the TUI does at start-up.
    Gori::Verb::OsProfile::Os.values.each do |os|
      Gori::Verb::Keymap.build(r, os)
    end
  end
end

# The Rewriter's rule list moved onto the keymap — with ONE key held back, for a structural
# reason worth pinning so nobody "fixes" it later.
describe "Rewriter rule keys" do
  r = Gori::Verbs.registry

  it "binds every rule action, and leaves the two that shadow a Global key to the menu" do
    plain = ->(k : String) { typed_chord(k) }
    r["rewriter.add"].chords.should contain(plain.call("a"))
    r["rewriter.edit"].chords.should contain(plain.call("e"))
    r["rewriter.delete"].chords.should contain(plain.call("d"))
    r["rewriter.move-up"].chords.should contain(typed_chord("k", shift: true))
    r["rewriter.toggle-default"].chords.should be_empty # menu-only: ⇧X is the wipe chord elsewhere
    # global ⇄ project is menu-only since the key audit's F7: `s` is the Global scope lens,
    # and a scoped chord always beats the Global fallback, so this list quietly cost an
    # operator the lens key for an action used when a rule is FILED, not while triaging.
    r["rewriter.scope"].chords.should be_empty
    r["rewriter.scope"].menu_key.should eq('s')
  end

  it "takes a REAL chord on `t`, because F4 moved the toggle off `x` entirely" do
    # This verb had no chord at all, and the reason was structural: `rewriter.select-line`
    # binds bare `x` in this same SCOPE for the preview pane, `Keymap#lookup` is keyed by
    # scope alone and returns ONE id, so a chord on `rewriter.toggle` shadowed one of them —
    # which is why the toggle was hand-rolled in `RewriterController#handle_list_key` and `x`
    # was not rebindable here.
    #
    # On `t` the two never meet, so the verb is an ordinary chord with an ordinary gate: the
    # `available:` lambda asks `rewriter_rule_list_focused?`, which is exactly the pane the
    # deleted arm ran in.
    r["rewriter.toggle"].chords.should eq([typed_chord("t")])
    r["rewriter.toggle"].menu_key.should eq('t')
    r["rewriter.select-line"].chords.should contain(typed_chord("x"))
    r["rewriter.select-line"].section.should eq(:preview)
    r["rewriter.toggle"].section.should eq(:rules)
    # …and the other three rule lists say it the same way.
    {"colormarker.toggle", "probe-rules.toggle", "oast.toggle-provider"}.each do |id|
      r[id].chords.should eq([typed_chord("t")]), id
      r[id].menu_key.should eq('t'), id
    end
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
