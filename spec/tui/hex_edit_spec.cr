require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def hx(s : String)
  HexEdit.new(s.to_slice)
end

describe Gori::Tui::HexEdit do
  it "overtypes a nibble (hi then lo) and advances the cursor" do
    h = hx("GE")    # 0x47 0x45
    h.set_nibble(4) # byte0 hi := 4 → 0x47 (unchanged)
    h.set_nibble(8) # byte0 lo := 8 → 0x48 ('H')
    h.nib.should eq(2)
    String.new(h.to_bytes).should eq("HE")
  end

  it "grows from an empty buffer by typing" do
    h = hx("")
    h.len.should eq(0)
    h.set_nibble(4) # appends a byte, sets hi
    h.set_nibble(1) # sets lo → 0x41 'A'
    String.new(h.to_bytes).should eq("A")
  end

  it "appends a byte when typing at the end slot" do
    h = hx("A")                      # 0x41, nib 0
    h.set_nibble(4); h.set_nibble(1) # overtype byte0 back to 'A', cursor → append slot (nib 2)
    h.nib.should eq(2)
    h.set_nibble(4); h.set_nibble(2) # new byte 0x42 'B'
    String.new(h.to_bytes).should eq("AB")
  end

  it "inserts a 0x00 byte at the cursor" do
    h = hx("AB")
    h.move_right; h.move_right # cursor on byte 1 ('B')
    h.insert_byte              # 0x00 before 'B'
    h.to_bytes.should eq(Bytes[0x41, 0x00, 0x42])
    h.nib.should eq(2) # cursor on the new byte's hi nibble
  end

  it "backspaces the byte before the cursor (no-op at the start)" do
    h = hx("AB")
    h.backspace.should be_false # nib 0 → nothing before
    h.move_right; h.move_right  # onto byte 1
    h.backspace.should be_true  # deletes byte 0 ('A')
    String.new(h.to_bytes).should eq("B")
  end

  it "deletes the byte under the cursor (no-op past the end)" do
    h = hx("AB")
    h.delete.should be_true # removes 'A'
    String.new(h.to_bytes).should eq("B")
    h.move_right; h.move_right # past end
    h.delete.should be_false
  end

  it "navigates rows and reports at_top?" do
    h = hx("x" * 40) # 3 rows (16/16/8)
    h.at_top?.should be_true
    h.move_rows(1) # down one 16-byte row
    h.at_top?.should be_false
    h.move_rows(-5) # clamps to top
    h.at_top?.should be_true
  end

  it "round-trips arbitrary bytes including 0x00 / 0xff" do
    h = HexEdit.new(Bytes[0x00, 0xff, 0x0a, 0x80])
    h.to_bytes.should eq(Bytes[0x00, 0xff, 0x0a, 0x80])
  end

  it "renders offset + ascii without crashing" do
    backend = MemoryBackend.new(100, 4)
    HexEdit.new("GET /".to_slice).render(Screen.new(backend), Rect.new(0, 0, 100, 4), true, 0)
    backend.contains?("00000000").should be_true
    backend.contains?("GET /").should be_true # ascii gutter
  end

  it "tracks mutated? (a pure peek stays clean, an edit flips it)" do
    h = hx("GET")
    h.mutated?.should be_false
    h.move_right # navigation is not a mutation
    h.mutated?.should be_false
    h.set_nibble(4)
    h.mutated?.should be_true
  end

  it "clips drawing to the rect width (no bleed into an adjacent pane)" do
    backend = MemoryBackend.new(120, 2)
    # a full 16-byte row would span ~78 cols; constrain to a 40-wide pane at x=0
    HexEdit.new(Bytes.new(16) { |i| 0x41_u8 + i.to_u8 }).render(Screen.new(backend), Rect.new(0, 0, 40, 2), true, 0)
    backend.row(0)[40, 80].strip.should eq("") # nothing drawn past the pane edge
  end

  it "draws both ascii bars on an empty buffer (no lone |)" do
    backend = MemoryBackend.new(100, 2)
    HexEdit.new(Bytes.empty).render(Screen.new(backend), Rect.new(0, 0, 100, 2), true, 0)
    backend.contains?("||").should be_true # opening + closing bar adjacent
  end
end
