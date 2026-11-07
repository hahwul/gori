require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Fuzzer's TARGET border carries two things on its right: the mode chip `Frame` draws, and
# an `SNI` marker shown when an override is set. The marker used to place itself at
# `rect.right - size - 1` — inside the mode chip's own cells — so setting an override painted
# over the right of ` ↵:READ ` and left `↵: SNI ` on the border. The hit-test still measured
# the whole mode rect underneath, so a press on the letters an operator could SEE saying SNI
# toggled insert mode.
#
# Repeater met this first and chained the marker left of the chip instead
# (`repeater_view.cr#target_chrome_chain`, whose comment describes exactly this). These pin
# the ported fix in both halves — what is drawn, and what a press does — and locate the marker
# by READING the rendered row rather than by asking the view, so a geometry that renders one
# way and hit-tests another cannot satisfy both examples.
private def sni_fuzzer(sni : String) : FuzzerView
  view = FuzzerView.new
  view.load_request("https://1.2.3.4", "GET / HTTP/1.1\r\nHost: vhost.test\r\n\r\n", false, sni)
  view
end

private def border_row(view : FuzzerView, rect : Rect) : String
  backend = MemoryBackend.new(rect.right, rect.bottom)
  view.render(Screen.new(backend), rect, focused: false)
  backend.row(rect.y)
end

describe "FuzzerView TARGET border chrome" do
  rect = Rect.new(0, 0, 60, 20)

  it "leaves the mode chip intact when an SNI override is set" do
    row = border_row(sni_fuzzer("alt.example.com"), rect)
    row.should contain("SNI")
    # ` READ ` in full. Before the fix the SNI marker ate the chip's last three cells.
    row.should contain(Frame.mode_badge_label(false))
  end

  it "does not answer the mode chip for a press on the SNI marker" do
    view = sni_fuzzer("alt.example.com")
    row = border_row(view, rect)
    x = row.index("SNI").not_nil!
    # Every cell of the marker is inert: it reports what it IS, it is not a control.
    ((x - 1)...(x + 4)).each do |mx|
      view.target_chrome_hit(rect, mx, rect.y).should be_nil
    end
  end

  it "still answers the mode chip on the chip's own cells" do
    # The positive control — without it the example above also passes for a hit-test that has
    # simply stopped working.
    view = sni_fuzzer("alt.example.com")
    row = border_row(view, rect)
    mode_x = row.index(Frame.mode_badge_label(false).strip).not_nil!
    view.target_chrome_hit(rect, mode_x, rect.y).should eq(:mode)
  end

  it "shows no marker at all without an override" do
    border_row(sni_fuzzer(""), rect).should_not contain("SNI")
  end

  it "drops the marker rather than overlapping when the card is too narrow" do
    # `Frame`'s badges drop out when they do not fit; the hand-rolled marker clamped with
    # `.max` and drew over the card title instead.
    row = border_row(sni_fuzzer("alt.example.com"), Rect.new(0, 0, 18, 20))
    row.should_not contain("SNI")
  end
end
