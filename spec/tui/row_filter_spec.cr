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
    f.shown?.should be_true # a held query still owns the bar row
    f.start
    f.handle_key(key(Termisu::Input::Key::Escape)).should be_true
    f.active?.should be_false
    f.shown?.should be_false
  end

  it "draws the caret row while editing and the held query after" do
    f = RowFilter.new
    f.start
    "ab".each_char { |c| f.handle_key(key(Termisu::Input::Key::LowerA, c)) }
    b = MemoryBackend.new(40, 1)
    f.render_bar(Screen.new(b), Rect.new(0, 0, 40, 1))
    b.row(0).should contain("filter › ab")
    f.handle_key(key(Termisu::Input::Key::Enter))
    b = MemoryBackend.new(40, 1)
    f.render_bar(Screen.new(b), Rect.new(0, 0, 40, 1))
    b.row(0).should contain(": ab")
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
