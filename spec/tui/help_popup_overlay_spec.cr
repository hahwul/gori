require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# Help's two reference pages as a popup over the current pane. The examples that matter are
# the ones that pin it to HelpView rather than to itself: the whole reason this overlay is
# 200 lines and not 400 is that it renders HelpView's rows with HelpView's painter, and the
# moment it stops doing that the two surfaces start disagreeing about what a key does.
private def registry
  Gori::Verbs.registry
end

private def shortcuts(tab : Symbol = :history) : HelpPopupOverlay
  HelpPopupOverlay.shortcuts(registry, tab)
end

private def ev(char : Char, ctrl = false, alt = false) : Termisu::Event::Key
  mods = Termisu::Input::Modifier::None
  mods |= Termisu::Input::Modifier::Ctrl if ctrl
  mods |= Termisu::Input::Modifier::Alt if alt
  Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: char, modifiers: mods)
end

# The FIELDS section of a query page, as {name => help}. Lets an example assert the vocabulary
# a surface teaches without depending on row order or on the sections around it.
private def field_rows(rows : Array(Gori::Tui::HelpView::Row)) : Hash(String, String)
  out = {} of String => String
  in_fields = false
  rows.each do |r|
    if r.kind == :head
      in_fields = r.a.starts_with?("FIELDS")
      next
    end
    out[r.a.rchop(':')] = r.b if in_fields && r.kind == :item
  end
  out
end

describe Gori::Tui::HelpPopupOverlay do
  it "renders the SAME rows the Help tab does, for both pages" do
    # Not "renders something plausible": the row LISTS are compared, so a future edit that
    # gives the popup its own copy of either page fails here rather than in six months when
    # a rebind shows up on one surface and not the other.
    shortcuts.rows.should eq(HelpView.shortcut_rows(registry))
    HelpPopupOverlay.query_reference.rows.should eq(HelpView.query_rows)
  end

  it "resolves the key column through the live keymap, not the raw SECTIONS literal" do
    # `history.repeater`'s row is written as `^R` in SECTIONS and carries a verb id, so a
    # popup that read SECTIONS directly would still print `^R` and look correct. What proves
    # the popup went through `binding_label` is a row whose literal and effective label
    # DIFFER — `app.palette` is chorded `ctrl-p`, which renders as `^P`.
    rows = shortcuts.rows
    palette = rows.find { |r| r.kind == :item && r.b.includes?("command palette") }
    palette.should_not be_nil
    palette.not_nil!.a.should eq(Gori::Hotkeys.binding_label(registry, "app.palette", "^P"))
  end

  it "supplies the shell chrome every migrated modal owes" do
    OverlayHarness.new(shortcuts).assert_chrome(OverlayKind::Help, "SHORTCUTS")
    OverlayHarness.new(HelpPopupOverlay.query_reference).assert_chrome(OverlayKind::Help, "QUERY LANGUAGE")
  end

  describe "the per-surface field vocabulary" do
    # The GRAMMAR is one — every bar parses through FilterAst — but the FIELD LIST is not, and
    # a reference that lists fields the bar under it rejects, or defines them the other way
    # round, is worse than no reference. `InterceptFilter::FIELD_HELP`'s own comment says it
    # was merged-not-copied over QL's to stop exactly this drift.

    it "teaches the Intercept condition's own fields, not QL's" do
      rows = HelpView.query_rows(Gori::InterceptFilter::FIELDS, Gori::InterceptFilter::FIELD_HELP_PROC)
      fields = field_rows(rows)

      # The four QL entries a hold gate deliberately redefines.
      fields["status"].should eq("code/class — and scopes to RESPONSES only")
      fields["proto"].should eq("http, or ws to opt WebSocket messages IN")
      fields["header"].should eq("head of the message in hand (this leg only)")
      fields["body"].should eq("payload in hand — WS messages, extract rules")

      # And none of the nine QL fields a gate can never answer.
      %w[size reqsize respsize dur stub req.header resp.header req.body resp.body].each do |f|
        fields.has_key?(f).should be_false, "the intercept reference offers `#{f}:`, which the gate rejects"
      end
    end

    it "drops aliases whose target the surface does not have" do
      # `res.header:` is not "also accepted" where `resp.header:` does not exist.
      rows = HelpView.query_rows(Gori::InterceptFilter::FIELDS, Gori::InterceptFilter::FIELD_HELP_PROC)
      rows.any? { |r| r.a.starts_with?("res.header") }.should be_false
      # QL keeps them.
      HelpView.query_rows.any? { |r| r.a.starts_with?("res.header") }.should be_true
    end

    it "teaches Sitemap's own tag:, which never reaches the parser" do
      rows = HelpView.query_rows(["tag"] + Gori::QL::FIELDS, SitemapView::QL_HELP)
      field_rows(rows)["tag"].should eq("path memo on this node — set with space → T")
    end

    it "still teaches the shared grammar on every surface" do
      [HelpView.query_rows,
       HelpView.query_rows(Gori::InterceptFilter::FIELDS, Gori::InterceptFilter::FIELD_HELP_PROC),
       HelpView.query_rows(["tag"] + Gori::QL::FIELDS, SitemapView::QL_HELP)].each do |rows|
        heads = rows.select(&.kind.== :head).map(&.a)
        heads.should contain("SYNTAX")
        heads.should contain("WORTH KNOWING")
      end
    end

    it "leaves the Help tab's own Query page on plain QL" do
      HelpView.query_rows.should eq(HelpView.query_rows(Gori::QL::FIELDS))
    end
  end

  describe "the context-aware landing" do
    it "opens on the section for the tab you came from" do
      h = OverlayHarness.new(shortcuts(:repeater))
      rendered = h.render
      # VISIBLE, not `scroll == head_index`: the offset is clamped against the card height at
      # render, so a section near the tail settles above its own head. Being on screen is the
      # property the operator actually has.
      rendered.contains?("REPEATER").should be_true
      rendered.contains?("send the request").should be_true
    end

    it "lands on OTHER TABS for a tab with no section of its own" do
      HelpPopupOverlay.landing_scroll(HelpView.shortcut_rows(registry), :issues).should_not eq(0)
      rows = HelpView.shortcut_rows(registry)
      idx = HelpPopupOverlay.landing_scroll(rows, :issues)
      rows[idx].a.should eq("OTHER TABS")
    end

    it "opens at the top from Help itself and from an unmapped tab" do
      HelpPopupOverlay.landing_scroll(HelpView.shortcut_rows(registry), :help).should eq(0)
    end

    it "maps every real tab to a section that exists" do
      # Two failure modes, both silent: a tab missing from TAB_SECTION quietly opens at the
      # top, and a typo'd title does the same. Neither is visible from the map itself.
      titles = HelpView::SECTIONS.map { |(t, _)| t }
      HelpView::TAB_SECTION.each do |tab, title|
        titles.should contain(title), "TAB_SECTION[#{tab}] names a section that does not exist: #{title}"
      end
      Chrome::TABS.each do |(sym, _)|
        next if sym == :help # deliberately absent — the whole sheet is what that tab already shows
        HelpView::TAB_SECTION.has_key?(sym).should be_true, "no TAB_SECTION entry for the #{sym} tab"
      end
    end
  end

  describe "the filter" do
    it "narrows to matching rows and keeps each survivor's section head" do
      ov = shortcuts
      before = ov.rows.size
      OverlayHarness.new(ov).type("hex")
      ov.rows.size.should be < before
      ov.rows.none? { |r| r.kind == :gap }.should be_true
      items = ov.rows.select { |r| r.kind == :item }
      items.should_not be_empty
      items.all? { |r| "#{r.a} #{r.b}".downcase.includes?("hex") }.should be_true
      # A hit has to say WHERE it applies — `y` means different things in HISTORY and JWT.
      ov.rows.first.kind.should eq(:head)
    end

    it "restores the full list on backspace" do
      ov = shortcuts
      all = ov.rows.size
      h = OverlayHarness.new(ov)
      h.type("hex")
      3.times { h.press(Termisu::Input::Key::Backspace) }
      ov.rows.size.should eq(all)
    end

    it "reports the narrowed count on the card, against the same denominator at rest" do
      total = HelpView.shortcut_rows(registry).count { |r| r.kind == :item }
      # Unfiltered must count ITEMS too. Counting `@all.size` there put section heads and blank
      # spacers in the numerator, so the border jumped from "189 rows" to "N of 156" on the
      # first keystroke — two denominators for one list, which reads as rows disappearing.
      OverlayHarness.new(shortcuts).rendered?("#{total} rows").should be_true

      ov = shortcuts
      OverlayHarness.new(ov).type("hex")
      matched = ov.rows.count { |r| r.kind == :item }
      OverlayHarness.new(ov).rendered?("#{matched} of #{total}").should be_true
    end

    it "parks the caret on its own card, not the filter bar it was opened from" do
      # `Screen#desired_cursor` is last-writer-wins per frame and the tab body draws first, so
      # an overlay that sets no cursor leaves the caret blinking in the bar underneath — and
      # this is the one overlay reachable straight from an editing text bar (`?`).
      area = OverlayHarness::DEFAULT_AREA
      ov = shortcuts
      screen = Screen.new(MemoryBackend.new(area.w, area.h))
      screen.cursor(0, 0) # stand in for the filter bar drawn underneath this frame
      ov.render(screen, area)
      box = ov.overlay_box(area).not_nil!
      screen.desired_cursor.should eq({box.x + 2, box.y + 1})
    end

    it "says so when nothing matches, instead of drawing an empty card" do
      ov = shortcuts
      OverlayHarness.new(ov).type("zzzznotathing")
      ov.rows.should be_empty
      OverlayHarness.new(ov).rendered?("no rows match").should be_true
    end
  end

  describe "key routing" do
    it "hops to the palette on ^P" do
      ov = shortcuts
      hopped = 0
      ov.on_palette = -> { hopped += 1; nil }
      OverlayHarness.new(ov).press(Termisu::Input::Key::LowerP, 'p', ctrl: true).should eq(:open)
      hopped.should eq(1)
      ov.query.should be_empty
    end

    it "drops every OTHER ctrl chord instead of typing its letter into the filter" do
      # This is what `!ev.ctrl? && !ev.alt?` on the printable arm buys, and it is NOT what the
      # ^P example above proves: ^P is claimed by an earlier arm, so that one passes with or
      # without the guard. The real hazard is the rest of the alphabet — `Event::Key#char`
      # falls back to `key.to_char`, so ^K arrives carrying 'k' and an unguarded arm silently
      # types it. ^K/^X/^R are muscle memory in six scopes; every one of them would land here
      # as filter text.
      ov = shortcuts
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::LowerK, 'k', ctrl: true)
      h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true)
      h.press(Termisu::Input::Key::LowerR, 'r', alt: true)
      ov.query.should be_empty
      ov.rows.size.should eq(HelpView.shortcut_rows(registry).size)
    end

    it "types a bare p into the filter" do
      ov = shortcuts
      OverlayHarness.new(ov).press(Termisu::Input::Key::LowerP, 'p')
      ov.query.should eq("p")
    end

    it "does NOT bind j/k/g/G to motion — they are filter input" do
      # With a filter bar, a letter arm above the printable arm eats that letter out of every
      # query someone types (`g` is in "graphql", `k` in "key"). ProjectPicker learned the
      # same rule from the other side.
      ov = shortcuts
      OverlayHarness.new(ov).type("gjkG")
      ov.query.should eq("gjkG")
    end

    it "closes on esc and stays open on ↵" do
      OverlayHarness.new(shortcuts).press(Termisu::Input::Key::Escape).should eq(:closed)
      # Read-only: there is nothing to commit, and a :commit here would let a stray Enter
      # close a card the operator is still reading.
      h = OverlayHarness.new(shortcuts)
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      h.commits.should eq(0)
    end

    it "scrolls with the arrows, the page keys and the wheel" do
      ov = shortcuts(:help) # starts at the top
      h = OverlayHarness.new(ov)
      ov.scroll.should eq(0)
      h.press(Termisu::Input::Key::Down)
      ov.scroll.should eq(1)
      # Drawn first, because the shell always draws before the next key arrives and the page
      # size is only knowable on that path (see page_step). Without this the step falls back to
      # the pre-first-frame seed, which is what the raw numbers below would otherwise pin.
      h.render
      h.press(Termisu::Input::Key::PageDown)
      # ⇞/⇟ must move a real page, not a hardcoded guess — the hint says "page". The card in
      # DEFAULT_AREA (80x24) is 22 rows tall, leaving 18 list rows under the filter bar and
      # divider, so a page is 17 (one row of overlap) on top of the 1 from ↓.
      ov.scroll.should eq(18)
      h.press(Termisu::Input::Key::Home)
      ov.scroll.should eq(0)
      h.wheel(3)
      ov.scroll.should eq(3)
    end
  end

  it "degrades to a one-line notice rather than a broken card on a short terminal" do
    # Height-constrained, which is the case an operator actually hits (a wide, short pane).
    # The line names its own escape because it is the only thing on screen — the one
    # placement `overlay_hint_placement_spec` exempts from the hint-lives-in-`hint` rule.
    short = Rect.new(0, 0, 60, 6)
    ov = shortcuts
    ov.overlay_box(short).should be_nil
    OverlayHarness.new(ov, area: short).rendered?("esc to close").should be_true
  end

  it "refuses the card rather than truncating rows when the pane is too narrow" do
    narrow = Rect.new(0, 0, 30, 24)
    shortcuts.overlay_box(narrow).should be_nil
  end

  it "is wide enough for the longest row on both pages" do
    # The point of the popup is reading the sentence that explains a key, so a card that cuts
    # the longest one has failed at its only job. `draw_row` hands a description `w - 27`
    # columns on the Shortcuts page — 2 pad + KEY_W + KEY_GAP left, 1 + two borders right.
    #
    # This fails when someone adds a description longer than the card, which is the moment to
    # decide between a shorter sentence and a wider card — not six months later when an
    # operator finds the row that trails off into `…`.
    shortcut_desc = HelpView.shortcut_rows(registry).select(&.kind.== :item).max_of(&.b.size)
    shortcut_desc.should be <= HelpPopupOverlay::MAX_W - 2 - 2 - HelpView::KEY_W - HelpView::KEY_GAP - 1

    query_desc = HelpView.query_rows.select(&.kind.== :item).max_of(&.b.size)
    query_desc.should be <= HelpPopupOverlay::MAX_W - 2 - 2 - HelpView::QUERY_KEY_W - HelpView::KEY_GAP - 1
  end
end

# The `?`-opens-the-QL-reference key, which lives on the three filter bars rather than on the
# overlay. Driven as a predicate because a controller needs a Host, and a Host needs the Runner,
# which needs a live tty — the same reason OverlayHarness exists for the modal tier.
describe "the QL reference key on a filter bar" do
  it "fires on `?` when the bar is empty" do
    TabController.ql_help_key?(ev('?'), "").should be_true
  end

  it "types a literal `?` once anything has been typed" do
    # EMPTY buffer only, not "after whitespace": `?id=` is a plausible free-text search on a
    # proxy, and a trigger state the operator cannot see is worse than one that only fires
    # from a visibly empty bar.
    TabController.ql_help_key?(ev('?'), "host:acme").should be_false
    TabController.ql_help_key?(ev('?'), "host:acme ").should be_false
  end

  it "ignores every other key, and `?` carried by a modifier" do
    TabController.ql_help_key?(ev('a'), "").should be_false
    TabController.ql_help_key?(ev('/'), "").should be_false
    TabController.ql_help_key?(ev('?', ctrl: true), "").should be_false
    TabController.ql_help_key?(ev('?', alt: true), "").should be_false
  end

  it "is wired into ALL THREE bars, above each printable arm" do
    # The three handle_query_key methods are byte-for-byte parallel, so the failure mode is a
    # partial fix: two bars answer `?` and the third silently types it. Source-scanned because
    # there is no way to reach a controller without the Runner.
    dir = File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers")
    %w[history_controller sitemap_controller intercept_controller].each do |name|
      src = File.read(File.join(dir, "#{name}.cr"))
      src.includes?("TabController.ql_help_key?").should be_true,
        "#{name}.cr never consults ql_help_key? — its filter bar still types the `?`"
      # Above the `else` that inserts the char, or the guard never runs.
      help_at = src.index("TabController.ql_help_key?").not_nil!
      insert_at = src.index("query_insert(c)").not_nil!
      help_at.should be < insert_at, "#{name}.cr checks ql_help_key? below its printable arm"
    end
  end

  it "is advertised on the cold hint of a bar that has it, and only there" do
    QuerySuggest.cold_hint(help_key: true).includes?("? reference").should be_true
    # The Colormarker rule form shares this generator for its `when:` band, where `?` is just
    # a character — advertising the key there would be a lie.
    QuerySuggest.cold_hint.includes?("? reference").should be_false
  end

  it "does not push `-term excludes` off a narrow bar to make room for itself" do
    # `fits?`/the shrink loop protect `-term excludes` BY INDEX, so anything inserted ahead of
    # it moves it right on every surface at once — and none of the three bars passes `width`,
    # so the loop cannot claw it back. Leading with the chip cost 16 columns and newly cut the
    # token off on terminals 84-99 wide. The new chip goes BEHIND it instead.
    plain = QuerySuggest.cold_hint
    with_key = QuerySuggest.cold_hint(help_key: true)
    with_key.index("-term excludes").should eq(plain.index("-term excludes"))
    with_key.index("? reference").not_nil!.should be > with_key.index("-term excludes").not_nil!
  end
end
