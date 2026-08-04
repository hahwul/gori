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
private def each_target_view(&)
  rv = RepeaterView.new
  rv.restore(URL, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, true)
  rv.focus_pane(:target)
  rv.target_home
  yield rv, "Repeater"

  fv = FuzzerView.new
  fv.load_request(URL, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, "")
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
