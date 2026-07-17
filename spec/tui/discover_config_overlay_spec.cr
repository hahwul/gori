require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def dseed : DiscoverSeed
  DiscoverSeed.new([{"/", "http://h.test/"}], "h.test")
end

describe Gori::Tui::DiscoverConfigOverlay do
  it "carries custom headers into the built config" do
    ov = DiscoverConfigOverlay.new(dseed)
    ov.set_headers([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
    ov.build_config.headers.should eq([{"Authorization", "Bearer t"}, {"X-Env", "staging"}])
  end

  it "defaults to no custom headers" do
    DiscoverConfigOverlay.new(dseed).build_config.headers.should be_empty
  end

  it "exposes a headers row before the start row" do
    ov = DiscoverConfigOverlay.new(dseed)
    (DiscoverConfigOverlay::ROW_HEADERS < DiscoverConfigOverlay::ROW_START).should be_true
    ov.set_selected(DiscoverConfigOverlay::ROW_HEADERS)
    ov.on_headers_row?.should be_true
    ov.on_start_row?.should be_false
  end

  it "renders without crashing and maps a click to the headers row" do
    ov = DiscoverConfigOverlay.new(dseed)
    ov.set_headers([{"A", "b"}])
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 3 + DiscoverConfigOverlay::ROW_HEADERS)
      .should eq(DiscoverConfigOverlay::ROW_HEADERS)
  end
end
