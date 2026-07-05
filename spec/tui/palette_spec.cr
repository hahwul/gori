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
    # No shipped verb is coming_soon anymore (settings:hotkeys went live), so exercise the
    # badge mechanism with a synthetic registry.
    ctx = FakeExecContext.new
    reg = Gori::Verb::Registry.new
    reg.register(Gori::Verb::Definition.new("demo.soon", "demo:soon", "A future thing",
      Gori::Verb::Scope::Global, coming_soon: true) { |_| nil })
    palette = PaletteState.new(reg)
    palette.reset(ctx)
    "demo:soon".each_char { |c| palette.append(c, ctx) }

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("demo:soon").should be_true
    backend.contains?("soon").should be_true # the placeholder badge
  end

  it "registers a Global 'Go to' jump for every catalog tab so each is palette-reachable" do
    r = Gori::Verbs.registry
    # The named tab jumps are the only by-command way to reach a tab hidden in
    # settings:tabs — so every entry in the canonical catalog (incl. the default-hidden
    # Miner) must have one, or it becomes unreachable from the palette.
    Gori::Tui::Chrome::TABS.each do |(tab, label)|
      verb = r["tab.#{tab}"]?
      verb.should_not be_nil
      verb.not_nil!.title.should eq("Go to #{label}")
      verb.not_nil!.scope.should eq(Gori::Verb::Scope::Global)
    end
  end

  it "surfaces the Fuzzer tab jump when the palette is filtered by 'fuzz'" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "fuzz".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should contain("tab.fuzzer")
  end

  it "categorizes Global verbs so the palette can group them by kind" do
    r = Gori::Verbs.registry
    r["tab.history"].category.should eq(Gori::Verb::Category::Navigation)
    r["nav.next-tab"].category.should eq(Gori::Verb::Category::Navigation)
    r["app.back"].category.should eq(Gori::Verb::Category::Navigation)
    r["settings.theme"].category.should eq(Gori::Verb::Category::Settings)
    r["app.quit"].category.should eq(Gori::Verb::Category::System)
    r["app.palette"].category.should eq(Gori::Verb::Category::System)
    r["capture.toggle"].category.should eq(Gori::Verb::Category::Action) # the default kind
  end

  it "surfaces import commands when the palette is filtered by 'import:'" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "import:".each_char { |c| palette.append(c, ctx) }
    ids = palette.results.map(&.id)
    ids.should contain("import.har")
    ids.should contain("import.urls")
    ids.should contain("import.oas")
  end

  it "renders a verb's EFFECTIVE chord so a rebind is reflected (not the default)" do
    prev = Gori::Settings.keymap_overrides
    begin
      ctx = FakeExecContext.new
      palette = PaletteState.new(Gori::Verbs.registry)
      palette.reset(ctx)
      "Toggle capture".each_char { |c| palette.append(c, ctx) } # capture.toggle (default: c)

      # Default binding: the rebound label is nowhere on screen yet.
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      base = MemoryBackend.new(80, 24)
      palette.render(Screen.new(base), Rect.new(0, 0, 80, 24))
      base.contains?("ctrl-y").should be_false

      # Rebind capture.toggle → ^Y; the palette's chord column must follow the keymap.
      Gori::Settings.keymap_overrides = {"capture.toggle" => ["ctrl-y"]}
      rebound = MemoryBackend.new(80, 24)
      palette.render(Screen.new(rebound), Rect.new(0, 0, 80, 24))
      rebound.contains?("ctrl-y").should be_true
    ensure
      Gori::Settings.keymap_overrides = prev
    end
  end

  it "ignores a hand-edited override for a FIXED verb so it can't advertise a dead chord" do
    prev = Gori::Settings.keymap_overrides
    begin
      ctx = FakeExecContext.new
      palette = PaletteState.new(Gori::Verbs.registry)
      palette.reset(ctx)
      "Command palette".each_char { |c| palette.append(c, ctx) } # app.palette (FIXED: ^P hardcoded)

      # A hand-edited settings.json binds the FIXED app.palette to ctrl-y. Dispatch drops it
      # (rebindable? == false) and ^P still opens the palette — so the palette must NOT show it.
      Gori::Settings.keymap_overrides = {"app.palette" => ["ctrl-y"]}
      backend = MemoryBackend.new(80, 24)
      palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
      backend.contains?("ctrl-y").should be_false # the dead override is filtered out
      backend.contains?("ctrl-p").should be_true  # the real (default, hardcoded) chord shows
    ensure
      Gori::Settings.keymap_overrides = prev
    end
  end

  it "prints a colour-coded category sigil before each entry" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "Toggle capture".each_char { |c| palette.append(c, ctx) } # an Action verb

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("▸ Toggle capture").should be_true # the Action sigil precedes the title
  end
end
