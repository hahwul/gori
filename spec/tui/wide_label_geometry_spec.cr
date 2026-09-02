require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Label geometry measured in CELLS, not characters.
#
# Every one of these helpers used `String#size` to place the thing drawn after a label, size
# the card around it, or hit-test it. That is exact for ASCII and half the truth for Hangul
# (two cells per syllable), so a Korean label overlapped its value, a Korean button was
# clickable across half its band, and a centred footer sat a quarter-width to the right.
# `Screen#text` already advanced by display width — these are the arithmetic sites that had
# to agree with it before any label can be drawn in Korean.
describe "wide-label geometry" do
  it "sizes confirm buttons by display width and hit-tests across every cell" do
    dlg = ConfirmDialog.new("DELETE", "Delete this?", confirm_label: "삭제", cancel_label: "취소")
    box = dlg.overlay_box(Rect.new(0, 0, 80, 24))
    confirm_rect, cancel_rect = dlg.button_rects(box)
    confirm_rect.w.should eq(Screen.draw_width(" 삭제 ")) # 6 cells — `size` said 4
    cancel_rect.x.should eq(confirm_rect.right + 4)
    dlg.button_at(box, confirm_rect.right - 1, confirm_rect.y).should eq(:confirm)
    dlg.button_at(box, cancel_rect.right - 1, cancel_rect.y).should eq(:cancel)
    dlg.button_at(box, confirm_rect.right, confirm_rect.y).should be_nil # the gap
  end

  it "hit-tests a right-chained badge over the cells its Hangul name occupies" do
    badges = [{:send, "^R", "전송"}] of {Symbol, String, String}
    w = Screen.draw_width(" ^R:전송 ") # 9 cells
    Frame.right_badge_edge(20, 0, badges).should eq(20 - w)
    Frame.right_badge_hit(20 - w, 0, 0, 20, 0, badges).should eq(:send)
    Frame.right_badge_hit(19, 0, 0, 20, 0, badges).should eq(:send)
    Frame.right_badge_hit(20 - w - 1, 0, 0, 20, 0, badges).should be_nil
  end

  it "walks a left-to-right chip run by display width" do
    chips = [{:diff, " d:차이 "}, {:hex, " ^X:hex "}] of {Symbol, String}
    first = Screen.draw_width(" d:차이 ") # 8 cells
    Frame.left_chip_hit(10 + first - 1, 0, 0, 10, chips).should eq(:diff)
    Frame.left_chip_hit(10 + first, 0, 0, 10, chips).should be_nil # the 1-col gap
    Frame.left_chip_hit(10 + first + 1, 0, 0, 10, chips).should eq(:hex)
  end

  it "advances tour tab chips and their hit rects by cell width, not char count" do
    # Each Hangul syllable is 2 cells but 1 char, so a char-measured advance drifts one cell per
    # syllable: the chips after a Korean tab name would draw and hit-test off their labels.
    rects = Tutorial.tab_chip_rects(["AB", "탭", "C"], 0, 0, 100)
    rects.map(&.last).should eq([0, 1, 2])
    rects[0][0].x.should eq(0)
    rects[1][0].x.should eq(5)  # after " AB " (4 cells) + a 1-col gap
    rects[1][0].w.should eq(4)  # " 탭 " is 4 cells — String#size said 3
    rects[2][0].x.should eq(10) # 5 + 4 cells + 1 gap: the wide char advanced by cells, not chars
  end

  it "stops the tour tab run before the first chip that would overflow the width" do
    Tutorial.tab_chip_rects(["AB", "CD"], 0, 0, 8).map(&.last).should eq([0])
  end

  it "starts the status hint one cell past a Hangul focus badge" do
    rect = Rect.new(0, 23, 80, 1)
    backend = MemoryBackend.new(80, 24)
    Chrome.render_status(Screen.new(backend), rect, focus: "본문", hints: "hints here")
    row = backend.row(rect.y)
    row[1].should eq('본')
    row[3].should eq('문')
    hint_x = Screen.draw_width(" 본문 ") + 1
    row[hint_x, 10].should eq("hints here")
  end

  it "widens the hidden-tab dropdown to a Hangul label's cells" do
    menu = MoreMenu.new([{:history, "히스토리"}, {:notes, "Notes"}])
    box = menu.overlay_box(Rect.new(70, 0, 10, 1), Rect.new(0, 1, 80, 20)).not_nil!
    box.w.should eq(Screen.draw_width("히스토리") + 4)
  end

  it "pads a protobuf preview by cells, so a Hangul value keeps its column" do
    ProtobufTree.cut("한글", 6).should eq("한글  ")
    ProtobufTree.cut("한글테스트", 6).should eq("한글… ")
    Screen.draw_width(ProtobufTree.cut("한글테스트", 6)).should eq(6)
  end
end
