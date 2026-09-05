require "../spec_helper"
require "socket"

private alias D = Gori::Discover

private def with_wordlist(names : Array(String), &)
  path = File.tempname("gori-discover-words", ".txt")
  File.write(path, names.join('\n'))
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

# What the builder DERIVES, flattened so two plans compare with a single `should eq`. The
# Config knobs are deliberately absent: all three arms are handed the same Config instance,
# so reading `max_depth`/`containment`/… back off it would compare that object with itself
# and could never fail. Only these four are computed by `Plan.build`. `policy` is the CLASS
# NAME rather than the object — UnscopedStoreScope is a StoreScope subclass, so comparing
# instances would let the include-boundary waiver slip through unnoticed.
private record Shape,
  seed : String,
  host : String,
  word_count : Int32,
  policy : String

private def shape_of(options : D::PlanOptions) : Shape
  plan = D::Plan.build(options, ungated_outbound)
  Shape.new(seed: plan.seed, host: plan.host, word_count: plan.word_count,
    policy: plan.policy.class.name)
end

# The one run every surface is asked to assemble, expressed as the Config each of them
# builds. Identical by construction — what differs between the arms is the SEED STRING and
# nothing else, which is the whole remaining surface-specific job after the refactor.
private def run_config(wordlist : String) : D::Config
  D::Config.new(concurrency: 5, max_requests: 100_i64, spider: true, bruteforce: true,
    max_depth: 2, user_wordlist: wordlist, extensions: ["php"],
    containment: D::Containment::SameOrigin)
end

# A one-request run against a local listener: spider only, depth 0, `max_requests: 1` so every
# derived well-known probe is refused by CappedBackend without touching the network. Exactly
# one GET reaches the origin, so the head it records is unambiguous.
private def one_shot_config(headers : Array({String, String}) = [] of {String, String}) : D::Config
  D::Config.new(concurrency: 1, retries: 0, max_requests: 1_i64, spider: true,
    bruteforce: false, max_depth: 0, timeout: 3.seconds, headers: headers)
end

# Every path `seed_frontier` queues by name at the origin, and how many requests the seed plus
# that whole set costs. Derived from the constant rather than written out, because these
# budgets are what let a crawled link reach the wire at all: a hard-coded one meant that
# widening `WELL_KNOWN` silently starved the crawled-link assertions below into passing
# vacuously — `CappedBackend` refuses over budget without touching the network, so the origin
# simply never saw the hop the test is about, and `seen` was empty for the right reason and
# the wrong one at once.
private WELL_KNOWN_PATHS = D::Engine::WELL_KNOWN.map { |path, _| path }.to_a
# The origin-root soft-404 calibration `seed_frontier` queues for every SPIDER run — the gate
# that stops a wildcard-200 origin minting well-known findings — costs `calibrate_probes`
# sends of its own. Read off the default Config for the same reason the set above is derived
# from the constant: it is part of what the seed frontier spends before a crawled link can
# reach the wire.
private SEED_CALIBRATION_PROBES = D::Config.new.calibrate_probes
private SEED_FRONTIER_COST      = (1 + WELL_KNOWN_PATHS.size + SEED_CALIBRATION_PROBES).to_i64

# Room for everything `seed_frontier` queues plus ONE crawled link, so a depth-1 hop is
# observable. Used by the policy A/B, which asserts on that hop.
private def crawl_config : D::Config
  D::Config.new(concurrency: 1, retries: 0, max_requests: SEED_FRONTIER_COST + 1, spider: true,
    bruteforce: false, max_depth: 1, timeout: 3.seconds)
end

# The seed and its derived well-known paths and NOTHING else: depth 0 so no link can add
# a further request, and headroom on `max_requests` so one would still be visible on the
# wire rather than swallowed by CappedBackend. Used by the Layer-2 tests on the seed set.
private def seed_trio_config : D::Config
  D::Config.new(concurrency: 1, retries: 0, max_requests: SEED_FRONTIER_COST + 4, spider: true,
    bruteforce: false, max_depth: 0, timeout: 3.seconds)
end

# The request targets an origin actually saw, in the order it saw them.
private def targets_of(heads : Array(String)) : Array(String)
  heads.compact_map { |h| h.lines.first?.try(&.split(' ')[1]?) }
end

# The origin-root calibration's bogus paths — `Engine#bogus_name` is `Random::Secure.hex(8)`,
# so 16 hex characters directly under "/". Subtracted where a test asserts on the exact set of
# paths a gate let through: the calibration is a soft-404 measurement, not a guess under test.
private def calibration_probes(targets : Array(String)) : Array(String)
  targets.select(&.matches?(%r{\A/[0-9a-f]{16}\z}))
end

# Run one plan against a throwaway origin. Yields the listener's port so the caller can
# build a seed pointing at it; returns the findings plus every request head the origin saw.
#
# Driving the ENGINE (rather than reading `Plan`'s getters back) is what makes these tests
# worth having: the getters and the engine are populated from the same locals, so asserting
# `plan.seed` / `plan.policy` alone cannot tell a plan that hands the crawl the right values
# from one that reports them and passes the engine something else.
private def run_one(outbound = ungated_outbound, body = "hi", events : Array(D::Event)? = nil,
                    &build : Int32 -> D::PlanOptions) : {Array(D::Finding), Array(String)}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = [] of String
  spawn(name: "discover-plan-spec-origin") do
    while conn = server.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      seen << (head ? String.new(head) : "")
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n" \
              "Connection: close\r\n\r\n#{body}"
      conn.flush
      conn.close
    end
  end
  begin
    plan = D::Plan.build(build.call(port), outbound)
    findings = [] of D::Finding
    plan.engine.run do |ev|
      events << ev if events
      findings << ev.finding if ev.is_a?(D::FindingEvent)
    end
    {findings, seen}
  ensure
    server.close
  end
end

describe Gori::Discover::Plan do
  describe "cross-surface equivalence" do
    it "assembles the same run from each surface's seed spelling" do
      Gori::Settings.env_vars = [{"SEED", "https://acme.test"}]
      with_wordlist(["zz-plan-spec-a", "zz-plan-spec-b"]) do |wl|
        config = run_config(wl)
        # `gori run discover --target acme.test/api` — a bare host, no scheme.
        cli = shape_of(D::PlanOptions.new("acme.test/api", config: config))
        # MCP `{"url": "$SEED/api"}` — an env token the agent never resolved itself.
        mcp = shape_of(D::PlanOptions.new("$SEED/api", config: config))
        # The TUI, seeded from a Sitemap row that already carries a full URL.
        tui = shape_of(D::PlanOptions.new("https://acme.test/api", config: config))

        cli.should eq(mcp)
        cli.should eq(tui)
        # Pinned literally, so the three arms agree on a stated answer and not just on
        # each other: scheme defaulted, env token expanded, both applied exactly once.
        cli.seed.should eq("https://acme.test/api")
        cli.host.should eq("acme.test")
      end
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "normalizes the seed the scope gate matches on" do
      # Every surface gates with `outbound.check(plan.seed, plan.host)`, so the spelling of
      # this string decides whether a `string`/`regex` rule matches. Left un-normalized, an
      # exclude anchored on `^https://prod\.acme\.test` missed `PROD.acme.test` and
      # `prod.acme.test:443`, and an include anchored on `^https://acme\.test/` missed a seed
      # given as a bare host. Both were live before this builder existed.
      shape_of(D::PlanOptions.new("https://PROD.Acme.Test:443/api")).seed.should eq("https://prod.acme.test/api")
      shape_of(D::PlanOptions.new("acme.test")).seed.should eq("https://acme.test/")
      shape_of(D::PlanOptions.new("http://acme.test:8080/a?b=1")).seed.should eq("http://acme.test:8080/a?b=1")
    end

    it "blocks an out-of-scope seed whose spelling differs from the rule's" do
      # The above, proven through the real gate rather than through string equality.
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "regex", "^https://prod\\.acme\\.test")
        ob = Gori::Outbound.agent(scope, false)
        plan = D::Plan.build(D::PlanOptions.new("https://PROD.acme.test:443/"), ob)
        ob.check(plan.seed, plan.host).blocked?.should be_true
      end
    end

    # #884 / the Layer-1 half of #407. The seed carries its port, and Layer 1 used to be handed
    # that string verbatim while every url-level include is written port-free — so a discover
    # run against a legitimate `:8443` target was refused as out of scope by the very rule that
    # scoped it in, and the engine's own comment (`gate_url`) named the bug without fixing it
    # on this side. The EXCLUDE side now reads the port instead.
    it "judges the seed in the two spellings the engine's Layer 2 already used" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "string", "https://acme.test/api/")
        ob = Gori::Outbound.agent(scope, false)

        gate, excl = D::Url.gate_urls("https://acme.test:8443/api/v1")
        ob.check(gate, "acme.test", excl).blocked?.should be_false
        # ...and the port-bearing spelling on its own is what the include cannot match, which
        # is exactly why Layer 1 must not be handed it.
        ob.check("https://acme.test:8443/api/v1", "acme.test").blocked?.should be_true
      end
    end

    it "refuses a seed an EXCLUDE carves out BY PORT" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", ":19316")
        ob = Gori::Outbound.agent(scope, false)

        gate, excl = D::Url.gate_urls("https://acme.test:19316/api")
        v = ob.check(gate, "acme.test", excl)
        v.blocked?.should be_true
        v.excluded?.should be_true # names the rule to delete, not "add an include"

        ok_gate, ok_excl = D::Url.gate_urls("https://acme.test:19304/api")
        ob.check(ok_gate, "acme.test", ok_excl).blocked?.should be_false
      end
    end

    it "reads the user wordlist from config.user_wordlist on every surface" do
      # `--wordlist` and MCP's `wordlist` arg used to bypass the Config and be handed to
      # Wordlist.load separately, leaving config.user_wordlist nil on two surfaces out of
      # three. One field now, so the count moves for all of them or none.
      with_wordlist(["zz-plan-spec-a", "zz-plan-spec-b"]) do |wl|
        with_list = shape_of(D::PlanOptions.new("https://acme.test/", config: run_config(wl)))
        without = shape_of(D::PlanOptions.new("https://acme.test/",
          config: D::Config.new(concurrency: 5, max_requests: 100_i64, spider: true,
            bruteforce: true, max_depth: 2, extensions: ["php"],
            containment: D::Containment::SameOrigin)))
        with_list.word_count.should eq(without.word_count + 2)
      end
    end
  end

  describe "the crawl-time scope policy is derived from the Outbound" do
    seed = "https://acme.test/api"

    it "bounds nothing but still consults Layer 2 when the project has no scope rules" do
      # Issue #392: a rule-LESS scope is not an ABSENT one. It used to get OpenScope, whose
      # allowed? is unconditionally true, so Layer 2 was missing for the whole run.
      with_store do |store|
        scope = Gori::Scope.load(store)
        [Gori::Outbound.agent(scope, false), Gori::Outbound.cli(scope, false),
         Gori::Outbound.interactive(scope)].each do |ob|
          policy = D::Plan.build(D::PlanOptions.new(seed), ob).policy
          policy.class.should eq(D::StoreScope)
          # Containment is unchanged: configured? is still false, so scope-aware containment
          # keeps falling back to same-origin and boundary? is never consulted.
          policy.configured?.should be_false
          # And with Sandbox off, an ordinary rule-less run is bounded exactly as before.
          policy.allowed?(seed, "acme.test", nil).should be_true
        end
      end
    end

    it "fails CLOSED for discover when Sandbox is on and the project has no rules" do
      # Sandbox is enabled independently of rules, and §3 makes a scope with no include rules
      # block everything on purpose. Every other sweep already refused here (`sweep_block`
      # skips only on a NIL scope) and the proxy blocked every request, while discover crawled
      # and brute-forced unrestricted — fail-open in the one configuration §3 calls fail-closed.
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.enable_sandbox
        [Gori::Outbound.agent(scope, false), Gori::Outbound.cli(scope, false),
         Gori::Outbound.interactive(scope)].each do |ob|
          D::Plan.build(D::PlanOptions.new(seed), ob).policy
            .allowed?(seed, "acme.test", nil).should be_false
        end
      end
    end

    it "keeps OpenScope when there is genuinely no project" do
      # `scope.nil?` is a different question from "the scope has no rules", and only the
      # former means there is nothing to consult.
      D::Plan.build(D::PlanOptions.new(seed), ungated_outbound).policy.class.should eq(D::OpenScope)
    end

    it "applies the project scope when one is configured and Layer 1 was not waived by the operator" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        [Gori::Outbound.agent(scope, false), Gori::Outbound.cli(scope, false),
         Gori::Outbound.interactive(scope)].each do |ob|
          D::Plan.build(D::PlanOptions.new(seed), ob).policy.class.should eq(D::StoreScope)
        end
      end
    end

    it "keeps the include boundary under an operator waiver when the seed IS in scope" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        # --allow-unscoped / allow_unscoped:true is redundant here, so it must not widen
        # the crawl: the seed the operator named is inside the boundary already.
        [Gori::Outbound.cli(scope, true), Gori::Outbound.agent(scope, true)].each do |ob|
          D::Plan.build(D::PlanOptions.new(seed), ob).policy.class.should eq(D::StoreScope)
        end
      end
    end

    it "drops the include boundary only for an OPERATOR waiver on an out-of-scope seed" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "other.test")
        [Gori::Outbound.cli(scope, true), Gori::Outbound.agent(scope, true)].each do |ob|
          policy = D::Plan.build(D::PlanOptions.new(seed), ob).policy
          policy.class.should eq(D::UnscopedStoreScope)
          # The behavioural difference, not just the class: scope-aware containment falls
          # back to same-origin instead of blocking every hop off the seed.
          policy.configured?.should be_false
          # The hard gate survives the waiver.
          policy.allowed?(seed, "acme.test", nil).should be_true
        end

        # The TUI is ALSO Layer-1 waived — for Reason::Interactive — and that must NOT
        # widen the crawl: "a human typed this target" is not a request to drop the
        # include boundary the same human configured.
        tui = D::Plan.build(D::PlanOptions.new(seed), Gori::Outbound.interactive(scope)).policy
        tui.class.should eq(D::StoreScope)
        tui.configured?.should be_true
        tui.boundary?(seed, "acme.test").should be_false
      end
    end

    it "still bounds a sandbox-blocked host under an operator waiver" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "other.test")
        scope.enable_sandbox
        policy = D::Plan.build(D::PlanOptions.new(seed), Gori::Outbound.cli(scope, true)).policy
        policy.allowed?(seed, "acme.test", nil).should be_false
      end
    end

    # The getters above and the Engine are populated from the same locals, so all five stay
    # green if `Plan.build` reports the right policy and hands the CRAWL an ungated one.
    # These two drive the engine instead, as an A/B on one crawled link: same plan, same
    # harness, only the scope rules differ.
    #
    # The assertion is about the LINK, not the seed: the seed trio takes a DIFFERENT path
    # through the gate (Layer 2 only — see the Layer-2 block below and DESIGN.md §7), so
    # asserting on it here would conflate the two.
    linked = %(<html><a href="/deeper">d</a></html>)

    it "hands the derived policy to the engine, not just to the getter" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "elsewhere.test")
        scope.enable_sandbox
        findings, seen = run_one(Gori::Outbound.interactive(scope), linked) do |port|
          D::PlanOptions.new("http://127.0.0.1:#{port}/", config: crawl_config, verify: false)
        end
        seen.any?(&.includes?("/deeper")).should be_false
        findings.map(&.url).any?(&.includes?("/deeper")).should be_false
      end
    end

    it "crawls that same link once the scope allowlists the host" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "127.0.0.1")
        scope.enable_sandbox
        findings, seen = run_one(Gori::Outbound.interactive(scope), linked) do |port|
          D::PlanOptions.new("http://127.0.0.1:#{port}/", config: crawl_config, verify: false)
        end
        seen.any?(&.includes?("GET /deeper ")).should be_true
        findings.map(&.url).any?(&.includes?("/deeper")).should be_true
      end
    end
  end

  # Issue #364 / DESIGN.md §7. The seed and its derived well-known paths waive Layer 1 —
  # a human typed the target — but not Layer 2, whose promise ("blocks ALL out-of-scope
  # traffic") is unconditional. These drive a REAL `Gori::Scope` end to end and assert on the
  # bytes the origin received, because a policy double could only restate the decision.
  describe "Layer 2 on the seed and its derived well-known paths" do
    it "sends nothing at all — and says why — when Sandbox blocks the seed's host" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "elsewhere.test")
        scope.enable_sandbox
        events = [] of D::Event
        # `Outbound.interactive` is the STRONGEST case for leaving the seed alone: the TUI's
        # Layer 1 is waived precisely because the operator chose this target. Sandbox still
        # has to stop it.
        findings, seen = run_one(Gori::Outbound.interactive(scope), "hi", events) do |port|
          D::PlanOptions.new("http://127.0.0.1:#{port}/", config: seed_trio_config, verify: false)
        end
        seen.should be_empty
        findings.should be_empty
        events.map(&.class).should eq([D::ErrorEvent])
        events.first.as(D::ErrorEvent).message.should contain(D::Engine::SEED_BLOCKED)
      end
    end

    it "sends the seed and every well-known path once Sandbox allowlists the host" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "127.0.0.1")
        scope.enable_sandbox
        _findings, seen = run_one(Gori::Outbound.interactive(scope)) do |port|
          D::PlanOptions.new("http://127.0.0.1:#{port}/", config: seed_trio_config, verify: false)
        end
        got = targets_of(seen)
        (got - calibration_probes(got)).sort.should eq((["/"] + WELL_KNOWN_PATHS).sort)
      end
    end

    it "drops every derived well-known path to an EXCLUDE rule while the seed still goes out" do
      # Sandbox is OFF here: Layer 2 is Sandbox *plus* explicit excludes, and discover is the
      # most automated sweep gori has, so an operator's carve-out has to hold on its seed
      # requests exactly as it does on every URL the crawl derives afterwards.
      #
      # The rule excludes every path with anything after the origin's slash, which is exactly
      # the well-known set and nothing else at depth 0 — written that way rather than as a
      # list of filenames so it keeps covering `WELL_KNOWN` as that grows.
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "127.0.0.1")
        scope.add("exclude", "regex", "127\\.0\\.0\\.1/.+")
        _findings, seen = run_one(Gori::Outbound.interactive(scope)) do |port|
          D::PlanOptions.new("http://127.0.0.1:#{port}/", config: seed_trio_config, verify: false)
        end
        targets_of(seen).should eq(["/"])
      end
    end
  end

  describe "the wire" do
    it "expands $VAR in custom headers without touching the caller's Config" do
      Gori::Settings.env_vars = [{"TOKEN", "s3cr3t"}]
      config = one_shot_config(D::Headers.parse_lines(["X-Auth: $TOKEN"]))
      findings, seen = run_one do |port|
        D::PlanOptions.new("http://127.0.0.1:#{port}/probe", config: config, verify: false)
      end
      findings.size.should eq(1)
      seen.size.should eq(1)
      seen[0].should contain("GET /probe HTTP/1.1\r\n")
      seen[0].should contain("X-Auth: s3cr3t\r\n")
      # The TUI's headers overlay binds this very instance; expanding in place would
      # rewrite what it shows and expand a SECOND time on the next ^R.
      config.headers.should eq([{"X-Auth", "$TOKEN"}])
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "drops a header whose expanded value carries CRLF" do
      # `Headers.parse_lines` refuses a hand-typed CRLF, but it only ever saw `$TOKEN`.
      # Without a second guard after expansion, an env var's value would splice extra
      # headers into every probe the crawl sends.
      #
      # This is the BACKSTOP, not the report. Dropping silently here is what made an
      # authenticated sweep run unauthenticated and answer "found nothing" over the whole
      # authenticated surface — so the surface now REFUSES the run up front, by name, off
      # `Headers.unsafe_expanded` (see spec/discover/headers_spec.cr and
      # `gori run discover`). The drop stays because this is the last look before the wire
      # and a binding can resolve later than plan-build; it just is no longer the only look.
      Gori::Settings.env_vars = [{"TOKEN", "a\r\nX-Injected: 1"}]
      config = one_shot_config(D::Headers.parse_lines(["X-Auth: $TOKEN"]))
      _findings, seen = run_one do |port|
        D::PlanOptions.new("http://127.0.0.1:#{port}/probe", config: config, verify: false)
      end
      seen.size.should eq(1)
      seen[0].should_not contain("X-Injected")
      seen[0].should_not contain("X-Auth")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    # Issue #367: every CLI/MCP tool passed `overrides:` to its sender and no TUI tool did,
    # so a project host override silently did not apply to a TUI-launched crawl. The
    # argument's absence was invisible to the old specs, so this pair asserts the DIALLED
    # host, not the plumbing: `.invalid` is reserved (RFC 2606) and never resolves, so the
    # run can only reach the local listener through the override.
    it "dials the override IP while keeping the original name in the Host header" do
      with_store do |store|
        overrides = Gori::HostOverrides.load(store)
        overrides.add("nonexistent.invalid", "127.0.0.1").should be_true
        findings, seen = run_one do |port|
          D::PlanOptions.new("http://nonexistent.invalid:#{port}/probe",
            config: one_shot_config, verify: false, overrides: overrides)
        end
        findings.size.should eq(1)
        seen.size.should eq(1)
        seen[0].should contain("GET /probe HTTP/1.1\r\n")
        seen[0].should contain("Host: nonexistent.invalid:") # name preserved, only the IP changed
      end
    end

    it "hands the RESOLVED seed to the engine, not just to the getter" do
      # `plan.seed` alone cannot prove this: a build that resolves the seed for the getter and
      # passes `options.target` to `Engine.new` reports the same string either way. Here the
      # raw target is an unexpanded env token, so the crawl reaches the listener only if the
      # engine received the resolved form.
      Gori::Settings.env_vars = [{"SEEDORIGIN", "http://127.0.0.1"}]
      findings, seen = run_one do |port|
        D::PlanOptions.new("$SEEDORIGIN:#{port}/probe?a=1", config: one_shot_config, verify: false)
      end
      findings.size.should eq(1)
      seen.size.should eq(1)
      seen[0].should contain("GET /probe?a=1 HTTP/1.1\r\n")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "cannot reach the same target with no overrides (so the override is what connects)" do
      findings, seen = run_one do |port|
        D::PlanOptions.new("http://nonexistent.invalid:#{port}/probe",
          config: one_shot_config, verify: false)
      end
      findings.should be_empty
      seen.should be_empty
    end
  end

  describe "refusals" do
    it "reports NoTechnique before anything else, so a surface names the flags first" do
      both_off = D::Config.new(spider: false, bruteforce: false)
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("", config: both_off), ungated_outbound) }
      ex.reason.should eq(D::PlanError::Reason::NoTechnique)
    end

    it "reports NoTarget for a blank seed, and for one an env var emptied" do
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("   "), ungated_outbound) }
      ex.reason.should eq(D::PlanError::Reason::NoTarget)
      # The second case pins the ORDER: expansion has to happen before the blank test, or a
      # var set to "" reaches the parser and reports BadTarget("https://") instead.
      Gori::Settings.env_vars = [{"NOTHING", ""}]
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("$NOTHING"), ungated_outbound) }
      ex.reason.should eq(D::PlanError::Reason::NoTarget)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "reports BadTarget with the expanded string a surface quotes back" do
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("http://"), ungated_outbound) }
      ex.reason.should eq(D::PlanError::Reason::BadTarget)
      ex.detail.should eq("http://")
      # Quoting the raw `$BROKEN` back would leave the operator hunting for a URL that is not
      # what the run actually tried.
      Gori::Settings.env_vars = [{"BROKEN", "http://"}]
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("$BROKEN"), ungated_outbound) }
      ex.detail.should eq("http://")
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "refuses a seed whose expanded value carries CRLF" do
      # `URI.parse` keeps a raw CR/LF in the path and the seed is spliced into a request line,
      # so this would otherwise inject a second request on every surface.
      Gori::Settings.env_vars = [{"EVIL", "http://acme.test/x\r\nX-Injected: 1"}]
      ex = expect_raises(D::PlanError) { D::Plan.build(D::PlanOptions.new("$EVIL"), ungated_outbound) }
      ex.reason.should eq(D::PlanError::Reason::BadTarget)
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end

    it "reports Wordlist for an unreadable path instead of raising File::Error at a surface" do
      config = D::Config.new(user_wordlist: File.join(Dir.tempdir, "gori-nope-#{Process.pid}.txt"))
      ex = expect_raises(D::PlanError) do
        D::Plan.build(D::PlanOptions.new("https://acme.test/", config: config), ungated_outbound)
      end
      ex.reason.should eq(D::PlanError::Reason::Wordlist)
      ex.detail.should_not be_nil
    end
  end
end
