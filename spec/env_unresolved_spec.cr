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

  # `.unresolved_wire` is GONE. It existed for exactly one caller — the plan builders'
  # head-only refusal (#519) — and the owner retired that: a `$NAME` with no value is a
  # literal string on the wire, head and body alike. `.unresolved` survives because the DIAL
  # TUPLE still refuses (a `$` is not a legal byte in a hostname), and these pin that a
  # request head is now left alone by everything.
  describe "the head is no longer refused" do
    it "expands a head whose token resolves and leaves an unset one literal" do
      with_vars([{"HEADTOKEN", "HV"}]) do
        wire = "POST /p HTTP/1.1\r\nX-A: $HEADTOKEN\r\nX-B: $NOPE\r\n\r\n{\"q\":\"$BODYTOKEN\"}"
        String.new(Gori::Env.expand_wire(wire))
          .should eq("POST /p HTTP/1.1\r\nX-A: HV\r\nX-B: $NOPE\r\n\r\n{\"q\":\"$BODYTOKEN\"}")
      end
    end

    it "leaves a binary body untouched, and no longer needs a head/body split to do it" do
      with_vars([] of {String, String}) do
        # The reason the check USED to be head-only: `$` followed by [A-Za-z_] occurs by
        # chance about once per 1.2KB of high-entropy bytes, so a whole-request refusal
        # would have blocked essentially every replay of a compressed or encrypted upload.
        # Nothing refuses now, so the hazard is gone rather than narrowed — pinned because a
        # future check that forgets the reasoning would resurrect it.
        body = Bytes.new(4096) { |i| (i * 31 + 7).to_u8! }
        body[100] = 0x24_u8 # '$'
        body[101] = 0x41_u8 # 'A'
        body[900] = 0x24_u8
        body[901] = 0x5F_u8 # '_'
        wire = String.new("POST /u HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice + body)
        Gori::Env.unresolved(wire).should_not be_empty # a REPORT, not a gate
        String.new(Gori::Env.expand_wire(wire)).should eq(wire)
      end
    end

    it "leaves a head-only buffer (no blank line) literal too" do
      with_vars([] of {String, String}) do
        head = "GET /$MISSING HTTP/1.1\r\nHost: t.test"
        String.new(Gori::Env.expand_wire(head)).should eq(head)
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

# ROUND 7, OWNER POLICY — this block is INVERTED, deliberately.
#
# #519 made all five plan builders REFUSE an unresolved `$NAME` in the request head, and
# this block existed to stop any one of them losing that check. The owner retired the rule:
# a `$NAME` with a value is followed, and without one it is a literal string on the wire.
# The token grammar is byte-identical to GraphQL's `$id`, Mongo's `$ne` and JSON Schema's
# `$ref`, so the refusal made a parameterised GraphQL query, a Mongo filter and an OpenAPI
# document unsendable from every engine.
#
# So all five are asserted together again, for the opposite fact: a builder that RE-ADDS the
# check fails this block. What each builder still refuses is its DIAL TUPLE — see the target
# examples further down; `$` is not a legal byte in a hostname, so no operator test case is
# lost there, and a literal one comes back as an out-of-scope block naming the wrong gate.
describe "plan builders no longer refuse an unresolved env token in the head" do
  it "Fuzz::Plan.build sends the token literally" do
    with_vars([] of {String, String}) do
      options = Gori::Fuzz::PlanOptions.new(
        "GET /a?q=§x§ HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n",
        target: "http://t.test",
        sources: [Gori::Fuzz::InlineList.new(["p"])] of Gori::Fuzz::PayloadSource)
      Gori::Fuzz::Plan.build(options, ungated).template.to_s.should contain("Bearer $SESSION")
    end
  end

  it "Miner::Plan.build sends the token literally" do
    with_vars([] of {String, String}) do
      options = Gori::Miner::PlanOptions.new(
        "GET /a HTTP/1.1\r\nHost: t.test\r\nCookie: s=$SESSION\r\n\r\n",
        target: "http://t.test")
      String.new(Gori::Miner::Plan.build(options, ungated).request).should contain("s=$SESSION")
    end
  end

  it "Sequencer::Plan.build sends the token literally" do
    with_vars([] of {String, String}) do
      loc = Gori::Sequencer::TokenLoc.new(kind: Gori::Sequencer::ExtractKind::Cookie, selector: "sid")
      config = Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay, token_loc: loc, goal: 10)
      options = Gori::Sequencer::PlanOptions.new(
        "GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: $SESSION\r\n\r\n".to_slice,
        target: "http://t.test", config: config)
      String.new(Gori::Sequencer::Plan.build(options, ungated).request).should contain("Auth: $SESSION")
    end
  end

  # The COMPLEMENT for all three: a token that HAS a value still resolves. The policy is
  # "follow the value if there is one", not "stop expanding".
  it "still expands a head token that HAS a value" do
    with_vars([{"SESSION", "s3cr3t"}]) do
      options = Gori::Miner::PlanOptions.new(
        "GET /a HTTP/1.1\r\nHost: t.test\r\nCookie: s=$SESSION\r\n\r\n",
        target: "http://t.test")
      wire = String.new(Gori::Miner::Plan.build(options, ungated).request)
      wire.should contain("s=s3cr3t")
      wire.should_not contain("$SESSION")
    end
  end

  # …and the complement, which is what those three were missing. "Send this capture to the
  # fuzzer / miner / sequencer" is the MAIN consumer of a captured flow, and the refusal above
  # made every OData / Mongo / SSTI capture unsweepable while `gori run repeater <same-flow>`
  # replayed it fine. Same `evidence?` flag, same meaning and same two policies as
  # `Repeater::PlanOptions#evidence?` — see spec/repeater/evidence_provenance_spec.cr.
  it "Fuzz::Plan.build does NOT refuse, and does not substitute, on EVIDENCE" do
    with_vars([{"filter", "PWNED"}]) do
      options = Gori::Fuzz::PlanOptions.new(
        "GET /a?$filter=§x§&$top=10 HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n",
        evidence: true, target: "http://t.test",
        sources: [Gori::Fuzz::InlineList.new(["p"])] of Gori::Fuzz::PayloadSource)
      plan = Gori::Fuzz::Plan.build(options, ungated)
      wire = String.new(plan.generator.baseline_request)
      wire.should contain("$filter=")
      wire.should contain("$top=10")
      wire.should contain("Bearer $SESSION")
      wire.should_not contain("PWNED")
    end
  end

  it "Miner::Plan.build does NOT refuse, and keeps a bare-LF head, on EVIDENCE" do
    with_vars([{"where", "XX"}]) do
      raw = "POST /a HTTP/1.1\nHost: t.test\nContent-Length: 9\n\n{\"$where\"}"
      options = Gori::Miner::PlanOptions.new(raw, evidence: true, target: "http://t.test")
      String.new(Gori::Miner::Plan.build(options, ungated).request).should eq(raw)
    end
  end

  it "Sequencer::Plan.build does NOT refuse, and keeps a bare-LF head, on EVIDENCE" do
    with_vars([{"top", "9"}]) do
      raw = "GET /a?$top=10 HTTP/1.1\nHost: t.test\nAuth: $SESSION\n\n"
      loc = Gori::Sequencer::TokenLoc.new(kind: Gori::Sequencer::ExtractKind::Cookie, selector: "sid")
      config = Gori::Sequencer::Config.new(mode: Gori::Sequencer::Mode::LiveReplay, token_loc: loc, goal: 10)
      options = Gori::Sequencer::PlanOptions.new(raw.to_slice, evidence: true,
        target: "http://t.test", config: config)
      String.new(Gori::Sequencer::Plan.build(options, ungated).request).should eq(raw)
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

  # Discover expands TWICE inside its builder — the seed and the custom header values. The
  # SEED keeps its refusal (it is the dial tuple); the HEADERS lost theirs, and that is the
  # example the owner named: `--header 'X-Mongo: $ne'` must reach the wire as written.
  it "Discover::Plan.build sends an unresolved custom HEADER literally" do
    with_vars([] of {String, String}) do
      config = Gori::Discover::Config.new
      config.headers = [{"X-Mongo", "$ne"}, {"Authorization", "Bearer $SESSION"}]
      options = Gori::Discover::PlanOptions.new("https://t.test/", config: config)
      Gori::Discover::Plan.build(options, ungated).config.headers
        .should eq([{"X-Mongo", "$ne"}, {"Authorization", "Bearer $SESSION"}])
    end
  end

  it "Repeater::Plan.build sends the token literally" do
    with_vars([] of {String, String}) do
      options = Gori::Repeater::PlanOptions.new(
        ["GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice],
        target: "http://t.test")
      String.new(Gori::Repeater::Plan.build(options, ungated).bytes).should contain("Bearer $SESSION")
    end
  end

  # `expand_request: false` means the SURFACE already expanded (MCP's RequestBuilder, the
  # TUI editor's byte modes). This used to be the path a check guarded by
  # `if options.expand_request?` would let through, so the builder refused regardless. It
  # now ships those bytes as handed over, which is what `verbatim` always meant.
  it "Repeater::Plan.build sends pre-expanded bytes literally too (expand_request: false)" do
    with_vars([] of {String, String}) do
      options = Gori::Repeater::PlanOptions.new(
        ["GET /a HTTP/1.1\r\nHost: t.test\r\nAuth: Bearer $SESSION\r\n\r\n".to_slice],
        expand_request: false, target: "http://t.test")
      String.new(Gori::Repeater::Plan.build(options, ungated).bytes).should contain("Bearer $SESSION")
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

  # No token is a refusal any more, in the body or the head. Kept as the body half of that
  # pair; the head half is the example below it.
  it "does not refuse a token in the BODY" do
    with_vars([] of {String, String}) do
      plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(
        ["POST /a HTTP/1.1\r\nHost: t.test\r\n\r\n{\"q\":\"$NOTATOKEN\"}".to_slice],
        target: "http://t.test"), ungated)
      String.new(plan.bytes).should contain("$NOTATOKEN")
    end
  end

  # INVERTED for the owner's round-7 policy. This used to assert `Plan.build` RAISED
  # `UnresolvedEnv` for a head token, which made a GraphQL `?query=…$id…`, a Mongo `$where`
  # header and a JSON Schema `$ref` header unsendable from every repeater surface.
  it "does not refuse a token in the HEAD either, and ships it literally" do
    with_vars([] of {String, String}) do
      plan = Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(
        ["GET /graphql?query=q($id)&f=$ne HTTP/1.1\r\nHost: t.test\r\nX-Ref: $ref\r\n\r\n".to_slice],
        target: "http://t.test"), ungated)
      wire = String.new(plan.bytes)
      wire.should contain("/graphql?query=q($id)&f=$ne")
      wire.should contain("X-Ref: $ref")
    end
  end

  # The DIAL TUPLE keeps its refusal, and that is the deliberate exception: `$` is not a
  # legal byte in a hostname, so there is no operator test case to protect, and a literal
  # `$HOST` there comes back as an out-of-scope block naming a gate that was never involved.
  it "still refuses an unresolved token in the TARGET" do
    with_vars([] of {String, String}) do
      expect_raises(Gori::Repeater::PlanError) do
        Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new(
          ["GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n".to_slice],
          target: "http://$NOHOST.test"), ungated)
      end
    end
  end
end
