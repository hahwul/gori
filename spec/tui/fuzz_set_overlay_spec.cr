require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def okey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def otype(ov : FuzzSetOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(okey(Termisu::Input::Key::LowerA, c)) }
end

private def ctrl_d : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerD, Termisu::Input::Modifier::Ctrl)
end

describe Gori::Tui::FuzzSetOverlay do
  it "List: multi-line values build a newline-joined spec (newline = a new value)" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Down)) # Type row → the values editor
    otype(ov, "admin")
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "root")
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:list)
    spec.value.should eq("admin\nroot\n")
    Gori::Tui::SetSpec.list_values(spec.value).should eq(["admin", "root"])
    spec.display.should eq("admin,root")
  end

  it "List: a comma inside a value is payload text, not a separator" do
    ov = FuzzSetOverlay.for_list
    otype(ov, %({"id":1,"role":"admin"}))
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "' OR 1=1,--")
    spec = ov.build_spec.not_nil!
    Gori::Tui::SetSpec.list_values(spec.value).should eq([%({"id":1,"role":"admin"}), "' OR 1=1,--"])
    # …and reopening the set shows the same two lines, not four.
    FuzzSetOverlay.editing(spec, 0).build_spec.not_nil!.value.should eq(spec.value)
  end

  it "List: typing on the Type row (before any nav) drops into the values editor" do
    # ^L opens focused on the Type selector; the first keystroke/paste must not be lost.
    ov = FuzzSetOverlay.for_list
    otype(ov, "admin")
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "root")
    ov.build_spec.not_nil!.value.should eq("admin\nroot\n")
  end

  it "Numbers: bounds above Int32::MAX survive build_spec (Int64 range)" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Right))                 # List → Numbers
    ov.handle_key(okey(Termisu::Input::Key::Down))                  # Type row → From
    5.times { ov.handle_key(okey(Termisu::Input::Key::Backspace)) } # clear "1"
    otype(ov, "3000000000")
    ov.build_spec.not_nil!.value.should eq("3000000000-100:1")
  end

  it "seeds a LEGACY comma-joined List set (a session saved before the newline grammar)" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:list, "a,b,c"), 0)
    ov.edit_index.should eq(0)
    Gori::Tui::SetSpec.list_values("a,b,c").should eq(["a", "b", "c"])
    ov.build_spec.not_nil!.value.should eq("a\nb\nc\n") # re-saved under the current grammar
  end

  it "esc returns :commit; a blank List yields nil so @sets stays unchanged" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Escape)).should eq(:commit)
    ov.build_spec.should be_nil
  end

  it "Numbers: the from/to/step defaults build the range grammar" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Right)) # Type: List → Numbers
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:numbers)
    spec.value.should eq("1-100:1")
  end

  it "Wordlist maps to the :file kind" do
    ov = FuzzSetOverlay.for_list
    2.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # → Wordlist
    ov.handle_key(okey(Termisu::Input::Key::Down))              # → the Path field
    otype(ov, "/tmp/words.txt")
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:file)
    spec.value.should eq("/tmp/words.txt")
  end

  it "Brute builds the charset:min-max grammar from its defaults" do
    ov = FuzzSetOverlay.for_list
    4.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # → Brute
    ov.build_spec.not_nil!.value.should eq("abc:1-3")
  end

  it "cycling the Type row wraps back to List" do
    ov = FuzzSetOverlay.for_list
    6.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # list→…→brute→preset→list
    ov.handle_key(okey(Termisu::Input::Key::Down))              # values editor
    otype(ov, "x")
    ov.build_spec.not_nil!.kind.should eq(:list)
  end

  it "Preset: selecting the type yields a :preset set with a built-in name (←/→ cycles)" do
    ov = FuzzSetOverlay.for_list
    5.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # List → … → Preset (last)
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:preset)
    Gori::Fuzz::Presets.names.should contain(spec.value) # a real preset name
    ov.handle_key(okey(Termisu::Input::Key::Down))       # Type row → the Preset selector
    ov.handle_key(okey(Termisu::Input::Key::Right))      # cycle to the next preset
    ov.build_spec.not_nil!.value.should_not eq(spec.value)
  end

  it "seeds a :preset set back onto its selector" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:preset, "traversal"), 1)
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:preset)
    spec.value.should eq("traversal")
  end

  it "renders the preset selector with the available names" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:preset, "sqli"), 0)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("Preset").should be_true
    backend.contains?("sqli").should be_true
    backend.contains?("payloads").should be_true # the count meta line
  end

  it "seeds a Numbers set back into its from/to/step fields" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:numbers, "5-50:5"), 2)
    ov.build_spec.not_nil!.value.should eq("5-50:5")
  end

  it "renders the box with the type selector and applies esc semantics" do
    ov = FuzzSetOverlay.for_list
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("PAYLOAD SET").should be_true
    backend.contains?("List").should be_true
  end

  it "^D on the wordlist Path field toggles the typed path in/out of favorites" do
    dir = File.tempname("gori-fuzz-set-overlay-favorite")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.fuzz_favorite_wordlists = [] of String

      ov = FuzzSetOverlay.for_list
      2.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # List → Wordlist
      ov.handle_key(okey(Termisu::Input::Key::Down))              # Type row → the Path field
      otype(ov, "/tmp/words.txt")

      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_false
      ov.handle_key(ctrl_d).should eq(:stay) # doesn't apply/close the overlay
      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_true
      # the star indicator renders alongside the Path field once favorited
      backend = MemoryBackend.new(120, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("★").should be_true

      ov.handle_key(ctrl_d) # toggle back off
      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_false

      # the path itself is untouched — ^D only manages favorites
      ov.build_spec.not_nil!.value.should eq("/tmp/words.txt")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.fuzz_favorite_wordlists = [] of String
    end
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(FuzzSetOverlay.for_list).assert_chrome(OverlayKind::FuzzSet, "PAYLOAD SET")
  end

  it "esc applies the edited set through the injected closure" do
    ov = FuzzSetOverlay.for_list
    applied = [] of SetSpec?
    h = OverlayHarness.new(ov)
    h.on_commit do
      applied << ov.build_spec
      true
    end
    h.press(Termisu::Input::Key::Down) # Type row → the values editor
    h.type("a").should eq(:open)
    h.press(Termisu::Input::Key::Enter) # ↵ opens a new value line, it does NOT apply
    h.commits.should eq(0)
    h.type("b").should eq(:open)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    applied.map(&.try(&.value)).should eq(["a\nb\n"])
  end

  it "↵ on the last FIELD row applies (Numbers: From/To/Step)" do
    ov = FuzzSetOverlay.for_list
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Right)            # Type: List → Numbers
    3.times { h.press(Termisu::Input::Key::Down) } # Type → From → To → Step (the last row)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.build_spec.not_nil!.value.should eq("1-100:1")
  end

  it "a click outside the card APPLIES rather than dismissing" do
    # This modal has no cancel: apply_close_fuzz_set was the shell's click-away path too.
    away = OverlayHarness.new(FuzzSetOverlay.for_list)
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(1)
  end

  it "a click on the Type row focuses it and stays open" do
    ov = FuzzSetOverlay.for_list
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down) # move off the Type row into the values editor
    h.click_in_box(2, 1).should eq(:open)
    h.commits.should eq(0)
    # Proof the Type row really took focus back: → cycles the payload type there, whereas
    # in the values editor the same key only moves the caret.
    h.press(Termisu::Input::Key::Right)
    ov.build_spec.not_nil!.kind.should eq(:numbers)
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    h = OverlayHarness.new(FuzzSetOverlay.for_list)
    h.press(Termisu::Input::Key::Right) # Type: List → Numbers (rows: type/from/to/step)
    h.wheel(3)                          # → Step, the last row
    # ↵ applies only from the last row — on the Type row it would just advance.
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
  end

  it "APPLIES a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # editor diverges from the base class on purpose: the pre-seam shell ran
    # `apply_close_fuzz_set(ov) if box.nil?`, so an unrenderable card must APPLY, and the
    # inherited :cancel would silently drop the payload set the user had already typed.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:list, "a,b"), 0)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:commit)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(1)
    h.rendered?("payload set editor").should be_true
  end

  it "hit-tests rows against the rect the shell passes (layout.body)" do
    # Production hands an overlay `layout.body` — shorter than the screen and offset from it,
    # so this 20-row card renders clipped to 14 and sits lower. Only CLICKS can tell the two
    # areas apart: handle_key never sees `area`, so driving keys through a smaller rect would
    # be a byte-for-byte copy of the DEFAULT_AREA examples above. A 16-row body is what yields
    # the 14-row card now that every modal insets from its area by 2.
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzSetOverlay.for_list
    h = OverlayHarness.new(ov, area: body)
    box = h.box.not_nil!
    box.h.should eq(14) # clipped from the 20 rows DEFAULT_AREA would allow

    h.press(Termisu::Input::Key::Down) # Type row → the values editor
    h.type("admin")
    # The Type row sits at box.y + 1 of the SMALLER box; clicking it must take focus back.
    h.click(box.x + 2, box.y + 1).should eq(:open)
    h.press(Termisu::Input::Key::Right) # → cycles the type, which only the Type row does
    ov.build_spec.not_nil!.kind.should eq(:numbers)

    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(1)
  end

  it "routes IME preedit into the focused editor" do
    ov = FuzzSetOverlay.for_list
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down) # into the values editor
    h.type("x")                        # non-empty, so the editor renders instead of the placeholder
    h.preedit("한")
    h.rendered?("한").should be_true
    ov.build_spec.not_nil!.value.should eq("x\n") # composing text is not in the buffer yet
  end

  # `Overlay#handle_click` places the caret in whichever listed field the press landed in —
  # "a press inside a drawn field is a caret, not a no-op". This card overrides handle_click
  # to pick the row and used to stop there, so the caret stayed wherever the last keystroke
  # left it and the next character went somewhere the operator did not point.
  it "places the caret where a click lands in a field, not where typing left it" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:brute, "abcdef:1:3"), 0)
    area = Rect.new(0, 0, 120, 30)
    ov.render(Screen.new(MemoryBackend.new(120, 30)), area)
    box = ov.overlay_box(area).not_nil!

    # Charset is the first field row of :brute, drawn at box.y + 3, value column at +2+LABEL_W.
    value_x = box.x + 2 + 9
    ov.handle_click(area, value_x + 3, box.y + 3).should eq(:stay)
    otype(ov, "X")

    ov.build_spec.not_nil!.value.should start_with("abcXdef")
  end

  # `@fields` holds all eight for every payload type while `render_fields` draws only the
  # current type's rows, so an off-screen field kept the geometry it was drawn at under a
  # PREVIOUS type and could win a hit-test against a click meant for a visible one.
  it "exposes only the payload type's own fields to the pointer" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:brute, "abcdef:1:3"), 0)
    ov.text_fields.size.should eq(3) # charset, min, max — not all eight

    # NOTE: the SetSpec kind is `:file`; `:wordlist` is the overlay's ptype name for it.
    wl = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:file, "/tmp/w.txt"), 0)
    wl.text_fields.size.should eq(1) # path

    # :preset has no TextField at all, so the card must not claim drag support for it.
    pre = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:preset, "sqli"), 0)
    pre.text_fields.should be_empty
    pre.supports_drag?.should be_false
  end
end
