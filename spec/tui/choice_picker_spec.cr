require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

describe Gori::Tui::ChoicePicker do
  it "opens on the row whose value is current" do
    ChoicePicker.for_severity(3).selected_value.should eq(3) # High
    ChoicePicker.for_status(2).selected_value.should eq(2)   # false-positive
  end

  it "maps a mnemonic key to its row (case-insensitive), nil for a miss" do
    p = ChoicePicker.for_severity(0)
    p.index_for('h').should eq(1) # HIGH
    p.set_selected(p.index_for('C').not_nil!)
    p.selected_value.should eq(4) # CRITICAL
    p.index_for('z').should be_nil
  end

  it "clamps movement at both ends" do
    p = ChoicePicker.for_status(0)
    p.move(-5)
    p.selected.should eq(0)
    p.move(99)
    p.selected_value.should eq(3) # resolved (last)
  end

  it "renders the title, labels, and a current marker" do
    backend = MemoryBackend.new(80, 24)
    ChoicePicker.for_severity(2).render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("SET SEVERITY").should be_true
    backend.contains?("MEDIUM").should be_true
    backend.contains?("current").should be_true
  end
end

describe "ChoicePicker — Overlay contract" do
  it "supplies the chrome the shell's collapsed title/hint ladders read off it" do
    # Unlike the confirm, this modal's badge IS its card heading — the pre-seam ladder
    # read the badge off this same getter, so it varies per picker.
    h = OverlayHarness.new(ChoicePicker.for_severity(2))
    h.assert_chrome(OverlayKind::Choice, "SET SEVERITY")
    OverlayHarness.new(ChoicePicker.for_probe_mode(1)).assert_chrome(OverlayKind::Choice, "SET PROBE MODE")
    # Only a confirm raised from inside another modal carries a restore. A picker that grew
    # one would re-open something behind it after a plain dismiss.
    h.overlay.on_close.should be_nil
  end

  it "sets on ↵ and cancels on esc" do
    h = OverlayHarness.new(ChoicePicker.for_severity(2))
    picked = nil.as(Int32?)
    h.on_commit { picked = h.overlay.as(ChoicePicker).selected_value; true }
    h.press(Termisu::Input::Key::Up) # MEDIUM → HIGH
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    picked.should eq(3)

    esc = OverlayHarness.new(ChoicePicker.for_severity(2))
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  # A mnemonic is a ONE-keystroke pick: it both moves the highlight and commits, so the
  # commit must observe the row the letter named, not the row that was highlighted.
  it "applies a row's mnemonic directly, without a second ↵" do
    h = OverlayHarness.new(ChoicePicker.for_severity(2))
    picked = nil.as(Int32?)
    h.on_commit { picked = h.overlay.as(ChoicePicker).selected_value; true }
    h.type("C").should eq(:closed) # CRITICAL, case-insensitive
    picked.should eq(4)
  end

  it "falls back to j/k nav when they are not themselves a mnemonic" do
    h = OverlayHarness.new(ChoicePicker.for_severity(4)) # opens on CRITICAL (row 0)
    picker = h.overlay.as(ChoicePicker)
    h.type("j")
    picker.selected.should eq(1)
    h.commits.should eq(0) # nav, not a pick
    h.type("k")
    picker.selected.should eq(0)
  end

  # …and the mnemonic WINS when a row actually claims j or k, so the letter never
  # silently degrades into a cursor move on some future picker.
  it "prefers a j/k mnemonic over vim-style nav" do
    p = ChoicePicker.new("PICK", [
      ChoicePicker::Choice.new("stay", 's', Theme.muted, 0),
      ChoicePicker::Choice.new("jump", 'j', Theme.accent, 1),
    ], 0, :test)
    h = OverlayHarness.new(p)
    h.type("j").should eq(:closed)
    p.selected_value.should eq(1)
  end

  # The mnemonic branch is guarded by `!ev.ctrl? && !ev.alt?`. Without that guard a Ctrl or
  # Alt chord whose letter happens to be a mnemonic would SET an issue's severity/status —
  # or the Probe mode — in one keystroke, with no confirmation.
  it "ignores a mnemonic carried on a ctrl or alt chord" do
    h = OverlayHarness.new(ChoicePicker.for_severity(2))
    h.press(Termisu::Input::Key::LowerC, 'c', ctrl: true).should eq(:open)
    h.press(Termisu::Input::Key::LowerC, 'c', alt: true).should eq(:open)
    h.commits.should eq(0)
    h.overlay.as(ChoicePicker).selected_value.should eq(2) # still MEDIUM, not CRITICAL
  end

  it "swallows any other printable so a value pick stays deliberate" do
    h = OverlayHarness.new(ChoicePicker.for_severity(2))
    h.type("zq").should eq(:open)
    h.commits.should eq(0)
    h.overlay.as(ChoicePicker).selected_value.should eq(2)
  end

  it "scrolls the list with the wheel rather than committing" do
    h = OverlayHarness.new(ChoicePicker.for_severity(4))
    h.wheel(3)
    h.overlay.as(ChoicePicker).selected.should eq(3)
    h.commits.should eq(0)
  end

  it "routes clicks: a row selects AND applies, outside dismisses" do
    p = ChoicePicker.for_severity(4) # opens on CRITICAL (row 0)
    h = OverlayHarness.new(p)
    box = h.box.not_nil!
    p.handle_click(h.area, box.x + 3, box.y + 3).should eq(:commit) # third row: MEDIUM
    p.selected_value.should eq(2)
    p.handle_click(h.area, box.x - 1, box.y).should eq(:cancel)
  end

  describe ".for_export_format" do
    it "marks no row 'current' but still defaults to Markdown" do
      # Unlike its three siblings this picker SETS nothing — it asks a one-off question, so a
      # "● current" marker would claim a state that doesn't exist. Passing -1 gets that for
      # free while `@selected` still parks on row 0, the report ⇧E used to write outright.
      p = ChoicePicker.for_export_format
      p.selected.should eq(0)
      p.selected_value.should eq(0) # :markdown — see Runner::EXPORT_FORMATS
      h = OverlayHarness.new(ChoicePicker.for_export_format)
      h.rendered?("● current").should be_false
      h.rendered?("EXPORT ISSUES AS").should be_true
    end

    it "commits a format on its mnemonic, in one keystroke" do
      {'m' => 0, 'j' => 1, 's' => 2}.each do |key, value|
        h = OverlayHarness.new(ChoicePicker.for_export_format)
        h.press(Termisu::Input::Key::LowerA, key)
        h.commits.should eq(1)
        h.overlay.as(ChoicePicker).selected_value.should eq(value)
      end
    end

    it "indexes Runner::EXPORT_FORMATS — the picker holds labels, the Runner holds symbols" do
      # A row whose value has no symbol behind it would silently export the wrong format.
      p = ChoicePicker.for_export_format
      (0..2).each { |i| Gori::Tui::Runner::EXPORT_FORMATS[i]?.should_not be_nil }
      p.set_selected(2)
      Gori::Tui::Runner::EXPORT_FORMATS[p.selected_value].should eq(:sarif)
    end
  end

  # The harness default area is the whole screen, which is roomier than the `layout.body`
  # production hands over, so this path needs an explicit rect: with no card drawn there is
  # nothing to click, and a click must dismiss rather than act on a phantom row.
  it "dismisses a click when the area is too small to draw the card" do
    p = ChoicePicker.for_severity(2)
    tiny = Rect.new(0, 0, 16, 4)
    p.overlay_box(tiny).should be_nil
    p.handle_click(tiny, 8, 2).should eq(:cancel)
  end

  # The agent-target picker (#1090) is the first ChoicePicker whose rows carry a name the PEER
  # chose, and the first whose labels routinely outrun the card: `overlay_box` never widens
  # past `area.w - 4`, while the label was drawn with `Screen#text`'s default limit — the
  # terminal width — so it ran straight over the card's right border into the backdrop.
  it "keeps a label longer than the card inside the card's border" do
    long = "claude-code-very-long-name · pid 48213 · attached 3m ago"
    p = ChoicePicker.new("TELL WHICH AGENT",
      [ChoicePicker::Choice.new(long, '1', Theme.text, 0),
       ChoicePicker::Choice.new("all attached agents", '2', Theme.accent, 1)], -1, :agent_target)
    area = Rect.new(0, 0, 60, 20)
    backend = MemoryBackend.new(60, 20)
    p.render(Screen.new(backend), area)
    box = p.overlay_box(area).not_nil!
    row = backend.row(box.y + 1)
    # The border is still the border, and nothing was painted outside the card.
    row[box.right - 1].should eq('│')
    row[box.right...].strip.should eq("")
    row[...box.x].strip.should eq("")
  end

  # The `● current` marker keeps a blank column on each side. Reserving only its own width
  # plus one left a truncated label touching the bullet (`…● current`).
  it "keeps a gap between a truncated label and the current marker" do
    long = "a name far too long for this card to hold at all"
    p = ChoicePicker.new("PICK", [ChoicePicker::Choice.new(long, '1', Theme.text, 7)], 7, :agent_target)
    area = Rect.new(0, 0, 44, 20)
    backend = MemoryBackend.new(44, 20)
    p.render(Screen.new(backend), area)
    box = p.overlay_box(area).not_nil!
    row = backend.row(box.y + 1)
    row.should contain("● current")
    row[row.index("● current").not_nil! - 1].should eq(' ')
  end

  # `overlay_box` sizes the card from the widest label. Measured in CHARACTERS it under-sizes
  # by half for a CJK or emoji name, which is the same overflow one step earlier.
  it "sizes the card by display columns, not by character count" do
    wide = ChoicePicker.new("T", [ChoicePicker::Choice.new("가" * 20, '1', Theme.text, 0)], -1, :agent_target)
    narrow = ChoicePicker.new("T", [ChoicePicker::Choice.new("a" * 20, '1', Theme.text, 0)], -1, :agent_target)
    area = Rect.new(0, 0, 120, 20)
    wide.overlay_box(area).not_nil!.w.should eq(narrow.overlay_box(area).not_nil!.w + 20)
  end
end
