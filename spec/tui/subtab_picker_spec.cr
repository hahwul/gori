require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def sample_picker : SubtabPicker
  SubtabPicker.new("FIND SUB-TAB", [
    SubtabPicker::Row.new(0, "login", "POST /login https://app.example.com"),
    SubtabPicker::Row.new(1, "search api", "GET /api/search https://api.example.com"),
    SubtabPicker::Row.new(2, "checkout", "POST /cart/checkout https://shop.example.com"),
  ])
end

describe Gori::Tui::SubtabPicker do
  it "starts on the first row and hands back its absolute index" do
    p = sample_picker
    p.selected.should eq(0)
    p.selected_index.should eq(0)
  end

  it "filters by label or request line and resets the cursor to the first match" do
    p = sample_picker
    p.query_char('a')
    p.query_char('p')
    p.query_char('i') # "api" matches only the search-api row (by label) ...
    p.selected_index.should eq(1)

    p2 = sample_picker
    "shop".each_char { |c| p2.query_char(c) } # ... and by the target host (detail)
    p2.selected_index.should eq(2)
  end

  it "is case-insensitive and ANDs whitespace-separated terms" do
    p = sample_picker
    "POST checkout".each_char { |c| p.query_char(c) }
    p.selected_index.should eq(2) # both terms hit only the checkout row
  end

  it "reports no match when the filter excludes every row" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.selected_index.should be_nil
  end

  it "restores rows on backspace" do
    p = sample_picker
    "checkout".each_char { |c| p.query_char(c) }
    p.selected_index.should eq(2)
    8.times { p.backspace }
    p.selected_index.should eq(0) # full list back, cursor at the top
  end

  it "clamps movement at both ends" do
    p = sample_picker
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected_index.should eq(2) # last row
  end

  it "renders the title and the sub-tab labels" do
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("FIND SUB-TAB").should be_true
    backend.contains?("login").should be_true
    backend.contains?("checkout").should be_true
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
describe "SubtabPicker — Overlay contract" do
  it "carries the chrome, with a ↵ verb that varies by open-site" do
    # The Runner interpolated `@subtab_picker.action` into its hint arm; the overlay owns
    # that now, and the card's own hint row must read the same string as the bottom row.
    search = sample_picker
    OverlayHarness.new(search).assert_chrome(OverlayKind::RepeaterSubtab, "FIND SUB-TAB")
    search.hint.should eq("type to filter · ↑/↓ select · ↵ jump · esc cancel")
    OverlayHarness.new(search).rendered?("↵ jump").should be_true

    link = SubtabPicker.new("PICK REPEATER", [SubtabPicker::Row.new(0, "a", "b")], action: "link")
    link.title.should eq("PICK REPEATER")
    link.hint.should eq("type to filter · ↑/↓ select · ↵ link · esc cancel")
    OverlayHarness.new(link).rendered?("↵ link").should be_true
  end

  it "hands back the ABSOLUTE sub-tab index, not the filtered position" do
    # jump_subtab and db_id_at both index the real strip, so returning the filtered offset
    # would jump to — or link — the wrong session the moment a filter is typed.
    ov = sample_picker
    OverlayHarness.new(ov).type("checkout")
    ov.entry_count.should eq(1)
    ov.selected.should eq(0)
    ov.selected_index.should eq(2)
  end

  it "resets the cursor to the top of each new match set" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    h.press(Termisu::Input::Key::Down)
    ov.selected.should eq(1)
    h.type("e") # login/search api/checkout all still match
    ov.entry_count.should eq(3)
    ov.selected.should eq(0)
  end

  it "↵ commits the highlighted row; esc cancels without committing" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    jumped = [] of Int32
    h.on_commit { jumped << ov.selected_index.not_nil!; true }
    h.press(Termisu::Input::Key::Down)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    jumped.should eq([1])

    esc = OverlayHarness.new(sample_picker)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  it "⌫ widens the filter again and is a no-op on an empty query" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    h.type("checkout")
    ov.entry_count.should eq(1)
    8.times { h.press(Termisu::Input::Key::Backspace) }
    ov.entry_count.should eq(3)
    h.press(Termisu::Input::Key::Backspace).should eq(:open) # already empty
    ov.entry_count.should eq(3)
  end

  it "routes IME preedit into the filter bar" do
    h = OverlayHarness.new(sample_picker)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
    h.rendered?("filter:").should be_true
  end

  it "clicking a row commits it; clicking outside dismisses" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    h.click_in_box(3, 3).should eq(:closed) # the list starts at box.y + 3
    ov.selected.should eq(0)
    h.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
  end
end
