require "../spec_helper"

# A store with an unconfigured Scope: `Outbound.interactive` waives Layer 1 anyway, and
# with no rules Layer 2 (Sandbox / EXCLUDE) has nothing to block — the gate is not what
# these examples are about (`spec/outbound_spec.cr` owns it).
private def miner_spec_store(&)
  path = File.tempname("gori-miner-view", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

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

  it "request_with_finding injects the selected param (canary or probe value)" do
    req = "GET /search?q=hi HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice
    view = Gori::Tui::MinerView.new
    view.load("https://h.test", req, false, nil, Gori::Miner::Config.new)

    with_canary = Gori::Miner::Finding.new("debug", Gori::Miner::Location::Query,
      Gori::Miner::Evidence::Reflection, Gori::Miner::Confidence::Confirmed, "gqabcd1234", nil, 0_i64)
    out = String.new(view.request_with_finding(with_canary))
    out.should contain("debug=gqabcd1234")
    out.should contain("q=hi") # original params preserved; miner appends candidates

    no_canary = Gori::Miner::Finding.new("admin", Gori::Miner::Location::Query,
      Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, 200, 12_i64)
    out2 = String.new(view.request_with_finding(no_canary))
    out2.should contain("admin=1")
  end

  describe "#build_engine" do
    it "words each Miner::PlanError in the tab's own vocabulary" do
      # The builder reports a machine-readable reason; these sentences are the tab's
      # contract, and are what the status bar shows when ^R cannot start a run.
      miner_spec_store do |store|
        scope = Gori::Scope.load(store)
        view = Gori::Tui::MinerView.new
        view.load("::::", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil,
          Gori::Miner::Config.new)
        engine, err = view.build_engine(false, scope, nil)
        engine.should be_nil
        err.should eq("invalid target — use scheme://host[:port]/path")

        unchecked = Gori::Tui::MinerView.new
        unchecked.load("http://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil,
          Gori::Miner::Config.new(locations: [] of Gori::Miner::Location))
        engine2, err2 = unchecked.build_engine(false, scope, nil)
        engine2.should be_nil
        err2.should eq("no locations selected")

        bad_list = Gori::Tui::MinerView.new
        cfg = Gori::Miner::Config.new
        cfg.user_wordlist = File.tempname("gori-miner-view-missing", ".txt")
        bad_list.load("http://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice, false, nil, cfg)
        engine3, err3 = bad_list.build_engine(false, scope, nil)
        engine3.should be_nil
        err3.should_not be_nil
        err3.not_nil!.should start_with("wordlist error:")
      end
    end

    # #367: the Miner tab dialled straight past the project's HOST OVERRIDES pane, so a
    # host pinned to a staging IP was mined at its real DNS address. `miner-tui.test` has
    # no address (reserved TLD), so reaching the listener at all proves the pin was applied.
    it "applies the project's hostname overrides to the dialled host" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        while conn = server.accept?
          head = Gori::Proxy::Codec::Http1.read_head(conn)
          # Reflect the canary of exactly one candidate name so the mine has a finding.
          hit = head ? String.new(head).match(/[?&]debug=(gq[0-9a-f]{8})/) : nil
          body = hit ? "debug=#{hit[1]} on" : "hello"
          conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
          conn.flush
          conn.close
        end
      end

      begin
        miner_spec_store do |store|
          overrides = Gori::HostOverrides.load(store)
          overrides.add("miner-tui.test", "127.0.0.1").should be_true

          view = Gori::Tui::MinerView.new
          view.load("http://miner-tui.test:#{port}",
            "GET /?q=hi HTTP/1.1\r\nHost: miner-tui.test\r\n\r\n".to_slice, false, nil,
            Gori::Miner::Config.new(locations: [Gori::Miner::Location::Query]))
          engine, err = view.build_engine(false, Gori::Scope.load(store), overrides)
          err.should be_nil

          findings = [] of Gori::Miner::Finding
          errors = 0_i64
          engine.not_nil!.run do |ev|
            case ev
            when Gori::Miner::FindingEvent then findings << ev.finding
            when Gori::Miner::DoneEvent    then errors = ev.progress.errors
            end
          end
          errors.should eq(0)
          findings.map(&.name).should contain("debug")
        end
      ensure
        server.close
      end
    end
  end
end
