require "./spec_helper"

# Issue #519: an env token whose variable is not set used to be left on the wire
# verbatim — a request went out carrying the seven characters `$SESSION` as a header
# value, the origin answered 401, and nothing distinguished "the variable is unset"
# from "the target rejects this token".
#
# The fix is a refusal at plan-build time on every surface that SENDS, and no change at
# all to `Env.expand`, whose literal-passthrough is correct on a display path. So this
# file asserts both halves: the query API and the five builders that use it, plus the
# display behaviour that had to stay put.

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

private def with_vars(vars : Array({String, String}), &)
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = vars
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
end

describe Gori::Env do
  describe ".unresolved" do
    it "names only the tokens expand would leave literal, in first-appearance order" do
      with_vars([{"HOST", "api.test"}]) do
        Gori::Env.unresolved("$HOST/$B?x=$A&y=$B").should eq(["B", "A"])
      end
    end

    it "returns nothing when every token resolves, and nothing when there is no token" do
      with_vars([{"HOST", "api.test"}]) do
        Gori::Env.unresolved("https://$HOST/a").should be_empty
        Gori::Env.unresolved("https://api.test/a").should be_empty
        # `${...}` and `$(...)` are not tokens at all: KEY_HEAD is [A-Za-z_], so the
        # shell/template payloads that use them are untouched by this check.
        Gori::Env.unresolved("${7*7} $(id)").should be_empty
      end
    end

    it "agrees with expand: every name it reports is one expand left in the output" do
      with_vars([{"HOST", "api.test"}]) do
        text = "$HOST $MISSING $$ESCAPED"
        expanded = Gori::Env.expand(text)
        Gori::Env.unresolved(text).each do |name|
          expanded.should contain("$#{name}")
        end
        # ...and the converse for the resolved one: it is gone.
        expanded.should_not contain("$HOST")
      end
    end

    it "is byte-safe on invalid UTF-8, where the char-based token_regions is not" do
      with_vars([] of {String, String}) do
        # 0x80 is a lone continuation byte — a captured flow's binary body routinely
        # carries such bytes, and `String#chars` decodes them lossily to U+FFFD.
        text = String.new(Bytes[0x24, 0x41, 0x80, 0x24, 0x42])
        Gori::Env.unresolved(text).should eq(["A", "B"])
      end
    end
  end

  describe ".unresolved_wire" do
    it "checks the head and never the body" do
      with_vars([] of {String, String}) do
        wire = "POST /p HTTP/1.1\r\nX-A: $HEADTOKEN\r\n\r\n{\"q\":\"$BODYTOKEN\"}"
        Gori::Env.unresolved_wire(wire).should eq(["HEADTOKEN"])
        # The whole-text form still sees both — the narrowing is `_wire`'s alone.
        Gori::Env.unresolved(wire).should eq(["HEADTOKEN", "BODYTOKEN"])
      end
    end

    it "does not refuse a request whose BODY is binary" do
      with_vars([] of {String, String}) do
        # The concrete reason the check is head-only: `$` followed by [A-Za-z_] occurs by
        # chance about once per 1.2KB of high-entropy bytes, so a whole-request check
        # would refuse essentially every replay of a compressed or encrypted upload.
        # Modelled here as binary filler carrying a few such byte pairs outright, so the
        # test states the case rather than relying on a lucky sample.
        body = Bytes.new(4096) { |i| (i * 31 + 7).to_u8! }
        body[100] = 0x24_u8 # '$'
        body[101] = 0x41_u8 # 'A'
        body[900] = 0x24_u8
        body[901] = 0x5F_u8 # '_'
        wire = String.new("POST /u HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice + body)
        Gori::Env.unresolved(wire).should_not be_empty # the body alone trips the naive check
        Gori::Env.unresolved_wire(wire).should be_empty
      end
    end

    it "treats a head-only buffer (no blank line) as all head" do
      with_vars([] of {String, String}) do
        Gori::Env.unresolved_wire("GET /$MISSING HTTP/1.1\r\nHost: t.test").should eq(["MISSING"])
      end
    end
  end

  it ".token_list renders names back into the spelling the operator typed" do
    with_vars([] of {String, String}) do
      Gori::Env.token_list(["A", "B"]).should eq("$A, $B")
    end
  end

  # The half of #519 that had to NOT change: a display path keeps showing the literal
  # token, and `token_regions` keeps marking it unknown for the highlighter.
  describe "display paths are unchanged" do
    it "expand still leaves an unregistered token literal" do
      with_vars([{"HOST", "api.test"}]) do
        Gori::Env.expand("GET http://$HOST/p\nAuth: $MISSING").should eq(
          "GET http://api.test/p\nAuth: $MISSING")
      end
    end

    it "token_regions still reports the unknown token rather than raising" do
      with_vars([{"HOST", "h"}]) do
        Gori::Env.token_regions("http://$HOST/$OTHER").should eq([{7, 12, true}, {13, 19, false}])
      end
    end
  end
end

# The point of the issue: it is not enough for ONE builder to refuse. All five expand at
# plan-build time and all five send, so all five are asserted here together — a builder
# that loses the check fails this block rather than quietly shipping the token.
describe "plan builders refuse an unresolved env token (#519)" do
  it "Fuzz::Plan.build refuses and names the token" do
    with_vars([] of {String, String}) do
      options = Gori::Fuzz::PlanOptions.new(
        "GET /a?q=§x§ HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n",
        target: "http://t.test",
        sources: [Gori::Fuzz::InlineList.new(["p"])] of Gori::Fuzz::PayloadSource)
      ex = expect_raises(Gori::Fuzz::PlanError) { Gori::Fuzz::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Fuzz::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SESSION")
    end
  end

  it "Miner::Plan.build refuses and names the token" do
    with_vars([] of {String, String}) do
      options = Gori::Miner::PlanOptions.new(
        "GET /a HTTP/1.1\r\nHost: t.test\r\nCookie: s=$SESSION\r\n\r\n",
        target: "http://t.test")
      ex = expect_raises(Gori::Miner::PlanError) { Gori::Miner::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Miner::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SESSION")
    end
  end

  it "Sequencer::Plan.build refuses and names the token" do
    with_vars([] of {String, String}) do
      loc = Gori::Sequencer::TokenLoc.new(kind: Gori::Sequencer::ExtractKind::Cookie, selector: "sid")
      config = Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay, token_loc: loc, goal: 10)
      options = Gori::Sequencer::PlanOptions.new(
        "GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: $SESSION\r\n\r\n".to_slice,
        target: "http://t.test", config: config)
      ex = expect_raises(Gori::Sequencer::PlanError) { Gori::Sequencer::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Sequencer::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SESSION")
    end
  end

  it "Discover::Plan.build refuses an unresolved SEED and names the token" do
    with_vars([] of {String, String}) do
      options = Gori::Discover::PlanOptions.new("$SEED/api")
      ex = expect_raises(Gori::Discover::PlanError) { Gori::Discover::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Discover::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SEED")
    end
  end

  # Discover expands TWICE inside its builder — the seed and the custom header values —
  # and the header call is the one a "check the target" fix would miss. An unresolved
  # token there rides every probe the crawl sends.
  it "Discover::Plan.build refuses an unresolved custom HEADER and names the token" do
    with_vars([] of {String, String}) do
      config = Gori::Discover::Config.new
      config.headers = [{"Authorization", "Bearer $SESSION"}]
      options = Gori::Discover::PlanOptions.new("https://t.test/", config: config)
      ex = expect_raises(Gori::Discover::PlanError) { Gori::Discover::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Discover::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SESSION")
    end
  end

  it "Repeater::Plan.build refuses and names the token" do
    with_vars([] of {String, String}) do
      options = Gori::Repeater::PlanOptions.new(
        ["GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice],
        target: "http://t.test")
      ex = expect_raises(Gori::Repeater::PlanError) { Gori::Repeater::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Repeater::PlanError::Reason::UnresolvedEnv)
      ex.detail.should eq("$SESSION")
    end
  end

  # `expand_request: false` means the SURFACE already expanded (MCP's RequestBuilder, the
  # TUI editor's byte modes). The token is then already sitting in the bytes handed over,
  # so the builder must still refuse — this is the path a check guarded by
  # `if options.expand_request?` would let straight through.
  it "Repeater::Plan.build refuses pre-expanded bytes too (expand_request: false)" do
    with_vars([] of {String, String}) do
      options = Gori::Repeater::PlanOptions.new(
        ["GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice],
        expand_request: false, target: "http://t.test")
      ex = expect_raises(Gori::Repeater::PlanError) { Gori::Repeater::Plan.build(options, ungated) }
      ex.reason.should eq(Gori::Repeater::PlanError::Reason::UnresolvedEnv)
    end
  end

  it "Repeater::Plan.build refuses an unresolved TARGET and an unresolved SNI" do
    with_vars([] of {String, String}) do
      wire = ["GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice]
      bad_target = Gori::Repeater::PlanOptions.new(wire, target: "http://$HOST")
      expect_raises(Gori::Repeater::PlanError) { Gori::Repeater::Plan.build(bad_target, ungated) }
        .detail.should eq("$HOST")

      bad_sni = Gori::Repeater::PlanOptions.new(wire, target: "https://t.test", sni: "$SNI_HOST")
      expect_raises(Gori::Repeater::PlanError) { Gori::Repeater::Plan.build(bad_sni, ungated) }
        .detail.should eq("$SNI_HOST")
    end
  end

  # The control the refusals are worth nothing without: with the variable SET, every
  # builder proceeds and the value — not the token — is what the plan carries.
  it "builds normally once the variable is set, substituting the value" do
    with_vars([{"SESSION", "s3cr3t"}, {"HOST", "t.test"}]) do
      plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(
        ["GET /a HTTP/1.1\r\nHost: $HOST\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice],
        target: "http://$HOST"), ungated)
      plan.host.should eq("t.test")
      wire = String.new(plan.bytes)
      wire.should contain("Auth: Bearer s3cr3t")
      wire.should_not contain("$SESSION")
    end
  end

  # A body token is deliberately NOT a refusal (see `Env.unresolved_wire`): the body is
  # where a `$` is a byte rather than a reference, and refusing there would block every
  # binary upload replay. Pinned so the narrowing is a stated decision, not an accident.
  it "does not refuse a token in the BODY" do
    with_vars([] of {String, String}) do
      plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(
        ["POST /a HTTP/1.1\r\nHost: t.test\r\n\r\n{\"q\":\"$NOTATOKEN\"}".to_slice],
        target: "http://t.test"), ungated)
      String.new(plan.bytes).should contain("$NOTATOKEN")
    end
  end
end
