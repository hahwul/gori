require "../spec_helper"

private alias SW = Gori::Tui::SetupWizard

# The wizard's minimum terminal height used to be checked PER STEP, against each step's own
# `content_rows`. The steps don't agree — BIND needs 14 terminal rows, COMPANION 13, REVIEW 15 — so a
# 14-row terminal rendered BIND, THEME and COMPANION and then replaced REVIEW with "terminal too
# small". REVIEW is the only step that can commit, and input runs regardless of the render
# guard, so ↵ still saved from a screen that said it couldn't draw. `MIN_H` is now derived from
# the tallest step; these examples pin that derivation from BOTH sides, so a step that grows a
# row can't quietly push the real floor past the advertised one again.
describe Gori::Tui::SetupWizard do
  it "gives every fixed-layout step a card that fits at MIN_H" do
    {SW::BIND_ROWS, SW::COMPANION_ROWS, SW::REVIEW_ROWS}.each do |rows|
      # `rows + 3` = top border + pad row + content + bottom border, which is exactly the
      # invariant render_* rely on: they draw at fixed offsets down to `box.y + 2 + rows - 1`.
      SW.card_h(SW::MIN_H, rows).should be >= rows + 3
    end
  end

  it "sets MIN_H no higher than the tallest step actually needs" do
    # One row below the floor the tallest step must NOT fit — otherwise MIN_H is padded and the
    # wizard turns away terminals it could have served.
    tallest = {SW::BIND_ROWS, SW::COMPANION_ROWS, SW::REVIEW_ROWS}.max
    SW.card_h(SW::MIN_H - 1, tallest).should be < tallest + 3
  end

  it "advertises the width that Layout.usable? actually rejects at" do
    # `fits?` takes its width test entirely from Layout.usable?; MIN_W exists only to be the
    # number in the on-screen "min 40x15" message. So the pair that matters is: the advertised
    # width is accepted, and one column under it is not. The second assertion is the load-bearing
    # one — it fails if Layout's floor moves and the message is left promising a size that no
    # longer works.
    Gori::Tui::Layout.usable?(SW::MIN_W, SW::MIN_H).should be_true
    Gori::Tui::Layout.usable?(SW::MIN_W - 1, SW::MIN_H).should be_false
  end

  # The click targets are the SAME offsets the renderers draw at (one constant each), so the
  # only thing left to pin is that every one of them lies inside the step's own interior —
  # `box.y + 2 .. box.y + 1 + rows` — otherwise the card's bottom border, or the row past it,
  # would take a click for the row it never drew.
  it "keeps every clickable row inside its step's interior" do
    {
      {SW::BIND_FIELD_ROW + 1, SW::BIND_ROWS},
      {SW::COMPANION_MOTION_ROW, SW::COMPANION_ROWS},
      {SW::REVIEW_OFFER_ROW + 1, SW::REVIEW_ROWS},
    }.each do |(last_row, rows)|
      last_row.should be >= 2
      last_row.should be <= rows + 1
    end
  end

  # Only "address in use" is a warning; a host this machine cannot bind, or a sandbox that
  # forbids binding altogether, must read as free — the app reports those itself at launch.
  describe ".port_in_use?" do
    it "never flags port 0" do
      SW.port_in_use?("127.0.0.1", 0).should be_false
    end

    it "reads an unbindable host as free" do
      SW.port_in_use?("192.0.2.1", 8070).should be_false # TEST-NET-1, never local
    end

    it "flags a port something already listens on, and only that" do
      listener = begin
        TCPServer.new("127.0.0.1", 0)
      rescue Socket::Error
        pending!("cannot bind a loopback listener in this environment")
      end
      begin
        port = listener.local_address.port
        SW.port_in_use?("127.0.0.1", port).should be_true
        listener.close
        SW.port_in_use?("127.0.0.1", port).should be_false
      ensure
        listener.close rescue nil
      end
    end
  end

  # The COMPANION step holds Miss Ring's column band back out of its own text column, so a card too
  # narrow to seat her beside the copy doesn't shrink that copy, it shreds it: at MIN_W the
  # text column was 19 columns and all three lines — including the one sentence saying what
  # the step is asking — came out as a stub plus an ellipsis. She is now dropped instead, the
  # same trade `theme_list_w` makes with the theme preview panel. Pinned from both sides so
  # the threshold can't drift back over the advertised minimum.
  describe ".companion_preview_x" do
    # COMPANION is a non-BIND step, so it gets the wide card.
    private_box = ->(w : Int32) {
      cw = SW.card_w(w, 84)
      Gori::Tui::Rect.new({(w - cw) // 2, 0}.max, 0, cw, SW.card_h(SW::MIN_H, SW::COMPANION_ROWS))
    }

    it "drops her at the advertised minimum width" do
      SW.companion_preview_x(private_box.call(SW::MIN_W)).should be_nil
    end

    it "seats her on a card that can hold the step's opening line beside her" do
      # 69 columns is the first width whose card leaves COMPANION_TEXT_MIN for the text, and 68 the
      # last that doesn't — the pair is what stops the constant from being quietly padded.
      # COMPANION_TEXT_MIN is the width of that opening line ("A mascot in the corner, off unless
      # you want her.", 48 columns) and is coupled to it BY HAND, so a reword of the sentence
      # is a reason to revisit the constant and therefore these two numbers.
      SW.companion_preview_x(private_box.call(69)).should_not be_nil
      SW.companion_preview_x(private_box.call(68)).should be_nil
      SW.companion_preview_x(private_box.call(80)).should_not be_nil
    end

    it "leaves her sprite inside the card's interior" do
      # She occupies `px .. px + COMPANION_PREVIEW_W - 1` (plate, sprite, plate); the interior's last
      # column is `right - 2`. draw_companion_preview writes those cells unclipped, so an off-by-one
      # here would paint over the card's right border rather than truncate.
      box = private_box.call(80)
      px = SW.companion_preview_x(box).not_nil!
      (px + SW::COMPANION_PREVIEW_W - 1).should be <= box.right - 2
      px.should be > box.x
    end
  end
end
