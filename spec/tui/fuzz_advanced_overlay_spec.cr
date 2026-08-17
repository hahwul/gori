require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def akey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def blank_snapshot : Gori::Tui::AdvancedSnapshot
  Gori::Tui::AdvancedSnapshot.new(
    conc: "20", rate: "", timeout: "", retries: "0", max_requests: "", race: "",
    follow: false, calibrate: false, keep_alive: true, update_cl: true, reframe_grpc: false,
    m_status: "", m_size: "", m_words: "", m_regex: "",
    f_status: "", f_size: "", f_words: "", f_regex: "")
end

describe Gori::Tui::FuzzAdvancedOverlay do
  it "edits the concurrency text row and reflects it in the snapshot" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    2.times { ov.handle_key(akey(Termisu::Input::Key::Backspace)) } # clear "20"
    "50".each_char { |c| ov.handle_key(akey(Termisu::Input::Key::LowerA, c)) }
    ov.snapshot.conc.should eq("50")
  end

  it "toggles a boolean row with space (←/→ on text rows never toggles it)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    5.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → Follow redirects (row 5, past Max requests)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.follow.should be_true
  end

  it "esc returns :commit so the open-site's closure writes the snapshot back" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.handle_key(akey(Termisu::Input::Key::Escape)).should eq(:commit)
  end

  it "renders every field on its own labeled row" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("ADVANCED").should be_true
    backend.contains?("Concurrency").should be_true
    backend.contains?("Match status").should be_true
    backend.contains?("Filter regex").should be_true
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot)).assert_chrome(OverlayKind::FuzzAdvanced, "ADVANCED")
  end

  it "esc applies the edited snapshot through the injected closure" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    applied = [] of String
    h = OverlayHarness.new(ov)
    h.on_commit do
      applied << ov.snapshot.conc
      true
    end
    2.times { h.press(Termisu::Input::Key::Backspace) } # clear "20"
    h.type("50").should eq(:open)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    applied.should eq(["50"])
  end

  it "↵ advances a row and, on the LAST row, does nothing at all" do
    # Pins the PRE-EXISTING behaviour the migration preserved: handle_key discards the
    # case's value, so handle_text's commit-on-the-last-row never reaches the shell. Only
    # esc and a click-away apply. See the note on FuzzAdvancedOverlay#handle_key.
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Enter).should eq(:open) # row 0 → row 1
    h.commits.should eq(0)
    (FuzzAdvancedOverlay::ROWS.size - 1).times { h.press(Termisu::Input::Key::Down) }
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
    # …and the last row stays FOCUSED rather than stepping out of ROWS' range: what gets
    # typed next still lands in the last row (Race — appended after Filter regex).
    h.type("x").should eq(:open)
    ov.snapshot.race.should eq("x")
  end

  it "a click outside the card APPLIES rather than dismissing" do
    # This modal has no cancel: apply_close_fuzz_advanced was the shell's click-away path too.
    away = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(1)
  end

  it "a click inside focuses the row under the pointer and stays open" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.click_in_box(2, 6).should eq(:open) # rows start at box.y + 1 → row index 5 (Follow redirects)
    h.commits.should eq(0)
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.follow.should be_true
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov)
    h.wheel(6) # → Calibrate (row 6)
    h.press(Termisu::Input::Key::Space)
    ov.snapshot.calibrate.should be_true
    ov.snapshot.follow.should be_false
  end

  it "routes IME preedit into the focused text row" do
    h = OverlayHarness.new(FuzzAdvancedOverlay.new(blank_snapshot))
    h.preedit("한")
    h.rendered?("한").should be_true
  end

  it "APPLIES a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # editor diverges from the base class on purpose: the pre-seam shell ran
    # `apply_close_fuzz_advanced(ov) if box.nil?`, so an unrenderable card must APPLY, and
    # the inherited :cancel would silently drop knobs the user had already edited.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:commit)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(1)
    h.rendered?("advanced editor").should be_true
  end

  it "toggles keep-alive, which starts on" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.snapshot.keep_alive.should be_true
    7.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → Keep-alive (row 7)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.keep_alive.should be_false
    ov.snapshot.calibrate.should be_false # the neighbouring toggles are untouched
    ov.snapshot.follow.should be_false
    ov.snapshot.update_cl.should be_true
  end

  # The gRPC reframe row is the ONE toggle on this card whose default is off, and it sits
  # directly under Auto Content-Length because they are the same kind of knob pointed at the
  # two length declarations one gRPC request carries (DESIGN.md §7). It reaches the snapshot
  # like any other toggle — FuzzerView#apply_advanced is what puts it on `Fuzz::Config`.
  it "toggles gRPC reframe, which starts OFF (the headless default)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.snapshot.reframe_grpc.should be_false
    9.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → gRPC reframe (row 9)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.reframe_grpc.should be_true
    ov.snapshot.update_cl.should be_true # the neighbour above is untouched
    ov.snapshot.keep_alive.should be_true
  end

  it "renders the gRPC reframe row with its unary caveat in the label" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("gRPC reframe (unary)").should be_true
  end

  it "never focuses a row it did not draw — the hint row and the bottom border are not rows" do
    # `render` reserves the last two interior lines (the hint on box.bottom-2, the border on
    # box.bottom-1), but handle_click computed `i = my - (box.y + 1)` with no upper bound
    # beyond `ri < ROWS.size`, so a click on either selected @scroll + visible (+1) — an
    # index that was never under the cursor — and the next render scrolled to follow it.
    # Focus-only (no commit-on-row-click here), so nothing fired; still the wrong row.
    #
    # Production hands `layout.body`, which is what makes this reachable: the card clips to
    # 14 rows there, so only 11 of the ROWS are drawn. Under the harness's 80x24 default
    # every row fits and `visible == ROWS.size` hides the whole bug. The 16-row body is what
    # yields that 14-row card now that every modal insets from its area by 2.
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    box = h.box.not_nil!
    box.y.should eq(5) # rows run box.y+1 (6) .. 16; hint on 17, border on 18

    h.click_in_box(2, 12).should eq(:open) # the hint row
    h.click_in_box(2, 13).should eq(:open) # the bottom border
    h.type("9")
    ov.snapshot.conc.should eq("209")  # focus never left row 0…
    ov.snapshot.m_size.should eq("")   # …and did not land on an undrawn row (hint → +11)
    ov.snapshot.m_words.should eq("")  # …nor on the one past it (border → +12)
    ov.snapshot.m_status.should eq("") # …nor anywhere else in the match block

    # Positive control: the LAST drawn row is still a live click target. (Row +10 — "Match
    # status" since the gRPC-reframe toggle joined the two length knobs above it.)
    edge = FuzzAdvancedOverlay.new(blank_snapshot)
    eh = OverlayHarness.new(edge, area: body)
    eh.click_in_box(2, 11).should eq(:open)
    eh.type("7")
    edge.snapshot.m_status.should eq("7")
    edge.snapshot.conc.should eq("20")
  end

  it "offsets a click by the scroll position once the list has scrolled" do
    # Production hands an overlay `layout.body` — shorter than the screen and offset from it —
    # so this 16-row body renders a card clipped to 14 and the row list must scroll to reach the
    # bottom fields. That scroll is what makes handle_click's `@scroll + i` load-bearing:
    # @scroll only ever advances inside `render`, so a click example that never renders
    # leaves it at 0, where `@scroll + i` and plain `i` are indistinguishable.
    body = Gori::Tui::Rect.new(2, 4, 76, 16)
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    h = OverlayHarness.new(ov, area: body)
    h.box.should_not be_nil
    h.rendered?("Filter regex").should be_false # off-screen until the list scrolls
    (FuzzAdvancedOverlay::ROWS.size - 1).times { h.press(Termisu::Input::Key::Down) }
    h.rendered?("Filter regex").should be_true # this render is what advances @scroll
    h.type("x")

    # The list has scrolled, so the first VISIBLE row is no longer ROWS[0] (Concurrency):
    # the 4th visible row is "Match size", which is where this click must land.
    h.click_in_box(2, 4).should eq(:open)
    h.type("9")
    ov.snapshot.m_size.should eq("9")  # lands in Retries if the click ignores @scroll
    ov.snapshot.retries.should eq("0") # …and the un-scrolled rows stay untouched
    ov.snapshot.conc.should eq("20")
    ov.snapshot.race.should eq("x") # the last row — Race, appended after Filter regex

    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(1)
  end
end
