require "../support/tui_contract"

include Gori::Tui

# WHAT A PRESS ARMS — the guard that decides whether the motion after a press extends a
# selection, and over whose text.
#
# It grew teeth with #1124. Until then `drag_to_cursor` refused every gesture its pane was not
# already in INSERT for, and that refusal was quietly standing in for a press-target test:
# panes answered `supports_drag?` from the focused pane, or from a bare `true`. Once a drag
# works in READ too, every press that is NOT on the text has to be told apart — or a press on
# a chip, a border, or a row the editor was never drawn into opens a band the operator did not
# point at, and `settings:mouse` drag-copy writes it to the clipboard and toasts that it did.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, so the shell half is pinned by
# reading the method bodies — the idiom spec/tui/factory_reset_apply_spec.cr uses. Comments are
# stripped first: a comment explaining a rule contains the tokens the rule looks for.
private def mouse_body(signature : String) : String
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "mouse.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
  body = src[/^\s*#{Regex.escape(signature)}.*?^  end$/m]?
  body.should_not be_nil
  body.not_nil!
end

describe "Runner — the press the drag guard is asked about" do
  # `drag_press_target?` re-derives `dispatch_click`'s precedence, and the two had drifted: the
  # SUB-TAB STRIP tier consumes any press on the chip row ("even between chips") and moves focus
  # only when the press lands ON a chip — so a press on the empty half of that row never reached
  # the tab while `@focus` stayed `:body`. Every controller answers `supports_drag?` from what
  # its own `handle_click` recorded, so the answer was the PREVIOUS press's: a click in a note,
  # one on the strip's empty half, then a twitch, extended the note's band. The companion and
  # top-bar tiers have the same shape.
  it "is the one that actually reached the tab body" do
    dispatch = mouse_body("private def dispatch_click(layout : Layout, mx : Int32, my : Int32) : Nil")
    dispatch.should contain("@click_reached_body = false")
    # Raised NEXT TO the call it stands for, so a tier inserted above it cannot start reporting
    # a body press it swallowed.
    dispatch.index("@click_reached_body = true").not_nil!
      .should be < dispatch.index("click_body(layout.body, mx, my)").not_nil!

    guard = mouse_body("private def drag_press_target?(layout : Layout, mx : Int32, my : Int32) : Bool")
    guard.should contain("return false unless @click_reached_body")
    # …and only on the TAB tier: an overlay hit-tests its own card and answers above this.
    guard.index("ov.supports_drag?").not_nil!
      .should be < guard.index("@click_reached_body").not_nil!
  end
end

# A comfortable terminal, so the DESCRIPTION card has its full geometry.
private AREA = TuiContract::AREA

private def with_project(&)
  TuiContract.with_session("press-target") do |session|
    host = TuiContract::Host.new(session)
    ctl = ProjectController.new(host)
    host.tab = :project
    ctl.on_enter
    yield ctl
  end
end

describe "ProjectController — the DESCRIPTION card's border" do
  # `pane_at` answers `:desc` for the whole card, border rows included, and neither
  # `desc_click_to_cursor` nor `desc_select_word` hit-tests: both clamp through
  # `card.inset(1, 1)`. So the hairline used to place the caret on the last visible line and a
  # pair of presses used to take a word from it — which forced INSERT before #1124 and paints a
  # `y`-copyable READ band after it, i.e. a selection the operator never pointed at, now
  # observable. `IssuesController` has carried this test on both halves all along.
  it "takes the focus, but neither the caret nor a word" do
    with_project do |ctl|
      ctl.view.focus_pane(:desc)
      ctl.view.replace_desc("alpha beta\ngamma delta\nepsilon zeta")
      TuiContract.render(ctl)
      card = ctl.view.desc_card_rect(AREA).not_nil!

      ctl.handle_click(AREA, card.x + 4, card.bottom - 1).should be_true
      ctl.view.pane.should eq(:desc) # the press still lands the focus
      ctl.supports_drag?.should be_false
      ctl.handle_double_click(AREA, card.x + 4, card.bottom - 1).should be_false
      ctl.view.desc_selection?.should be_false
      ctl.view.desc_insert_mode?.should be_false
    end
  end

  # …and the text of the same card still does both, so the guard above narrowed nothing else.
  it "still aims the caret from the card's text" do
    with_project do |ctl|
      ctl.view.focus_pane(:desc)
      ctl.view.replace_desc("alpha beta\ngamma delta\nepsilon zeta")
      TuiContract.render(ctl)
      inner = ctl.view.desc_card_rect(AREA).not_nil!.inset(1, 1)

      ctl.handle_click(AREA, inner.x + 2, inner.y + 1).should be_true
      ctl.supports_drag?.should be_true
      ctl.view.desc_copy_text.should eq("gamma delta")
    end
  end

  # `focus_pane` only assigns `@pane` — it does not close an open HOST OVERRIDES / ENV row — so
  # a flat `@press_on_desc || ov_adding? || env_row_open?` armed a drag on the DESCRIPTION card
  # through a disjunct about a different pane, and `handle_drag` (which dispatches on `pane`)
  # then ran its `:desc` arm on it.
  it "arms no drag through an ENV row left open on another pane" do
    with_project do |ctl|
      ctl.view.focus_pane(:env)
      ctl.view.env_add_start
      ctl.view.env_adding?.should be_true

      ctl.view.focus_pane(:desc) # the half of a chip click that does not close the row
      TuiContract.render(ctl)
      card = ctl.view.desc_card_rect(AREA).not_nil!
      ctl.handle_click(AREA, card.x + 4, card.y).should be_true # the card's border row
      ctl.supports_drag?.should be_false
    end
  end
end
