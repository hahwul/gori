require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# PickerOverlay / FilterPickerOverlay are the base the seven C4 selection-list modals
# share (issue #355). Each of them used to repeat the same dispatch by hand in runner.cr;
# unifying seven copies is exactly where a "harmless" tidy silently changes behaviour, so
# what is pinned here is the base's own contract, once, for every subclass at the same
# time. The per-modal files own the behaviour that actually differs.

# What the shell really hands an overlay on an 80x24 terminal: layout.body, which is
# 6 rows shorter and offset from OverlayHarness::DEFAULT_AREA (the whole screen).
private PROD_BODY = Gori::Tui::Rect.new(2, 4, 76, 18)

# Small enough that EVERY C4 card bails out of overlay_box with nil. The filter pickers
# floor at w<30/h<8 and the prompt-tier ones at w<18/h<5, so this clears the lower bound.
private NO_ROOM = Gori::Tui::Rect.new(0, 0, 20, 4)

private def flow_rows : Array(Gori::Store::FlowRow)
  (1..3).map do |i|
    Gori::Store::FlowRow.new(i.to_i64, 1_i64, "https", "GET", "h#{i}.test", 443, "/p#{i}",
      200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  end
end

private def every_picker : Array(PickerOverlay)
  [
    FlowPicker.new(flow_rows, :a),
    SubtabPicker.new("FIND SUB-TAB", [SubtabPicker::Row.new(0, "a", "b")]),
    LinkPicker.new([LinkPicker::Row.new(Gori::Store::LinkOwnerKind::Issue, 1_i64,
      "#1 [high] t", "t", "h.test · open")]),
    LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64),
    CopyPicker.new("COPY AS", [CopyMenu::Option.new("URL", 'u', "https://a.test/")]),
    SendPicker.new("Send selection to", "abc", SendMenu.destinations),
  ] of PickerOverlay
end

describe Gori::Tui::PickerOverlay do
  it "clamps the cursor at both ends for every picker" do
    every_picker.each do |ov|
      ov.move(-99)
      ov.selected.should eq(0), "#{ov.class} underflowed"
      ov.move(99)
      ov.selected.should eq({ov.entry_count - 1, 0}.max), "#{ov.class} overflowed"
    end
  end

  it "leaves the cursor alone on an empty list rather than going negative" do
    # entry_count 0 has no valid index; the pre-migration guards were `return if empty?`.
    [FlowPicker.new([] of Gori::Store::FlowRow, :a),
     SubtabPicker.new("FIND SUB-TAB", [] of SubtabPicker::Row),
     LinksOverlay.new(Gori::Store::LinkOwnerKind::Issue, 1_i64),
     CopyPicker.new("COPY AS", [] of CopyMenu::Option),
     SendPicker.new("Send selection to", "x", [] of SendMenu::Destination)].each do |ov|
      ov.entry_count.should eq(0), "#{ov.class} is not actually empty"
      ov.move(1)
      ov.selected.should eq(0)
      ov.set_selected(5)
      ov.selected.should eq(0)
    end
  end

  it "the wheel scrolls the list — the base routes handle_wheel to move" do
    ov = FlowPicker.new(flow_rows, :a)
    OverlayHarness.new(ov).wheel(2)
    ov.selected.should eq(2)
  end

  it "still centres a card in layout.body, not just in the harness's full screen" do
    # DEFAULT_AREA is the whole 80x24 screen; production gives 76x18 at (2,4). A card that
    # only fits in the former would be a nil box — an unclickable modal — in the real app.
    every_picker.each do |ov|
      box = ov.overlay_box(PROD_BODY)
      box.should_not be_nil, "#{ov.class} has no box at the production body size"
      b = box.not_nil!
      PROD_BODY.contains?(b.x, b.y).should be_true, "#{ov.class} starts outside the body"
      (b.right <= PROD_BODY.right).should be_true, "#{ov.class} overflows the body width"
      (b.bottom <= PROD_BODY.bottom).should be_true, "#{ov.class} overflows the body height"
    end
  end

  it "turns EVERY click into a dismiss once the terminal is too small to draw the card" do
    # Every pre-migration handler opened with `box.nil? || dismiss_zone? → close`. The base
    # has to keep that: with no card on screen there is nothing to hit, and swallowing the
    # click would strand the user in an invisible modal.
    every_picker.each do |ov|
      ov.overlay_box(NO_ROOM).should be_nil, "#{ov.class} still claims a box at 20x4"
      ov.handle_click(NO_ROOM, 5, 3).should eq(:cancel), "#{ov.class} swallowed a click with no card"
    end
  end
  it "answers a click on an EMPTY picker instead of raising out of the event loop" do
    # CopyPicker/SendPicker size their card from the widest row, via a max_of that throws
    # on an empty list — and the base calls overlay_box on EVERY click. Both open-sites
    # refuse to open an empty picker today, so this is unreachable; it is guarded because
    # the base now makes "a click outside dismisses" a promise for all seven, and an
    # Enumerable::EmptyError out of handle_click would take the event loop with it.
    area = Gori::Tui::Rect.new(0, 0, 80, 24)
    [CopyPicker.new("COPY AS", [] of CopyMenu::Option),
     SendPicker.new("Send selection to", "x", [] of SendMenu::Destination)].each do |ov|
      ov.overlay_box(area).should be_nil, "#{ov.class} sized a card from zero rows"
      ov.handle_click(area, 5, 5).should eq(:cancel)
    end

    # The filter pickers keep a fixed-size card, so an empty one still has a box: a click
    # inside is swallowed, a click outside dismisses. Neither may raise.
    [FlowPicker.new([] of Gori::Store::FlowRow, :a),
     SubtabPicker.new("FIND SUB-TAB", [] of SubtabPicker::Row)].each do |ov|
      box = ov.overlay_box(area).not_nil!
      ov.handle_click(area, box.x + 3, box.y + 4).should eq(:stay)
      ov.handle_click(area, 0, 0).should eq(:cancel)
    end
  end
end

describe Gori::Tui::FilterPickerOverlay do
  it "reports :stay for a filter keystroke and :commit/:cancel only for ↵/esc" do
    # The raw vocabulary, not the harness's collapsed :open/:closed — a filter key that
    # leaked :commit would apply the modal on every character typed.
    ov = FlowPicker.new(flow_rows, :a)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: 'h')).should eq(:stay)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Down)).should eq(:stay)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Backspace)).should eq(:stay)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should eq(:commit)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "drops control characters from the filter instead of typing them in" do
    # handle_key's `else` arm forwards whatever ev.char it is given, so the control guard
    # has to live in query_char — otherwise a stray tab or escape byte lands in the query
    # and silently filters every row away with no visible cause.
    ov = FlowPicker.new(flow_rows, :a)
    ov.query_char('\t')
    ov.query_char('\e')
    ov.entry_count.should eq(3)
    OverlayHarness.new(ov).rendered?("filter:").should be_false # the query is still empty

    ov.query_char('h') # ...but a printable one does go in
    OverlayHarness.new(ov).rendered?("filter:").should be_true
  end

  it "does not type a Ctrl chord's letter into the filter query" do
    # ^P over an open filter picker: Event::Key#char falls back to key.to_char, so the
    # event carries 'p' even though nothing printable was typed. query_char's own
    # `return if ch.control?` cannot see it — the char is the plain letter, not the C0 byte.
    ov = FlowPicker.new(flow_rows, :a)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerP,
      Termisu::Input::Modifier::Ctrl)).should eq(:stay)
    OverlayHarness.new(ov).rendered?("filter:").should be_false
  end

  it "does not type a Ctrl chord's letter under the CSI-u / Kitty parse either" do
    # There @char is attached explicitly, so the fallback is not what delivers the letter.
    kitty = FlowPicker.new(flow_rows, :a)
    kitty.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerP,
      Termisu::Input::Modifier::Ctrl, 'p')).should eq(:stay)
    OverlayHarness.new(kitty).rendered?("filter:").should be_false
  end

  it "does not filter the list away when the operator presses the quit chord" do
    # quit_chord_claimed?(modal: true) is false, so ^C/^D reach the modal. 'c' appears in
    # no haystack ("get hN.test/pN 200"), so typing it empties the list under the operator.
    ov = FlowPicker.new(flow_rows, :a)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerC,
      Termisu::Input::Modifier::Ctrl))
    ov.entry_count.should eq(3)
  end

  it "still types a plain printable, and an Alt chord's letter is inert too" do
    ov = FlowPicker.new(flow_rows, :a)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerC, char: 'c'))
    ov.entry_count.should eq(0) # a real keystroke still filters
    OverlayHarness.new(ov).rendered?("filter:").should be_true

    alt = FlowPicker.new(flow_rows, :a)
    alt.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerC,
      Termisu::Input::Modifier::Alt))
    alt.entry_count.should eq(3)
  end

  it "keeps LibraryPicker's own ^X delete working" do
    # LibraryPicker claims ^X before calling super, so the base's guard must not shadow it —
    # the subclass half of this base's contract, the way every_picker is the geometry half.
    deleted = [] of Int32
    ov = LibraryPicker.new("SAVED", [LibraryPicker::Row.new(0, "alpha", "spec")], "chain")
    ov.on_delete = ->(i : Int32) { deleted << i; nil }
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX,
      Termisu::Input::Modifier::Ctrl)).should eq(:stay)
    deleted.should eq([0])
  end

  it "a committed character ends an in-progress IME composition" do
    # Otherwise the preedit underline lingers next to text that already committed.
    h = OverlayHarness.new(FlowPicker.new(flow_rows, :a))
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
    h.type("h")
    h.rendered?("preedithere").should be_false
  end
end
