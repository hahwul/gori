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

  it "↵ starts from a location row without unchecking it; ␣ still toggles (#1373)" do
    q = [Gori::Miner::Location::Query]
    ov = MineConfigOverlay.new(seed(q, q))
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should eq(:commit)
    ov.build_config.locations.should eq(q)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Space)).should eq(:stay)
    ov.any_checked?.should be_false
  end

  it "cycles max-requests, concurrency and notification on their rows and reports the Start row" do
    ov = MineConfigOverlay.new(seed([Gori::Miner::Location::Query], [Gori::Miner::Location::Query]))
    # rows: [0]=query, [1]=max requests, [2]=concurrency, [3]=notification, [4]=keep-alive,
    #       [5]=macro step, [6]=macro cadence, [7]=macro on failure, [8]=start
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
    3.times { ov.move(1) } # the three macro rows (#1350)
    ov.on_start_row?.should be_false
    ov.move(1) # start row
    ov.on_start_row?.should be_true
  end

  describe "request-time macro rows (#1350)" do
    q = [Gori::Miner::Location::Query]
    sessions = [{3_i64, "csrf-fetch"}, {7_i64, "GET /form"}] of {Int64, String}

    it "builds no macro until a step is picked — every mine that came before" do
      ov = MineConfigOverlay.new(seed(q, q), macro_sessions: sessions)
      ov.build_config.request_macro.should be_nil
    end

    it "picks one saved session by id, with the cadence and failure policy beside it" do
      ov = MineConfigOverlay.new(seed(q, q), macro_sessions: sessions)
      ov.set_selected(5) # macro step
      ov.adjust(1)
      ov.set_selected(6) # cadence: request → 2
      ov.adjust(1)
      ov.set_selected(7) # on failure: skip → stop
      ov.adjust(1)
      spec = ov.build_config.request_macro.not_nil!
      spec.steps.should eq(["3"])
      spec.cadence.every.should eq(2)
      spec.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)
      ov.set_selected(5)
      ov.adjust(1) # the second session
      ov.build_config.request_macro.not_nil!.steps.should eq(["7"])
      ov.adjust(1) # …and back to off
      ov.build_config.request_macro.should be_nil
    end

    it "leaves the cadence and failure rows inert while no step is picked" do
      ov = MineConfigOverlay.new(seed(q, q), macro_sessions: sessions)
      ov.set_selected(6)
      ov.adjust(1)
      ov.set_selected(7)
      ov.adjust(1)
      ov.set_selected(5)
      ov.adjust(1) # now a step is picked
      spec = ov.build_config.request_macro.not_nil!
      spec.cadence.every.should eq(1) # the earlier presses changed nothing
      spec.on_failure.should eq(Gori::RequestMacro::OnFailure::Skip)
    end

    it "has nothing to pick in a project with no saved session, and says so" do
      ov = MineConfigOverlay.new(seed(q, q))
      ov.set_selected(5)
      ov.adjust(1)
      ov.toggle
      ov.build_config.request_macro.should be_nil
      backend = MemoryBackend.new(80, 24)
      ov.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
      backend.contains?("no Repeater session in this project").should be_true
    end

    it "draws the picked step's name" do
      ov = MineConfigOverlay.new(seed(q, q), macro_sessions: sessions)
      ov.set_selected(5)
      ov.adjust(1)
      backend = MemoryBackend.new(100, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
      backend.contains?("csrf-fetch").should be_true
      backend.contains?("macro cadence").should be_true
    end
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

describe "MineConfigOverlay#prefill (Miner Reconfigure)" do
  q = [Gori::Miner::Location::Query]
  qh = [Gori::Miner::Location::Query, Gori::Miner::Location::Headers]
  sessions = [{3_i64, "csrf-fetch"}, {7_i64, "GET /form"}] of {Int64, String}

  it "shows the session's own config instead of the defaults" do
    c = Gori::Miner::Config.new
    c.locations = [Gori::Miner::Location::Headers]
    c.concurrency = 40
    c.notify = Gori::Miner::NotifyMode::Off
    c.max_requests = 500_i64
    c.keep_alive = false
    c.request_macro = Gori::RequestMacro::Spec.new(["7"], Gori::RequestMacro::Cadence.new(5),
      Gori::RequestMacro::OnFailure::Stop)
    ov = MineConfigOverlay.new(seed(qh, q), macro_sessions: sessions)
    ov.prefill(c)
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("500").should be_true # the cycler shows the session's cap
    got = ov.apply_to(c.dup)
    got.locations.should eq([Gori::Miner::Location::Headers])
    got.concurrency.should eq(40)
    got.notify.should eq(Gori::Miner::NotifyMode::Off)
    got.max_requests.should eq(500_i64)
    got.keep_alive?.should be_false
    m = got.request_macro.not_nil!
    m.steps.should eq(["7"])
    m.cadence.every.should eq(5)
    m.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)
  end

  it "keeps a value its cyclers cannot show unless the operator moves that row" do
    c = Gori::Miner::Config.new
    c.locations = q
    c.max_requests = 300_i64 # not a MAX_REQ_CHOICES entry: index 0 would mean "no cap"
    c.concurrency = 7
    two = Gori::RequestMacro::Spec.new(["3", "7"], Gori::RequestMacro::Cadence.new(5),
      Gori::RequestMacro::OnFailure::Stop)
    c.request_macro = two
    ov = MineConfigOverlay.new(seed(qh, q), macro_sessions: sessions)
    ov.prefill(c)
    got = ov.apply_to(c.dup)
    got.max_requests.should eq(300_i64)
    got.concurrency.should eq(7)
    got.request_macro.not_nil!.steps.should eq(["3", "7"])
  end

  it "writes only its own knobs onto the session's config, and its last row applies" do
    c = Gori::Miner::Config.new
    c.locations = q
    c.stability_rounds = 9
    c.user_wordlist = "/tmp/words.txt"
    c.bucket_size[Gori::Miner::Location::Query] = 7
    ov = MineConfigOverlay.new(seed(qh, q))
    ov.prefill(c)
    ov.reconfiguring?.should be_true
    ov.set_selected(1) # Headers
    ov.toggle
    got = ov.apply_to(c.dup)
    got.locations.should eq(qh)
    got.stability_rounds.should eq(9)
    got.user_wordlist.should eq("/tmp/words.txt")
    got.bucket_size[Gori::Miner::Location::Query].should eq(7)
    c.locations.should eq(q) # the session's own config is untouched until apply
    backend = MemoryBackend.new(80, 24)
    ov.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
    backend.contains?("Apply to session").should be_true
    ov.hint.should contain("apply")
  end
end
