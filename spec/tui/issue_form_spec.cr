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

  # Pre-seam the shell had NO click arm for this modal, so neither a click-away nor a click
  # on the card did anything. The Overlay base default dismisses on click-away, so this
  # asserts the RAW vocabulary: `:stay`, not merely "the harness still reports open".
  it "ignores clicks entirely, inside the card and outside it" do
    h = OverlayHarness.new(IssueForm.new)
    h.overlay.handle_click(h.area, 40, 12).should eq(:stay) # dead centre, on the card
    h.overlay.handle_click(h.area, 0, 0).should eq(:stay)   # far corner, click-away
    h.click(0, 0).should eq(:open)
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
