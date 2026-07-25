require "../spec_helper"
require "socket"

private alias Q = Gori::Sequencer

# The builder takes the Outbound as an argument (Layer-1 strictness differs per surface on
# purpose), so the equivalence check uses one ungated decision for all three — the gate is
# not what is under test here, `spec/outbound_spec.cr` owns that.
private def ungated : Gori::Outbound
  ungated_outbound
end

private def with_ov_store(&)
  path = File.tempname("gori-seqplan", ".db")
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

# One-shot loopback HTTP responder that RECORDS the request head it received; returns
# {server, port, recorded}. The caller closes the server.
private def loopback_responder(reply : String) : {TCPServer, Int32, Array(String)}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = [] of String
  spawn do
    if conn = server.accept?
      head = [] of String
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
        head << line
      end
      seen << head.join("\n")
      conn << reply
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  {server, port, seen}
end

private def drain(engine : Q::Engine) : Array(Q::Sample)
  samples = [] of Q::Sample
  engine.run { |ev| samples << ev.sample if ev.is_a?(Q::SampleEvent) }
  samples
end

# Everything downstream of PlanOptions that a surface could get wrong, flattened so two
# plans can be compared with a single `should eq`. `request` is the decisive field: the
# exact bytes the collection replays, after the builder's one `Env.expand_wire`.
private record Shape,
  scheme : String,
  host : String,
  port : Int32,
  http2 : Bool,
  request : String,
  request_target : String,
  goal : Int32,
  analyse_only : Bool,
  mode : Q::Mode,
  token_loc : Q::TokenLoc,
  concurrency : Int32,
  retries : Int32,
  timeout : Time::Span?,
  max_requests : Int64?

private def shape_of(options : Q::PlanOptions) : Shape
  plan = Q::Plan.build(options, ungated)
  origin = plan.origin!
  Shape.new(scheme: origin.scheme, host: origin.host, port: origin.port, http2: plan.http2?,
    request: String.new(plan.request), request_target: plan.request_target, goal: plan.goal,
    analyse_only: plan.analyse_only?, mode: plan.config.mode, token_loc: plan.config.token_loc,
    concurrency: plan.config.concurrency, retries: plan.config.retries,
    timeout: plan.config.timeout, max_requests: plan.config.max_requests)
end

# A fresh live-replay Config per arm: it is a MUTABLE object the plan reads in place, so
# the three surfaces must not share one instance (that would compare a config with itself).
private def live_config(loc : Q::TokenLoc, goal : Int32, concurrency : Int32 = 1) : Q::Config
  cfg = Q::Config.new(mode: Q::Mode::LiveReplay, token_loc: loc, goal: goal, concurrency: concurrency)
  cfg.retries = 0
  cfg.timeout = 5.seconds
  cfg
end

# The raw request a captured flow would seed all three surfaces with.
private RAW = "POST /login?next=%2Fapp HTTP/1.1\r\nHost: t.test\r\n" \
              "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 13\r\n\r\nuser=jay&p=hi"

# One logical run, expressed the way each surface's option parser would hand it over.
# `gori run sequence` and MCP arrive with a flow's raw bytes plus that flow's target; the
# TUI arrives with the target the operator (or the seed) put in the session. Equivalent
# inputs, three genuinely different shapes.
private record SurfaceCase,
  name : String,
  origin : Tuple(String, String, Int32),
  request_target : String,
  goal : Int32,
  http2 : Bool,
  token_loc : Q::TokenLoc,
  concurrency : Int32,
  cli : Proc(Q::PlanOptions),
  mcp : Proc(Q::PlanOptions),
  tui : Proc(Q::PlanOptions)

private def surface_cases : Array(SurfaceCase)
  cookie = Q::TokenLoc.cookie("SID")
  regex = Q::TokenLoc.new(Q::ExtractKind::Regex, %("csrf":"([a-f0-9]+)"))
  [
    SurfaceCase.new(
      name: "cookie collection over a flow-seeded request",
      origin: {"http", "t.test", 8080}, request_target: "/login?next=%2Fapp", goal: 250,
      http2: false, token_loc: cookie, concurrency: 1,
      cli: -> { Q::PlanOptions.new(RAW.to_slice, default_target: "http://t.test:8080",
        config: live_config(cookie, 250), verify: false) },
      # An agent that sends no `url` (or a blank one) means "use the flow's target".
      mcp: -> { Q::PlanOptions.new(RAW.to_slice, default_target: "http://t.test:8080", target: "",
        config: live_config(cookie, 250), verify: false) },
      tui: -> { Q::PlanOptions.new(RAW.to_slice, target: "http://t.test:8080",
        config: live_config(cookie, 250), verify: false) }),
    SurfaceCase.new(
      name: "regex collection over h2, explicit target beating the flow's",
      origin: {"https", "api.t.test", 443}, request_target: "/login?next=%2Fapp", goal: 40,
      http2: true, token_loc: regex, concurrency: 4,
      cli: -> { Q::PlanOptions.new(RAW.to_slice, default_target: "http://ignored.test",
        target: "https://api.t.test", http2: true, config: live_config(regex, 40, 4), verify: false) },
      mcp: -> { Q::PlanOptions.new(RAW.to_slice, default_target: "http://ignored.test",
        target: "https://api.t.test", http2: true, config: live_config(regex, 40, 4), verify: false) },
      tui: -> { Q::PlanOptions.new(RAW.to_slice, target: "https://api.t.test", http2: true,
        config: live_config(regex, 40, 4), verify: false) }),
  ]
end

describe Gori::Sequencer::Plan do
  describe "surface equivalence" do
    surface_cases.each do |c|
      it "assembles the same collection from CLI, MCP and TUI options — #{c.name}" do
        cli = shape_of(c.cli.call)
        # Pin the shape against literals FIRST, field by field: three surfaces agreeing on a
        # WRONG plan would pass an arm-to-arm comparison silently, and the config-derived
        # fields (mode/token_loc/concurrency/…) are read back off the very instance each arm
        # passed in — so comparing arms alone says nothing about them at all.
        {cli.scheme, cli.host, cli.port}.should eq(c.origin)
        cli.request_target.should eq(c.request_target)
        cli.request.should eq(RAW)
        cli.goal.should eq(c.goal)
        cli.http2.should eq(c.http2)
        cli.token_loc.should eq(c.token_loc)
        cli.concurrency.should eq(c.concurrency)
        cli.mode.should eq(Q::Mode::LiveReplay)
        cli.analyse_only.should be_false

        shape_of(c.mcp.call).should eq(cli)
        shape_of(c.tui.call).should eq(cli)
      end
    end
  end

  it "reads the config instance the caller owns, not a copy of it" do
    # The TUI's config overlay edits ONE `Config` in place while a tab is open, so a plan
    # that copied it would run yesterday's goal/descriptor. Identity, not equality.
    cfg = live_config(Q::TokenLoc.cookie("SID"), 7)
    plan = Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, target: "http://t.test",
      config: cfg, verify: false), ungated)
    plan.config.should be(cfg)
    cfg.goal = 9
    plan.goal.should eq(9)
  end

  describe "Env expansion" do
    it "expands the request and the target exactly once" do
      # `$A` resolves to the literal text `$B`. Expanding a second time (which the CLI and
      # MCP source readers did on top of this one, and which the TUI's seed path did to a
      # pasted request) would resolve that to "zzz" — so the surviving `$B` IS the assertion.
      prefix = Gori::Settings.env_prefix
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"A", "$B"}, {"B", "zzz"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = Q::Plan.build(Q::PlanOptions.new(
        "GET /t?v=$A HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice,
        default_target: "http://$A.test", config: live_config(Q::TokenLoc.cookie("SID"), 5),
        verify: false), ungated)
      plan.origin!.host.should eq("$B.test")
      String.new(plan.request).should eq("GET /t?v=$B HTTP/1.1\r\nHost: t.test\r\n\r\n")
      plan.request_target.should eq("/t?v=$B")
    ensure
      Gori::Settings.env_prefix = prefix || "$"
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    it "normalizes a bare-LF head to CRLF (the TUI used to skip expand_wire entirely)" do
      plan = Q::Plan.build(Q::PlanOptions.new(
        "GET /p HTTP/1.1\nHost: t.test\n\nbody\nkeeps\nLF".to_slice, target: "http://t.test",
        config: live_config(Q::TokenLoc.cookie("SID"), 5), verify: false), ungated)
      # Head normalized, BODY left byte-for-byte (a body's LFs are payload, not framing).
      String.new(plan.request).should eq("GET /p HTTP/1.1\r\nHost: t.test\r\n\r\nbody\nkeeps\nLF")
    end
  end

  describe "analyse-only (manual) plans" do
    it "carries no origin and no sender, and replays the pasted tokens" do
      cfg = Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa", "bb", "", "cc"])
      plan = Q::Plan.build(Q::PlanOptions.new(config: cfg), ungated)
      plan.analyse_only?.should be_true
      plan.origin.should be_nil
      plan.request.size.should eq(0)
      plan.request_target.should eq("")
      plan.goal.should eq(3) # non-blank tokens only
      drain(plan.engine).map(&.token).should eq(["aa", "bb", "cc"])
    end

    it "raises from origin! rather than handing a live surface a fake origin" do
      cfg = Q::Config.new(mode: Q::Mode::Manual, manual_tokens: ["aa"])
      plan = Q::Plan.build(Q::PlanOptions.new(config: cfg), ungated)
      expect_raises(Gori::Error) { plan.origin! }
    end

    it "cannot be turned into a live run by flipping the config it shares with its caller" do
      # `config` is the caller's live instance, so a consumer CAN flip mode after the plan is
      # built. With no sender there is nothing to reach for: the engine must report a clean
      # error and send nothing. This is what makes "manual carries no backend" safe — a
      # throwaway `Sender` pointed at http://localhost:80 (what this replaced) would instead
      # have dialled a real socket here.
      cfg = Q::Config.new(mode: Q::Mode::Manual, token_loc: Q::TokenLoc.cookie("SID"),
        goal: 3, manual_tokens: ["aa"])
      plan = Q::Plan.build(Q::PlanOptions.new(config: cfg), ungated)
      cfg.mode = Q::Mode::LiveReplay
      errors = [] of String
      samples = [] of Q::Sample
      plan.engine.run do |ev|
        errors << ev.message if ev.is_a?(Q::ErrorEvent)
        samples << ev.sample if ev.is_a?(Q::SampleEvent)
      end
      errors.size.should eq(1)
      errors[0].should contain("send backend")
      samples.should be_empty # nothing was attempted, not even a failed send
    end

    it "ignores the target and descriptor a manual session may still hold" do
      # The TUI keeps the seed's target/descriptor when the mode is flipped to manual; none
      # of it may turn a no-network analysis into a send.
      cfg = Q::Config.new(mode: Q::Mode::Manual, token_loc: Q::TokenLoc.cookie(""),
        manual_tokens: ["aa"])
      plan = Q::Plan.build(Q::PlanOptions.new("GET / HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice,
        target: "::::", config: cfg), ungated)
      plan.analyse_only?.should be_true
    end
  end

  describe "refusals" do
    cookie = Q::TokenLoc.cookie("SID")

    it "reports NoTarget when neither an explicit nor a flow target is given" do
      ex = expect_raises(Q::PlanError) do
        Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, config: live_config(cookie, 5)), ungated)
      end
      ex.reason.should eq(Q::PlanError::Reason::NoTarget)
    end

    it "reports BadTarget with the expanded string a surface quotes back" do
      ex = expect_raises(Q::PlanError) do
        Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, target: "::::",
          config: live_config(cookie, 5)), ungated)
      end
      ex.reason.should eq(Q::PlanError::Reason::BadTarget)
      ex.detail.should eq("::::")
    end

    it "reports NoTokenLoc for a blank selector on a kind that needs one" do
      [Q::ExtractKind::Cookie, Q::ExtractKind::Header, Q::ExtractKind::Regex,
       Q::ExtractKind::JsonPath].each do |kind|
        ex = expect_raises(Q::PlanError) do
          Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, target: "http://t.test",
            config: live_config(Q::TokenLoc.new(kind, " "), 5)), ungated)
        end
        ex.reason.should eq(Q::PlanError::Reason::NoTokenLoc)
      end
    end

    it "accepts a Position descriptor with no selector (its offsets ARE the selector)" do
      plan = Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, target: "http://t.test",
        config: live_config(Q::TokenLoc.new(Q::ExtractKind::Position, "", 4, 20), 5)), ungated)
      plan.origin!.host.should eq("t.test")
    end

    it "reports NoTokens for a manual plan with nothing to analyze" do
      # Empty and all-empty, matching what the engine counts as collectable. A
      # whitespace-only entry is a real token here — all three surfaces strip and reject
      # blanks while parsing their own input, so one never reaches the builder.
      [[] of String, ["", ""]].each do |tokens|
        ex = expect_raises(Q::PlanError) do
          Q::Plan.build(Q::PlanOptions.new(
            config: Q::Config.new(mode: Q::Mode::Manual, manual_tokens: tokens)), ungated)
        end
        ex.reason.should eq(Q::PlanError::Reason::NoTokens)
      end
    end

    it "checks the target before the token descriptor" do
      # The order every surface's error text inherits: with both wrong, the target is what
      # gets reported (what the TUI and `gori run sequence` already did).
      ex = expect_raises(Q::PlanError) do
        Q::Plan.build(Q::PlanOptions.new(RAW.to_slice, config: live_config(Q::TokenLoc.cookie(""), 5)), ungated)
      end
      ex.reason.should eq(Q::PlanError::Reason::NoTarget)
    end
  end

  describe "host overrides (#367)" do
    it "dials the project's override IP, and cannot reach the host without it" do
      # A/B over ONE responder on ONE port, where `overrides:` is the ONLY difference —
      # a control that also changed the port would be explained just as well by a refused
      # connection, and would not isolate the override as the cause.
      req = "GET /token HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n".to_slice
      server, port, seen = loopback_responder("HTTP/1.1 200 OK\r\nSet-Cookie: SID=abc123; Path=/\r\nContent-Length: 2\r\n\r\nhi")
      begin
        with_ov_store do |store|
          ov = Gori::HostOverrides.load(store)
          ov.add("nonexistent.invalid", "127.0.0.1").should be_true
          options = ->(overrides : Gori::HostOverrides?) {
            Q::PlanOptions.new(req, target: "http://nonexistent.invalid:#{port}",
              config: live_config(Q::TokenLoc.cookie("SID"), 1), verify: false, overrides: overrides)
          }

          # B first, so the one-shot responder is still unclaimed for A: no overrides is
          # exactly what every TUI workbench tool passed before #367, and it is why the gap
          # was invisible — nothing else about the run changes.
          unpinned = drain(Q::Plan.build(options.call(nil), ungated).engine)
          unpinned.should_not be_empty # a vacuous none?/all? over zero samples proves nothing
          unpinned.none?(&.token).should be_true
          unpinned.compact_map(&.error).size.should eq(unpinned.size)

          pinned = drain(Q::Plan.build(options.call(ov), ungated).engine)
          pinned.size.should eq(1)
          pinned[0].token.should eq("abc123")
          # The bytes reached the loopback responder unchanged, Host header included: an
          # override changes the connect IP only.
          seen.first.should contain("GET /token HTTP/1.1")
          seen.first.should contain("Host: nonexistent.invalid")
        end
      ensure
        server.close
      end
    end
  end
end
