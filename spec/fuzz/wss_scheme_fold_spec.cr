require "../spec_helper"

private alias F = Gori::Fuzz

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

private RAWREQ = "GET /chat HTTP/1.1\r\nHost: t.test\r\nCookie: s=secret\r\n\r\n"
private MARKED = "GET /chat?q=§x§ HTTP/1.1\r\nHost: t.test\r\nCookie: s=secret\r\n\r\n"

# `Repeater::Engine`/`H2Engine` decide TLS with `scheme == "https"` ALONE, so a `wss://`
# target that reaches them unfolded dials CLEARTEXT to a TLS port. `Fuzz::Origin` folds
# ws→http / wss→https at construction so every surface that builds one (the Fuzzer/Miner/
# Sequencer Plan builders, Repeater Minimize on TUI/CLI/MCP, Probe active) is correct by
# construction. Before this fold, all of these produced a `wss` origin and dialled plaintext.
describe "Fuzz::Origin scheme fold (wss:// must not dial cleartext)" do
  it "folds ws/wss at direct construction (the Repeater Minimize path)" do
    F::Origin.new("wss", "t.test", 443).scheme.should eq("https")
    F::Origin.new("ws", "t.test", 80).scheme.should eq("http")
    F::Origin.new("https", "t.test", 443).scheme.should eq("https") # unchanged
    F::Origin.new("http", "t.test", 80).scheme.should eq("http")    # unchanged
  end

  it "folds wss in Fuzz::Plan.build" do
    plan = F::Plan.build(
      F::PlanOptions.new(MARKED, target: "wss://t.test/chat",
        sources: [F::InlineList.new(%w[a])] of F::PayloadSource,
        config: F::Config.new(mode: F::Mode::Sniper, concurrency: 1, keep_bodies: :none),
        matcher: F::Matcher.new(keep_bodies: :none), verify: false),
      ungated)
    plan.origin.scheme.should eq("https")
  end

  it "folds wss in Miner::Plan.build" do
    plan = Gori::Miner::Plan.build(
      Gori::Miner::PlanOptions.new(RAWREQ, target: "wss://t.test/chat",
        config: Gori::Miner::Config.new),
      ungated)
    plan.origin.scheme.should eq("https")
  end

  it "folds wss in Sequencer::Plan.build" do
    plan = Gori::Sequencer::Plan.build(
      Gori::Sequencer::PlanOptions.new(RAWREQ.to_slice, target: "wss://t.test/chat",
        config: Gori::Sequencer::Config.new(token_loc: Gori::Sequencer::TokenLoc.cookie("s"))),
      ungated)
    plan.origin!.scheme.should eq("https")
  end
end
