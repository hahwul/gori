require "../spec_helper"
require "../support/tui_contract"

# src/gori/tui/keyset_pad.cr — the setup wizard's practice pad. It must answer a key the way an
# editor pane does under the STAGED keyset, so these examples press real key events and read
# the text the pad ends up holding. One registry for the file: `Verbs.registry` builds a new
# one on every call.
private REGISTRY = Gori::Verbs.registry

private alias Kind = Gori::Verb::Keyset::Kind

private def pad(kind : Kind = Kind::Helix) : Gori::Tui::KeysetPad
  Gori::Tui::KeysetPad.new(kind, REGISTRY, "auto", {} of String => Array(Gori::Verb::Chord))
end

private def press(p : Gori::Tui::KeysetPad, keys : String) : Nil
  keys.each_char { |c| p.handle_key(TuiContract.plain(c)) }
end

private def esc : Termisu::Event::Key
  TuiContract.key(Termisu::Input::Key::Escape)
end

private LINES = Gori::Tui::KeysetPad::SAMPLE.split('\n')

describe Gori::Tui::KeysetPad do
  before_each { Gori::Tui::Register.clear }

  describe "helix-ish" do
    it "selects the line with x, deletes it with d, and p puts it back below" do
      p = pad
      press(p, "xd")
      p.text.should eq(LINES[1..].join("\n"))
      press(p, "p")
      p.text.should eq([LINES[1], LINES[0], LINES[2]].join("\n"))
    end

    it "undoes from READ with ^Z" do
      p = pad
      press(p, "xd")
      p.handle_key(TuiContract.ctrl('z'))
      p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
    end

    it "does not take vim's dd: d with nothing selected deletes nothing" do
      p = pad
      press(p, "dd")
      p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
    end
  end

  describe "vim-ish" do
    it "deletes the caret's line with dd and pastes it back with p" do
      p = pad(Kind::Vim)
      press(p, "d")
      p.armed?.should be_true
      press(p, "d")
      p.text.should eq(LINES[1..].join("\n"))
      press(p, "p")
      p.text.should eq([LINES[1], LINES[0], LINES[2]].join("\n"))
    end

    it "yanks with yy into the register only, linewise" do
      p = pad(Kind::Vim)
      press(p, "yy")
      Gori::Tui::Register.text.should eq(LINES[0])
      Gori::Tui::Register.linewise?.should be_true
      p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
    end

    it "spends an armed d on the next key, whatever it is" do
      p = pad(Kind::Vim)
      press(p, "dj")
      p.armed?.should be_false
      p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
      p.status.should contain("cancelled")
    end

    it "grows a ⇧V selection a line per j, as V then j does, and deletes the lines" do
      p = pad(Kind::Vim)
      press(p, "Vjd")
      p.text.should eq(LINES[2])
    end

    it "moves the caret with h and l" do
      p = pad(Kind::Vim)
      press(p, "llhaZ")
      p.handle_key(esc)
      p.text.should start_with("GEZT")
    end

    it "steps words with w / b and types at a line edge with ⇧A / ⇧I" do
      p = pad(Kind::Vim)
      press(p, "wwbiZ") # GET → / → api, back to /
      p.handle_key(esc)
      p.text.should start_with("GET Z/api")
      press(p, "AQ")
      p.handle_key(esc)
      p.text.lines[0].should end_with("HTTP/1.1Q")
      press(p, "jIY")
      p.handle_key(esc)
      p.text.lines[1].should eq("YHost: example.test")
    end

    it "undoes with u and selects the line with ⇧V, not x" do
      p = pad(Kind::Vim)
      press(p, "x")
      p.status.should contain("nothing in an editor answers it")
      press(p, "Vd")
      p.text.should eq(LINES[1..].join("\n"))
      press(p, "u")
      p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
    end
  end

  it "deletes whole lines after growing a line selection upward, under both keysets" do
    {Kind::Helix, Kind::Vim}.each do |kind|
      Gori::Tui::Register.clear
      p = pad(kind)
      press(p, "jj")
      press(p, kind.vim? ? "V" : "x")
      p.handle_key(TuiContract.key(Termisu::Input::Key::Up, :shift))
      press(p, "d")
      p.text.should eq(LINES[0])
    end
  end

  it "leaves helix-ish x then j a plain move: the selection collapses" do
    p = pad
    press(p, "xjd")
    p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
  end

  it "types in INS and hands esc back only from a plain READ" do
    p = pad
    press(p, "i")
    p.insert?.should be_true
    press(p, "X")
    p.handle_key(esc).should be_true # INS → READ, kept
    p.insert?.should be_false
    p.text.should start_with("XGET")
    p.handle_key(esc).should be_false # READ: the host's key
  end

  it "clears a selection on esc, and hands the next esc back" do
    p = pad(Kind::Vim)
    press(p, "Vj")
    p.handle_key(esc).should be_true
    press(p, "d") # arms dd now: nothing is selected
    p.armed?.should be_true
    p.handle_key(esc).should be_true # …which esc cancels
    p.handle_key(esc).should be_false
    p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
  end

  it "keeps an armed d's esc for itself" do
    p = pad(Kind::Vim)
    press(p, "d")
    p.handle_key(esc).should be_true
    p.armed?.should be_false
  end

  it "never falls through to Global: c does not reach stop-capture" do
    p = pad
    press(p, "c")
    p.status.should contain("nothing in an editor answers it")
    p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
  end

  it "keeps the text across a keyset switch, and drops an armed operator" do
    p = pad(Kind::Vim)
    press(p, "d")
    p.keyset = Kind::Helix
    p.armed?.should be_false
    press(p, "d")
    p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
  end

  # The pad's templates name vim-only verbs (`dd` is `{editor.delete-line}` twice), so they
  # are checked here, under the keyset each is drawn in, rather than by the keyset-blind hint
  # scan (spec/verb/hint_token_expands_spec.cr).
  it "leaves no token unexpanded in any status line it draws" do
    {Kind::Helix, Kind::Vim}.each do |kind|
      p = pad(kind)
      p.status.should_not contain('{')
      press(p, kind.vim? ? "V" : "x")
      p.status.should_not contain('{')
      press(p, "y")
      p.status.should_not contain('{')
      press(p, "d")
      p.status.should_not contain('{')
    end
    p = pad(Kind::Vim)
    press(p, "d")
    p.status.should_not contain('{')
    press(p, "j")
    p.status.should_not contain('{')
    # `p` before anything was taken: the first key a vim hand tries on an empty register.
    {Kind::Helix, Kind::Vim}.each do |kind|
      Gori::Tui::Register.clear
      p = pad(kind)
      press(p, "p")
      p.status.should start_with("nothing to paste")
      p.status.should_not contain('{')
    end
  end

  it "drops an armed d when the host takes the keys back" do
    p = pad(Kind::Vim)
    press(p, "d")
    p.disarm
    press(p, "j")
    p.status.should_not contain("cancelled")
    press(p, "d")
    p.armed?.should be_true # a fresh first press, not the second half of the old one
    p.text.should eq(Gori::Tui::KeysetPad::SAMPLE)
  end

  it "names ^F in INS the way it does in READ, as a prompt a real pane opens" do
    p = pad
    press(p, "i")
    p.handle_key(TuiContract.ctrl('f'))
    p.status.should contain("opens in a real pane")
  end

  it "spells each keyset's reference row in real chords, with no token left over" do
    p = pad
    helix = p.reference(Kind::Helix)
    vim = p.reference(Kind::Vim)
    {helix, vim}.each(&.should_not(contain('{')))
    helix.should start_with("x line")
    vim.should start_with("⇧V line")
    vim.should contain("dd delete")
    vim.should contain("u undo")
  end
end
