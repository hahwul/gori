require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def sample_issue(id : Int64, title : String, host : String = "app.test") : Gori::Store::Issue
  Gori::Store::Issue.new(id, 0_i64, 0_i64, title, Gori::Store::Severity::High, host, nil, "")
end

private def sample_picker : IssuePicker
  IssuePicker.new([
    sample_issue(1_i64, "Reflected XSS"),
    sample_issue(2_i64, "SQL injection"),
    sample_issue(3_i64, "Missing header"),
  ])
end

describe Gori::Tui::IssuePicker do
  it "pins create at index 0 and defaults selection to the first real issue" do
    p = sample_picker
    p.selected.should eq(1)
    p.selected_create?.should be_false
    p.selected_issue.try(&.id).should eq(1_i64)
    p.entry_count.should eq(4) # create + 3 issues
  end

  it "selects create when the project has no issues" do
    p = IssuePicker.new([] of Gori::Store::Issue)
    p.selected.should eq(0)
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.entry_count.should eq(1)
  end

  it "moves onto the create row and back onto issues" do
    p = sample_picker
    p.move(-1)
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.move(1)
    p.selected_issue.try(&.title).should eq("Reflected XSS")
  end

  it "keeps create pinned while filtering and lands on the first match" do
    p = sample_picker
    "sql".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_false
    p.selected_issue.try(&.title).should eq("SQL injection")
    p.move(-1)
    p.selected_create?.should be_true
  end

  it "falls back to create when the filter matches nothing" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_true
    p.selected_issue.should be_nil
    p.entry_count.should eq(1)
  end

  it "restores the list on backspace with selection on the first issue" do
    p = sample_picker
    "sql".each_char { |c| p.query_char(c) }
    3.times { p.backspace }
    p.selected.should eq(1)
    p.selected_issue.try(&.id).should eq(1_i64)
  end

  it "renders the create row and issue titles" do
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("PICK ISSUE").should be_true
    backend.contains?("+ New issue…").should be_true
    backend.contains?("Reflected XSS").should be_true
    backend.contains?("SQL injection").should be_true
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
describe "IssuePicker — Overlay contract" do
  it "carries the chrome the Runner's ladder arms used to hard-code" do
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::IssuePick, "PICK ISSUE")
    # The bottom row says "link"; the card's own hint row also names the create action.
    sample_picker.hint.should eq("type to filter · ↑/↓ select · ↵ link · esc cancel")
    OverlayHarness.new(sample_picker).rendered?("↵ link / create").should be_true
  end

  it "keeps the pinned create row out of the filtered count (the off-by-one)" do
    ov = sample_picker
    OverlayHarness.new(ov).type("sql")
    ov.entry_count.should eq(2) # "+ New issue…" plus the one match
    ov.selected.should eq(1)
    ov.selected_create?.should be_false
    ov.selected_issue.try(&.id).should eq(2_i64)
    ov.move(-1)
    ov.selected_create?.should be_true
    ov.selected_issue.should be_nil
  end

  it "lands on the create row when nothing matches" do
    ov = sample_picker
    OverlayHarness.new(ov).type("zzzz")
    ov.entry_count.should eq(1)
    ov.selected_create?.should be_true
  end

  it "↵ on an existing issue commits it to the injected closure" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    linked = [] of Int64
    h.on_commit { linked << ov.selected_issue.not_nil!.id; true }
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    linked.should eq([1_i64])
  end

  it "↵ on the create row is still a plain :commit — the closure decides what create means" do
    # Runner#link_picked_issue answers that :commit by opening the NEW ISSUE form and
    # reporting FALSE, because close_active_overlay would otherwise wipe the @overlay that
    # form just claimed. Mirrored here: the overlay must not special-case the create row.
    ov = IssuePicker.new([] of Gori::Store::Issue)
    ov.selected_create?.should be_true
    h = OverlayHarness.new(ov)
    creates = 0
    h.on_commit do
      creates += 1 if ov.selected_create?
      false # "I put my own modal up — do not close me"
    end
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    creates.should eq(1)
  end

  it "esc cancels; a row click commits; a click away dismisses" do
    esc = OverlayHarness.new(sample_picker)
    esc.press(Termisu::Input::Key::Escape).should eq(:closed)
    esc.commits.should eq(0)

    ov = sample_picker
    click = OverlayHarness.new(ov)
    click.click_in_box(3, 4).should eq(:closed) # list starts at box.y + 3 → second row
    ov.selected.should eq(1)
    click.commits.should eq(1)

    away = OverlayHarness.new(sample_picker)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
  end
end
