require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `RowFilter` — the `/` substring lens the Discover FINDINGS, Miner RESULTS and Authorize
# request lists share (lifted from the OAST callbacks filter).

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

describe Gori::Tui::RowFilter do
  it "matches case-insensitively, and everything on a blank query" do
    f = RowFilter.new
    f.matches?("GET /Admin").should be_true
    f.start
    "adm".each_char { |c| f.handle_key(key(Termisu::Input::Key::LowerA, c)) }
    f.text.should eq("adm")
    f.matches?("GET /Admin").should be_true
    f.matches?("GET /login").should be_false
  end

  it "keeps the query on ↵, clears it on esc, and never lets a key out" do
    f = RowFilter.new
    f.start
    f.editing?.should be_true
    f.shown?.should be_true
    "x".each_char { |c| f.handle_key(key(Termisu::Input::Key::LowerX, c)) }
    f.handle_key(key(Termisu::Input::Key::Tab)).should be_true # swallowed — the ring must not move
    f.text.should eq("x")
    f.handle_key(key(Termisu::Input::Key::Enter)).should be_true
    f.editing?.should be_false
    f.active?.should be_true
    f.shown?.should be_false # a held query rides the border above its rows, it owns no row
    f.start
    f.handle_key(key(Termisu::Input::Key::Escape)).should be_true
    f.active?.should be_false
    f.shown?.should be_false
  end

  it "draws the caret row while editing and rests on a border after" do
    f = RowFilter.new
    f.start
    "ab".each_char { |c| f.handle_key(key(Termisu::Input::Key::LowerA, c)) }
    b = MemoryBackend.new(40, 1)
    f.render_bar(Screen.new(b), Rect.new(0, 0, 40, 1))
    b.row(0).should contain("filter › ab")
    # Typing: the border says nothing, the row has it.
    b = MemoryBackend.new(40, 1)
    f.render_label(Screen.new(b), 2, 0, 40, 5)
    b.row(0).strip.should be_empty
    f.handle_key(key(Termisu::Input::Key::Enter))
    b = MemoryBackend.new(40, 1)
    f.render_bar(Screen.new(b), Rect.new(0, 0, 40, 1))
    b.row(0).strip.should be_empty # no row at rest
    f.render_label(Screen.new(b), 2, 0, 40, 5)
    b.row(0).should start_with("   : ab ")
  end

  it "names its key on the border while idle, unless there is nothing to narrow" do
    f = RowFilter.new
    b = MemoryBackend.new(40, 1)
    f.render_label(Screen.new(b), 2, 0, 40, 5)
    b.row(0).should start_with("   / filter ")
    empty = MemoryBackend.new(40, 1)
    f.render_label(Screen.new(empty), 2, 0, 40, 0)
    empty.row(0).strip.should be_empty
  end
end

describe "RowFilter shell keys (#1379)" do
  it "answers ^A ^E ^U ^W like the `/` bars" do
    ctrl = Termisu::Input::Modifier::Ctrl
    f = RowFilter.new
    f.start
    "get admin".each_char { |c| f.handle_key(key(Termisu::Input::Key::Unknown, c)) }
    f.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerW, ctrl, nil)).should be_true
    f.text.should eq("get ")
    f.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, ctrl, nil))
    f.handle_key(key(Termisu::Input::Key::Unknown, 'x'))
    f.text.should eq("xget ")
    f.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerE, ctrl, nil))
    f.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerU, ctrl, nil))
    f.text.should eq("")
    f.editing?.should be_true
  end
end

# One dress for every filter at rest (sub-tab strips, list cards, Issues, OAST, Help).
describe "Frame.filter_label" do
  it "draws the key idle and `: query` when one is held, never reaching max_x" do
    b = MemoryBackend.new(40, 1)
    Frame.filter_label(Screen.new(b), 2, 0, 40, "", tail: " · f find").should eq(21)
    b.row(0).should start_with("   / filter · f find ")
    held = MemoryBackend.new(40, 1)
    Frame.filter_label(Screen.new(held), 2, 0, 40, "status:500")
    held.row(0).should start_with("   : status:500 ")
    held.fg_at(3, 0).should eq(Theme.muted) # the colon is chrome
    held.fg_at(5, 0).should eq(Theme.text)  # the query is the operator's
  end

  it "drops the tail, then everything, as the room runs out" do
    b = MemoryBackend.new(40, 1)
    Frame.filter_label(Screen.new(b), 0, 0, 12, "", tail: " · f find")
    b.row(0).rstrip.should eq(" / filter")
    none = MemoryBackend.new(40, 1)
    Frame.filter_label(Screen.new(none), 0, 0, 6, "", tail: " · f find").should eq(0)
    none.row(0).strip.should be_empty
    cut = MemoryBackend.new(40, 1)
    Frame.filter_label(Screen.new(cut), 0, 0, 12, "a-very-long-query")
    cut.row(0)[12, 28].strip.should be_empty # nothing at or past max_x
    cut.row(0).should start_with(" : a-very")
  end

  it "starts a label one hairline cell past a card's title, or where the title would be" do
    rect = Rect.new(0, 0, 60, 5)
    Frame.after_title(rect, nil).should eq(2)
    Frame.after_title(rect, "FINDINGS").should eq(13) # `╭─ FINDINGS ─` then the label
  end

  # A border meta can be long (OAST's eviction caveat, Activity's chips, a Rewriter tally
  # with globals). The label stops at it rather than painting over it or under it.
  it "keeps a card's label to three fifths, and short of a meta that reaches into them" do
    rect = Rect.new(0, 0, 50, 5)
    RowFilter.label_limit(rect).should eq(30)
    RowFilter.label_limit(rect, 40).should eq(30) # a short meta past the three fifths
    RowFilter.label_limit(rect, 22).should eq(22) # a long one: the label yields
  end
end
