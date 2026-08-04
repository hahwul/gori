require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

describe Gori::Tui::IssueForm do
  it "cycles severity (tab) and carries an edit id for re-titling" do
    form = IssueForm.new("GET /x", "acme.test", 7_i64)
    form.severity.should eq(Gori::Store::Severity::Medium) # default
    form.severity_cycle(1)
    form.severity.should eq(Gori::Store::Severity::High)
    form.severity_cycle(-2)
    form.severity.should eq(Gori::Store::Severity::Low)
    form.edit_id.should be_nil

    edit = IssueForm.new("old", nil, nil, Gori::Store::Severity::Critical, edit_id: 42_i64)
    edit.edit_id.should eq(42_i64)
    edit.severity.should eq(Gori::Store::Severity::Critical)
  end

  it "supplies the chrome the shell's collapsed title/hint ladders read off it" do
    # The badge is the constant "ISSUE" for BOTH headings — pin it against `heading`, which
    # is what a naive `getter title` would have leaked into the top bar.
    h = OverlayHarness.new(IssueForm.new(heading: "EDIT ISSUE"))
    h.assert_chrome(OverlayKind::IssueNew, "ISSUE")
    # Only a confirm raised from inside another modal carries a restore. A form that grew
    # one would re-open something behind it after a plain dismiss.
    h.overlay.on_close.should be_nil
    h.rendered?("EDIT ISSUE").should be_true
  end

  it "types into the title, moves the caret with ←/→, and inserts at it" do
    h = OverlayHarness.new(IssueForm.new)
    form = h.overlay.as(IssueForm)
    h.type("abc")
    form.issue_title.should eq("abc")
    h.press(Termisu::Input::Key::Left)
    h.press(Termisu::Input::Key::Left)
    h.type("X") # caret sits between 'a' and 'b'
    form.issue_title.should eq("aXbc")
    h.press(Termisu::Input::Key::Backspace)
    form.issue_title.should eq("abc")
  end

  # Guarded by `!ev.ctrl? && !ev.alt?`: a chord is a command, not text, and without the
  # guard every unhandled Ctrl/Alt combination would type its letter into the title.
  it "ignores printables carried on a ctrl or alt chord" do
    h = OverlayHarness.new(IssueForm.new("abc"))
    h.press(Termisu::Input::Key::LowerX, 'x', ctrl: true).should eq(:open)
    h.press(Termisu::Input::Key::LowerX, 'x', alt: true).should eq(:open)
    h.overlay.as(IssueForm).issue_title.should eq("abc")
  end

  # A plain letter key with no Unicode char attached still types — Termisu's
  # `Event::Key#char` resolves it from the key itself. Pinned because it is the ONLY
  # reason dropping the handler's redundant `|| key.to_char` is safe.
  it "types a key that arrives with no char attached" do
    h = OverlayHarness.new(IssueForm.new)
    h.press(Termisu::Input::Key::LowerZ) # no char argument
    h.overlay.as(IssueForm).issue_title.should eq("z")
  end

  # `title` is the shell's badge; `issue_title` is what the user typed. They are one
  # identifier apart at the call site (Runner#create_issue_from_form reads issue_title) and
  # `form.title` compiles cleanly there, which would name every created issue "ISSUE".
  it "keeps the badge and the typed title as separate readers" do
    form = IssueForm.new("a real finding")
    form.issue_title.should eq("a real finding")
    form.title.should eq("ISSUE")
  end

  it "cycles severity on tab / shift-tab without touching the title" do
    h = OverlayHarness.new(IssueForm.new("keep"))
    form = h.overlay.as(IssueForm)
    h.press(Termisu::Input::Key::Tab)
    form.severity.should eq(Gori::Store::Severity::High)
    h.press(Termisu::Input::Key::BackTab)
    form.severity.should eq(Gori::Store::Severity::Medium)
    form.issue_title.should eq("keep")
  end

  it "commits on ↵ and cancels on esc" do
    h = OverlayHarness.new(IssueForm.new)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)

    esc = OverlayHarness.new(IssueForm.new)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)
  end

  it "stays open when the injected commit rejects" do
    h = OverlayHarness.new(IssueForm.new, commit: false)
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1)
  end

  it "routes IME preedit and clears it once a character commits" do
    h = OverlayHarness.new(IssueForm.new)
    h.preedit("ㅎ")
    h.rendered?("ㅎ").should be_true
    h.type("x")
    h.render.contains?("ㅎ").should be_false
  end

  # This modal used to answer `:stay` to EVERY click, inside the card and out — the one
  # overlay in the tree a click-away could not dismiss, while the `Overlay` base default and
  # `PickerOverlay` give that to all thirty-odd others. Assert the RAW vocabulary, not merely
  # "the harness reports closed", so the outcome is pinned as a dismiss and not a commit.
  it "dismisses on a click outside the card, like every other modal" do
    h = OverlayHarness.new(IssueForm.new)
    h.overlay.handle_click(h.area, 0, 0).should eq(:cancel)
    h.click(0, 0).should eq(:closed)
    h.commits.should eq(0) # a click-away is a cancel, never a create
  end

  it "swallows a click on the card's inert rows rather than leaking it underneath" do
    h = OverlayHarness.new(IssueForm.new)
    box = h.box.not_nil!
    h.overlay.handle_click(h.area, box.x + 2, box.y + 2).should eq(:stay) # blank row under the title
    h.click_in_box(2, 2).should eq(:open)
  end

  # The card draws `title › <text>` on its second row and nothing inverted that column, so
  # the caret could only be moved with ←/→ from wherever it happened to sit.
  it "places the title caret at a click on the title row" do
    h = OverlayHarness.new(IssueForm.new("abcdef"))
    form = h.overlay.as(IssueForm)
    # `title › ` is 8 columns past the card's 2-column inset, so +10 is the first title cell;
    # +13 lands on 'd' — the click must put the caret BEFORE it, not at the end of the string.
    h.click_in_box(13, IssueForm::TITLE_ROW).should eq(:open)
    h.type("X")
    form.issue_title.should eq("abcXdef")
  end

  it "clamps a click past the end of the title to the end of the text" do
    h = OverlayHarness.new(IssueForm.new("ab"))
    h.click_in_box(40, IssueForm::TITLE_ROW)
    h.type("!")
    h.overlay.as(IssueForm).issue_title.should eq("ab!")
  end

  # The severity row draws `severity ‹ MEDIUM ›  (tab to change)`. The chevrons and the hint
  # both promise a step; before this the row was drawn and dead.
  it "steps severity from the row's own chevrons" do
    h = OverlayHarness.new(IssueForm.new)
    form = h.overlay.as(IssueForm)
    h.click_in_box(2 + IssueForm::SEV_PREFIX.index('‹').not_nil!, IssueForm::SEV_ROW) # the ‹ cell
    form.severity.should eq(Gori::Store::Severity::Low)
    h.click_in_box(2 + IssueForm::SEV_PREFIX.size + form.severity.label.size + 1, IssueForm::SEV_ROW) # the › cell
    form.severity.should eq(Gori::Store::Severity::Medium)
  end

  it "treats a click on the severity label as the forward step its hint advertises" do
    h = OverlayHarness.new(IssueForm.new)
    h.click_in_box(2 + IssueForm::SEV_PREFIX.size + 1, IssueForm::SEV_ROW)
    h.overlay.as(IssueForm).severity.should eq(Gori::Store::Severity::High)
  end

  # The interactive span ends at the closing `›`. Past it the row holds a hint and then blank
  # cells; a dead cell that silently changes the severity of the issue about to be filed is the
  # same divergence as an affordance that does nothing, pointed the other way.
  it "leaves severity alone for a click past the row's drawn span" do
    h = OverlayHarness.new(IssueForm.new)
    box = h.box.not_nil!
    h.click(box.right - 2, box.y + IssueForm::SEV_ROW).should eq(:open)
    h.overlay.as(IssueForm).severity.should eq(Gori::Store::Severity::Medium) # untouched
  end

  # …and the cells LEFT of the `‹`, which draw the word "severity".
  it "leaves severity alone for a click on the row's label text" do
    h = OverlayHarness.new(IssueForm.new)
    h.click_in_box(2, IssueForm::SEV_ROW)
    h.overlay.as(IssueForm).severity.should eq(Gori::Store::Severity::Medium)
  end

  # `overlay_box` is now the geometry `render` itself draws from, so a card with no room to
  # draw and the base "any click dismisses" path agree.
  it "reports no box — and dismisses any click — when the area cannot hold the card" do
    tiny = OverlayHarness.new(IssueForm.new, area: Gori::Tui::Rect.new(0, 0, 80, 4))
    tiny.box.should be_nil
    tiny.rendered?("NEW ISSUE").should be_false
    tiny.overlay.handle_click(tiny.area, 1, 1).should eq(:cancel)
  end

  # The base default routes a wheel notch to `move`, which HERE walks the title caret —
  # a scroll must not silently re-aim where the next character lands.
  it "ignores the scroll wheel rather than walking the title caret" do
    h = OverlayHarness.new(IssueForm.new("abcdef"))
    form = h.overlay.as(IssueForm)
    h.wheel(-3)
    h.type("!")
    form.issue_title.should eq("abcdef!") # caret still at the end, not dragged left
  end

  it "carries the pending workbench link ref so dropping the form drops the link" do
    ref = {Gori::Store::LinkRefKind::Repeater, 9_i64}
    IssueForm.new(link_ref: ref).link_ref.should eq(ref)
    IssueForm.new.link_ref.should be_nil # a standalone create never inherits one
  end
end
