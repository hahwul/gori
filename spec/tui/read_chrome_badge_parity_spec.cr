require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Four defects found by sweeping the tree for the shapes the Repeater's WebSocket panes had:
# a second derivation of something the widget already knows, and a draw that disagrees with the
# hit-test it is drawn for. Every one of them is a place where the screen and the clipboard, or
# the screen and the click, told the operator different things.
#
#   A. FuzzerView drew the `§N` marker-count badge 4 cells INSIDE the 7-cell NOR/INS chip, so the
#      TEMPLATE border read "↵: §2" — the mode chip destroyed and the count ambiguous.
#   B. FuzzerView#template_home/end and JwtSession's Home/End moved the EDITOR caret without
#      adopting it into the READ cursor. Symptoms differ because the painters differ: the Fuzzer
#      (which `sync_from`s every frame) kept a phantom band whose ends had crossed, so `y` copied
#      ""; JWT (which paints purely from its read cursor) moved a caret nobody could see.
#   C. Every NOR/INS chip was drawn from `focused && insert?` while its hit-test and its click
#      handler read `insert?` alone. A pane that retained INS while focus moved away drew the
#      7-cell " ↵:NOR " over a 5-cell " INS " hit rect — two dead cells — and clicking a chip
#      that said "↵:NOR" turned insert OFF.
#   D. The READ band and block caret measured the RAW line in the two panes that CONCEAL text
#      (`§value¦chain§`), so both landed N columns right of what they addressed, and the band —
#      which re-draws its own text — put the hidden `¦chain` back on screen. Copy was correct
#      throughout, so the band highlighted different bytes than `y` put on the clipboard.
describe "READ-mode chrome + border badge parity" do
  # The rows a 120×N render puts things on: the TARGET band is 3 rows, so the request/template
  # card's top border is row 3 and its first content row is row 4.
  border_y = 3
  content_y = 4

  describe "A · fuzzer §N badge" do
    it "chains the marker count clear of the NOR/INS chip" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§&y=§2§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:template)
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), Rect.new(0, 0, 120, 30))
      row = b.row(border_y)

      # Both are legible and neither is inside the other.
      row.should contain("↵:NOR")
      row.should contain("§2")
      row.index("§2").not_nil!.should be < row.index("↵:NOR").not_nil! # count chains LEFT
      row.should_not contain("↵: §")                                   # the overlap's signature
    end

    it "keeps the mode chip clickable with the count beside it" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:template)
      rect = Rect.new(0, 0, 120, 30)
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), rect)
      col = b.row(border_y).index("↵:NOR").not_nil!
      view.template_chrome_hit(rect, col + 1, border_y).should eq(:mode)
    end
  end

  describe "B · READ-mode Home/End adopt the read cursor" do
    it "extends on ⇧End and collapses on a plain Home (fuzzer template)" do
      view = FuzzerView.new
      view.load_request("https://h", "GET /abc HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:template)
      view.render(Screen.new(MemoryBackend.new(120, 30)), Rect.new(0, 0, 120, 30))
      view.template_insert?.should be_false

      view.template_end(true)
      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("GET /abc HTTP/1.1")

      # A plain Home must COLLAPSE. Left un-adopted, the anchor stayed put while the caret went
      # to column 0 — the band's two ends crossed and `y` copied nothing at all.
      view.pane_select_line
      view.template_home(false)
      view.pane_selection?.should be_false
      view.pane_copy_text.should eq("GET /abc HTTP/1.1") # the caret line, not ""
    end

    it "moves the READ caret, not just the editor's (jwt input)" do
      s = JwtSession.new("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhIn0.sig", nil)
      s.input_mode.should eq(InputMode::Read)
      s.input_read.cursor.cx.should eq(0)

      s.input_end
      # JwtView#paint_read_chrome draws from `input_read` alone, so this is the number that
      # decides where the block caret lands.
      s.input_read.cursor.cx.should eq(s.input.lines_snapshot[0].size)
      s.input_read.selection?.should be_false

      s.input_home(true) # ⇧Home extends back to column 0
      s.input_read.selection?.should be_true
      s.input_read.cursor.cx.should eq(0)

      s.input_home(false) # …and a plain Home collapses it
      s.input_read.selection?.should be_false
    end

    it "leaves INSERT mode's own anchor alone (jwt input)" do
      s = JwtSession.new("abcdef", nil)
      s.input_mode = InputMode::Insert
      s.input_end(true)
      s.input.selection?.should be_true       # the editor owns it in INS …
      s.input_read.selection?.should be_false # … and the read cursor stays out of it
    end
  end

  describe "C · the NOR/INS chip states the pane's real mode" do
    # `Frame.mode_badge`'s two labels are different widths, and `chrome_hit` is called from a
    # click handler with no idea which pane had focus when the frame was drawn.
    it "draws INS on an unfocused Repeater pane that retained it, and hit-tests the same cells" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      view.focus_pane(:request)
      view.enter_request_insert!
      view.focus_pane(:response) # focus leaves; nothing exits insert on a focus change
      view.request_insert?.should be_true

      rect = Rect.new(0, 0, 120, 24)
      b = MemoryBackend.new(120, 24)
      view.render(Screen.new(b), rect)
      row = b.row(border_y)
      row.should contain("INS")
      row.should_not contain("↵:NOR") # the label no longer lies about the mode

      # Every cell of the drawn chip hit-tests as :mode, and the run is exactly " INS " wide.
      hits = (0...120).select { |x| view.chrome_hit(rect, x, border_y) == :mode }
      hits.should_not be_empty
      (hits.last - hits.first + 1).should eq(Frame.mode_badge_label(true).size)
      ins_at = row.index("INS").not_nil!
      hits.should contain(ins_at)
      hits.should contain(ins_at + 2)
    end

    it "does the same on the Repeater TARGET card" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      view.focus_pane(:target)
      view.enter_target_insert!
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 120, 24)
      b = MemoryBackend.new(120, 24)
      view.render(Screen.new(b), rect)
      b.row(0).should contain("INS")
      col = b.row(0).index("INS").not_nil!
      view.chrome_hit(rect, col, 0).should eq(:target_mode)
    end

    it "does the same on the Fuzzer TARGET card" do
      view = FuzzerView.new
      view.load_request("https://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:target)
      view.enter_target_insert!
      view.focus_pane(:template)
      rect = Rect.new(0, 0, 120, 30)
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), rect)
      b.row(0).should contain("INS")
      col = b.row(0).index("INS").not_nil!
      view.target_chrome_hit(rect, col, 0).should eq(:mode)
    end

    # Focus is still on screen — it moved to the border, where it always was.
    it "still dims the border of the unfocused pane" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, true)
      view.focus_pane(:request)
      view.enter_request_insert!
      focused = MemoryBackend.new(120, 24)
      view.render(Screen.new(focused), Rect.new(0, 0, 120, 24))
      lit = focused.fg_grid[border_y][1]

      view.focus_pane(:response)
      dim = MemoryBackend.new(120, 24)
      view.render(Screen.new(dim), Rect.new(0, 0, 120, 24))
      dim.fg_grid[border_y][1].should_not eq(lit)
    end
  end

  describe "D · READ chrome over a concealed ¦chain" do
    # `§v¦b64§` renders as `§v§` — the chain is concealed in the buffer, occupying no cells. A
    # caret addressing a byte to its RIGHT therefore belongs at the DRAWN column, not the raw one.
    marked = "GET /?a=§v¦b64§&z=TAIL HTTP/1.1\r\nHost: h\r\n\r\n"

    it "puts the Repeater's READ caret on the glyph it addresses" do
      view = RepeaterView.new
      view.restore("https://h.test", marked, false, true)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 120, 24)
      view.render(Screen.new(MemoryBackend.new(120, 24)), rect)

      view.request_text.lines.first.index("TAIL").not_nil!.times { view.request_read_move(0, 1) }
      b = MemoryBackend.new(120, 24)
      view.render(Screen.new(b), rect)

      caret = (0...120).find { |x| b.bg_grid[content_y][x] == Theme.accent_bg }
      caret.should eq(b.row(content_y).index("TAIL")) # not 4 columns right of it
    end

    it "keeps the Repeater's READ band from unconcealing the chain" do
      view = RepeaterView.new
      view.restore("https://h.test", marked, false, true)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 120, 24)
      view.render(Screen.new(MemoryBackend.new(120, 24)), rect)
      view.pane_select_line

      b = MemoryBackend.new(120, 24)
      view.render(Screen.new(b), rect)
      b.row(content_y).should contain("§v§")      # still concealed under the band …
      b.row(content_y).should_not contain("¦b64") # … the band does not put it back
      view.pane_copy_text.should contain("¦b64")  # while the COPY keeps the real bytes
    end

    it "puts the Fuzzer's READ caret on the glyph it addresses" do
      view = FuzzerView.new
      view.load_request("https://h", marked, false, "")
      view.focus_pane(:template)
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect)

      view.template_text.lines.first.index("TAIL").not_nil!.times { view.template_read_move(0, 1) }
      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), rect)

      caret = (0...120).find { |x| b.bg_grid[content_y][x] == Theme.accent_bg }
      caret.should eq(b.row(content_y).index("TAIL"))
    end

    it "keeps the Fuzzer's READ band from unconcealing the chain" do
      view = FuzzerView.new
      view.load_request("https://h", marked, false, "")
      view.focus_pane(:template)
      rect = Rect.new(0, 0, 120, 30)
      view.render(Screen.new(MemoryBackend.new(120, 30)), rect)
      view.pane_select_line

      b = MemoryBackend.new(120, 30)
      view.render(Screen.new(b), rect)
      b.row(content_y).should contain("§v§")
      b.row(content_y).should_not contain("¦b64")
      view.pane_copy_text.should contain("¦b64")
    end

    # A marker-free buffer must be byte-for-byte what it always drew: `conceal_of` returns nil
    # there, so the band and caret take the same path they took before this change.
    it "is unchanged on a buffer with nothing concealed" do
      view = RepeaterView.new
      view.restore("https://h.test", "GET /?a=v&z=TAIL HTTP/1.1\r\nHost: h\r\n\r\n", false, true)
      view.focus_pane(:request)
      rect = Rect.new(0, 0, 120, 24)
      view.render(Screen.new(MemoryBackend.new(120, 24)), rect)
      view.request_text.lines.first.index("TAIL").not_nil!.times { view.request_read_move(0, 1) }
      b = MemoryBackend.new(120, 24)
      view.render(Screen.new(b), rect)
      caret = (0...120).find { |x| b.bg_grid[content_y][x] == Theme.accent_bg }
      caret.should eq(b.row(content_y).index("TAIL"))
    end
  end
end
