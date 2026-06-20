require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

describe Gori::Tui::PaletteState do
  it "lists verbs, filters by query, and selects via the registry (P1)" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    palette.results.size.should be > 0 # empty query lists everything available

    "quit".each_char { |c| palette.append(c, ctx) }
    palette.results.first.id.should eq("app.quit")
    palette.selected_verb.try(&.id).should eq("app.quit")
  end

  it "moves the selection within results" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    palette.move(1)
    palette.selected.should eq(1)
    palette.move(-5) # clamps
    palette.selected.should eq(0)
  end

  it "renders the overlay with the query and a result row" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "palette".each_char { |c| palette.append(c, ctx) }

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("palette").should be_true         # the typed query
    backend.contains?("Command palette").should be_true # the matched verb title
  end

  it "scrolls the visible window so a selection past the fold stays on-screen" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    palette.results.size.should be > 12 # more verbs than fit the rendered list box

    last = palette.results.last.title

    # At the top the last result is below the fold → not rendered.
    top = MemoryBackend.new(80, 24)
    palette.render(Screen.new(top), Rect.new(0, 0, 80, 24))
    top.contains?(last).should be_false

    # Jump to the last result → the window scrolls to keep the selection visible.
    palette.move(palette.results.size) # clamps to the last index
    bottom = MemoryBackend.new(80, 24)
    palette.render(Screen.new(bottom), Rect.new(0, 0, 80, 24))
    bottom.contains?(last).should be_true
  end

  it "marks coming-soon verbs with a 'soon' badge (exposed but not functional)" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "settings:theme".each_char { |c| palette.append(c, ctx) } # a coming_soon verb

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("settings:theme").should be_true
    backend.contains?("soon").should be_true # the placeholder badge
  end
end
