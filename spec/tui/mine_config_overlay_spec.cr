require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def seed(applicable, default) : MineSeed
  MineSeed.new(
    target: "http://h.test",
    request: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    http2: false, sni: nil, flow_id: nil, summary: "GET /api",
    applicable: applicable, default: default)
end

describe Gori::Tui::MineConfigOverlay do
  it "pre-checks the default locations and excludes others" do
    ov = MineConfigOverlay.new(seed(
      [Gori::Miner::Location::Query, Gori::Miner::Location::Json, Gori::Miner::Location::Headers],
      [Gori::Miner::Location::Query, Gori::Miner::Location::Json]))
    cfg = ov.build_config
    cfg.locations.should eq([Gori::Miner::Location::Query, Gori::Miner::Location::Json])
    ov.any_checked?.should be_true
  end

  it "toggles a location checkbox" do
    ov = MineConfigOverlay.new(seed(
      [Gori::Miner::Location::Query, Gori::Miner::Location::Headers],
      [Gori::Miner::Location::Query]))
    ov.move(1) # to the Headers row (index 1)
    ov.toggle
    ov.build_config.locations.should eq([Gori::Miner::Location::Query, Gori::Miner::Location::Headers])
  end

  it "cycles concurrency and notification on their rows and reports the Start row" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    # rows: [0]=query, [1]=concurrency, [2]=notification, [3]=start
    ov.move(1) # concurrency row
    ov.adjust(1)
    ov.build_config.concurrency.should eq(20) # default 10 → next choice
    ov.move(1)                                # notification row
    ov.adjust(1)
    ov.build_config.notify.should eq(Gori::Miner::NotifyMode::Off)
    ov.move(1) # start row
    ov.on_start_row?.should be_true
  end

  it "defaults notification to when-found" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    ov.build_config.notify.should eq(Gori::Miner::NotifyMode::WhenFound)
  end

  it "restores the last saved overlay choices from Settings" do
    Gori::Settings.mine_locations = ["query", "json"]
    Gori::Settings.mine_concurrency = 20
    Gori::Settings.mine_notify = "always"
    Gori::Settings.mine_prefs_saved = true
    ov = MineConfigOverlay.new(seed(
      [Gori::Miner::Location::Query, Gori::Miner::Location::Json, Gori::Miner::Location::Headers],
      [Gori::Miner::Location::Query]))
    cfg = ov.build_config
    cfg.locations.should eq([Gori::Miner::Location::Query, Gori::Miner::Location::Json])
    cfg.concurrency.should eq(20)
    cfg.notify.should eq(Gori::Miner::NotifyMode::Always)
  ensure
    Gori::Settings.mine_locations = [] of String
    Gori::Settings.mine_concurrency = 10
    Gori::Settings.mine_notify = "when-found"
    Gori::Settings.mine_prefs_saved = false
  end

  it "renders without crashing and maps a click to a row" do
    ov = MineConfigOverlay.new(seed(
      [Gori::Miner::Location::Query, Gori::Miner::Location::Json], [Gori::Miner::Location::Query]))
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 3).should eq(0) # first location row
  end
end
