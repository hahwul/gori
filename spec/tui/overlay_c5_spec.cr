require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# Batch C5 of the Overlay migration (#355): the Preferences family — the unified modal and
# the theme / tab-bar / hostnames / env / hotkeys editors it opens.
#
# Everything here rides OverlayHarness, which replays Runner#dispatch_overlay_key /
# #dispatch_overlay_click, so these lock the routing runner.cr no longer spells out:
# a handle_*_key method and six `case @overlay` arms per modal were deleted, and the
# behaviour they encoded now has to live in the overlay or in an injected closure.
#
# The three things worth being careful about, and why each gets examples below:
#   * the ADD/PREFIX sub-modes of the hostnames + env editors folded into their parent
#     overlay, so esc there must cancel the SUB-MODE and leave the modal up;
#   * the hotkey rebinder's capture mode, which the shell routes to ahead of its own
#     ^C/^D quit-arm — the overlay answers for that by BEING a modal, not through
#     `raw_key_capture?`: `Runner.quit_chord_claimed?` yields both chords whenever an
#     Overlay is up (that is what stopped ^D in the Fuzzer payload-set editor from
#     quitting gori), so `raw_key_capture?` now only governs the raw-dispatch branch;
#   * the nested lifecycle, which was a shell-wide `@prefs_return` flag and is now
#     `Overlay#on_close`, running on a cancel AND on a commit that closed.
#
# CAVEAT on driving keys: these overlays branch on `ev.key` for navigation (`key.lower_k?`)
# and on `ev.char` for mnemonics, exactly as the deleted Runner handlers did. So a mnemonic
# is pressed as `press(Key::LowerA, 'a')` and vim-nav as `press(Key::LowerK)` — `type` would
# send every char on Key::LowerA and silently miss the nav branch.

private ESC   = Termisu::Input::Key::Escape
private ENTER = Termisu::Input::Key::Enter
private SPACE = Termisu::Input::Key::Space
private LEFT  = Termisu::Input::Key::Left
private RIGHT = Termisu::Input::Key::Right
private DOWN  = Termisu::Input::Key::Down
private UP    = Termisu::Input::Key::Up
private TAB   = Termisu::Input::Key::Tab
private BKSP  = Termisu::Input::Key::Backspace
private ALPHA = Termisu::Input::Key::LowerA

# Press a printable mnemonic the way the terminal delivers it: the real char attached, so
# `ev.char` sees it. The key itself is irrelevant to every mnemonic branch in this family.
private def mnemonic(h : OverlayHarness, c : Char) : Symbol
  h.press(ALPHA, c)
end

# ^P — the one chord every modal in this family claims, to leave for the command palette.
private def ctrl_p(h : OverlayHarness) : Symbol
  h.press(Termisu::Input::Key::LowerP, ctrl: true)
end

# A Ctrl chord as the terminal delivers it, aimed STRAIGHT at the overlay. `Event::Key#char`
# is `@char || key.to_char`, so a Ctrl+D event reports 'd' — and `Runner.quit_chord_claimed?`
# yields ^C/^D whenever a modal is up (quit_chord_spec.cr), so that 'd' really does arrive at
# a mnemonic arm here. `handle_key` rather than `press` because OverlayHarness's own header
# says it does not model the shell's pre-filter, and because `:stay` is what has to be pinned.
private def ctrl_chord(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::Ctrl, nil)
end

# ---------------------------------------------------------------------------------------
# TAB BAR
# ---------------------------------------------------------------------------------------

# Hide every tab but one, so the next space hits the "last visible" refusal. Each toggle
# succeeds until only one is left standing, whose toggle is refused — which also parks the
# selection on that row.
private def leave_one_visible(o : TabsOverlay) : Nil
  o.to_prefs.each_with_index do |(_, vis), i|
    next unless vis
    o.set_selected(i)
    o.toggle_selected
  end
end

describe "C5 · TabsOverlay on the Overlay seam" do
  it "supplies the chrome the collapsed title/hint ladders read off it" do
    OverlayHarness.new(TabsOverlay.new).assert_chrome(OverlayKind::Tabs, "TAB BAR")
  end

  it "applies the working copy on ↵ and discards it on esc" do
    ov = TabsOverlay.new
    ov.on_commit = -> { true } # mirrors the open-site's save_tabs
    h = OverlayHarness.new(ov)
    h.press(ENTER).should eq(:closed)
    h.commits.should eq(1)

    esc = OverlayHarness.new(TabsOverlay.new)
    esc.press(ESC).should eq(:closed)
    esc.commits.should eq(0) # esc must never persist the working copy
  end

  it "reorders with K/J and only moves the selection with k/j" do
    ov = TabsOverlay.new
    before = ov.to_prefs
    h = OverlayHarness.new(ov)
    mnemonic(h, 'j') # selection down only
    ov.to_prefs.should eq(before)
    mnemonic(h, 'J') # now reorder the row the selection landed on
    ov.to_prefs[1].should eq(before[2])
    ov.to_prefs[2].should eq(before[1])
  end

  it "refuses to hide the last visible tab and reports the refusal as a toast" do
    ov = TabsOverlay.new
    toasts = [] of String
    ov.on_toast = ->(m : String) { toasts << m; nil }
    leave_one_visible(ov)
    h = OverlayHarness.new(ov)
    h.press(SPACE, ' ').should eq(:open)
    toasts.should eq(["keep at least one tab visible"])
    ov.to_prefs.count { |(_, vis)| vis }.should eq(1) # the hide really was refused
  end

  it "keeps the modal up while r raises the shell's reset confirm" do
    # The confirm outlives the keystroke, so `r` must NOT close the editor — the reset
    # lands later, from the confirm's action, on this same instance.
    ov = TabsOverlay.new
    resets = 0
    ov.on_reset = -> { resets += 1; nil }
    h = OverlayHarness.new(ov)
    mnemonic(h, 'r').should eq(:open)
    resets.should eq(1)
    h.commits.should eq(0)
  end

  it "selects the clicked row, so a reorder after it moves that row and not row 0" do
    ov = TabsOverlay.new
    before = ov.to_prefs
    h = OverlayHarness.new(ov)
    h.click_in_box(5, 4).should eq(:open) # list starts at box.y+2 → third row (index 2)
    mnemonic(h, 'J')
    after = ov.to_prefs
    after[2].should eq(before[3])
    after[3].should eq(before[2])
    after[0].should eq(before[0]) # row 0 untouched — the click really moved the selection
  end

  it "dismisses on a click away without applying anything" do
    h = OverlayHarness.new(TabsOverlay.new)
    h.overlay.handle_click(h.area, 0, 0).should eq(:cancel) # raw vocabulary, not just :closed
    h.click(0, 0).should eq(:closed)
    h.commits.should eq(0)
  end

  it "scrolls the selection with the wheel" do
    ov = TabsOverlay.new
    before = ov.to_prefs
    h = OverlayHarness.new(ov)
    h.wheel(3) # one notch, already ±3-scaled like Runner#handle_wheel
    mnemonic(h, 'J')
    ov.to_prefs[3].should eq(before[4]) # selection had moved to index 3
    ov.to_prefs[4].should eq(before[3])
  end

  it "runs on_close after a commit AND after a cancel — the pop-back into Preferences" do
    # This is what replaced @prefs_return + settle_sub_editor. Both exits have to reach it:
    # saving the tab bar from inside the Preferences modal must land back there too, not
    # only escaping out of it.
    {ENTER, ESC}.each do |k|
      ov = TabsOverlay.new
      backs = 0
      ov.on_close = -> { backs += 1; nil }
      ov.on_commit = -> { true }
      h = OverlayHarness.new(ov)
      h.press(k).should eq(:closed)
      backs.should eq(1), "on_close did not run for #{k}"
    end
  end

  it "leaves the shell's ^C/^D quit-arm alone" do
    TabsOverlay.new.raw_key_capture?.should be_false
  end
end

# ---------------------------------------------------------------------------------------
# HOSTNAME OVERRIDES
# ---------------------------------------------------------------------------------------

private def with_hosts(entries : Array({String, String}), &)
  prev = Gori::Settings.hostname_overrides
  Gori::Settings.hostname_overrides = entries
  yield
ensure
  Gori::Settings.hostname_overrides = prev.not_nil!
end

# The editor wired the way its open-site wires it, minus the disk write: `on_save` reports
# a successful persist so the toasts take their "saved" branch.
private def hosts_editor(saves : Array(Int32)? = nil, toasts : Array(String)? = nil,
                         persisted : Bool = true) : HostsOverlay
  ov = HostsOverlay.new
  ov.on_save = -> { saves.try(&.<<(1)); persisted }
  ov.on_toast = ->(m : String) { toasts.try(&.<<(m)); nil }
  ov
end

describe "C5 · HostsOverlay on the Overlay seam" do
  it "supplies chrome, and swaps the hint when the add row opens" do
    with_hosts([] of {String, String}) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      h.assert_chrome(OverlayKind::Hosts, "HOSTNAME OVERRIDES")
      ov.hint.should contain("a add")
      mnemonic(h, 'a')
      ov.hint.should contain(%("IP host")) # the add row owns the bottom row while it is up
    end
  end

  it "commits a valid entry from the add row and persists it" do
    with_hosts([] of {String, String}) do
      saves = [] of Int32
      toasts = [] of String
      ov = hosts_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("10.0.0.1 staging.acme.test")
      h.press(ENTER).should eq(:open) # ↵ commits the ROW, never the modal
      ov.to_overrides.should eq([{"staging.acme.test", "10.0.0.1"}])
      saves.size.should eq(1)
      # `added` / `updated`, the distinction the Project pane editing the same list already
      # made — the overlay holds `@edit_index` and simply never said which it had done.
      toasts.last.should eq("host override added — 1 total")
    end
  end

  it "reports a failed disk write without pretending the entry was saved" do
    with_hosts([] of {String, String}) do
      toasts = [] of String
      ov = hosts_editor(nil, toasts, persisted: false)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("10.0.0.1 staging.acme.test")
      h.press(ENTER)
      ov.to_overrides.size.should eq(1) # applied in memory…
      toasts.last.should contain("could not save")
      toasts.last.should_not contain("host override saved")
    end
  end

  it "rejects a malformed entry with a toast and adds nothing" do
    with_hosts([] of {String, String}) do
      saves = [] of Int32
      toasts = [] of String
      ov = hosts_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("not-an-ip")
      h.press(ENTER)
      ov.to_overrides.should be_empty
      saves.should be_empty # nothing to persist
      toasts.last.should contain("need")
    end
  end

  it "esc in the add row cancels the ROW, not the modal" do
    # The sub-mode folded into this overlay; the shell no longer has a handle_hosts_add_key
    # to route to, so the overlay itself has to swallow that esc.
    with_hosts([] of {String, String}) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      ov.adding?.should be_true
      h.press(ESC).should eq(:open)
      ov.adding?.should be_false
      h.press(ESC).should eq(:closed) # a second esc, now in the list, closes it
    end
  end

  it "backspace on an empty add input cancels the row, but not while it has text" do
    with_hosts([] of {String, String}) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("1")
      h.press(BKSP)
      ov.adding?.should be_true # deleted the char, kept the row
      h.press(BKSP)
      ov.adding?.should be_false # nothing left to delete → the row backs out
    end
  end

  it "types the IP/host separator on Tab instead of jumping focus" do
    with_hosts([] of {String, String}) do
      saves = [] of Int32
      ov = hosts_editor(saves)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("10.0.0.1")
      h.press(TAB)
      h.type("acme.test")
      h.press(ENTER)
      ov.to_overrides.should eq([{"acme.test", "10.0.0.1"}]) # Tab landed as the space
    end
  end

  it "edits the selected row in place rather than appending a duplicate" do
    with_hosts([{"acme.test", "10.0.0.1"}]) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      h.press(ENTER) # ↵ on a list row opens the edit form seeded with that row
      ov.adding?.should be_true
      9.times { h.press(BKSP) } # trim exactly "acme.test" off "10.0.0.1 acme.test"
      h.type("beta.test")
      h.press(ENTER)
      ov.to_overrides.should eq([{"beta.test", "10.0.0.1"}]) # replaced, not appended
    end
  end

  it "deletes the selected row and persists" do
    with_hosts([{"acme.test", "10.0.0.1"}, {"beta.test", "10.0.0.2"}]) do
      saves = [] of Int32
      toasts = [] of String
      ov = hosts_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'd')
      ov.to_overrides.should eq([{"beta.test", "10.0.0.2"}])
      saves.size.should eq(1)
      toasts.last.should eq("host override deleted: acme.test")
    end
  end

  it "does NOT delete on ^D — the quit chord must not reach the `d` mnemonic" do
    # The chord the operator presses to leave gori, landing on the destructive delete one
    # example up because the mnemonic arm reads `ev.char` with no modifier guard. Nothing
    # may be removed, and nothing may be written to disk on the way out.
    with_hosts([{"app.test", "127.0.0.1"}, {"api.test", "10.0.0.1"}]) do
      saves = [] of Int32
      ov = hosts_editor(saves)

      ov.handle_key(ctrl_chord(Termisu::Input::Key::LowerD)).should eq(:stay)
      ov.to_overrides.should eq([{"app.test", "127.0.0.1"}, {"api.test", "10.0.0.1"}])
      saves.should be_empty
    end
  end

  it "still hands ^P to the palette — the ctrl arm sits above the char read" do
    with_hosts([{"app.test", "127.0.0.1"}]) do
      jumps = 0
      ov = hosts_editor
      ov.on_palette = -> { jumps += 1; nil }
      ov.handle_key(ctrl_chord(Termisu::Input::Key::LowerP)).should eq(:stay)
      jumps.should eq(1)
    end
  end

  it "navigates with k/j (the key, not the char) and the wheel" do
    with_hosts([{"a.test", "10.0.0.1"}, {"b.test", "10.0.0.2"}, {"c.test", "10.0.0.3"}]) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::LowerJ)
      h.press(Termisu::Input::Key::LowerJ)
      mnemonic(h, 'd')
      ov.to_overrides.map(&.[0]).should eq(["a.test", "b.test"]) # deleted the third

      ov2 = hosts_editor
      h2 = OverlayHarness.new(ov2)
      h2.wheel(3) # clamps to the last row on a 3-entry list
      mnemonic(h2, 'd')
      ov2.to_overrides.map(&.[0]).should eq(["a.test", "b.test"])
    end
  end

  it "dismisses on a click away and selects the clicked row" do
    with_hosts([{"a.test", "10.0.0.1"}, {"b.test", "10.0.0.2"}]) do
      ov = hosts_editor
      h = OverlayHarness.new(ov)
      h.click_in_box(5, 3).should eq(:open) # list starts at box.y+2 → second row
      mnemonic(h, 'd')
      ov.to_overrides.map(&.[0]).should eq(["a.test"]) # the click moved the selection

      away = OverlayHarness.new(hosts_editor)
      away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
      away.click(0, 0).should eq(:closed)
    end
  end
end

# ---------------------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------------------

private def with_env(prefix : String, vars : Array({String, String}), &)
  prev_prefix = Gori::Settings.env_prefix
  prev_vars = Gori::Settings.env_vars
  Gori::Settings.env_prefix = prefix
  Gori::Settings.env_vars = vars
  yield
ensure
  Gori::Settings.env_prefix = prev_prefix.not_nil!
  Gori::Settings.env_vars = prev_vars.not_nil!
end

private def env_editor(saves : Array(Int32)? = nil, toasts : Array(String)? = nil) : EnvOverlay
  ov = EnvOverlay.new
  ov.on_save = -> { saves.try(&.<<(1)); true }
  ov.on_toast = ->(m : String) { toasts.try(&.<<(m)); nil }
  ov
end

describe "C5 · the form overlays must not shadow the Overlay contract" do
  it "keeps `commit` meaning the shell's commit, not the add-row field parser" do
    # Crystal has no `override` keyword, so a form method named `commit` SILENTLY replaces
    # `Overlay#commit`, which the shell calls to run the injected closure and decide whether
    # to close. Both editors used to name their "parse the IP host / KEY VALUE row" method
    # exactly that; it was inert only because neither returns a :commit outcome today, and it
    # would have broken the moment one did — the shell would run the parser and read its
    # truthy Symbol (`:empty`!) as "close me", never running on_commit.
    #
    # Driven through an `Overlay`-typed reference, which is how the shell holds it, so the
    # example fails the same way the shell would.
    with_hosts([] of {String, String}) do
      with_env("$", [] of {String, String}) do
        {HostsOverlay.new.as(Overlay), EnvOverlay.new.as(Overlay)}.each do |ov|
          ran = 0
          ov.on_commit = -> { ran += 1; true }
          ov.commit.should be_true # Bool, not a Symbol
          ran.should eq(1), "#{ov.class} shadowed Overlay#commit with its own method"
        end
      end
    end
  end
end

describe "C5 · EnvOverlay on the Overlay seam" do
  it "supplies chrome, and its hint tracks BOTH sub-modes" do
    # This replaced env_overlay_hints, the one hint the Runner computed in a method rather
    # than a `case` arm — three states, all of which have to survive the move.
    with_env("$", [] of {String, String}) do
      ov = env_editor
      h = OverlayHarness.new(ov)
      h.assert_chrome(OverlayKind::Env, "ENVIRONMENT")
      ov.hint.should contain("p prefix")
      mnemonic(h, 'a')
      ov.hint.should contain(%("KEY VALUE"))
      h.press(ESC)
      mnemonic(h, 'p')
      ov.hint.should contain("type prefix")
    end
  end

  it "commits a KEY VALUE pair from the add row and persists it" do
    with_env("$", [] of {String, String}) do
      saves = [] of Int32
      toasts = [] of String
      ov = env_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("HOST api.example.com")
      h.press(ENTER).should eq(:open)
      ov.to_config[1].should eq([{"HOST", "api.example.com"}])
      saves.size.should eq(1)
      toasts.last.should eq("env var added — 1 total")
    end
  end

  it "rejects a malformed pair and refuses a duplicate KEY" do
    with_env("$", [{"HOST", "api.example.com"}]) do
      toasts = [] of String
      ov = env_editor(nil, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'a')
      h.type("1BAD value")
      h.press(ENTER).should eq(:open) # the row stays up, holding the rejected text
      toasts.last.should contain("KEY is")
      ov.to_config[1].should eq([{"HOST", "api.example.com"}])

      h.press(ESC) # back out of the add row, then start a clean one
      mnemonic(h, 'a')
      h.type("HOST other")
      h.press(ENTER)
      toasts.last.should eq("env var: KEY already defined — edit it (e)")
      ov.to_config[1].should eq([{"HOST", "api.example.com"}]) # unchanged
    end
  end

  it "edits the prefix sigil in its own sub-mode, which esc backs out of" do
    with_env("$", [] of {String, String}) do
      saves = [] of Int32
      toasts = [] of String
      ov = env_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'p')
      ov.prefix_editing?.should be_true
      h.press(ESC).should eq(:open) # cancels the SUB-MODE, not the modal
      ov.prefix_editing?.should be_false
      ov.to_config[0].should eq("$")

      mnemonic(h, 'p')
      h.press(BKSP) # clear the seeded "$"
      h.type("%")
      h.press(ENTER).should eq(:open)
      ov.to_config[0].should eq("%")
      saves.size.should eq(1)
      toasts.last.should eq(%(env prefix saved — "%"))
    end
  end

  it "rejects an empty prefix instead of persisting a blank sigil" do
    with_env("$", [] of {String, String}) do
      saves = [] of Int32
      toasts = [] of String
      ov = env_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      mnemonic(h, 'p')
      h.press(BKSP)
      h.press(ENTER)
      toasts.last.should eq("env prefix: empty")
      saves.should be_empty
      ov.to_config[0].should eq("$")
    end
  end

  it "deletes the selected var and persists" do
    with_env("$", [{"HOST", "a"}, {"TOKEN", "b"}]) do
      saves = [] of Int32
      toasts = [] of String
      ov = env_editor(saves, toasts)
      h = OverlayHarness.new(ov)
      h.press(DOWN)
      mnemonic(h, 'd')
      ov.to_config[1].should eq([{"HOST", "a"}])
      saves.size.should eq(1)
      # `<noun> deleted: <name>` — the shape every delete-success toast uses now, so it reads
      # in parallel with its own failure line.
      toasts.last.should eq("env var deleted: TOKEN")
    end
  end

  it "does NOT delete on ^D — the quit chord must not reach the `d` mnemonic" do
    # Same arm as the hostnames editor's, and the same cost: a var the operator never asked
    # to lose, deleted and persisted by the first half of a two-press quit.
    with_env("$", [{"TOKEN", "abc"}, {"HOST", "x"}]) do
      saves = [] of Int32
      ov = env_editor(saves)

      ov.handle_key(ctrl_chord(Termisu::Input::Key::LowerD)).should eq(:stay)
      ov.to_config[1].should eq([{"TOKEN", "abc"}, {"HOST", "x"}])
      saves.should be_empty
    end
  end

  it "still hands ^P to the palette — the ctrl arm sits above the char read" do
    with_env("$", [{"TOKEN", "abc"}]) do
      jumps = 0
      ov = env_editor
      ov.on_palette = -> { jumps += 1; nil }
      ov.handle_key(ctrl_chord(Termisu::Input::Key::LowerP)).should eq(:stay)
      jumps.should eq(1)
    end
  end

  it "esc closes from the list, and a click away dismisses" do
    with_env("$", [] of {String, String}) do
      h = OverlayHarness.new(env_editor)
      h.press(ESC).should eq(:closed)

      away = OverlayHarness.new(env_editor)
      away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
      away.click(0, 0).should eq(:closed)
    end
  end
end

# ---------------------------------------------------------------------------------------
# HOTKEYS — the capture-mode carve-out
# ---------------------------------------------------------------------------------------

private def fresh_hotkeys : HotkeysOverlay
  Gori::Settings.keymap_os = "auto"
  Gori::Settings.keymap_overrides = {} of String => Array(String)
  HotkeysOverlay.new(Gori::Verbs.registry)
end

private def reset_keymap : Nil
  Gori::Settings.keymap_os = "auto"
  Gori::Settings.keymap_overrides = {} of String => Array(String)
end

describe "C5 · HotkeysOverlay on the Overlay seam" do
  it "supplies chrome, and its hint switches to the capture prompt" do
    ov = fresh_hotkeys
    OverlayHarness.new(ov).assert_chrome(OverlayKind::Hotkeys, "HOTKEYS")
    ov.hint.should contain("rebind")
    ov.begin_capture
    ov.hint.should eq("press a key to bind · esc cancel")
  ensure
    reset_keymap
  end

  it "claims every key ahead of the shell's pre-filter ONLY while capturing" do
    # runner.cr:975 — the global ^C/^D quit-arm is skipped, and the key handed straight to
    # the modal, exactly when this is true. If it answered true in browse mode the app
    # could no longer be quit from the hotkeys editor; if it answered false in capture,
    # binding ^C/^D would arm a quit instead of being rejected inline by reserved.cr.
    ov = fresh_hotkeys
    ov.raw_key_capture?.should be_false
    ov.begin_capture
    ov.raw_key_capture?.should be_true
    ov.cancel_capture
    ov.raw_key_capture?.should be_false
  ensure
    reset_keymap
  end

  it "records the next key as a binding and returns to browse" do
    ov = fresh_hotkeys
    h = OverlayHarness.new(ov)
    mnemonic(h, 'e') # e/␣ enter capture on the selected row
    ov.capturing?.should be_true
    h.press(Termisu::Input::Key::LowerY, 'y', alt: true).should eq(:open)
    ov.capturing?.should be_false
    working, _ = ov.to_working
    working.values.first.should eq(Gori::Verb::Chord.new("y", alt: true))
  ensure
    reset_keymap
  end

  it "esc in capture backs out to browse and binds nothing" do
    ov = fresh_hotkeys
    h = OverlayHarness.new(ov)
    mnemonic(h, ' ')
    ov.capturing?.should be_true
    h.press(ESC).should eq(:open) # NOT a modal dismiss — capture owns that esc
    ov.capturing?.should be_false
    ov.to_working[0].should be_empty
    h.press(ESC).should eq(:closed) # …and now the browse esc does close it
  ensure
    reset_keymap
  end

  it "stays in capture on a reserved chord instead of applying it" do
    ov = fresh_hotkeys
    h = OverlayHarness.new(ov)
    mnemonic(h, 'e')
    h.press(Termisu::Input::Key::LowerC, 'c', ctrl: true).should eq(:open)
    ov.capturing?.should be_true # reserved.cr rejected it inline
    ov.to_working[0].should be_empty
    h.rendered?("quits gori").should be_true # and said why, in the card's footer
  ensure
    reset_keymap
  end

  it "applies the working copy on ↵ and discards it on esc" do
    ov = fresh_hotkeys
    ov.on_commit = -> { true } # mirrors save_hotkeys at the open-site
    h = OverlayHarness.new(ov)
    h.press(ENTER).should eq(:closed)
    h.commits.should eq(1)

    esc = OverlayHarness.new(fresh_hotkeys)
    esc.press(ESC).should eq(:closed)
    esc.commits.should eq(0)
  ensure
    reset_keymap
  end

  it "cycles the OS profile with ←/→ and dismisses on a click away" do
    ov = fresh_hotkeys
    h = OverlayHarness.new(ov)
    h.press(RIGHT).should eq(:open)
    ov.to_working[1].should_not eq("auto")
    h.press(LEFT)
    ov.to_working[1].should eq("auto")

    away = OverlayHarness.new(fresh_hotkeys)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
    away.click(0, 0).should eq(:closed)
  ensure
    reset_keymap
  end
end

# ---------------------------------------------------------------------------------------
# SETTINGS CARD (the theme swatch list)
# ---------------------------------------------------------------------------------------

private def with_theme(name : String, &)
  prev = Gori::Settings.theme
  Gori::Settings.theme = name
  yield
ensure
  Gori::Settings.theme = prev.not_nil!
  Theme.apply(prev.not_nil!)
end

describe "C5 · SettingsOverlay on the Overlay seam" do
  it "supplies the chrome the collapsed ladders read off it" do
    with_theme("gori") do
      OverlayHarness.new(SettingsOverlay.new(:theme)).assert_chrome(OverlayKind::Settings, "SETTINGS")
    end
  end

  it "live-previews the theme the selection lands on, by key and by wheel" do
    with_theme("gori") do
      ov = SettingsOverlay.new(:theme)
      previews = [] of String?
      ov.on_preview = -> { previews << ov.theme_value; nil }
      h = OverlayHarness.new(ov)
      h.press(DOWN)
      h.wheel(1)
      previews.size.should eq(2)
      previews.compact.size.should eq(2)          # :theme always names a theme
      previews.uniq.size.should eq(previews.size) # each step landed on a DIFFERENT theme
    end
  end

  it "saves the focused section on ↵ and hands the toast to the shell, staying open" do
    with_theme("gori") do
      ov = SettingsOverlay.new(:theme)
      saved = [] of {Symbol, String}
      ov.on_save = ->(sec : Symbol, msg : String) { saved << {sec, msg}; nil }
      h = OverlayHarness.new(ov)
      h.press(DOWN)
      h.press(ENTER).should eq(:open) # ↵ saves the section; it does NOT close the card
      saved.size.should eq(1)
      saved.first[0].should eq(:theme)
      Gori::Settings.theme.should_not eq("gori") # the moved-to theme really persisted
    end
  end

  it "keeps the card up while ^R raises the shell's reset confirm" do
    with_theme("gori") do
      ov = SettingsOverlay.new(:theme)
      resets = 0
      ov.on_reset = -> { resets += 1; nil }
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::LowerR, ctrl: true).should eq(:open)
      resets.should eq(1)
    end
  end

  it "cancels on esc and on a click away, so the shell can revert the preview" do
    with_theme("gori") do
      h = OverlayHarness.new(SettingsOverlay.new(:theme))
      h.press(ESC).should eq(:closed)
      h.closes.should eq(1) # on_close is where revert_theme_preview hangs

      away = OverlayHarness.new(SettingsOverlay.new(:theme))
      away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
      away.click(0, 0).should eq(:closed)
    end
  end

  it "opens an action row's own editor instead of saving the section" do
    # Network's "Hostname overrides" row. The card only ever shows :theme in-app, but the
    # opener path is the field engine's, not the theme section's — and the same branch
    # serves the mouse (click) and the keyboard (↵).
    with_theme("gori") do
      ov = SettingsOverlay.new(:network)
      opened = [] of Symbol
      ov.on_open_editor = ->(sec : Symbol) { opened << sec; nil }
      saved = 0
      ov.on_save = ->(_s : Symbol, _m : String) { saved += 1; nil }
      h = OverlayHarness.new(ov)
      # Walk to the LAST network field — the Hostnames opener. By count, not a pinned index:
      # what matters is that it is last, and a literal only breaks on the next added field.
      (SettingsView::NETWORK_FIELDS.size - 1).times { h.press(DOWN) }
      h.press(ENTER).should eq(:open)
      opened.should eq([:hosts])
      saved.should eq(0) # an opener row must not persist the section
    end
  end
end

# ---------------------------------------------------------------------------------------
# PREFERENCES — the parent of the nested lifecycle
# ---------------------------------------------------------------------------------------

describe "C5 · PreferencesOverlay on the Overlay seam" do
  it "supplies the chrome the collapsed ladders read off it" do
    OverlayHarness.new(PreferencesOverlay.new).assert_chrome(OverlayKind::Preferences, "PREFERENCES")
  end

  it "closes on esc when clean, and only after the warning when edits are pending" do
    # The view owns this guard; what the overlay adds is the mapping — a warning is :stay,
    # a real close is :cancel. Collapsing both to :cancel would drop typed input silently.
    h = OverlayHarness.new(PreferencesOverlay.new)
    h.press(ESC).should eq(:closed)

    dirty = PreferencesOverlay.new(:general)
    d = OverlayHarness.new(dirty)
    d.press(SPACE, ' ') # flip a toggle in the focused section
    d.press(ESC).should eq(:open)
    d.press(ESC).should eq(:closed)
  end

  it "stays up when an opener row hands off to its dedicated editor" do
    # :open must NOT be :commit or :cancel. The shell's closure opens the editor, which
    # replaces @active_overlay itself — a :cancel here would then close the EDITOR the
    # closure just opened, one keystroke after it appeared.
    ov = PreferencesOverlay.new(:theme)
    opened = [] of Symbol
    ov.on_open_editor = ->(sec : Symbol) { opened << sec; nil }
    h = OverlayHarness.new(ov)
    h.press(ENTER).should eq(:open)
    opened.should eq([:theme])
    h.commits.should eq(0)
    h.closes.should eq(0) # nothing closed → no pop-back fired
  end

  it "reports a save to the shell without closing the modal" do
    prev = Gori::Settings.clipboard_osc52?
    begin
      ov = PreferencesOverlay.new(:general)
      saved = [] of Symbol
      ov.on_saved = ->(sec : Symbol, _m : String) { saved << sec; nil }
      h = OverlayHarness.new(ov)
      h.press(SPACE, ' ') # flip the focused toggle so the save has something to persist
      h.press(ENTER).should eq(:open)
      saved.should eq([:general])
      Gori::Settings.clipboard_osc52?.should eq(!prev)
    ensure
      Gori::Settings.clipboard_osc52 = prev
    end
  end

  it "hands ^P to the shell and lets IT leave the stack" do
    # The palette jump can't be a :cancel: Runner#jump_to_palette drops the whole stack
    # WITHOUT running on_close, precisely so a nested editor's pop-back doesn't re-open on
    # top of the palette. Returning :cancel here would run this modal's on_close instead.
    ov = PreferencesOverlay.new
    jumps = 0
    ov.on_palette = -> { jumps += 1; nil }
    h = OverlayHarness.new(ov)
    ctrl_p(h).should eq(:open)
    jumps.should eq(1)
    h.closes.should eq(0)
  end

  it "dismisses on a click away, through the same unsaved-edits guard as esc" do
    h = OverlayHarness.new(PreferencesOverlay.new)
    h.overlay.handle_click(h.area, 0, 0).should eq(:cancel)
    h.click(0, 0).should eq(:closed)

    dirty = PreferencesOverlay.new(:general)
    d = OverlayHarness.new(dirty)
    d.press(SPACE, ' ')
    d.click(0, 0).should eq(:open) # a stray click must not discard what was typed
    d.click(0, 0).should eq(:closed)
  end

  it "moves the field focus with the wheel" do
    # Asserted through the rendered card because the focused row is private state; the
    # highlight is the only thing the user can actually see move.
    h = OverlayHarness.new(PreferencesOverlay.new(:general))
    before = (0...24).map { |y| h.render.row(y) }
    h.wheel(3)
    after = (0...24).map { |y| h.render.row(y) }
    after.should_not eq(before)
  end
end
