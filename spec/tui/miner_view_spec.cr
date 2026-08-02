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

# PROVENANCE, on the Miner → Repeater handoff (space ▸ Send to Repeater from a finding).
#
# The Miner ENGINE is byte-clean — it holds the session request as `Bytes` and puts a
# latin-1/binary field on the wire untouched, which a live mine against a reflecting origin
# confirms. This is the other road out of the same evidence: the seed the Repeater tab opens
# with, which ^R then RE-SENDS. It used to be built with `String.new(injected).scrub` plus a
# CRLF→LF collapse, so on the live mine of `q=hi&bin=<ff fe 01 02>&z=1`:
#
#   miner sent  71 3d 68 69 26 62 69 6e 3d ff fe 01 02 26 7a 3d 31 26 64 65 62 75 67 3d …
#   repeater    71 3d 68 69 26 62 69 6e 3d ef bf bd ef bf bd 01 02 26 7a 3d 31 26 …
#
# — four bytes of growth under the `Content-Length: 34` the seed still carried.
#
# NOTE: these are REGRESSION guards, not control-red evidence. `repeater_seed_for` is
# extracted here (mirroring `FuzzerController.repeater_seed_for`, which exists for exactly
# this reason), so at the base commit the examples would not compile. The behaviour control
# is the live mine above plus the recorded wire bytes quoted in the fix.
describe "Gori::Tui::MinerController Miner → Repeater seed" do
  bin = Bytes[0xFF, 0xFE, 0x01, 0x02]
  body = String.build do |io|
    io << "q=hi&bin="
    io.write(bin)
    io << "&z=1"
  end
  req = String.build do |io|
    io << "POST /m HTTP/1.1\r\nHost: h.test\r\n"
    io << "Content-Type: application/x-www-form-urlencoded\r\n"
    io << "Content-Length: #{body.bytesize}\r\n\r\n"
    io << body
  end.to_slice

  finding = Gori::Miner::Finding.new("debug", Gori::Miner::Location::Form,
    Gori::Miner::Evidence::Reflection, Gori::Miner::Confidence::Confirmed,
    "gq22fbb1be", 200, 10_i64)

  loaded = -> do
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", req, false, nil, Gori::Miner::Config.new)
    view
  end

  it "hands the Repeater the bytes the miner injected, not a scrubbed copy" do
    view = loaded.call
    injected = view.request_with_finding(finding)
    seed = Gori::Tui::MinerController.repeater_seed_for(view, finding)
    # Byte-for-byte, no `should include?` — the fixture is deliberately not valid UTF-8.
    seed.request_text.to_slice.to_a.should eq(injected.to_a)
    sb = seed.request_text.to_slice
    (0..(sb.size - bin.size)).any? { |i| sb[i, bin.size] == bin }.should be_true
    # `.scrub` turned each of those two bytes into the three of U+FFFD, so the seed's body
    # ran four bytes past the Content-Length the seed itself still carried.
    head, seeded_body = seed.request_text.split("\r\n\r\n", 2)
    head.should contain("Content-Length: #{seeded_body.bytesize}")
    seed.label.should eq("debug (form)")
  end

  it "keeps the head's CRLFs instead of collapsing them to LF" do
    seed = Gori::Tui::MinerController.repeater_seed_for(loaded.call, finding)
    seed.request_text.should start_with("POST /m HTTP/1.1\r\nHost: h.test\r\n")
    seed.request_text.should_not contain("\n\n") # a bare-LF head terminator
  end

  it "keeps a body's OWN CRLF, which the collapse used to flatten" do
    crlf_body = "a=1\r\nb=2"
    raw = "POST /m HTTP/1.1\r\nHost: h.test\r\nContent-Type: text/plain\r\n" \
          "Content-Length: #{crlf_body.bytesize}\r\n\r\n#{crlf_body}"
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", raw.to_slice, false, nil, Gori::Miner::Config.new)
    hdr = Gori::Miner::Finding.new("X-Debug", Gori::Miner::Location::Headers,
      Gori::Miner::Evidence::Status, Gori::Miner::Confidence::Confirmed, nil, 200, 1_i64)
    seed = Gori::Tui::MinerController.repeater_seed_for(view, hdr)
    seed.request_text.should end_with("a=1\r\nb=2")
  end

  # COMPLEMENT: a valid-UTF-8 finding keeps every character it always had — `.scrub` was a
  # no-op on it and stays one. Its head's CRLFs DO survive now where they used to be
  # collapsed; that is the deliberate half of this change, and it matches what the Fuzzer's
  # seed and History→Repeater (`origin_form_text`) already hand over.
  it "carries a valid-UTF-8 session request through unchanged, byte for byte" do
    utf8_body = "q=관리자&z=1"
    raw = "POST /m HTTP/1.1\r\nHost: h.test\r\n" \
          "Content-Type: application/x-www-form-urlencoded\r\n" \
          "Content-Length: #{utf8_body.bytesize}\r\n\r\n#{utf8_body}"
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", raw.to_slice, false, nil, Gori::Miner::Config.new)
    seed = Gori::Tui::MinerController.repeater_seed_for(view, finding)
    seed.request_text.should contain("q=관리자")
    seed.request_text.should contain("debug=gq22fbb1be")
    seed.request_text.to_slice.to_a.should eq(view.request_with_finding(finding).to_a)
  end
end
