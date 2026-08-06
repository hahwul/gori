require "../spec_helper"
require "socket"

private alias Q = Gori::Sequencer

# The Sequencer tab's own option gathering: view state → `Sequencer::PlanOptions` →
# `Plan.build`. `spec/sequencer/plan_spec.cr` covers the builder; what can only be checked
# HERE is the mapping — the TUI arm of #367 was exactly a surface that assembled a correct
# plan out of incomplete options, and a builder-level spec cannot see that.

private def with_store(&)
  path = File.tempname("gori-seqview", ".db")
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

# One-shot loopback HTTP responder; returns {server, port}. The caller closes the server.
private def loopback_responder(reply : String) : {TCPServer, Int32}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    if conn = server.accept?
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      end
      conn << reply
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  {server, port}
end

private def drain(engine : Q::Engine) : Array(Q::Sample)
  samples = [] of Q::Sample
  engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }
  samples
end

private def live_view(target : String, request : String) : Gori::Tui::SequencerView
  view = Gori::Tui::SequencerView.new
  cfg = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie("SID"),
    goal: 1, concurrency: 1)
  cfg.retries = 0
  cfg.timeout = 5.seconds
  view.load(target, request.to_slice, false, nil, cfg)
  view
end

describe Gori::Tui::SequencerView do
  describe "#build_engine host overrides (#367)" do
    it "dials the project's override IP, and cannot reach the host without it" do
      # A/B over ONE responder on ONE port where the `overrides` ARGUMENT is the only
      # difference. Before #367 every TUI workbench tool passed nil here while
      # `gori run sequence` pinned the override, so the same request from the two surfaces
      # went to two different machines with nothing in the UI to say so.
      req = "GET /token HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n"
      server, port = loopback_responder("HTTP/1.1 200 OK\r\nSet-Cookie: SID=tok9; Path=/\r\nContent-Length: 2\r\n\r\nhi")
      begin
        with_store do |store|
          ov = Gori::HostOverrides.load(store)
          ov.add("nonexistent.invalid", "127.0.0.1").should be_true
          scope = Gori::Scope.load(store)

          # Nil first, so the one-shot responder is still unclaimed for the override run.
          engine, err = live_view("http://nonexistent.invalid:#{port}", req).build_engine(false, scope, nil)
          err.should be_nil
          unpinned = drain(engine.not_nil!)
          unpinned.should_not be_empty # a vacuous none? over zero samples proves nothing
          unpinned.none?(&.token).should be_true

          engine, err = live_view("http://nonexistent.invalid:#{port}", req).build_engine(false, scope, ov)
          err.should be_nil
          pinned = drain(engine.not_nil!)
          pinned.size.should eq(1)
          pinned[0].token.should eq("tok9")
        end
      ensure
        server.close
      end
    end
  end

  describe "#build_engine refusals" do
    it "words every PlanError reason in the tab's own vocabulary" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        req = "GET / HTTP/1.1\r\nHost: t.test\r\n\r\n"

        # NoTarget / BadTarget — one hint covers both (the tab has one target field).
        engine, err = live_view("", req).build_engine(true, scope, nil)
        engine.should be_nil
        err.should eq("invalid target — use scheme://host[:port]/path")
        engine, err = live_view("::::", req).build_engine(true, scope, nil)
        engine.should be_nil
        err.should eq("invalid target — use scheme://host[:port]/path")

        # NoTokenLoc — names the config overlay, not a CLI flag.
        view = Gori::Tui::SequencerView.new
        view.load("http://t.test", req.to_slice, false, nil,
          Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: Q::TokenLoc.cookie(" ")))
        engine, err = view.build_engine(true, scope, nil)
        engine.should be_nil
        err.should eq("set a token location first")

        # NoTokens — the manual-paste wording.
        view = Gori::Tui::SequencerView.new
        view.load("", Bytes.empty, false, nil,
          Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["", ""]))
        engine, err = view.build_engine(true, scope, nil)
        engine.should be_nil
        err.should eq("no tokens to analyze — paste some first")
      end
    end
  end

  describe "#build_engine manual mode" do
    it "returns an analyse-only engine that replays the pasted tokens and sends nothing" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        view = Gori::Tui::SequencerView.new
        # A manual session keeps the seed's target and descriptor; neither may turn an
        # offline analysis into a send, and there is no sender for it to use if it tried.
        view.load("http://nonexistent.invalid:1", "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
          false, nil, Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa", "", "bb"]))
        engine, err = view.build_engine(true, scope, nil)
        err.should be_nil
        drain(engine.not_nil!).map(&.token).should eq(["aa", "bb"])
      end
    end
  end

  # The report SUBJECT: what an exported file and an Issue promoted from the same verdict say
  # the run was about. Both renderings read it from here, so a mapping bug would make the two
  # describe the run differently — the one thing having a single renderer is meant to prevent.
  describe "#subject / #target_host" do
    it "names the live-replay origin, the descriptor and the operator's session name" do
      view = Gori::Tui::SequencerView.new
      cfg = Q::Config.new(token_loc: Q::TokenLoc.cookie("SID"))
      view.load("http://example.com:8080", "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, false, nil, cfg)
      view.name = "  login  " # trimmed, so an all-blank name does not become a blank row
      subject = view.subject
      subject.descriptor.should eq("cookie \"SID\"")
      subject.origin.should eq("http://example.com:8080")
      subject.mode.should eq("live replay")
      subject.session.should eq("login")
      view.target_host.should eq("example.com")
    end

    it "carries no origin or host for a manual paste" do
      view = Gori::Tui::SequencerView.new
      cfg = Q::Config.new(mode: Q::Mode::Manual, token_loc: Q::TokenLoc.cookie("SID"),
        manual_tokens: ["aa"])
      # A manual session still holds the seed's target; the subject must not claim the run
      # reached it, and `insert_issue` must get a nil host rather than an unvisited one.
      view.load("http://example.com:8080", Bytes.empty, false, nil, cfg)
      view.subject.origin.should be_nil
      view.subject.mode.should eq("manual")
      view.subject.session.should be_nil
      view.target_host.should be_nil
    end
  end
end
