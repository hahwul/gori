require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def sample_picker : NotePicker
  NotePicker.new([
    NotePicker::Row.new(10_i64, "1:XSS notes", "payload details"),
    NotePicker::Row.new(11_i64, "2:Auth flow", "token reuse"),
    NotePicker::Row.new(12_i64, "3:Recon", "subdomains"),
  ])
end

describe Gori::Tui::NotePicker do
  it "pins create at index 0 and defaults selection to the first real note" do
    p = sample_picker
    p.selected.should eq(1)
    p.selected_create?.should be_false
    p.selected_row.try(&.id).should eq(10_i64)
    p.entry_count.should eq(4)
  end

  it "selects create when there are no notes" do
    p = NotePicker.new([] of NotePicker::Row)
    p.selected.should eq(0)
    p.selected_create?.should be_true
    p.selected_row.should be_nil
    p.entry_count.should eq(1)
  end

  it "moves onto the create row and back onto notes" do
    p = sample_picker
    p.move(-1)
    p.selected_create?.should be_true
    p.move(1)
    p.selected_row.try(&.label).should eq("1:XSS notes")
  end

  it "keeps create pinned while filtering" do
    p = sample_picker
    "auth".each_char { |c| p.query_char(c) }
    p.selected_row.try(&.id).should eq(11_i64)
    p.move(-1)
    p.selected_create?.should be_true
  end

  it "falls back to create when the filter matches nothing" do
    p = sample_picker
    "zzz".each_char { |c| p.query_char(c) }
    p.selected_create?.should be_true
    p.entry_count.should eq(1)
  end

  it "renders the create row and note labels" do
    backend = MemoryBackend.new(100, 30)
    sample_picker.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("PICK NOTE").should be_true
    backend.contains?("+ New note…").should be_true
    backend.contains?("1:XSS notes").should be_true
    backend.contains?("2:Auth flow").should be_true
  end
end

# --- Overlay seam (issue #355, batch C4) ------------------------------------------
describe "NotePicker — Overlay contract" do
  it "carries the chrome the Runner's ladder arms used to hard-code" do
    OverlayHarness.new(sample_picker).assert_chrome(OverlayKind::NotePick, "PICK NOTE")
    sample_picker.hint.should eq("type to filter · ↑/↓ select · ↵ link · esc cancel")
    OverlayHarness.new(sample_picker).rendered?("↵ link / create").should be_true
  end

  it "keeps the pinned create row out of the filtered count (the off-by-one)" do
    ov = sample_picker
    OverlayHarness.new(ov).type("auth")
    ov.entry_count.should eq(2) # "+ New note…" plus the one match
    ov.selected.should eq(1)
    ov.selected_row.try(&.id).should eq(11_i64)
    ov.move(-1)
    ov.selected_create?.should be_true
    ov.selected_row.should be_nil
  end

  it "↵ on an existing note commits it to the injected closure" do
    ov = sample_picker
    h = OverlayHarness.new(ov)
    linked = [] of Int64
    h.on_commit { linked << ov.selected_row.not_nil!.id; true }
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    linked.should eq([10_i64])
  end

  it "↵ on the create row is a plain :commit that the closure may decline to close" do
    # Runner#link_picked_note creates the note, links it, and hands off to the open-vs-stay
    # CONFIRM modal — so it reports false, or close_active_overlay would wipe that confirm.
    ov = NotePicker.new([] of NotePicker::Row)
    ov.selected_create?.should be_true
    h = OverlayHarness.new(ov)
    creates = 0
    h.on_commit do
      creates += 1 if ov.selected_create?
      false
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
