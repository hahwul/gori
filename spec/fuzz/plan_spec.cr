require "../spec_helper"

private alias F = Gori::Fuzz

# The builder takes the Outbound as an argument (Layer-1 strictness differs per surface on
# purpose), so the equivalence check uses one ungated decision for all three — the gate is
# not what is under test here, `spec/outbound_spec.cr` owns that.
private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# Everything downstream of PlanOptions that a surface could get wrong, flattened so two
# plans can be compared with a single `should eq`. `jobs` is the decisive field: the exact
# request bytes, payloads and Sniper position of EVERY candidate the run would send.
private record Shape,
  scheme : String,
  host : String,
  port : Int32,
  http2 : Bool,
  positions : Int32,
  total : Int64?,
  request_target : String,
  mode : F::Mode,
  concurrency : Int32,
  keep_bodies : Symbol,
  auto_calibrate : Bool,
  match_status : String?,
  jobs : Array({Int64, Array(String), Int32?, String})

private def shape_of(options : F::PlanOptions) : Shape
  plan = F::Plan.build(options, ungated)
  jobs = [] of {Int64, Array(String), Int32?, String}
  plan.generator.each { |j| jobs << {j.index, j.payloads, j.position, String.new(j.bytes)} }
  Shape.new(scheme: plan.origin.scheme, host: plan.origin.host, port: plan.origin.port,
    http2: plan.http2?, positions: plan.template.position_count, total: plan.total,
    request_target: plan.request_target, mode: plan.config.mode,
    concurrency: plan.config.concurrency, keep_bodies: plan.config.keep_bodies,
    auto_calibrate: plan.matcher.auto_calibrate?, match_status: plan.matcher.match_status,
    jobs: jobs)
end

private def matcher(status : String?) : F::Matcher
  m = F::Matcher.new(keep_bodies: :none)
  m.match_status = status
  m
end

# The raw request a captured flow would seed all three surfaces with.
private RAW = "POST /s?q=hi&p=2 HTTP/1.1\r\nHost: t.test\r\n" \
              "Cookie: sid=abc\r\nContent-Type: application/x-www-form-urlencoded\r\n" \
              "Content-Length: 5\r\n\r\nn=jay"

# What `^A params` leaves in the TUI editor — the auto_mark output, pinned as a LITERAL so
# the TUI arm of the comparison is an independent statement and not `auto_mark` checked
# against itself.
private AUTO_MARKED = "POST /s?q=§hi§&p=§2§ HTTP/1.1\r\nHost: t.test\r\n" \
                      "Cookie: sid=§abc§\r\nContent-Type: application/x-www-form-urlencoded\r\n" \
                      "Content-Length: 5\r\n\r\nn=§jay§"

private MARK_RAW    = "GET /find?term=VAL&page=VAL HTTP/1.1\r\nHost: t.test\r\n\r\n"
private MARK_MARKED = "GET /find?term=§VAL§&page=§VAL§ HTTP/1.1\r\nHost: t.test\r\n\r\n"

# One logical run, expressed the way each surface's option parser would hand it over.
# `gori run fuzz` and MCP arrive with the flow's raw text plus an --auto / marks
# instruction; the TUI arrives with text the editor already marked, and a target the
# operator typed. Equivalent inputs, three genuinely different shapes.
private record SurfaceCase,
  name : String,
  positions : Int32,
  total : Int64,
  origin : Tuple(String, String, Int32),
  cli : Proc(F::PlanOptions),
  mcp : Proc(F::PlanOptions),
  tui : Proc(F::PlanOptions)

private def surface_cases : Array(SurfaceCase)
  [
    SurfaceCase.new(
      name: "sniper over an auto-marked, flow-seeded request",
      positions: 4, total: 12_i64, origin: {"http", "t.test", 8080},
      cli: -> {
        F::PlanOptions.new(RAW, default_target: "http://t.test:8080", auto_mark: true,
          sources: [F::InlineList.new(%w[a b c])] of F::PayloadSource,
          config: F::Config.new(mode: F::Mode::Sniper, concurrency: 20, keep_bodies: :none),
          matcher: matcher("200"), verify: false)
      },
      # An agent that sends no `url` (or a blank one) means "use the flow's target".
      mcp: -> {
        F::PlanOptions.new(RAW, default_target: "http://t.test:8080", target: "", auto_mark: true,
          sources: [F::InlineList.new(%w[a b c])] of F::PayloadSource,
          config: F::Config.new(mode: F::Mode::Sniper, concurrency: 20, keep_bodies: :none),
          matcher: matcher("200"), verify: false)
      },
      tui: -> {
        F::PlanOptions.new(AUTO_MARKED, target: "http://t.test:8080",
          sources: [F::InlineList.new(%w[a b c])] of F::PayloadSource,
          config: F::Config.new(mode: F::Mode::Sniper, concurrency: 20, keep_bodies: :none),
          matcher: matcher("200"), verify: false)
      }),
    SurfaceCase.new(
      name: "cluster bomb over a --mark token, with a processing pipeline",
      positions: 2, total: 6_i64, origin: {"https", "t.test", 443},
      cli: -> {
        F::PlanOptions.new(MARK_RAW, target: "https://t.test", marks: ["VAL"], http2: true,
          sources: [F::InlineList.new(%w[x y]), F::NumberRange.new(1_i64, 3_i64)] of F::PayloadSource,
          processors: [F::Prefix.new("<")] of F::Processor,
          config: F::Config.new(mode: F::Mode::ClusterBomb, concurrency: 4, keep_bodies: :none),
          matcher: matcher(nil), verify: false)
      },
      mcp: -> {
        F::PlanOptions.new(MARK_RAW, default_target: "http://ignored.test", target: "https://t.test",
          marks: ["VAL"], http2: true,
          sources: [F::InlineList.new(%w[x y]), F::NumberRange.new(1_i64, 3_i64)] of F::PayloadSource,
          processors: [F::Prefix.new("<")] of F::Processor,
          config: F::Config.new(mode: F::Mode::ClusterBomb, concurrency: 4, keep_bodies: :none),
          matcher: matcher(nil), verify: false)
      },
      tui: -> {
        F::PlanOptions.new(MARK_MARKED, target: "https://t.test", http2: true,
          sources: [F::InlineList.new(%w[x y]), F::NumberRange.new(1_i64, 3_i64)] of F::PayloadSource,
          processors: [F::Prefix.new("<")] of F::Processor,
          config: F::Config.new(mode: F::Mode::ClusterBomb, concurrency: 4, keep_bodies: :none),
          matcher: matcher(nil), verify: false)
      }),
  ]
end

describe Gori::Fuzz::Plan do
  describe "surface equivalence" do
    surface_cases.each do |c|
      it "assembles the same run from CLI, MCP and TUI options — #{c.name}" do
        cli = shape_of(c.cli.call)
        # Pin the shape against literals first: three surfaces agreeing on a WRONG plan
        # would otherwise pass this spec silently.
        {cli.scheme, cli.host, cli.port}.should eq(c.origin)
        cli.positions.should eq(c.positions)
        cli.total.should eq(c.total)
        cli.jobs.size.should eq(c.total)

        shape_of(c.mcp.call).should eq(cli)
        shape_of(c.tui.call).should eq(cli)
      end
    end
  end

  it "renders the payload into every marked position (sniper, one at a time)" do
    plan = F::Plan.build(surface_cases[0].cli.call, ungated)
    jobs = [] of F::Job
    plan.generator.each { |j| jobs << j }
    # Position 0 is the `q` query value; the other three keep their template defaults.
    String.new(jobs[0].bytes).should start_with("POST /s?q=a&p=2 HTTP/1.1\r\n")
    jobs[0].position.should eq(0)
    # Position 3 is the body value, so Content-Length is resynced from 5 ("n=jay") to 3.
    body_job = jobs.find! { |j| j.position == 3 }
    String.new(body_job.bytes).should end_with("\r\n\r\nn=a")
    String.new(body_job.bytes).should contain("Content-Length: 3\r\n")
  end

  it "applies the processing pipeline to every payload set" do
    plan = F::Plan.build(surface_cases[1].cli.call, ungated)
    payloads = [] of Array(String)
    plan.generator.each { |j| payloads << j.payloads }
    payloads.should eq([["<x", "<1"], ["<x", "<2"], ["<x", "<3"],
                        ["<y", "<1"], ["<y", "<2"], ["<y", "<3"]])
  end

  describe "Env expansion" do
    it "expands the template and the target exactly once" do
      # `$A` resolves to the literal text `$B`. Expanding a second time (which
      # `gori run fuzz` used to do to a flow's target, and MCP to both) would resolve
      # that to "zzz" — so the surviving `$B` IS the assertion.
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"A", "$B"}, {"B", "zzz"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = F::Plan.build(F::PlanOptions.new(
        "GET /p?x=§v§&t=$A HTTP/1.1\r\nHost: t.test\r\n\r\n",
        default_target: "http://$A.test",
        sources: [F::InlineList.new(["1"])] of F::PayloadSource,
        config: F::Config.new(keep_bodies: :none), verify: false), ungated)
      plan.origin.host.should eq("$B.test")
      jobs = [] of F::Job
      plan.generator.each { |j| jobs << j }
      String.new(jobs[0].bytes).should start_with("GET /p?x=1&t=$B HTTP/1.1\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    it "expands a registered var in the target" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = F::Plan.build(F::PlanOptions.new(
        "GET /?x=§v§ HTTP/1.1\r\nHost: h\r\n\r\n", target: "https://$HOST",
        sources: [F::InlineList.new(["1"])] of F::PayloadSource,
        config: F::Config.new(keep_bodies: :none), verify: false), ungated)
      {plan.origin.scheme, plan.origin.host, plan.origin.port}.should eq({"https", "api.test", 443})
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end
  end

  it "takes the request target from the UNMARKED first line" do
    # The gate matches this string against the scope rules, so a §…§ byte must never
    # reach it — auto_mark would otherwise turn `/s?q=hi` into `/s?q=§hi§`.
    plan = F::Plan.build(surface_cases[0].cli.call, ungated)
    plan.request_target.should eq("/s?q=hi&p=2")
  end

  it "counts each --mark token's occurrences so a surface can warn about a broad token" do
    plan = F::Plan.build(surface_cases[1].cli.call, ungated)
    plan.mark_matches.should eq([{"VAL", 2}])
  end

  it "syncs the matcher's auto-calibration flag from the config" do
    m = F::Matcher.new(keep_bodies: :none)
    m.auto_calibrate?.should be_false
    plan = F::Plan.build(F::PlanOptions.new(
      "GET /?x=§v§ HTTP/1.1\r\nHost: t.test\r\n\r\n", target: "http://t.test",
      sources: [F::InlineList.new(["1"])] of F::PayloadSource, matcher: m,
      config: F::Config.new(auto_calibrate: true, keep_bodies: :none), verify: false), ungated)
    plan.matcher.auto_calibrate?.should be_true
    m.auto_calibrate?.should be_true # the caller's live instance, not a copy
  end

  describe "refusals" do
    marked = "GET /?x=§v§ HTTP/1.1\r\nHost: t.test\r\n\r\n"
    payload = [F::InlineList.new(["1"])] of F::PayloadSource

    it "reports NoPositions for a template with no markers" do
      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new("GET / HTTP/1.1\r\nHost: t.test\r\n\r\n",
          target: "http://t.test", sources: payload), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::NoPositions)
    end

    it "reports NoTarget when neither an explicit nor a flow target is given" do
      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new(marked, sources: payload), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::NoTarget)
    end

    it "reports BadTarget with the expanded string a surface quotes back" do
      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new(marked, target: "::::", sources: payload), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::BadTarget)
      ex.detail.should eq("::::")
    end

    it "reports NoPayloads when no set was configured" do
      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new(marked, target: "http://t.test"), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::NoPayloads)
    end

    it "checks positions, then the target, then the payloads" do
      # The order every surface's error text inherits: with all three wrong, the
      # template's missing positions is what gets reported.
      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new("GET / HTTP/1.1\r\nHost: t.test\r\n\r\n"), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::NoPositions)

      ex = expect_raises(F::PlanError) do
        F::Plan.build(F::PlanOptions.new(marked), ungated)
      end
      ex.reason.should eq(F::PlanError::Reason::NoTarget)
    end
  end
end
