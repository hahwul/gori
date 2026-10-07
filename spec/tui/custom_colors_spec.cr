require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# User-defined Colormarker colours: the string-keyed resolver, the CUSTOM COLORS pane view, and
# the name+hex editor overlay.

describe "Theme.mark_color(String)" do
  it "resolves a built-in word through the active palette, keyed by string" do
    Theme.apply("goridark")
    # Against the palette FIELD each word names — `theme_row_tint_spec` pins the same mapping
    # across every built-in theme; these are the spot checks that keep this file readable.
    Theme.mark_color("red").should eq(Theme.red)
    Theme.mark_color("purple").should eq(Theme.syn_literal)
    # …and the tolerant aliases resolve to the nearest member's field.
    Theme.mark_color("cyan").should eq(Theme.syn_header)
    Theme.mark_color("magenta").should eq(Theme.syn_literal)
    Theme.mark_color("violet").should eq(Theme.syn_literal)
  end

  it "resolves a registered custom colour to its absolute hex, custom winning over an alias" do
    begin
      Theme.set_custom_marks({"coral" => "#ff6b6b", "cyan" => "#00ffff"})
      Theme.mark_color("coral").should eq(Color.from_hex("#ff6b6b"))
      # A custom named after an alias wins over the built-in the alias maps to.
      Theme.mark_color("cyan").should eq(Color.from_hex("#00ffff"))
    ensure
      Theme.set_custom_marks({} of String => String)
    end
  end

  it "falls back to a VISIBLE yellow for a dangling custom name, not muted" do
    Theme.set_custom_marks({} of String => String)
    # A rule still naming a deleted colour must not read as chrome — its row is active.
    Theme.mark_color("gone").should eq(Theme.yellow)
    Theme.mark_color("gone").should_not eq(Theme.muted)
  end
end

describe CustomColorsView do
  colors = [
    Gori::Settings::ColormarkerColor.new("coral", "#ff6b6b"),
    Gori::Settings::ColormarkerColor.new("teal", "#008080"),
  ]

  it "keeps row_capacity and row_at in agreement (every drawn row is hit-testable)" do
    view = CustomColorsView.new
    rect = Rect.new(0, 0, 40, 6)
    cap = view.row_capacity(rect, colors.size)
    cap.should be > 0
    # Every row the capacity claims resolves to a real index, and one past it does not.
    (0...cap).each do |i|
      idx = view.row_at(rect, rect.inset(1, 1).y + i, 0, colors.size)
      (idx.nil? || idx < colors.size).should be_true
    end
  end

  it "renders each colour's name, hex and a swatch" do
    view = CustomColorsView.new
    backend = MemoryBackend.new(40, 6)
    view.render(Screen.new(backend), Rect.new(0, 0, 40, 6), colors, 0, 0, true)
    backend.contains?("CUSTOM COLORS").should be_true
    backend.contains?("coral").should be_true
    backend.contains?("#ff6b6b").should be_true
  end

  it "shows an add hint when empty" do
    view = CustomColorsView.new
    backend = MemoryBackend.new(40, 6)
    view.render(Screen.new(backend), Rect.new(0, 0, 40, 6),
      [] of Gori::Settings::ColormarkerColor, 0, 0, false)
    backend.contains?("no custom colours").should be_true
  end
end

describe "ColormarkerView#pane_rects" do
  view = ColormarkerView.new

  it "splits a tall body into two tiling, non-overlapping panes" do
    inner = Rect.new(0, 0, 40, 20)
    rules, colors = view.pane_rects(inner)
    colors.empty?.should be_false
    # Exact tiling: the two panes cover the interior and nothing outside it.
    rules.y.should eq(inner.y)
    colors.y.should eq(rules.bottom)
    (rules.h + colors.h).should eq(inner.h)
  end

  it "keeps the whole body for the policy list when too short for both" do
    inner = Rect.new(0, 0, 40, 4)
    rules, colors = view.pane_rects(inner)
    colors.empty?.should be_true
    rules.h.should eq(inner.h)
  end
end

describe CustomColorOverlay do
  it "is invalid until it has a normalisable name AND hex" do
    ov = CustomColorOverlay.adding
    ov.valid?.should be_false
    ov = CustomColorOverlay.new(name: "coral", hex: "#ff6b6b")
    ov.valid?.should be_true
    ov.editing?.should be_false
    # A built-in word is not a legal custom name; a non-hex is not a colour.
    CustomColorOverlay.new(name: "red", hex: "#ffffff").valid?.should be_false
    CustomColorOverlay.new(name: "coral", hex: "nope").valid?.should be_false
  end

  it "seeds from an existing colour and remembers its original name for the rename path" do
    color = Gori::Settings::ColormarkerColor.new("coral", "#ff6b6b")
    ov = CustomColorOverlay.editing(color)
    ov.editing?.should be_true
    ov.name.should eq("coral")
    ov.hex.should eq("#ff6b6b")
    ov.original_name.should eq("coral")
  end

  it "renders the fields, a swatch and the Save row, and a click commits from Save" do
    ov = CustomColorOverlay.new(name: "coral", hex: "#ff6b6b")
    backend = MemoryBackend.new(100, 20)
    area = Rect.new(0, 0, 100, 20)
    ov.render(Screen.new(backend), area)
    backend.contains?("ADD CUSTOM COLOUR").should be_true
    backend.contains?("name:").should be_true
    backend.contains?("hex:").should be_true
    backend.contains?("Save colour").should be_true

    box = ov.overlay_box(area).not_nil!
    ov.handle_click(area, box.x + 5, box.y + 2 + CustomColorOverlay::ROW_SAVE).should eq(:commit)
  end
end
