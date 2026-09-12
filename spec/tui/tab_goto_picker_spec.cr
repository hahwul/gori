require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The `0` card is the one place an operator meets the whole tab catalog, so what it says about
# a tab that is off the bar is the whole of what "off the bar" means to them. It used to say
# `·`, a muted label and the literal word "hidden" — the vocabulary of the tab-HIDING feature
# the nine slots replaced, about a tab that opens on the very next keypress.
#
# These are rendering assertions on purpose: the defect was never in what the card DID (↵
# always worked on every row) but in how it read. MemoryBackend records chars + fg, which is
# exactly the pair that was lying.
describe TabGotoPicker do
  area = Rect.new(0, 1, 100, 24)

  # The shape Runner#open_tab_goto builds: the bar in its own order, then everything off it.
  rows = [
    TabGotoPicker::Row.new(:history, "History", 1, Chrome.tab_summary(:history)),
    TabGotoPicker::Row.new(:project, "Project", 2, Chrome.tab_summary(:project)),
    TabGotoPicker::Row.new(:decoder, "Decoder", nil, Chrome.tab_summary(:decoder)),
    TabGotoPicker::Row.new(:jwt, "JWT", nil, Chrome.tab_summary(:jwt)),
  ]

  render = ->(picker : TabGotoPicker, a : Rect) do
    backend = MemoryBackend.new(a.w, a.y + a.h)
    picker.render(Screen.new(backend), a)
    backend
  end

  it "gives an off-bar row the same ink as a slotted one" do
    picker = TabGotoPicker.new(rows)
    backend = render.call(picker, area)
    box = picker.overlay_box(area).not_nil!
    top = box.y + FilterPickerOverlay::LIST_OFFSET
    label_x = box.x + 6
    # Row 0 is selected (the cursor opens on the first row here), so compare the two UNselected
    # ones: a slotted `Project` and an off-bar `Decoder`. Same ink, or the card is grading them.
    backend.fg_at(label_x, top + 1).should eq(Theme.text)
    backend.fg_at(label_x, top + 2).should eq(Theme.text)
    backend.fg_at(label_x, top + 2).should_not eq(Theme.muted)
  end

  it "says nothing at all about a row with no digit" do
    picker = TabGotoPicker.new(rows)
    backend = render.call(picker, area)
    box = picker.overlay_box(area).not_nil!
    top = box.y + FilterPickerOverlay::LIST_OFFSET
    backend.row(top).should contain("1:") # the digit that reaches it
    backend.row(top + 2).should_not contain("hidden")
    backend.row(top + 2)[box.x + 3].should eq(' ') # no `·` placeholder either
  end

  it "carries each tab's one line, a step under its own label" do
    picker = TabGotoPicker.new(rows)
    backend = render.call(picker, area)
    box = picker.overlay_box(area).not_nil!
    top = box.y + FilterPickerOverlay::LIST_OFFSET
    summary_x = box.x + 6 + TabGotoPicker::LABEL_W + 1
    backend.row(top + 2).should contain(Chrome.tab_summary(:decoder))
    # The dim is per COLUMN — summary under label — on an off-bar row as much as a slotted one.
    backend.fg_at(summary_x, top + 2).should eq(Theme.muted)
    backend.fg_at(box.x + 6, top + 2).should eq(Theme.text)
  end

  it "filters on the summary, not just the name" do
    picker = TabGotoPicker.new(rows)
    "hash".each_char { |c| picker.query_char(c) }
    picker.entry_count.should eq(1)
    picker.selected_sym.should eq(:decoder) # `hash` appears only in Decoder's line
  end

  it "still answers to a slot digit" do
    picker = TabGotoPicker.new(rows)
    picker.query_char('2')
    picker.selected_sym.should eq(:project)
  end

  it "folds the summary away rather than cutting it on a narrow card" do
    narrow = Rect.new(0, 1, 34, 24)
    picker = TabGotoPicker.new(rows)
    box = picker.overlay_box(narrow).not_nil!
    picker.summary_w(box).should eq(0)
    backend = render.call(picker, narrow)
    top = box.y + FilterPickerOverlay::LIST_OFFSET
    backend.row(top).should contain("History") # the label keeps the whole row
    backend.row(top).should_not contain("every request")
  end

  # A tab added to the catalog without a line would render a blank column and nobody would
  # notice — the card draws fine either way. This is the gate that makes the omission loud.
  it "has a line for every catalog tab, none of them over the column" do
    Chrome::TABS.each do |(sym, label)|
      summary = Chrome.tab_summary(sym)
      summary.should_not be_empty
      Screen.display_width(label).should be <= TabGotoPicker::LABEL_W
      # 58-wide card: ▎ + gap + digit(3) + label(11) + gap, and a gutter before the frame.
      Screen.display_width(summary).should be <= TabGotoPicker::WIDE_W - 6 - TabGotoPicker::LABEL_W - 3
    end
  end
end
