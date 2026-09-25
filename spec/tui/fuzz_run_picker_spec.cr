require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe FuzzRunPicker do
  it "renders a selectable card when history contains exactly one run" do
    run = Gori::Store::FuzzRunRecord.new(
      1_i64, 2_i64, 3_i64, 4_i64, "https://example.test", "sniper",
      1_i64, 1_i64, 1_i64, 0_i64, "done")
    picker = FuzzRunPicker.new([run])

    picker.entry_count.should eq(1)
    picker.selected_row.should eq(run)
    box = picker.overlay_box(Rect.new(0, 0, 100, 20))
    box.should_not be_nil
    box.not_nil!.h.should be >= 4
  end

  it "names a condition_met run's stop row on its card, and none on a run without one (#1270)" do
    met = Gori::Store::FuzzRunRecord.new(
      1_i64, 2_i64, 3_i64, 4_i64, "https://example.test", "sniper",
      9_i64, 5_i64, 2_i64, 0_i64, "condition_met", snapshot_version: 1, stop_idx: 4_i64)
    plain = Gori::Store::FuzzRunRecord.new(
      2_i64, 2_i64, 3_i64, 4_i64, "https://example.test", "sniper",
      9_i64, 9_i64, 2_i64, 0_i64, "done", snapshot_version: 1)
    picker = FuzzRunPicker.new([met, plain])
    backend = MemoryBackend.new(100, 20)
    picker.render(Screen.new(backend), Rect.new(0, 0, 100, 20))
    backend.contains?("CONDITION_MET · stop #4").should be_true
    backend.contains?("DONE · stop").should be_false
  end

  it "arms load/delete actions for the shell to run only after close" do
    run = Gori::Store::FuzzRunRecord.new(
      7_i64, 2_i64, 3_i64, 4_i64, "https://example.test", "sniper",
      1_i64, 1_i64, 1_i64, 0_i64, "done")

    load_picker = FuzzRunPicker.new([run])
    load_picker.arm_load.should be_true
    load_picker.pending_action.not_nil!.kind.should eq(:load)
    load_picker.pending_action.not_nil!.id.should eq(7_i64)

    delete_picker = FuzzRunPicker.new([run])
    key = Termisu::Event::Key.new(Termisu::Input::Key::LowerD, char: 'd')
    delete_picker.handle_key(key).should eq(:cancel)
    delete_picker.pending_action.not_nil!.kind.should eq(:delete)
    delete_picker.pending_action.not_nil!.id.should eq(7_i64)
  end
end
