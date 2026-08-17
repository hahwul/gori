require "../spec_helper"

private alias R = Gori::Repeater

# A field-native field list carrying the shapes h1 head text cannot hold: a duplicate
# `:method`, a `:scheme` disagreeing with the connection, an operator-chosen `:authority`.
FN_FIELDS = [{":method", "GET"}, {":method", "POST"}, {":path", "/fn"},
             {":scheme", "http"}, {":authority", "spoofed"}]

# The builder takes the Outbound as an argument (Layer-1 strictness differs per surface on
# purpose), so the equivalence check uses one ungated decision for all three — the gate is
# not what is under test here, `spec/outbound_spec.cr` owns that.
private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# Everything downstream of PlanOptions that a surface could get wrong, flattened so two
# plans can be compared with a single `should eq`. `wires` is the decisive field: the exact
# bytes that would go on the wire.
private record Shape,
  scheme : String,
  host : String,
  port : Int32,
  http2 : Bool,
  websocket : Bool,
  sni : String?,
  wires : Array(String)

# `Settings` env vars are a process-wide singleton — set, yield, always restore. `env_prefix`
# is pinned too: another spec file sets it and does not restore it, so leaving it to whatever
# ran first would make these expansions depend on suite ordering.
private def with_env_vars(pairs : Array({String, String}), &)
  saved_global = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = pairs
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  yield
ensure
  Gori::Settings.env_vars = saved_global || [] of {String, String}
  Gori::Settings.project_env_vars = saved_project || [] of {String, String}
  Gori::Settings.env_prefix = saved_prefix || "$"
end

private def shape_of(options : R::PlanOptions) : Shape
  plan = R::Plan.build(options, ungated)
  Shape.new(scheme: plan.scheme, host: plan.host, port: plan.port, http2: plan.http2?,
    websocket: plan.websocket?, sni: plan.sni, wires: plan.requests.map { |b| String.new(b) })
end

# The stored wire of a saved repeater SESSION, with a deliberately-stale Content-Length so
# the auto-CL knob is observable.
private SESSION_RAW = "POST /login HTTP/1.1\r\nHost: t.test\r\nContent-Length: 999\r\n\r\nu=jay"
# What the SAME request looks like once the builder has framed it (CL synced to the body).
private SESSION_SYNCED = "POST /login HTTP/1.1\r\nHost: t.test\r\nContent-Length: 5\r\n\r\nu=jay"

private WS_UPGRADE = "GET /socket HTTP/1.1\r\nHost: t.test\r\nUpgrade: websocket\r\n" \
                     "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n\r\n"

# One logical send, expressed the way each surface's option parser would hand it over.
# `gori run repeater send` and MCP `send_request(repeater_id:)` arrive with the session row's
# RAW stored bytes; the TUI arrives with bytes its editor already expanded and length-synced,
# and a target the operator typed. Equivalent inputs, three genuinely different shapes.
# `expected` is what makes this more than an agreement check: three surfaces converging on the
# same WRONG plan would otherwise pass silently, so the CLI arm is pinned to a literal Shape
# before the other two are compared against it.
private record SurfaceCase,
  name : String,
  expected : Shape,
  cli : Proc(R::PlanOptions),
  mcp : Proc(R::PlanOptions),
  tui : Proc(R::PlanOptions)

private def surface_cases : Array(SurfaceCase)
  [
    SurfaceCase.new(
      name: "a saved session replay with auto-Content-Length on",
      expected: Shape.new(scheme: "https", host: "t.test", port: 443, http2: false,
        websocket: false, sni: nil, wires: [SESSION_SYNCED]),
      cli: -> { R::PlanOptions.new([SESSION_RAW.to_slice], default_target: "https://t.test") },
      # MCP never sets `target:` for a repeater send — `send_plan_options` only ever supplies
      # `default_target:` (from the session/flow row) or a pre-resolved `origin:`.
      mcp: -> { R::PlanOptions.new([SESSION_RAW.to_slice], default_target: "https://t.test") },
      tui: -> {
        R::PlanOptions.new([SESSION_SYNCED.to_slice], expand_request: false,
          auto_content_length: false, target: "https://t.test")
      }),
    SurfaceCase.new(
      name: "a WebSocket upgrade session, which never gets a Content-Length pass",
      expected: Shape.new(scheme: "https", host: "t.test", port: 443, http2: false,
        websocket: true, sni: nil, wires: [WS_UPGRADE]),
      cli: -> { R::PlanOptions.new([WS_UPGRADE.to_slice], default_target: "wss://t.test") },
      mcp: -> { R::PlanOptions.new([WS_UPGRADE.to_slice], default_target: "wss://t.test") },
      tui: -> {
        R::PlanOptions.new([WS_UPGRADE.to_slice], expand_request: false,
          auto_content_length: false, target: "wss://t.test")
      }),
    SurfaceCase.new(
      name: "an h2 replay to a non-default port with an SNI override",
      expected: Shape.new(scheme: "https", host: "t.test", port: 8443, http2: true,
        websocket: false, sni: "front.test", wires: [SESSION_SYNCED]),
      cli: -> {
        R::PlanOptions.new([SESSION_RAW.to_slice], default_target: "https://ignored.test",
          target: "https://t.test:8443", http2: true, sni: "front.test")
      },
      mcp: -> {
        R::PlanOptions.new([SESSION_RAW.to_slice], target: "https://t.test:8443",
          http2: true, sni: "front.test")
      },
      tui: -> {
        R::PlanOptions.new([SESSION_SYNCED.to_slice], expand_request: false,
          auto_content_length: false, target: "https://t.test:8443", http2: true, sni: "front.test")
      }),
  ]
end

describe Gori::Repeater::Plan do
  describe "cross-surface equivalence (#356)" do
    surface_cases.each do |c|
      it "assembles #{c.name} identically from the CLI, MCP and TUI option sets" do
        cli = shape_of(c.cli.call)
        cli.should eq(c.expected) # pinned first, so "all three agree" cannot mean "all three wrong"
        shape_of(c.mcp.call).should eq(cli)
        shape_of(c.tui.call).should eq(cli)
      end
    end

    # Pinned literals, not a round-trip through the builder — otherwise the equivalence
    # check above could agree on a wrong answer and still pass.
    it "frames the CLI/MCP session replay to the exact expected bytes" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "https://t.test:8443", http2: true, sni: "front.test"), ungated)
      String.new(plan.bytes).should eq(SESSION_SYNCED)
      plan.scheme.should eq("https")
      plan.host.should eq("t.test")
      plan.port.should eq(8443)
      plan.http2?.should be_true
      plan.sni.should eq("front.test")
      plan.websocket?.should be_false
    end
  end

  describe "the Content-Length policy" do
    it "resyncs a stale Content-Length when auto_content_length is ON" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test", auto_content_length: true), ungated)
      String.new(plan.bytes).should contain("Content-Length: 5\r\n")
    end

    # `repeater create --no-auto-cl`, and `gori run repeater -H "Content-Length: N"`, both
    # exist so a deliberately-wrong CL survives to the wire (CL-mismatch / smuggling tests).
    it "preserves a hand-set Content-Length when auto_content_length is OFF" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test", auto_content_length: false), ungated)
      String.new(plan.bytes).should contain("Content-Length: 999\r\n")
    end

    it "never runs the resync over a WebSocket handshake, even with auto_content_length ON" do
      raw = "GET /s HTTP/1.1\r\nHost: t.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
            "Sec-WebSocket-Version: 13\r\nContent-Length: 42\r\n\r\n"
      plan = R::Plan.build(R::PlanOptions.new([raw.to_slice],
        default_target: "http://t.test", auto_content_length: true), ungated)
      plan.websocket?.should be_true
      String.new(plan.bytes).should contain("Content-Length: 42\r\n") # untouched
    end
  end

  # PR 7. The gRPC length prefix is the OTHER length declaration in the same request, and it
  # gets the opposite default on purpose: Content-Length is resynced unless told not to, this
  # is left alone unless told to. See `PlanOptions#reframe_grpc?`.
  describe "the gRPC reframe policy" do
    it "is OFF by default, on the plan and on the sender it builds" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test"), ungated)
      plan.reframe_grpc?.should be_false
      plan.sender.reframe_grpc?.should be_false
    end

    it "carries the opt-in through to the sender that will encode the h2 request" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test", http2: true, reframe_grpc: true), ungated)
      plan.reframe_grpc?.should be_true
      plan.sender.reframe_grpc?.should be_true
    end

    # `with_requests` is MCP's post-assembly Match&Replace seam. It reuses the SAME sender
    # (so the scope verdict cannot be moved out from under a rewrite) and must keep the same
    # framing policy with it — a rewrite that changed the body length is precisely the case
    # the opt-in was turned on for.
    it "survives with_requests" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test", http2: true, reframe_grpc: true), ungated)
      plan.with_requests(["GET /rewritten HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice])
        .reframe_grpc?.should be_true
    end

    # The wires are NOT rewritten at build time: the reframe rides `H2Engine.parse_request`
    # at the send seam, so a body a `$BINDING` changes on the way out is covered too. Pinned
    # because "the plan bytes look unchanged" is otherwise easy to misread as "the flag did
    # nothing" — `spec/repeater/h2_engine_spec.cr` owns the byte-level half.
    it "leaves the plan's own wire bytes untouched — the reframe happens at the send seam" do
      opts = R::PlanOptions.new([SESSION_RAW.to_slice], default_target: "http://t.test", http2: true)
      off = R::Plan.build(opts, ungated)
      on = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://t.test", http2: true, reframe_grpc: true), ungated)
      on.bytes.should eq(off.bytes)
    end
  end

  describe "env expansion" do
    it "expands the request wire, the target and the SNI in one pass" do
      with_env_vars([{"HOSTV", "t.test"}, {"TOK", "s3cr3t"}, {"SNIV", "front.test"}]) do
        plan = R::Plan.build(R::PlanOptions.new(
          ["GET /a HTTP/1.1\nHost: $HOSTV\nAuth: $TOK\n\n".to_slice],
          default_target: "https://$HOSTV:9443", sni: "$SNIV"), ungated)
        String.new(plan.bytes).should eq("GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: s3cr3t\r\n\r\n")
        plan.host.should eq("t.test")
        plan.port.should eq(9443)
        plan.sni.should eq("front.test")
      end
    end

    # The TUI editor and MCP's RequestBuilder both hand over bytes they already expanded; a
    # second pass would re-expand a value that itself looks like a token.
    it "leaves the request bytes verbatim when expand_request is off" do
      with_env_vars([{"A", "$B"}, {"B", "leaked"}]) do
        plan = R::Plan.build(R::PlanOptions.new(["GET /$A HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice],
          expand_request: false, default_target: "http://t.test"), ungated)
        String.new(plan.bytes).should eq("GET /$A HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
    end
  end

  describe "target resolution" do
    it "prefers an explicit target over the seeding flow's" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        target: "http://explicit.test:8080", default_target: "https://seed.test"), ungated)
      plan.host.should eq("explicit.test")
      plan.port.should eq(8080)
    end

    # Deliberately NOT "blank means use the default": `gori run repeater --target "$UNSET"`
    # must fail rather than quietly redirect the send to the captured host. (`Fuzz::Plan`
    # differs here on purpose — an MCP fuzz caller really does send `"url": ""`.)
    it "refuses a blank explicit target instead of falling back to the default" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
          target: "  ", default_target: "https://seed.test"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::BadTarget)
    end

    it "still falls back to the default when no target is given at all" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "https://seed.test"), ungated)
      plan.host.should eq("seed.test")
    end

    it "takes a pre-resolved origin verbatim, over any target string" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        origin: R::Origin.new("https", "pinned.test", 8443), target: "http://ignored.test"), ungated)
      plan.scheme.should eq("https")
      plan.host.should eq("pinned.test")
      plan.port.should eq(8443)
    end

    it "brackets and unwraps an IPv6 literal target" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        default_target: "http://[::1]:8080"), ungated)
      plan.host.should eq("::1")
      plan.port.should eq(8080)
    end
  end

  describe "field-native h2 (h2_fields)" do
    it "builds a field-native plan: forces http2, carries the fields, needs no request bytes" do
      plan = R::Plan.build(R::PlanOptions.new(
        h2_fields: FN_FIELDS, target: "https://t.test:8443"), ungated)
      plan.http2?.should be_true
      plan.websocket?.should be_false
      plan.h2_fields.should eq(FN_FIELDS)
      plan.scheme.should eq("https")
      plan.host.should eq("t.test")
      plan.port.should eq(8443)
    end

    it "carries a field-native body onto the plan" do
      plan = R::Plan.build(R::PlanOptions.new(
        h2_fields: FN_FIELDS, h2_body: "payload".to_slice, target: "https://t.test"), ungated)
      String.new(plan.h2_body.not_nil!).should eq("payload")
    end

    # `refusal` and the scope gate both key off a request LINE, and a
    # field-native send has no head text — so `requests` holds ONE synthetic scope line built
    # from the FIRST :method/:path (the pair a receiver routes on). This pins that derivation
    # so the scope decision cannot silently start reading `/` for every field-native send.
    it "synthesizes the scope request line from the first :method/:path" do
      plan = R::Plan.build(R::PlanOptions.new(
        h2_fields: FN_FIELDS, target: "https://t.test"), ungated)
      String.new(plan.bytes).should start_with("GET /fn HTTP/2\r\n")
    end

    it "still resolves the origin (a bad target is refused before any send)" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new(h2_fields: FN_FIELDS, target: "ftp://t.test"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::UnsupportedScheme)
    end
  end

  describe "refusals" do
    it "reports NoTarget when neither a target nor a default is given" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice]), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::NoTarget)
    end

    it "reports BadTarget with the expanded string a surface can quote back" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice], target: "http://"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::BadTarget)
      ex.detail.should eq("http://")
    end

    it "reports BadTarget for a zero port (only MCP send_websocket used to catch this)" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice], target: "http://t.test:0"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::BadTarget)
    end

    it "reports NoRequest for an empty request list (the TUI's empty `%%%` split)" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new(default_target: "http://t.test"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::NoRequest)
    end

    it "reports UnsupportedScheme, carrying the scheme as detail" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice], target: "ftp://t.test"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::UnsupportedScheme)
      ex.detail.should eq("ftp")
    end

    it "still rejects a scheme no engine can dial" do
      ex = expect_raises(R::PlanError) do
        R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice], target: "gopher://t.test"), ungated)
      end
      ex.reason.should eq(R::PlanError::Reason::UnsupportedScheme)
      ex.detail.should eq("gopher")
    end
  end

  # `Engine` and `H2Engine` decide TLS with `scheme == "https"` ALONE, while `WsEngine` also
  # accepts `"wss"`. A plan carrying the ws/wss spelling therefore dialled CLEARTEXT whenever
  # the surface sent it as a plain one-shot instead of a framed exchange — which `gori run
  # repeater <flow-id> --target wss://…` does for a captured upgrade whose response was not
  # 101 (so the command's 101 guard never fires). Folding the spelling at the builder makes
  # every engine's test correct by construction.
  describe "ws/wss scheme folding" do
    {"ws" => "http", "wss" => "https"}.each do |typed, dialled|
      it "folds a hand-typed #{typed}:// target to #{dialled}" do
        plan = R::Plan.build(R::PlanOptions.new([WS_UPGRADE.to_slice],
          target: "#{typed}://t.test"), ungated)
        plan.websocket?.should be_true
        plan.scheme.should eq(dialled)
      end
    end

    it "folds wss on the pre-resolved origin path too" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        origin: R::Origin.new("wss", "t.test", 443)), ungated)
      plan.scheme.should eq("https")
    end

    # The regression itself: a wss:// target must never put the request on a plaintext
    # socket. Asserted end-to-end against a raw TCP listener, because the bug was invisible
    # at the type level — `plan.scheme` was simply carried through to a dialer that did not
    # understand it.
    it "never sends a wss:// one-shot in cleartext" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      seen = Channel(String).new(1)
      spawn do
        if sock = server.accept?
          buf = Bytes.new(4096)
          n = sock.read(buf)
          seen.send(String.new(buf[0, n]))
          sock.close rescue nil
        end
      rescue
      end

      begin
        secret = "session=SUPERSECRET"
        raw = "GET /socket HTTP/1.1\r\nHost: t.test\r\nUpgrade: websocket\r\n" \
              "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nCookie: #{secret}\r\n\r\n"
        plan = R::Plan.build(R::PlanOptions.new([raw.to_slice],
          target: "wss://127.0.0.1:#{port}", auto_content_length: false,
          verify: false, timeout: 3.seconds), ungated)
        plan.scheme.should eq("https")
        plan.send # fails: the listener speaks no TLS — the point is WHAT it received
        select
        when wire = seen.receive
          # A TLS ClientHello may land here; the request itself never may.
          wire.should_not contain(secret)
          wire.should_not contain("GET /socket")
        when timeout(3.seconds)
          # Nothing arrived at all — also fine, and equally proves no cleartext request.
        end
      ensure
        server.close
      end
    end
  end

  describe "group sends" do
    it "keeps every request in order and refuses the batch as a whole" do
      a = "GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n"
      b = "GET /b HTTP/1.1\r\nHost: t.test\r\n\r\n"
      plan = R::Plan.build(R::PlanOptions.new([a.to_slice, b.to_slice],
        expand_request: false, auto_content_length: false, target: "http://t.test"), ungated)
      plan.requests.map { |r| String.new(r) }.should eq([a, b])
      plan.bytes.should eq(a.to_slice) # #bytes is the FIRST request, not the last
      plan.refusal.should be_nil       # ungated
    end
  end

  describe "#with_requests" do
    it "carries the same origin and dialer onto rewritten bytes (MCP's Match&Replace)" do
      plan = R::Plan.build(R::PlanOptions.new([SESSION_RAW.to_slice],
        target: "https://t.test:8443", http2: true, sni: "front.test"), ungated)
      rewritten = plan.with_requests(["GET /rewritten HTTP/1.1\r\n\r\n".to_slice])
      String.new(rewritten.bytes).should eq("GET /rewritten HTTP/1.1\r\n\r\n")
      rewritten.scheme.should eq(plan.scheme)
      rewritten.host.should eq(plan.host)
      rewritten.port.should eq(plan.port)
      rewritten.http2?.should eq(plan.http2?)
      rewritten.sni.should eq(plan.sni)
      rewritten.sender.should be(plan.sender) # the SAME gated dialer, not a second one
    end
  end
  # `downgrade_version_line` documents itself as running "unasked on every send", but the TUI
  # was its only caller — so the SAME session sent `HTTP/2` down an h1 socket from
  # `gori run repeater send` and MCP while the TUI corrected it. Recorded at a raw-socket
  # origin before the fix. Doing it in `Plan.build` puts it on the path all three surfaces share.
  describe "an HTTP/2 version line on an h1 send" do
    it "is downgraded whichever surface built the plan" do
      plan = R::Plan.build(R::PlanOptions.new(["GET /v HTTP/2\r\nHost: h.test\r\n\r\n".to_slice],
        default_target: "http://h.test"), ungated)
      String.new(plan.bytes).lines.first.should eq("GET /v HTTP/1.1")
    end

    it "leaves a version the operator meant alone" do
      {"HTTP/1.0", "HTTP/9.9"}.each do |v|
        plan = R::Plan.build(R::PlanOptions.new(["GET /v #{v}\r\nHost: h.test\r\n\r\n".to_slice],
          default_target: "http://h.test"), ungated)
        String.new(plan.bytes).lines.first.should eq("GET /v #{v}")
      end
    end

    it "does not touch an h2 send, which builds its fields from this text" do
      plan = R::Plan.build(R::PlanOptions.new(["GET /v HTTP/2\r\nHost: h.test\r\n\r\n".to_slice],
        default_target: "http://h.test", http2: true), ungated)
      String.new(plan.bytes).lines.first.should eq("GET /v HTTP/2")
    end
  end
  # `--request-raw` / `--request-file` are documented as verbatim, and were not: `expand_wire`
  # promotes a bare LF to CRLF on every headless send, and `--no-auto-cl` only disabled the
  # Content-Length resync. A bare-LF header terminator is a standard front-end/back-end desync
  # primitive, so that removed a whole payload class from the headless surfaces while the TUI's
  # byte modes could still send it. `expand_request: false` is the flag every surface already
  # uses to mean "these bytes ARE the message"; `gori run repeater send --verbatim` sets it.
  describe "verbatim sends" do
    it "keeps a bare LF in the head instead of promoting it to CRLF" do
      raw = "GET /v HTTP/1.1\r\nHost: h.test\nX-Bare: lf\n\r\n".to_slice
      plan = R::Plan.build(R::PlanOptions.new([raw], default_target: "http://h.test",
        expand_request: false, auto_content_length: false), ungated)
      String.new(plan.bytes).should eq(String.new(raw))
    end

    it "promotes it by default, which is what every other send still does" do
      raw = "GET /v HTTP/1.1\r\nHost: h.test\nX-Bare: lf\n\r\n".to_slice
      plan = R::Plan.build(R::PlanOptions.new([raw], default_target: "http://h.test"), ungated)
      String.new(plan.bytes).should eq("GET /v HTTP/1.1\r\nHost: h.test\r\nX-Bare: lf\r\n\r\n")
    end

    it "also leaves the version line alone, since the operator asked for these exact bytes" do
      raw = "GET /v HTTP/2\r\nHost: h.test\r\n\r\n".to_slice
      plan = R::Plan.build(R::PlanOptions.new([raw], default_target: "http://h.test",
        expand_request: false, auto_content_length: false), ungated)
      String.new(plan.bytes).lines.first.should eq("GET /v HTTP/2")
    end

    # INVERTED for the owner's round-7 policy: this used to refuse, precisely BECAUSE the
    # check ran regardless of expansion. `expand_request: false` means the operator said the
    # bytes are the message, and now every path agrees — an unresolved `$VAR` goes out as
    # itself. (`$user.name`, `$IFS` and OData `$top` are the payloads that motivated it.)
    it "sends an unresolved $VAR as itself, since these are the exact bytes asked for" do
      raw = "GET /v HTTP/1.1\r\nHost: h.test\r\nX-T: $NOPE\r\n\r\n".to_slice
      plan = R::Plan.build(R::PlanOptions.new([raw], default_target: "http://h.test",
        expand_request: false, auto_content_length: false), ungated)
      String.new(plan.bytes).should contain("X-T: $NOPE")
    end
  end
end
