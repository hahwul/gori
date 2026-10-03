require "../spec_helper"

private alias Tour = Gori::Tui::Tutorial

# The tour's mock space menu and palette rows are real verbs, read from the registry, so the
# letters and keys a new user learns there are the ones the app answers (#1274, #1282). These
# pin that they stay real: a verb renamed away, a row that lost its letter, or a family that
# moved its key would otherwise leave the tour teaching a key that does nothing.
describe "Gori::Tui::Tutorial mock menus" do
  registry = Gori::Verbs.registry

  it "letters every level-1 row from the registry, and adds the Send flow to… row" do
    rows = Tour.space_rows(registry)
    rows.size.should eq(Tour::SPACE_VERBS.size + 1)
    Tour::SPACE_VERBS.each do |id|
      verb = registry[id]
      row = rows.find! { |r| r.title == verb.title }
      [row.key].should eq(registry.menu_keys(id))
      row.opens.should be_false
    end
    fam = rows.find!(&.opens)
    fam.key.should eq(Gori::Verbs::SEND_FLOW.key)
    fam.title.should eq(Gori::Verbs::SEND_FLOW.title)
  end

  # The real card drops a chord hint equal to the row's own letter (`SpaceMenu#chord_hint`);
  # the mock printed `y Copy flow y` (#1382).
  it "never repeats a row's letter as its chord hint, as the real card does" do
    (Tour.space_rows(registry) + Tour.send_rows(registry)).each do |row|
      next if row.opens
      row.hint.should_not eq(row.key.to_s)
      row.hint.should_not eq(row.key.to_s.upcase)
    end
    copy = Tour.space_rows(registry).find! { |r| r.title == registry["history.copy"].title }
    copy.hint.should eq("")
  end

  it "letters the second card from the family table" do
    rows = Tour.send_rows(registry)
    rows.size.should eq(Tour::SEND_VERBS.size)
    Tour::SEND_VERBS.zip(rows).each do |(id, row)|
      row.key.should eq(registry.l2_key(registry[id]))
    end
  end

  it "keeps the family row on screen at the smallest card" do
    # The shell is SHELL_ROWS tall there, and the menu keeps one row clear of its floor and
    # spends two on its own border — the rows left must reach the family row.
    (Tour::SEND_ROW_AT + 1).should be <= Tour::SHELL_ROWS - 1 - 2
  end

  it "stands the menu and palette lessons on the History chip" do
    Tour::TABS[Tour::HISTORY_TAB].should eq("History")
  end

  it "prints the hint the real palette prints: the key, else the menu path" do
    rows = Tour.palette_tab_rows(registry)
    rows.size.should eq(Tour::PALETTE_TAB_VERBS.size)
    Tour::PALETTE_TAB_VERBS.zip(rows).each do |(id, row)|
      want = Gori::Hotkeys.binding_for(registry, id).try(&.label) ||
             Gori::Hotkeys.menu_path(registry, id, compact: true)
      row.hint.should eq(want)
      row.this_tab.should be_true
    end
    # The lesson leans on one row with no key, whose hint is therefore a menu path.
    first = Tour::PALETTE_TAB_VERBS.first
    Gori::Hotkeys.binding_for(registry, first).should be_nil
    rows.first.hint.should eq(Gori::Hotkeys.menu_path(registry, first, compact: true))
  end
end

describe "Gori::Tui::Tutorial palette groups" do
  tab_rows = Tour.palette_tab_rows(Gori::Verbs.registry)

  it "browses the app commands alone on an empty query, ungrouped" do
    matches = Tour.palette_matches("", tab_rows)
    matches.none?(&.this_tab).should be_true
    Tour.palette_display(matches).map(&.[1]).none?(Nil).should be_true
  end

  it "finds a row in each group for the lesson's query, this tab's first" do
    matches = Tour.palette_matches(Tour::PALETTE_DEMO_QUERY, tab_rows)
    matches.any?(&.this_tab).should be_true
    matches.any? { |r| !r.this_tab }.should be_true
    matches.first.this_tab.should be_true
    headers = Tour.palette_display(matches).compact_map { |(h, idx)| h if idx.nil? }
    headers.should eq([Gori::Tui::PaletteState::TAB_HEADER, Gori::Tui::PaletteState::APP_HEADER])
  end

  it "indexes every command exactly once under the headers" do
    matches = Tour.palette_matches("o", tab_rows)
    idxs = Tour.palette_display(matches).compact_map { |(_, idx)| idx }
    idxs.should eq((0...matches.size).to_a)
  end
end

describe "Gori::Tui::Tutorial step order" do
  it "teaches the menu before the palette, whose hints spell menu paths" do
    Tour::Step::SpaceMenu.value.should be < Tour::Step::Palette.value
    Tour::STEP_RAIL.map { |(_, step)| step }.should eq(Tour::Step.values)
  end
end

describe "Gori::Tui::Tutorial mock sub-tab strips" do
  # The strip the Navigate lesson walks through is the app's, not a lookalike: Project and
  # Target have one, History (where the menu and palette lessons stand) does not.
  it "reads Project's and Target's chips from their real sets" do
    Tour.strip_labels(0).should eq(Gori::Tui::ProjectView::PANE_LABELS)
    Tour.strip_labels(1).should eq(Gori::Tui::TargetController::SUBS)
    Tour.strip_labels(Tour::HISTORY_TAB).should be_nil
  end

  it "names each focus level the way the app's badge does" do
    Tour.focus_badge(:menu).should eq("TABS")
    Tour.focus_badge(:strip).should eq("SUBTABS")
    Tour.focus_badge(:body).should eq("BODY")
    Tour.focus_badge(:body, insert: true).should eq("EDITOR")
    # The badge's reservation fits its widest word, so the chips never shift under it.
    [:menu, :strip, :body].each do |lvl|
      (Tour.focus_badge(lvl, true).size + 2).should be <= Tour::BADGE_W
    end
  end
end

# Forward and drop decide the selected (top) request, so the mock queue must shrink from the
# top: drawn as a count from the first row, `f` on /api/users made /admin vanish.
describe "Gori::Tui::Tutorial intercept mock" do
  it "drops the forwarded request, not the one below it" do
    Tour.held_rows(2).map { |(_, path, _)| path }.should eq(["/api/users", "/admin"])
    Tour.held_rows(1).map { |(_, path, _)| path }.should eq(["/admin"])
    Tour.held_rows(0).should be_empty
  end
end
