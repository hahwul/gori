require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The TARGET row — the single-line URL (and SNI) field at the top of the Repeater and Fuzzer
# — is a READ pane like any other: a caret, an anchor, a painted band, `LineFieldRead`
# behind all three. It had ⇧←/→ and two holes around them.
#
# ⇧Home / ⇧End. `target_home` / `target_end` ASSIGNED the caret, which never reaches the
# anchor living in `@target_read` — so the two keys that should have grown a selection to the
# edge of the value DROPPED it instead. This is the same defect #583 fixed in
# `TextArea#home`/`#end_of_line`, left standing on the one field that is not a TextArea.
#
# THE POINTER. `handle_drag` / `handle_double_click` listed `:request` and `:response` and
# not `:target`, so the field an operator most often wants to lift a slice out of (the URL)
# could be clicked but never dragged across. A bare press also assigned the caret directly,
# leaving a stale anchor behind: clicking away from a ⇧←/→ selection repainted the band from
# the OLD anchor to the new caret.
#
# Both views carry the same field, so every example runs against both.

private URL = "https://example.com/a/b?q=1"

# A view focused on the target row, caret at column 0, in READ mode (the mode whose band
# `draw_target_row` paints). The two constructors differ; everything after them does not.
private def each_target_view(url : String = URL, &)
  rv = RepeaterView.new
  rv.restore(url, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, true)
  rv.focus_pane(:target)
  rv.target_home
  yield rv, "Repeater"

  fv = FuzzerView.new
  fv.load_request(url, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, "")
  fv.focus_pane(:target)
  fv.target_home
  yield fv, "Fuzzer"
end

# The URL row of the target card: row 1 of the body, value starting at `field_base` —
# rect.x + 2 (the card inset) + the "›" marker + 1. The same inverse the view uses, written
# out here so a geometry drift shows up as a failing example rather than as an off-by-one
# selection nobody notices.
private def url_cell(col : Int32) : {Int32, Int32}
  {4 + col, 1}
end

describe "the TARGET row selection" do
  describe "⇧Home / ⇧End extend instead of dropping the selection" do
    it "⇧End selects from the caret to the end of the value" do
      each_target_view do |v, name|
        v.target_end(true)
        v.pane_selection?.should be_true, "#{name}: ⇧End left no selection"
        v.target_copy_text.should eq(URL), "#{name}: ⇧End selected the wrong span"
      end
    end

    it "⇧Home selects back to column 0" do
      each_target_view do |v, name|
        v.target_end        # park at the far end, unselected
        v.target_home(true) # …and pull the selection back over the whole value
        v.pane_selection?.should be_true, "#{name}: ⇧Home left no selection"
        v.target_copy_text.should eq(URL), "#{name}: ⇧Home selected the wrong span"
      end
    end

    it "a BARE Home/End still collapses the selection" do
      each_target_view do |v, name|
        v.target_end(true)
        v.pane_selection?.should be_true
        v.target_home
        v.pane_selection?.should be_false, "#{name}: a bare Home kept the band"
      end
    end

    it "⇧End GROWS a selection ⇧→ started rather than re-anchoring it" do
      each_target_view do |v, name|
        v.target_read_move(5, selecting: true) # anchor 0, caret 5 → "https"
        v.target_copy_text.should eq(URL[0...5])
        v.target_end(true) # caret to the end; the anchor must stay at 0
        v.target_copy_text.should eq(URL), "#{name}: ⇧End re-anchored mid-extend"
      end
    end
  end

  # INSERT edits move the text under a standing READ anchor; back in READ the band would span
  # what the operator never selected, and `y` would copy it.
  it "drops the READ band on entering INSERT" do
    each_target_view do |v, name|
      v.target_end
      v.target_read_move(-5, selecting: true)
      v.pane_selection?.should be_true
      v.enter_target_insert!
      v.exit_target_insert!
      v.pane_selection?.should be_false, "#{name}: the band survived an INSERT visit"
    end
  end

  describe "the pointer" do
    it "a press places the caret and a drag extends from it" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        px, py = url_cell(8)
        v.target_click_to_cursor(rect, px, py)
        v.pane_selection?.should be_false, "#{name}: a press alone made a selection"
        dx, dy = url_cell(17)
        v.target_drag_to_cursor(rect, dx, dy)
        v.pane_selection?.should be_true, "#{name}: the drag did not extend"
        v.target_copy_text.should eq(URL[8...17]), "#{name}: the drag covered the wrong span"
      end
    end

    # `move_cx(selecting: true)` plants the anchor on the first step, and a drag straight
    # down the row (or a ⇧→ ⇧← pair) leaves it ON the caret: an empty span the painter never
    # draws. `pane_selection?` reported that as a selection, and the unified Copy then took the
    # WHOLE value with no band on screen — under Drag release = `select + copy`, every drag
    # that did not move sideways put the entire URL on the clipboard.
    it "a drag that ends on its own press column leaves no selection, so nothing copies whole" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        px, py = url_cell(8)
        v.target_click_to_cursor(rect, px, py)
        v.target_drag_to_cursor(rect, px, py + 1) # straight down: same column
        v.pane_selection?.should be_false, "#{name}: a collapsed band counted as a selection"
        dx, dy = url_cell(12)
        v.target_drag_to_cursor(rect, dx, dy)
        v.pane_selection?.should be_true, "#{name}: the anchor was lost with the collapse"
        v.target_drag_to_cursor(rect, px, py) # …and back onto the anchor
        v.pane_selection?.should be_false, "#{name}: a band dragged back to nothing stayed live"
      end
    end

    it "a press COLLAPSES a standing selection instead of re-anchoring it" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        v.target_end(true)
        v.pane_selection?.should be_true
        px, py = url_cell(3)
        v.target_click_to_cursor(rect, px, py)
        v.pane_selection?.should be_false, "#{name}: the press left the old anchor standing"
      end
    end

    it "a double-click takes the word the press landed on" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        # column 10 is inside "example" of https://example.com/… — a word that stops at the
        # dots either side, since `.` is punctuation under the shared word rule.
        px, py = url_cell(10)
        v.target_click_to_cursor(rect, px, py)
        v.target_select_word.should be_true, "#{name}: no word taken"
        v.target_copy_text.should eq("example"), "#{name}: wrong word"
      end
    end

    it "a double-click on the value's trailing void takes nothing and keeps the caret" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        px, py = url_cell(URL.size + 6)
        v.target_click_to_cursor(rect, px, py)
        v.target_select_word.should be_false, "#{name}: took a word off the end of the value"
        v.pane_selection?.should be_false
      end
    end

    it "a double-click on a wide glyph's right half selects the word before the slash" do
      prefix = "https://example.com/"
      each_target_view("#{prefix}서울/next") do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        x, y = url_cell(prefix.size + 3)
        v.target_click_to_cursor(rect, x, y)
        v.target_select_word.should be_true, "#{name}: no word taken"
        v.target_copy_text.should eq("서울"), "#{name}: wrong word"
      end
    end

    it "a drag in INSERT mode is inert — that mode paints no band" do
      each_target_view do |v, name|
        rect = Rect.new(0, 0, 120, 20)
        v.enter_target_insert!
        px, py = url_cell(4)
        v.target_click_to_cursor(rect, px, py)
        dx, dy = url_cell(15)
        v.target_drag_to_cursor(rect, dx, dy)
        v.pane_selection?.should be_false, "#{name}: INSERT grew a selection nothing draws"
      end
    end
  end
end

# The row drew its value from column 0 whatever the caret did, so typing past the field's
# width (a long query string) went on blind behind the trailing `…`, caret included. It now
# windows around the caret the way every `input_line` field does, with a leading `…` for the
# scrolled-off start. At 80 columns the card is the top three rows: the value runs from
# column 4 to 78, and the border sits at 79.
private LONG_URL = "https://example.com/" + ("0123456789" * 15) + "XYZEND"

private def target_frame(v) : {MemoryBackend, Screen}
  b = MemoryBackend.new(80, 24)
  s = Screen.new(b)
  v.render(s, Rect.new(0, 0, 80, 24))
  {b, s}
end

private TARGET_CARD = Rect.new(0, 0, 80, 3)

describe "the TARGET row window" do
  it "keeps the caret and the tail of a long value on screen, in READ and INSERT" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      b, s = target_frame(v)
      row = b.row(1)
      row.should contain("XYZEND"), "#{name}: the typed tail was off screen"
      row[4].should eq('…'), "#{name}: no mark for the scrolled-off start"
      cx, cy = s.desired_cursor.not_nil!
      cy.should eq(1)
      (cx < 79).should be_true, "#{name}: the caret left the field"
      row[cx - 6, 6].should eq("XYZEND"), "#{name}: the caret is not after the tail"

      v.enter_target_insert!
      "QQ".each_char { |c| v.target_insert(c) }
      b, s = target_frame(v)
      b.row(1).should contain("XYZENDQQ"), "#{name}: typed text went on blind"
      s.desired_cursor.not_nil![0].should be < 79
    end
  end

  it "keeps both marks off a caret in the middle of a long value" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      v.target_read_move(-100)
      at = LONG_URL.size - 100
      b, s = target_frame(v)
      row = b.row(1)
      row[4].should eq('…'), name
      row[78].should eq('…'), "#{name}: no mark for the hidden tail"
      cx, _ = s.desired_cursor.not_nil!
      (5..77).should contain(cx)
      row[cx].should eq(LONG_URL[at]), "#{name}: the caret cell is not the caret's character"
      row[cx - 1].should eq(LONG_URL[at - 1]), "#{name}: the text left of the caret is off by the window"
    end
  end

  it "puts a click on a scrolled row on the character under the pointer" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      b, _ = target_frame(v)
      col = b.row(1).index("XYZEND").not_nil!
      v.target_click_to_cursor(TARGET_CARD, col, 1)
      v.target_end(true)
      v.target_copy_text.should eq("XYZEND"), "#{name}: the click was not rebased by the window"
    end
  end

  it "reads an unfocused row from its start, and a click there lands by that frame" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      v.focus_pane(name == "Fuzzer" ? :template : :request)
      b, _ = target_frame(v)
      b.row(1)[4, 8].should eq("https://"), "#{name}: an unfocused row kept its window"
      v.focus_pane(:target)
      v.target_click_to_cursor(TARGET_CARD, 4 + 8, 1) # what the unfocused frame showed there
      v.target_end(true)
      v.target_copy_text.should eq(LONG_URL[8..]), name
    end
  end
end

# A READ selection was painted from the field's start to the screen's edge, over the trailing
# `…` and the card's right border, so a selected long URL read as if it ended there. The band
# now stops where the text stops, on either side of the window.
describe "the TARGET row selection band" do
  it "stops short of the trailing mark and the border" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      v.target_home(true) # the whole value, the caret back at its start (an unscrolled row)
      b, _ = target_frame(v)
      b.row(1)[78].should eq('…'), "#{name}: the band painted over the trailing mark"
      b.bg_at(78, 1).should_not eq(Theme.accent_bg), name
      b.row(1)[79].should eq('│'), "#{name}: the band painted over the border"
      b.bg_at(79, 1).should_not eq(Theme.accent_bg), name
      b.bg_at(10, 1).should eq(Theme.accent_bg), "#{name}: no band at all"
    end
  end

  it "covers neither mark on a scrolled window" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end(true) # the whole value, the caret at its end: the window scrolled
      b, _ = target_frame(v)
      b.row(1)[4].should eq('…'), name
      b.bg_at(4, 1).should_not eq(Theme.accent_bg), "#{name}: the band covered the leading mark"
      b.bg_at(5, 1).should eq(Theme.accent_bg), "#{name}: no band over the visible text"

      v.target_end
      v.target_read_move(-100, selecting: true) # anchor at the end, beyond the trailing mark
      b, _ = target_frame(v)
      b.row(1)[78].should eq('…'), name
      b.bg_at(78, 1).should_not eq(Theme.accent_bg), "#{name}: the band covered the trailing mark"
      b.bg_at(79, 1).should_not eq(Theme.accent_bg), name
    end
  end
end

# The window followed the caret alone, so a press on a scrolled row moved the caret, the next
# frame re-windowed around it, and the drag events after it were rebased on text that had
# jumped: the band ran left while the pointer moved right. It now holds while the caret stays
# inside it. A frame is drawn between events, as the TUI does.
describe "the TARGET row drag on a scrolled window" do
  it "selects what the pointer swept" do
    each_target_view(LONG_URL) do |v, name|
      v.target_end
      b, _ = target_frame(v)
      swept = b.row(1)[20, 10]
      v.target_click_to_cursor(TARGET_CARD, 20, 1)
      {25, 30}.each do |x|
        b, _ = target_frame(v)
        b.row(1)[20, 10].should eq(swept), "#{name}: the text moved under the pointer"
        v.target_drag_to_cursor(TARGET_CARD, x, 1)
      end
      v.target_copy_text.should eq(swept), "#{name}: the band took text the pointer never crossed"
    end
  end
end

# A zero-width char is drawn as its six-column `⟨ZWSP⟩` badge, and the window kept one cell
# for the caret: a caret on it at the right edge stamped the badge over the card border.
describe "the TARGET row caret on a wide glyph" do
  it "keeps the caret's glyph inside the card" do
    each_target_view("https://example.com/" + ("x" * 120) + "\u200By") do |v, name|
      v.target_end
      v.target_read_move(-2) # onto the ZWSP
      b, s = target_frame(v)
      b.row(1)[79].should eq('│'), "#{name}: the caret badge ran over the border"
      cx, _ = s.desired_cursor.not_nil!
      (cx + 6 <= 79).should be_true, "#{name}: the badge does not fit where the caret sits"
    end
  end
end
