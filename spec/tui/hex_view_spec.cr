require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::HexView do
  it "computes the row count (16 bytes per row)" do
    HexView.rows(0).should eq(0)
    HexView.rows(1).should eq(1)
    HexView.rows(16).should eq(1)
    HexView.rows(17).should eq(2)
    HexView.rows(32).should eq(2)
    HexView.rows(33).should eq(3)
  end

  it "renders offset + hex bytes + ascii gutter" do
    backend = MemoryBackend.new(100, 4)
    HexView.render(Screen.new(backend), Rect.new(0, 0, 100, 4), "GET /".to_slice, 0)
    backend.contains?("00000000").should be_true # offset column
    backend.contains?("47 45 54").should be_true # 'G' 'E' 'T' = 0x47 0x45 0x54
    backend.contains?("|GET /|").should be_true  # ascii gutter (printable)
  end

  it "renders non-printable bytes as '.' in the ascii gutter" do
    backend = MemoryBackend.new(100, 4)
    HexView.render(Screen.new(backend), Rect.new(0, 0, 100, 4), Bytes[0x00, 0x41, 0x1f, 0x7f], 0)
    backend.contains?("00 41 1f 7f").should be_true
    backend.contains?("|.A..|").should be_true # 0x00/0x1f/0x7f → '.', 0x41 → 'A'
  end

  it "shows an empty-body placeholder" do
    backend = MemoryBackend.new(40, 2)
    HexView.render(Screen.new(backend), Rect.new(0, 0, 40, 2), Bytes.empty, 0)
    backend.contains?("(no body)").should be_true
  end

  it "windows: only renders rows from the scroll offset" do
    data = Bytes.new(64) { |i| i.to_u8 } # 4 rows of 16
    backend = MemoryBackend.new(100, 2)
    HexView.render(Screen.new(backend), Rect.new(0, 0, 100, 2), data, 2) # start at row 2 (offset 0x20)
    backend.contains?("00000020").should be_true                         # row 2
    backend.contains?("00000000").should be_false                        # row 0 scrolled off
  end
end
