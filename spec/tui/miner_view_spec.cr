require "../spec_helper"

describe Gori::Tui::MinerView do
  it "round-trips notify mode in session config JSON" do
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new(notify: Gori::Miner::NotifyMode::WhenFound))
    json = view.config_json
    restored = Gori::Tui::MinerView.new
    restored.restore(Gori::Store::MinerSessionRecord.new(
      id: 1, target: "http://h.test", request: Bytes.empty, http2: false, sni: nil,
      config: json, flow_id: nil, position: 0, name: nil))
    restored.config.notify.should eq(Gori::Miner::NotifyMode::WhenFound)
  end

  it "fronts a custom name on the sub-tab label (the rename path now wired for Miner)" do
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new)
    auto = view.label(18)
    view.name = "login probe" # MinerController#apply_rename sets this
    view.label(18).should contain("login")
    view.label(18).should_not eq(auto) # the custom name overrides the derived summary
  end

  it "verifies at_top? and results_at_top? behavior for vertical navigation" do
    view = Gori::Tui::MinerView.new
    view.focus_pane(:summary)
    view.at_top?.should be_true
    view.results_at_top?.should be_true

    view.focus_pane(:results)
    view.at_top?.should be_false
    view.results_at_top?.should be_true

    view.results_move(1)
    view.results_at_top?.should be_true # remains true when results empty

    # seed results and move
    view.append_finding(Gori::Miner::Finding.new("p1", Gori::Miner::Location::Query, Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64))
    view.append_finding(Gori::Miner::Finding.new("p2", Gori::Miner::Location::Query, Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64))
    view.results_move(1)
    view.results_at_top?.should be_false

    view.results_move(-1)
    view.results_at_top?.should be_true
  end

  it "apply_peer_session keeps focus and in-memory findings (reconcile soft-sync)" do
    view = Gori::Tui::MinerView.new
    view.load("https://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new)
    view.focus_pane(:results)
    view.append_finding(Gori::Miner::Finding.new("found", Gori::Miner::Location::Query,
      Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, nil, 0_i64))
    n = view.@results.size

    rec = Gori::Store::MinerSessionRecord.new(
      1_i64, "https://peer.test", "GET /peer HTTP/1.1\r\nHost: peer.test\r\n\r\n".to_slice,
      false, nil, %({"concurrency":10}), nil, 0, nil)
    view.apply_peer_session(rec)

    view.focus.should eq(:results)
    view.target_origin.should contain("peer.test")
    view.@results.size.should eq(n)
    view.session_side_matches?(rec).should be_true
  end
end
