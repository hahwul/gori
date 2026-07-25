require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

describe Gori::Tui::DiscoverHeadersOverlay do
  it "round-trips seeded headers through the editor buffer" do
    ov = DiscoverHeadersOverlay.new([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
  end

  it "renders seeded headers without crashing" do
    ov = DiscoverHeadersOverlay.new([{"A", "b"}])
    screen = Screen.new(MemoryBackend.new(80, 24))
    ov.render(screen, Rect.new(0, 0, 80, 24))
  end

  it "renders an empty editor without crashing" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    ov.headers.should be_empty
    screen = Screen.new(MemoryBackend.new(80, 24))
    ov.render(screen, Rect.new(0, 0, 80, 24))
  end

  # --- Overlay seam (see overlay.cr): the routing the Runner's generic dispatch replaced.
  # OverlayHarness replays Runner#dispatch_overlay_key / #dispatch_overlay_click.
  it "exposes the chrome the collapsed ladders used to hard-code" do
    OverlayHarness.new(DiscoverHeadersOverlay.new([] of {String, String}))
      .assert_chrome(OverlayKind::DiscoverHeaders, "CUSTOM HEADERS")
  end

  it "esc SAVES what was typed — there is no cancel path out of this sub-editor" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    saved = [] of Array({String, String})
    h = OverlayHarness.new(ov)
    h.on_commit do
      saved << ov.headers
      true
    end
    h.type("X-Env: staging").should eq(:open)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    saved.should eq([[{"X-Env", "staging"}]])
  end

  it "a click OUTSIDE the card saves too (esc semantics), a click inside just edits" do
    away = OverlayHarness.new(DiscoverHeadersOverlay.new([{"A", "b"}]))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(1) # NOT a dismissal: the base class's click-away cancel is overridden

    inside = OverlayHarness.new(DiscoverHeadersOverlay.new([{"A", "b"}]))
    inside.click_in_box(3, 1).should eq(:open)
    inside.commits.should eq(0)
  end

  it "↵ inserts a header line rather than committing" do
    ov = DiscoverHeadersOverlay.new([] of {String, String})
    h = OverlayHarness.new(ov)
    h.type("A: 1")
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.type("B: 2")
    ov.headers.should eq([{"A", "1"}, {"B", "2"}])
  end

  it "routes IME preedit into the editor" do
    # Seeded, because an EMPTY buffer renders the placeholder line instead of the editor.
    ov = DiscoverHeadersOverlay.new([{"A", "b"}])
    h = OverlayHarness.new(ov)
    h.rendered?("한").should be_false
    h.preedit("한") # composing text draws but has not committed to the buffer yet
    h.rendered?("한").should be_true
    ov.headers.should eq([{"A", "b"}])
  end

  it "the wheel does nothing (it never had a move entry in the shell's ladder)" do
    # Asserting on `headers` alone cannot fail: it re-parses the buffer, so it is caret- and
    # scroll-independent and holds no matter what a `move` override did. Compare the whole
    # drawn frame instead — glyphs AND background — so adding a `move` that scrolls the
    # editor or shifts the caret shows up here.
    ov = DiscoverHeadersOverlay.new([{"A", "b"}, {"C", "d"}])
    h = OverlayHarness.new(ov)
    before = h.render
    rows = (0...24).map { |y| before.row(y) }
    bgs = (0...24).map { |y| (0...80).map { |x| before.bg_at(x, y) } }

    h.wheel(3)

    after = h.render
    (0...24).each do |y|
      after.row(y).should eq(rows[y])
      (0...80).each { |x| after.bg_at(x, y).should eq(bgs[y][x]) }
    end
    ov.headers.should eq([{"A", "b"}, {"C", "d"}])
  end

  it "SAVES a click when the window is too small to draw the card" do
    # The overlay_box → nil path. OverlayHarness::DEFAULT_AREA is the whole screen, so this
    # path is unreachable through the default — pass an area that actually forces it. This
    # editor diverges from the base class on purpose: the pre-seam shell ran
    # `commit_discover_headers if box.nil?`, so an unrenderable card must SAVE, and the
    # inherited :cancel would silently drop headers the user had already typed.
    tiny = Gori::Tui::Rect.new(0, 0, 29, 6)
    ov = DiscoverHeadersOverlay.new([{"A", "b"}])
    ov.overlay_box(tiny).should be_nil
    ov.handle_click(tiny, 5, 3).should eq(:commit)
    h = OverlayHarness.new(ov, area: tiny)
    h.click(5, 3).should eq(:closed)
    h.commits.should eq(1)
    h.rendered?("headers editor").should be_true
  end

  it "hit-tests against the rect the shell passes, not the whole screen" do
    # Production hands `layout.body` — 6 rows shorter and offset — so the card is 14 rows
    # here against 16 under OverlayHarness::DEFAULT_AREA, and its top edge sits lower. A
    # point inside that band is INSIDE the card on the default area and OUTSIDE it here, so
    # the same click must save-and-close rather than keep editing. Driving keys through a
    # smaller area proves nothing: handle_key never sees `area`.
    body = Gori::Tui::Rect.new(2, 4, 76, 18)
    screen_h = OverlayHarness.new(DiscoverHeadersOverlay.new([{"A", "b"}]))
    body_h = OverlayHarness.new(DiscoverHeadersOverlay.new([{"A", "b"}]), area: body)
    screen_box = screen_h.box.not_nil!
    body_box = body_h.box.not_nil!
    body_box.y.should be > screen_box.y

    probe_y = screen_box.y # inside the screen-area card, above the body-area card
    screen_h.click(20, probe_y).should eq(:open)
    screen_h.commits.should eq(0)
    body_h.click(20, probe_y).should eq(:closed)
    body_h.commits.should eq(1)
  end
end
