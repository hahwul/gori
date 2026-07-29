require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def dseed : DiscoverSeed
  DiscoverSeed.new([{"/", "http://h.test/"}], "h.test")
end

describe Gori::Tui::DiscoverConfigOverlay do
  it "carries custom headers into the built config" do
    ov = DiscoverConfigOverlay.new(dseed)
    ov.set_headers([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.build_config.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
  end

  it "defaults to no custom headers" do
    DiscoverConfigOverlay.new(dseed).build_config.headers.should be_empty
  end

  it "exposes a headers row before the start row" do
    ov = DiscoverConfigOverlay.new(dseed)
    (DiscoverConfigOverlay::ROW_HEADERS < DiscoverConfigOverlay::ROW_START).should be_true
    ov.set_selected(DiscoverConfigOverlay::ROW_HEADERS)
    ov.on_headers_row?.should be_true
    ov.on_start_row?.should be_false
  end

  it "renders without crashing and maps a click to the headers row" do
    ov = DiscoverConfigOverlay.new(dseed)
    ov.set_headers([{"A", "b"}])
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 3 + DiscoverConfigOverlay::ROW_HEADERS)
      .should eq(DiscoverConfigOverlay::ROW_HEADERS)
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(DiscoverConfigOverlay.new(dseed)).assert_chrome(OverlayKind::DiscoverConfig, "DISCOVER")
  end

  it "↵ on Start commits; esc cancels without starting a run" do
    ov = DiscoverConfigOverlay.new(dseed)
    h = OverlayHarness.new(ov)
    ov.set_selected(DiscoverConfigOverlay::ROW_START)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)

    esc = OverlayHarness.new(DiscoverConfigOverlay.new(dseed))
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  it "keeps the popup up when the closure refuses (neither spider nor bruteforce)" do
    ov = DiscoverConfigOverlay.new(dseed)
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(DiscoverConfigOverlay::ROW_START)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # it DID run — it just refused to close
  end

  it "↵ on the headers row raises the sub-editor instead of committing or closing" do
    ov = DiscoverConfigOverlay.new(dseed)
    opened = 0
    ov.on_edit_headers = -> { opened += 1; nil }
    h = OverlayHarness.new(ov)
    ov.set_selected(DiscoverConfigOverlay::ROW_HEADERS)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    opened.should eq(1)
    h.commits.should eq(0)
  end

  it "␣ on a checkbox row toggles it and stays open" do
    ov = DiscoverConfigOverlay.new(dseed)
    h = OverlayHarness.new(ov)
    ov.set_selected(DiscoverConfigOverlay::ROW_SPIDER)
    before = ov.build_config.spider?
    h.press(Termisu::Input::Key::Space).should eq(:open)
    ov.build_config.spider?.should eq(!before)
    h.commits.should eq(0)
  end

  it "␣ on the keep-alive row turns connection reuse off in the built config" do
    # On by default — a run's largest cost against a remote origin is the handshake per probe
    # — but the row exists because a target with per-connection behaviour needs it off.
    ov = DiscoverConfigOverlay.new(dseed)
    ov.build_config.keep_alive?.should be_true
    h = OverlayHarness.new(ov)
    ov.set_selected(DiscoverConfigOverlay::ROW_KEEP)
    h.press(Termisu::Input::Key::Space).should eq(:open)
    ov.build_config.keep_alive?.should be_false
    h.commits.should eq(0)
  end

  it "←/→ cycles the row under the cursor" do
    ov = DiscoverConfigOverlay.new(dseed)
    h = OverlayHarness.new(ov)
    ov.set_selected(DiscoverConfigOverlay::ROW_DEPTH)
    depth = ov.build_config.max_depth
    h.press(Termisu::Input::Key::Right).should eq(:open)
    ov.build_config.max_depth.should_not eq(depth)
  end

  it "a click routes rows exactly like ↵; a click outside dismisses" do
    ov = DiscoverConfigOverlay.new(dseed)
    opened = 0
    ov.on_edit_headers = -> { opened += 1; nil }
    h = OverlayHarness.new(ov)
    # Rows start at box.y + 3 (see render).
    h.click_in_box(3, 3 + DiscoverConfigOverlay::ROW_HEADERS).should eq(:open)
    opened.should eq(1)
    h.click_in_box(3, 3 + DiscoverConfigOverlay::ROW_START).should eq(:closed)
    h.commits.should eq(1)

    away = OverlayHarness.new(DiscoverConfigOverlay.new(dseed))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "the wheel moves the selected row (base handle_wheel delegates to move)" do
    ov = DiscoverConfigOverlay.new(dseed)
    OverlayHarness.new(ov).wheel(DiscoverConfigOverlay::ROW_START)
    ov.on_start_row?.should be_true
  end

  it "dismisses (never starts a run on) a click when the window is too small" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. A
    # discovery run fires real traffic, so an unrenderable card MUST cancel, matching the
    # pre-seam `return close_discover_config if box.nil?`.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = DiscoverConfigOverlay.new(dseed)
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:cancel)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(0)
    h.rendered?("config needs").should be_true
  end

  it "still hit-tests its rows in the rect the shell actually passes (layout.body)" do
    # Production hands an overlay `layout.body` — 6 rows shorter and offset from the screen,
    # which for this card is where it starts getting clipped.
    body = Gori::Tui::Rect.new(2, 4, 76, 18)
    ov = DiscoverConfigOverlay.new(dseed)
    h = OverlayHarness.new(ov, area: body)
    box = h.box.not_nil!
    ov.row_at(box, box.x + 3, box.y + 3 + DiscoverConfigOverlay::ROW_START)
      .should eq(DiscoverConfigOverlay::ROW_START)
    h.click_in_box(3, 3 + DiscoverConfigOverlay::ROW_START).should eq(:closed)
    h.commits.should eq(1)
  end
end
