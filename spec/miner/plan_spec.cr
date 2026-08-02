require "../spec_helper"

private alias M = Gori::Miner

# The builder takes the Outbound as an argument (Layer-1 strictness differs per surface on
# purpose), so the equivalence check uses one ungated decision for all three — the gate is
# not what is under test here, `spec/outbound_spec.cr` owns that.
private def ungated : Gori::Outbound
  ungated_outbound
end

private def with_store(&)
  path = File.tempname("gori-miner-plan", ".db")
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

# `HostOverrides` needs a Store to load from (and to persist edits into).
private def store_backed_overrides(&)
  with_store { |store| yield Gori::HostOverrides.load(store) }
end

# Everything downstream of PlanOptions that a surface could get wrong, flattened so two
# plans can be compared with a single `should eq`. `request` is the decisive field: the
# exact wire bytes the engine mines, after Env expansion and head normalization.
private record Shape,
  scheme : String,
  host : String,
  port : Int32,
  http2 : Bool,
  locations : Array(M::Location),
  buckets : Array(Int32),
  inapplicable : Array(M::Location),
  request : String,
  request_target : String,
  names_count : Int32,
  total_names : Int64,
  concurrency : Int32,
  timeout : Time::Span?,
  max_requests : Int64?

private def shape_of(options : M::PlanOptions) : Shape
  plan = M::Plan.build(options, ungated)
  Shape.new(scheme: plan.origin.scheme, host: plan.origin.host, port: plan.origin.port,
    http2: plan.http2?, locations: plan.config.locations,
    buckets: plan.config.locations.map { |l| plan.config.bucket_for(l) },
    inapplicable: plan.inapplicable, request: String.new(plan.request),
    request_target: plan.request_target, names_count: plan.names.size,
    total_names: plan.total_names, concurrency: plan.config.concurrency,
    timeout: plan.config.timeout, max_requests: plan.config.max_requests)
end

private def config(concurrency : Int32 = 10, buckets : Hash(M::Location, Int32)? = nil) : M::Config
  M::Config.new(concurrency: concurrency, timeout: 7.seconds, max_requests: 500_i64,
    bucket_size: buckets || M::Config::DEFAULT_BUCKETS.dup)
end

# The raw request a captured flow would seed all three surfaces with. `gori run mine
# --request file.txt` reads a hand-authored file that may be LF-only; the TUI's session
# bytes and a captured flow are already CRLF. `Env.expand_wire` normalizes the HEAD (only)
# to CRLF, which is what makes those two inputs the same run.
private LF_RAW = "POST /s?q=hi HTTP/1.1\nHost: t.test\n" \
                 "Content-Type: application/x-www-form-urlencoded\nContent-Length: 5\n\nn=jay"

private CRLF_RAW = "POST /s?q=hi HTTP/1.1\r\nHost: t.test\r\n" \
                   "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nn=jay"

# One logical run, expressed the way each surface's option parser would hand it over.
# `gori run mine` and MCP arrive with a raw request and (usually) no --locations, leaving
# the builder to detect what applies; the TUI arrives with the config overlay's checkbox
# list already resolved. Equivalent inputs, three genuinely different shapes.
private record SurfaceCase,
  name : String,
  origin : Tuple(String, String, Int32),
  http2 : Bool,
  locations : Array(M::Location),
  buckets : Array(Int32),
  cli : Proc(M::PlanOptions),
  mcp : Proc(M::PlanOptions),
  tui : Proc(M::PlanOptions)

private def surface_cases : Array(SurfaceCase)
  [
    SurfaceCase.new(
      name: "auto-detected locations over a flow-seeded form POST",
      origin: {"http", "t.test", 8080}, http2: false,
      locations: [M::Location::Query, M::Location::Form],
      buckets: [128, 128],
      cli: -> { M::PlanOptions.new(LF_RAW, default_target: "http://t.test:8080", config: config) },
      # An agent that sends no `url` (or a blank one) means "use the flow's target".
      mcp: -> { M::PlanOptions.new(CRLF_RAW, default_target: "http://t.test:8080", target: "", config: config) },
      # The config overlay always hands over an explicit checkbox list.
      tui: -> {
        M::PlanOptions.new(CRLF_RAW, target: "http://t.test:8080",
          locations: [M::Location::Query, M::Location::Form], config: config)
      }),
    SurfaceCase.new(
      name: "explicit locations with one bucket size, over h2",
      origin: {"https", "t.test", 443}, http2: true,
      locations: [M::Location::Query, M::Location::Headers],
      buckets: [32, 32],
      cli: -> {
        M::PlanOptions.new(LF_RAW, target: "https://t.test", http2: true,
          locations: [M::Location::Query, M::Location::Headers], bucket: 32, config: config)
      },
      mcp: -> {
        M::PlanOptions.new(CRLF_RAW, default_target: "http://ignored.test", target: "https://t.test",
          http2: true, locations: [M::Location::Query, M::Location::Headers], bucket: 32, config: config)
      },
      # The TUI has no single --bucket knob: its Config carries a per-location hash, which
      # is exactly what --bucket / bucket: spreads over the resolved locations.
      tui: -> {
        M::PlanOptions.new(CRLF_RAW, target: "https://t.test", http2: true,
          locations: [M::Location::Query, M::Location::Headers],
          config: config(buckets: M::Config::DEFAULT_BUCKETS.merge({
            M::Location::Query => 32, M::Location::Headers => 32,
          })))
      }),
  ]
end

describe Gori::Miner::Plan do
  describe "surface equivalence" do
    surface_cases.each do |c|
      it "assembles the same run from CLI, MCP and TUI options — #{c.name}" do
        cli = shape_of(c.cli.call)
        # Pin the shape against literals first: three surfaces agreeing on a WRONG plan
        # would otherwise pass this spec silently.
        {cli.scheme, cli.host, cli.port}.should eq(c.origin)
        cli.http2.should eq(c.http2)
        cli.locations.should eq(c.locations)
        cli.buckets.should eq(c.buckets)
        cli.request.should eq(CRLF_RAW)
        cli.request_target.should eq("/s?q=hi")
        cli.inapplicable.should be_empty

        shape_of(c.mcp.call).should eq(cli)
        shape_of(c.tui.call).should eq(cli)
      end
    end
  end

  it "mines every candidate name at every resolved location" do
    plan = M::Plan.build(surface_cases[0].cli.call, ungated)
    plan.config.locations.should eq([M::Location::Query, M::Location::Form])
    plan.names.should contain("is_admin") # the compiled-in list, not an empty run
    plan.names.uniq.size.should eq(plan.names.size)
    # Query and Form accept every name (only headers/cookies/multipart filter names),
    # so the progress denominator is the whole list once per location.
    plan.total_names.should eq(plan.names.size.to_i64 * 2)
  end

  it "wires the origin, protocol and TLS settings into the dial seam" do
    # Everything below `Shape` reads back off the Config, which a Sender that dropped the
    # value would still report correctly. These read the SENDER, which is what dials.
    store_backed_overrides do |overrides|
      cfg = config
      cfg.timeout = 11.seconds
      plan = M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "https://t.test:8443",
        http2: true, locations: [M::Location::Query], config: cfg, verify: false,
        sni: "sni.test", overrides: overrides), ungated)
      plan.sender.origin.should eq(Gori::Fuzz::Origin.new("https", "t.test", 8443))
      plan.sender.@http2.should be_true
      plan.sender.@verify.should be_false
      plan.sender.@sni.should eq("sni.test")
      plan.sender.@timeout.should eq(11.seconds)
      # The caller's LIVE instance, not a copy: the TUI hands over the session's
      # HostOverrides, which the Project tab keeps editing while a mine runs (#367).
      plan.sender.@overrides.should be(overrides)
    end
  end

  it "merges a user wordlist into the candidate names" do
    path = File.tempname("gori-miner-words", ".txt")
    # Two names the built-in list cannot already hold, plus a comment and a blank line.
    File.write(path, "# a comment\nzzcustomparam\n\nzzotherparam\n")
    cfg = config
    cfg.user_wordlist = path
    plan = M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", config: cfg), ungated)
    plan.names.should contain("zzcustomparam")
    plan.names.should contain("zzotherparam")
    plan.names.should_not contain("# a comment")
    # Exactly two more than the same run without the file — comment/blank lines dropped.
    builtin_only = M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", config: config), ungated)
    plan.names.size.should eq(builtin_only.names.size + 2)
  ensure
    File.delete?(path) if path
  end

  describe "locations" do
    it "detects the applicable defaults when the surface named none" do
      # A GET with no body: Form/Json cannot apply, so the default is query only.
      plan = M::Plan.build(M::PlanOptions.new("GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n",
        target: "http://t.test", config: config), ungated)
      plan.config.locations.should eq([M::Location::Query])
    end

    it "keeps an explicitly named location that does not apply, and reports it" do
      # The CLI warns per location rather than dropping it, so the run still carries it.
      plan = M::Plan.build(M::PlanOptions.new("GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n",
        target: "http://t.test", locations: [M::Location::Query, M::Location::Form],
        config: config), ungated)
      plan.config.locations.should eq([M::Location::Query, M::Location::Form])
      plan.inapplicable.should eq([M::Location::Form])
    end

    it "offers the locations the RUN will see, expanding the request first" do
      # The TUI config overlay renders one checkbox per APPLICABLE location, so a location
      # missed at seed time cannot even be ticked. Deciding that on unexpanded bytes made
      # the overlay and `build` disagree about the same request.
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"BODY", %({"a":1})}]
      Gori::Settings.project_env_vars = [] of {String, String}
      req = ("POST /api HTTP/1.1\r\nHost: t.test\r\n" \
             "Content-Type: application/json\r\nContent-Length: 5\r\n\r\n$BODY").to_slice
      M::Plan.applicable_locations(req).applicable.should contain(M::Location::Json)
      M::Plan.applicable_locations(req).default.should contain(M::Location::Json)
      # Control: the very same bytes, unexpanded, carry no injectable JSON node at all —
      # so this passes only because the expansion happened.
      M::Detect.detect(req).applicable.should_not contain(M::Location::Json)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    it "writes the resolved locations into the caller's live config" do
      # `gori run mine` prints config.locations and the engine reads them, so the
      # resolved set has to be the one instance everybody holds.
      cfg = config
      cfg.locations.should eq([M::Location::Query]) # the Config default, pre-build
      M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", config: cfg), ungated)
      cfg.locations.should eq([M::Location::Query, M::Location::Form])
    end

    it "spreads one bucket size over the RESOLVED locations, not the requested ones" do
      cfg = config
      M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", bucket: 7,
        config: cfg), ungated)
      cfg.bucket_for(M::Location::Query).should eq(7)
      cfg.bucket_for(M::Location::Form).should eq(7) # detected, never named by the caller
      cfg.bucket_for(M::Location::Cookies).should eq(M::Config::DEFAULT_BUCKETS[M::Location::Cookies])
    end
  end

  describe "Env expansion" do
    it "expands the request and the target exactly once" do
      # `$A` resolves to the literal text `$B`. Expanding a second time (which MCP used to
      # do to a flow's target, once in mine_request_source and again in fuzz_origin) would
      # resolve that to "zzz" — so the surviving `$B` IS the assertion.
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"A", "$B"}, {"B", "zzz"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = M::Plan.build(M::PlanOptions.new(
        "GET /p?t=$A HTTP/1.1\r\nHost: t.test\r\n\r\n",
        default_target: "http://$A.test", config: config), ungated)
      plan.origin.host.should eq("$B.test")
      String.new(plan.request).should start_with("GET /p?t=$B HTTP/1.1\r\n")
      # The gate matches on this string, so it has to be the EXPANDED target too.
      plan.request_target.should eq("/p?t=$B")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    it "expands a registered var in the target" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = M::Plan.build(M::PlanOptions.new("GET /a HTTP/1.1\r\nHost: h\r\n\r\n",
        target: "https://$HOST", config: config), ungated)
      {plan.origin.scheme, plan.origin.host, plan.origin.port}.should eq({"https", "api.test", 443})
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # The expansion runs over the BODY too, and this builder framed nothing afterwards — so
    # every request the run sent declared the PRE-expansion length and wrote the post-
    # expansion body. A raw sink counting bytes saw 30 body bytes behind `Content-Length: 19`;
    # the 11 orphans sit in the connection as the front of the next request line. The origin
    # cannot see it (it reads exactly CL bytes), so the run reported `baseline: stable · 0
    # found · 0 errors` over a conversation a strict origin had 400'd. `Repeater::Plan` and
    # `Fuzz::Generator` both re-framed here and only the miner did not.
    it "re-frames Content-Length when expansion GROWS the body" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"id", "99999-EVIL-ENV"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      body = %({"a":"$id","b":"x"})
      plan = M::Plan.build(M::PlanOptions.new(
        "POST /api HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}",
        target: "http://t.test", locations: [M::Location::Json], config: config), ungated)
      wire = String.new(plan.request)
      sent_body = wire.split("\r\n\r\n", 2)[1]
      sent_body.should eq(%({"a":"99999-EVIL-ENV","b":"x"}))
      wire.should contain("Content-Length: #{sent_body.bytesize}\r\n")
      # The pre-fix bytes, spelled out: the token's own width, not the value's.
      wire.should_not contain("Content-Length: #{body.bytesize}\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: a value SHORTER than its token under-fills the declared length instead of
    # overflowing it, which hangs the origin waiting for bytes that never come rather than
    # smuggling. Same defect, opposite sign, and a resync-on-growth-only fix would miss it.
    it "re-frames Content-Length when expansion SHRINKS the body" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"LONGNAME", "z"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      body = %({"a":"$LONGNAME"})
      plan = M::Plan.build(M::PlanOptions.new(
        "POST /api HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}",
        target: "http://t.test", locations: [M::Location::Json], config: config), ungated)
      wire = String.new(plan.request)
      sent_body = wire.split("\r\n\r\n", 2)[1]
      sent_body.should eq(%({"a":"z"}))
      wire.should contain("Content-Length: #{sent_body.bytesize}\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: the overwhelmingly common request has no `$KEY` in its body at all, and it
    # must come out byte-identical — including a deliberately-wrong `Content-Length`, which is
    # the CL-desync probe an operator mines that endpoint to test. `Fuzz::ContentLength.sync`
    # is a RESYNC, so running it unconditionally would silently correct their payload.
    it "leaves a body with no token alone, including a deliberately-wrong Content-Length" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"id", "99999-EVIL-ENV"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      raw = "POST /api HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
            "Content-Length: 99\r\n\r\n{\"a\":\"x\"}"
      plan = M::Plan.build(M::PlanOptions.new(raw, target: "http://t.test",
        locations: [M::Location::Json], config: config), ungated)
      String.new(plan.request).should eq(raw)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: a bodyless request must not GROW a Content-Length, and a head-only
    # expansion must not be mistaken for a body change.
    it "does not add a Content-Length to a request that had none" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"UA", "gori-probe-agent"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = M::Plan.build(M::PlanOptions.new(
        "GET /a?x=1 HTTP/1.1\r\nHost: t.test\r\nUser-Agent: $UA\r\n\r\n",
        target: "http://t.test", locations: [M::Location::Query], config: config), ungated)
      wire = String.new(plan.request)
      wire.should eq("GET /a?x=1 HTTP/1.1\r\nHost: t.test\r\nUser-Agent: gori-probe-agent\r\n\r\n")
      wire.downcase.should_not contain("content-length")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: EVIDENCE never expands, so it must never re-frame either. A captured
    # `Content-Length: 99` over a 2-byte body is the thing the operator captured.
    it "does not touch a captured request's framing on the evidence path" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"id", "99999-EVIL-ENV"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      raw = "POST /api HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
            "Content-Length: 4\r\n\r\n{\"a\":\"$id\"}"
      plan = M::Plan.build(M::PlanOptions.new(raw, evidence: true, target: "http://t.test",
        locations: [M::Location::Json], config: config), ungated)
      String.new(plan.request).should eq(raw)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: the TUI Miner tab holds its editor buffer LF-joined, so the head reaching
    # this builder is bare-LF and `expand_wire` promotes it. A `\r\n\r\n`-only measurement of
    # "did the body change" (which is what `FlowRequest.resync_content_length_if_body_changed`
    # does) silently skips exactly that input; `Env.head_body_boundary` accepts both.
    it "re-frames a bare-LF authored request too" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"id", "99999-EVIL-ENV"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      body = %({"a":"$id"})
      plan = M::Plan.build(M::PlanOptions.new(
        "POST /api HTTP/1.1\nHost: t.test\nContent-Type: application/json\n" \
        "Content-Length: #{body.bytesize}\n\n#{body}",
        target: "http://t.test", locations: [M::Location::Json], config: config), ungated)
      wire = String.new(plan.request)
      sent_body = wire.split("\r\n\r\n", 2)[1]
      sent_body.should eq(%({"a":"99999-EVIL-ENV"}))
      wire.should contain("Content-Length: #{sent_body.bytesize}\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    # COMPLEMENT: chunked framing lives in the BODY, and gori cannot re-chunk without
    # rewriting the operator's framing payload — the rule `Env.content_length_digits` and
    # `Fuzz::ContentLength.sync` both already follow. The head must survive untouched.
    it "leaves a chunked request's head alone even when the body expanded" do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"id", "99999-EVIL-ENV"}]
      Gori::Settings.project_env_vars = [] of {String, String}
      plan = M::Plan.build(M::PlanOptions.new(
        "POST /api HTTP/1.1\r\nHost: t.test\r\nContent-Type: application/json\r\n" \
        "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n9\r\n$id\r\n0\r\n\r\n",
        target: "http://t.test", locations: [M::Location::Json], config: config), ungated)
      String.new(plan.request).should contain("Content-Length: 5\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
    end
  end

  # #367: every CLI/MCP tool passed `overrides:` to its sender and no TUI tool did, so a
  # host pinned in the Project tab's HOST OVERRIDES pane was mined at its real DNS address.
  # The old specs all passed with the argument absent, which is how it went unnoticed.
  it "dials the hostname override's IP instead of resolving the host" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    seen = Channel(String).new(1)
    spawn do
      while conn = server.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen.send(head ? String.new(head) : "")
        conn << "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        conn.flush
        conn.close
      end
    end

    begin
      with_store do |store|
        overrides = Gori::HostOverrides.load(store)
        overrides.add("miner.test", "127.0.0.1").should be_true

        req = "GET /probe HTTP/1.1\r\nHost: miner.test\r\n\r\n"
        opts = ->(ov : Gori::HostOverrides?) do
          M::PlanOptions.new(req, target: "http://miner.test:#{port}",
            locations: [M::Location::Query], config: config, verify: false, overrides: ov)
        end

        pinned = M::Plan.build(opts.call(overrides), ungated)
        result = pinned.sender.send(req.to_slice)
        result.error.should be_nil
        String.new(result.head).should start_with("HTTP/1.1 204")
        # The override changes ONLY the connect target: the Host header still names the
        # original host, which is what the server sees.
        seen.receive.should start_with("GET /probe HTTP/1.1\r\nHost: miner.test\r\n")

        # Control run: the SAME plan without the overrides cannot reach that listener —
        # `miner.test` is a reserved TLD with no address. Without this arm the assertion
        # above would also pass if the override had never been applied.
        bare = M::Plan.build(opts.call(nil), ungated)
        bare.sender.send(req.to_slice).error.should_not be_nil
      end
    ensure
      server.close
    end
  end

  describe "refusals" do
    it "reports NoTarget when neither an explicit nor a flow target is given" do
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, config: config), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::NoTarget)
    end

    it "reports BadTarget with the expanded string a surface quotes back" do
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "::::", config: config), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::BadTarget)
      ex.detail.should eq("::::")
    end

    it "reports NoLocations for an explicitly EMPTY location list" do
      # The TUI's config overlay can leave every checkbox unchecked. That is not the same
      # as "the surface named none" (nil), which auto-detects — mining the query string
      # anyway would ignore what the operator just said.
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test",
          locations: [] of M::Location, config: config), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::NoLocations)
    end

    it "reports Wordlist with the underlying message when the user list is unreadable" do
      cfg = config
      cfg.user_wordlist = File.tempname("gori-miner-missing", ".txt")
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", config: cfg), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::Wordlist)
      ex.detail.should_not be_nil
    end

    it "reports Wordlist when the user list names a DIRECTORY" do
      # A missing path raises File::Error, but reading a directory raises a plain IO::Error
      # — and File::Error is its SUBCLASS, so rescuing only File::Error let this escape
      # `gori run mine` as an unhandled exception with a backtrace.
      dir = File.tempname("gori-miner-dir")
      Dir.mkdir_p(dir)
      cfg = config
      cfg.user_wordlist = dir
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, target: "http://t.test", config: cfg), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::Wordlist)
    ensure
      Dir.delete?(dir) if dir
    end

    it "checks the target, then the locations" do
      # The order every surface's error text inherits: with both wrong, the missing
      # target is what gets reported.
      ex = expect_raises(M::PlanError) do
        M::Plan.build(M::PlanOptions.new(CRLF_RAW, locations: [] of M::Location, config: config), ungated)
      end
      ex.reason.should eq(M::PlanError::Reason::NoTarget)
    end
  end
end
