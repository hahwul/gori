require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def seed(applicable, default, flow_id : Int64? = nil) : MineSeed
  MineSeed.new(
    target: "http://h.test",
    request: "GET /api HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
    http2: false, sni: nil, flow_id: flow_id, summary: "GET /api",
    applicable: applicable, default: default)
end

describe Gori::Tui::MineConfigOverlay do
  it "lands inventory seed names on each seed by flow id (#1231)" do
    q = [Gori::Miner::Location::Query]
    ov = MineConfigOverlay.new(seed(q, q, 1_i64), [seed(q, q, 2_i64), seed(q, q)])
    ov.begin_seeding
    ov.seeding?.should be_true
    ov.build_config.seed_names.should be_empty # Start before it lands tests the wordlist alone
    ov.seed_status.to_s.should contain("seeding names")
    ov.land_seed_names({1_i64 => ["tenant"], 2_i64 => ["org"]})
    ov.seeding?.should be_false
    ov.seed_status.should eq("seeded names tested first on 2 of 3 flows")
    ov.build_config.seed_names.should eq(["tenant"])
    ov.extra_seeds.map(&.names).should eq([["org"], [] of String])
  end

  it "says nothing about seeding for a plain wordlist mine, and counts a single seed's names" do
    q = [Gori::Miner::Location::Query]
    MineConfigOverlay.new(seed(q, q)).seed_status.should be_nil
    MineConfigOverlay.new(seed(q, q).copy_with(names: ["a", "b"])).seed_status.should eq("+2 seeded names, tested first")
  end

  it "keeps every seed's names when the scan failed" do
    q = [Gori::Miner::Location::Query]
    ov = MineConfigOverlay.new(seed(q, q, 1_i64).copy_with(names: ["kept"]))
    ov.begin_seeding
    ov.land_seed_names(nil)
    ov.seeding?.should be_false
    ov.seed_status.to_s.should contain("seeding failed")
    ov.build_config.seed_names.should eq(["kept"])
  end

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

  it "cycles max-requests, concurrency and notification on their rows and reports the Start row" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    # rows: [0]=query, [1]=max requests, [2]=concurrency, [3]=notification, [4]=keep-alive, [5]=start
    ov.build_config.max_requests.should be_nil # uncapped is the first choice, and the default
    ov.move(1)                                 # max requests row
    ov.adjust(1)
    ov.build_config.max_requests.should eq(100_i64)
    ov.move(1) # concurrency row
    ov.adjust(1)
    ov.build_config.concurrency.should eq(20) # default 10 → next choice
    ov.move(1)                                # notification row
    ov.adjust(1)
    ov.build_config.notify.should eq(Gori::Miner::NotifyMode::Off)
    ov.move(1) # keep-alive row
    ov.on_start_row?.should be_false
    ov.move(1) # start row
    ov.on_start_row?.should be_true
  end

  it "reuses connections by default and turns pooling off from its own row" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    ov.build_config.keep_alive?.should be_true
    ov.set_selected(4) # the keep-alive row for a one-location seed
    ov.toggle
    ov.build_config.keep_alive?.should be_false
    # ←/→ flips it too, so the row behaves like the cyclers it sits under.
    ov.adjust(1)
    ov.build_config.keep_alive?.should be_true
  end

  it "defaults notification to when-found" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    ov.build_config.notify.should eq(Gori::Miner::NotifyMode::WhenFound)
  end

  it "restores the last saved overlay choices from Settings" do
    Gori::Settings.mine_locations = ["query", "json"]
    Gori::Settings.mine_concurrency = 20
    Gori::Settings.mine_notify = "always"
    Gori::Settings.mine_keep_alive = false
    Gori::Settings.mine_prefs_saved = true
    ov = MineConfigOverlay.new(seed(
      [Gori::Miner::Location::Query, Gori::Miner::Location::Json, Gori::Miner::Location::Headers],
      [Gori::Miner::Location::Query]))
    cfg = ov.build_config
    cfg.locations.should eq([Gori::Miner::Location::Query, Gori::Miner::Location::Json])
    cfg.concurrency.should eq(20)
    cfg.notify.should eq(Gori::Miner::NotifyMode::Always)
    cfg.keep_alive?.should be_false
  ensure
    Gori::Settings.mine_locations = [] of String
    Gori::Settings.mine_concurrency = 10
    Gori::Settings.mine_notify = "when-found"
    Gori::Settings.mine_keep_alive = true
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
