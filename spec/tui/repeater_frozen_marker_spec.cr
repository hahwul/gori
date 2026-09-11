require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Repeater's frozen-copy marker (#1038): `frozen ×N` on the RESPONSE border, meaning a
# frozen copy of this tab's exchange exists — never that the tab is locked. The request
# stays editable and the next send still replaces the response; the copy is why that is safe.

private def rows(backend : MemoryBackend, h : Int32) : Array(String)
  (0...h).map { |y| backend.row(y) }
end

describe "RepeaterView's frozen-evidence marker" do
  before_each { Gori::Settings.pretty_bodies_default = false }

  it "rides the RESPONSE border left of the latency read-out, and stays without a result" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:response)
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    rows(backend, 20).any?(&.includes?("frozen")).should be_false

    view.frozen_count = 2
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    border = rows(backend, 20).find!(&.includes?("RESPONSE"))
    border.should contain("frozen ×2")

    # With a result the latency read-out takes the corner and the marker chains left of it
    # — on a pane wide enough to hold both past the chip cluster.
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64))
    backend = MemoryBackend.new(160, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 160, 20))
    border = rows(backend, 20).find!(&.includes?("RESPONSE"))
    border.should contain("frozen ×2")
    border.index!("frozen ×2").should be < border.index!("1.0ms")
    # The marker is the FROZEN hue the Issues detail uses, so the two read as one fact.
    y = rows(backend, 20).index!(&.includes?("frozen ×2"))
    backend.fg_at(border.index!("frozen ×2"), y).should eq(Theme.syn_header)
  end

  it "is dropped whole when it would run into the chips, like the ⚠ — never truncated" do
    view = RepeaterView.new
    view.load_blank
    view.frozen_count = 1
    view.apply(Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "PONG".to_slice, nil, 1000_i64))
    # A 120-column terminal gives RESPONSE ~60 columns: chips + latency leave no room.
    backend = MemoryBackend.new(120, 20)
    view.render(Screen.new(backend), Rect.new(0, 0, 120, 20))
    rows(backend, 20).any?(&.includes?("frozen")).should be_false
  end
end
