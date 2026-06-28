require "../spec_helper"
require "../support/memory_backend"

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
