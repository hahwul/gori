require "../support/tui_contract"

include Gori::Tui

# The DESCRIPTION card under the pointer (#1124).
#
# A click AIMS the caret; it does not arm the editor. `desc_click_to_cursor` used to call
# `enter_desc_insert!` before placing the caret, so the gesture an operator uses to FOCUS a
# card also put it in INSERT — and the next bare letter was typed rather than run, which is
# how a `y` meant as copy became a `y` in the project's description, over whatever was
# selected. INS is entered the way the keyboard enters it (`i` / ↵) or by clicking the
# NOR/INS chip the card draws on its own border.
#
# Removing that also retired the `desc_insert_mode?` refusal in `desc_drag_to_cursor`, which
# had been doing double duty as a press-target guard: `supports_drag?` answered the bare
# `pane == :desc`, true even for a press on the sub-tab chip that SELECTED the pane or on the
# mode badge. A drag from either would otherwise open a band over cells outside the text, and
# `settings:mouse` drag-copy would put it on the clipboard.
private RECT = TuiContract::AREA

private def with_desc(&)
  TuiContract.with_session("desc-pointer") do |session|
    host = TuiContract::Host.new(session)
    ctl = ProjectController.new(host)
    host.tab = :project
    ctl.on_enter
    ctl.view.focus_pane(:desc)
    ctl.view.replace_desc("alpha beta\ngamma delta\nepsilon zeta")
    TuiContract.render(ctl)
    yield ctl
  end
end

# The card's interior, taken from the view's own geometry so the spec cannot drift from it.
private def desc_inner(ctl : ProjectController) : Rect
  ctl.view.desc_card_rect(RECT).not_nil!.inset(1, 1)
end

# The NOR/INS badge's own cell, inverted at the same numbers `ProjectController#handle_click`
# hit-tests it with.
private def mode_chip(ctl : ProjectController) : {Int32, Int32}
  card = ctl.view.desc_card_rect(RECT).not_nil!
  x = (card.x...card.right).find do |cx|
    Frame.mode_badge_hit(cx, card.y, card.y, card.right - 1, card.x + 2, ctl.view.desc_insert_mode?)
  end
  {x.not_nil!, card.y}
end

# The "DESCRIPTION" chip on the sub-tab strip above the card, found through the view's hit-test.
private def desc_strip_chip(ctl : ProjectController) : {Int32, Int32}
  RECT.h.times do |y|
    RECT.w.times do |x|
      return {x, y} if ctl.view.strip_chip_at(RECT, x, y) == :desc
    end
  end
  raise "the DESCRIPTION chip is not on screen"
end

describe "the Project DESCRIPTION under the pointer" do
  it "places the caret without arming the editor" do
    with_desc do |ctl|
      inner = desc_inner(ctl)
      ctl.handle_click(RECT, inner.x + 2, inner.y + 1).should be_true
      ctl.view.desc_insert_mode?.should be_false
      ctl.view.desc_copy_text.should eq("gamma delta") # READ's `y` with no band: the caret LINE
    end
  end

  it "takes the word under a double-click in READ, where `y` can reach it" do
    with_desc do |ctl|
      inner = desc_inner(ctl)
      ctl.handle_click(RECT, inner.x + 2, inner.y + 1).should be_true
      ctl.handle_double_click(RECT, inner.x + 2, inner.y + 1).should be_true
      ctl.view.desc_insert_mode?.should be_false
      ctl.view.desc_selection?.should be_true
      ctl.view.desc_copy_text.should eq("gamma")
    end
  end

  it "drags a READ band from the press" do
    with_desc do |ctl|
      inner = desc_inner(ctl)
      ctl.handle_click(RECT, inner.x, inner.y)
      ctl.supports_drag?.should be_true
      ctl.handle_drag(RECT, inner.x + 5, inner.y)
      ctl.view.desc_insert_mode?.should be_false
      ctl.view.desc_copy_text.should eq("alpha")
    end
  end

  it "keeps driving the editor's own caret once INS is on" do
    with_desc do |ctl|
      inner = desc_inner(ctl)
      ctl.view.enter_desc_insert!
      ctl.handle_click(RECT, inner.x + 2, inner.y + 2).should be_true
      ctl.view.desc_insert_mode?.should be_true
      ctl.handle_double_click(RECT, inner.x + 2, inner.y + 2).should be_true
      ctl.view.desc_copy_text.should eq("epsilon")
    end
  end

  it "arms no drag from the NOR/INS chip, which is a button and not text" do
    with_desc do |ctl|
      x, y = mode_chip(ctl)
      ctl.handle_click(RECT, x, y).should be_true
      ctl.view.desc_insert_mode?.should be_true # the chip did toggle
      ctl.supports_drag?.should be_false
    end
  end

  it "arms no drag from the sub-tab chip that selects the pane" do
    with_desc do |ctl|
      ctl.view.focus_pane(:scope) # arrive at DESCRIPTION the way the pointer does
      TuiContract.render(ctl)
      x, y = desc_strip_chip(ctl)
      ctl.handle_click(RECT, x, y).should be_true
      ctl.view.pane.should eq(:desc)
      ctl.supports_drag?.should be_false
    end
  end
end
