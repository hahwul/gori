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

  # The sandbox used to be reachable only from the Project NETWORK pane, so "is it Global?" is
  # the whole feature: a verb registered in any other scope compiles, wires up, passes its
  # verb_intents spec — and never appears here.
  it "surfaces the sandbox toggle for a 'sandbox' query (the palette lists Global verbs only)" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)

    "sandbox".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should contain("scope.toggle-sandbox")
    palette.selected_verb.try(&.id).should eq("scope.toggle-sandbox") # and it ranks first
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

  it "orders the empty-query palette: Settings → Go to → rest → Back → Quit" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    ids = palette.results.map(&.id)
    cats = palette.results.map(&.category)

    first_settings = cats.index(Gori::Verb::Category::Settings)
    first_settings.should_not be_nil
    first_non_settings = cats.index { |c| c != Gori::Verb::Category::Settings }
    first_non_settings.should_not be_nil
    first_settings.not_nil!.should be < first_non_settings.not_nil!

    # Go to … tab jumps right after the Settings block
    first_tab = ids.index { |id| id.starts_with?("tab.") }
    first_tab.should_not be_nil
    last_settings = ids.rindex { |id| Gori::Verbs.registry[id].category == Gori::Verb::Category::Settings }
    last_settings.should_not be_nil
    first_tab.not_nil!.should eq(last_settings.not_nil! + 1)

    # Exit paths always finish the list
    ids[-2].should eq("app.back")
    ids[-1].should eq("app.quit")
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

# The palette's query has a caret now: `edit` takes the motions the `/` bars have.
describe Gori::Tui::PaletteState, "caret" do
  it "moves by word and inserts at the caret" do
    ctx = FakeExecContext.new
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "quit now".each_char { |c| palette.append(c, ctx) }
    palette.edit(Termisu::Event::Key.new(Termisu::Input::Key::Left, Termisu::Input::Modifier::Ctrl), ctx).should be_true
    palette.append('x', ctx)
    palette.query.should eq("quit xnow")
    palette.edit(Termisu::Event::Key.new(Termisu::Input::Key::Home), ctx).should be_true
    palette.backspace(ctx) # at 0: nothing to delete, nothing raised
    palette.query.should eq("quit xnow")
    palette.edit(Termisu::Event::Key.new(Termisu::Input::Key::Delete), ctx).should be_true
    palette.query.should eq("uit xnow")
    palette.edit(Termisu::Event::Key.new(Termisu::Input::Key::LowerJ, Termisu::Input::Modifier::None, 'j'), ctx).should be_false
  end
end

# #1282: a TYPED query also searches the focused tab's actions, captured at ^P the way the
# space menu captures them at space (ActionContext). The empty browse stays Global.
describe Gori::Tui::PaletteState, "tab actions" do
  history_body = Gori::Tui::ActionContext.new(Gori::Verb::Scope::Body, :common)

  it "finds a tab action from its own tab, and not from another tab" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64 # so History's flow-gated actions are available
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "mock this".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should contain("history.mock-response")

    palette.capture(Gori::Tui::ActionContext.new(Gori::Verb::Scope::Repeater, :request, true), ctx)
    palette.reset(ctx)
    "mock this".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should_not contain("history.mock-response")
    palette.results.none?(&.id.starts_with?("history.")).should be_true
  end

  it "lists no tab actions without a captured context (Global only, as before)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.reset(ctx)
    "mock this".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should_not contain("history.mock-response")
    palette.tab_count.should eq(0)
  end

  it "does not list a tab action that is unavailable where ^P was pressed" do
    ctx = FakeExecContext.new
    reg = Gori::Verb::Registry.new
    reg.register(Gori::Verb::Definition.new("demo.on", "Zap on", "", Gori::Verb::Scope::Body) { |_| nil })
    reg.register(Gori::Verb::Definition.new("demo.off", "Zap off", "", Gori::Verb::Scope::Body,
      available: ->(_c : Gori::Verb::ExecContext) { false }) { |_| nil })
    palette = PaletteState.new(reg)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "zap".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should eq(["demo.on"])
  end

  it "keeps the empty-query browse exactly the curated Global list, rows and all" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    plain = PaletteState.new(Gori::Verbs.registry)
    plain.reset(ctx)
    scoped = PaletteState.new(Gori::Verbs.registry)
    scoped.capture(Gori::Tui::ActionContext.new(Gori::Verb::Scope::Body, :common, banner: "3 MARKED"), ctx)
    scoped.reset(ctx)

    scoped.results.map(&.id).should eq(plain.results.map(&.id))
    scoped.tab_count.should eq(0)
    a = MemoryBackend.new(80, 24)
    b = MemoryBackend.new(80, 24)
    plain.render(Screen.new(a), Rect.new(0, 0, 80, 24))
    scoped.render(Screen.new(b), Rect.new(0, 0, 80, 24))
    24.times do |y|
      b.row(y).should eq(a.row(y))
      80.times { |x| b.fg_at(x, y).should eq(a.fg_at(x, y)) }
    end
  end

  it "ranks tab matches ahead of Global ones, under a THIS TAB header" do
    ctx = FakeExecContext.new
    reg = Gori::Verb::Registry.new
    # The Global title is the exact query, so it would win any single ranking.
    reg.register(Gori::Verb::Definition.new("demo.global", "zap", "", Gori::Verb::Scope::Global) { |_| nil })
    reg.register(Gori::Verb::Definition.new("demo.tab", "Zoom and pan", "", Gori::Verb::Scope::Body) { |_| nil })
    palette = PaletteState.new(reg)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "zap".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should eq(["demo.tab", "demo.global"])
    palette.tab_count.should eq(1)
    palette.selected_verb.try(&.id).should eq("demo.tab")

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    rows = (0...24).map { |y| backend.row(y) }
    tab_header = rows.index(&.includes?("THIS TAB")).not_nil!
    tab_row = rows.index(&.includes?("Zoom and pan")).not_nil!
    app_header = rows.index(&.includes?("─ APP ─")).not_nil!
    tab_header.should be < tab_row
    tab_row.should be < app_header

    # A click on a header selects nothing; a click on the Global row picks it.
    box = palette.overlay_box(Rect.new(0, 0, 80, 24))
    palette.row_at(box, box.x + 5, tab_header).should be_nil
    palette.row_at(box, box.x + 5, app_header + 1).should eq(1)
  end

  it "ranks a real tab action ahead of the Global jump that shares its words" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "repeater".each_char { |c| palette.append(c, ctx) }
    ids = palette.results.map(&.id)
    ids.first.should eq("history.repeater")
    ids.index("history.repeater").not_nil!.should be < ids.index("tab.repeater").not_nil!
  end

  it "shows the marks banner in the title while tab rows are listed" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.capture(Gori::Tui::ActionContext.new(Gori::Verb::Scope::Body, :common, banner: "3 MARKED"), ctx)
    palette.reset(ctx)
    palette.title.should eq("COMMANDS") # the browse has no tab rows for it to speak for
    "delete flow".each_char { |c| palette.append(c, ctx) }
    palette.title.should eq("COMMANDS · 3 MARKED")
    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("COMMANDS · 3 MARKED").should be_true
  end

  it "hints a tab row's chord, else its space-menu letter" do
    ctx = FakeExecContext.new
    reg = Gori::Verb::Registry.new
    reg.register(Gori::Verb::Definition.new("demo.chorded", "Zap chorded", "", Gori::Verb::Scope::Body,
      [Gori::Verb::Chord.new("r", ctrl: true)]) { |_| nil })
    reg.register(Gori::Verb::Definition.new("demo.lettered", "Zap lettered", "", Gori::Verb::Scope::Body,
      mnemonic: 'Q') { |_| nil })
    reg.register(Gori::Verb::Definition.new("demo.bare", "Zap bare", "", Gori::Verb::Scope::Body) { |_| nil })
    palette = PaletteState.new(reg)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "zap".each_char { |c| palette.append(c, ctx) }
    palette.tab_count.should eq(3) # no menu_key is no bar: search finds a keyless action too

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    rows = (0...24).map { |y| backend.row(y) }
    rows.find(&.includes?("Zap chorded")).not_nil!.should contain("ctrl-r")
    rows.find(&.includes?("Zap lettered")).not_nil!.should contain("␣ Q")
    rows.find(&.includes?("Zap bare")).not_nil!.should_not contain("␣")
  end

  # A family member has no level-1 letter (#1274 WP9), yet search still finds it by title, and
  # its row names the two keys that reach it.
  it "finds a family member by title and hints its two-key menu path" do
    ctx = FakeExecContext.new
    reg = Gori::Verb::Registry.new
    reg.register_family(Gori::Verb::Family.new(:send, "Send to…", '>', :send, [{:to_zap, 'z'}]))
    reg.register(Gori::Verb::Definition.new("demo.member", "Zap member", "", Gori::Verb::Scope::Body,
      intent: :to_zap) { |_| nil })
    palette = PaletteState.new(reg)
    palette.capture(history_body, ctx)
    palette.reset(ctx)
    "zap".each_char { |c| palette.append(c, ctx) }
    palette.results.map(&.id).should eq(["demo.member"])

    backend = MemoryBackend.new(80, 24)
    palette.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    (0...24).map { |y| backend.row(y) }.find(&.includes?("Zap member")).not_nil!.should contain("␣ > z")
  end

  # Opening ^P over an open History detail: the detail's actions are what search finds, and
  # closing the palette puts the detail back so the pick runs against the flow on screen.
  it "searches an open History detail's actions and returns to the detail on close" do
    ctx = FakeExecContext.new
    here = Gori::Tui::ActionContext.capture(Gori::Verbs.registry, detail: true, focus: :body,
      scope: Gori::Verb::Scope::Body, pane_section: :common)
    here.scope.should eq(Gori::Verb::Scope::HistoryDetail)
    palette = PaletteState.new(Gori::Verbs.registry)
    palette.capture(here, ctx)
    palette.reset(ctx)
    "mine param".each_char { |c| palette.append(c, ctx) }
    palette.selected_verb.try(&.id).should eq("detail.mine")
    palette.tab_verb?(Gori::Verbs.registry["detail.mine"]).should be_true
    palette.tab_verb?(Gori::Verbs.registry["app.quit"]).should be_false

    Runner.palette_return(OverlayKind::Detail).should eq(OverlayKind::Detail)
    Runner.palette_return(OverlayKind::None).should eq(OverlayKind::None)
    Runner.palette_return(OverlayKind::Confirm).should eq(OverlayKind::None)
  end
end
