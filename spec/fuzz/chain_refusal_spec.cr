require "../spec_helper"

private alias F = Gori::Fuzz

# `§value¦chain§` naming a converter the run cannot apply must refuse the PLAN, not quietly
# put the raw payload on the wire.
#
# `Template#apply_chains` returns the payload verbatim when its chain does not run, arguing
# that a streaming fuzz run has nowhere to surface a per-position error. That was written when
# the only way to reach it was a typo. The saved-chain library added a class that is not a
# typo: a name the operator saved, that the `^Q` autocomplete offers and `gori run decoder
# list` prints as an ordinary converter, and that the library registered as an always-raising
# step precisely so the failure would be VISIBLE. Reproduced on the wire: five marked
# positions, three naming such a chain, all three carrying the plaintext payload under
# `1 sent · 0 errors`, `"error":null`, `"matched":true`, while `gori run decoder` named the
# identical refusal off the identical registry.

private def with_library(entries : Array({String, String}), &)
  before = Gori::Decoder.library
  Gori::Decoder.library = entries
  begin
    yield
  ensure
    Gori::Decoder.library = before
  end
end

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

private def plan_for(template : String, payload : String = "ff00") : F::Plan
  F::Plan.build(F::PlanOptions.new(template,
    target: "http://t.test",
    sources: [F::InlineList.new([payload])] of F::PayloadSource,
    config: F::Config.new(mode: F::Mode::BatteringRam)), ungated)
end

private def first_request(plan : F::Plan) : String
  out = ""
  # `next`, not `break`: Generator#each takes a CAPTURED block.
  plan.generator.each { |j| out = String.new(j.bytes) if out.empty? }
  out
end

private CHAINS = [
  {"myenc", "base64-encode > upper"},
  {"selfref", "selfref > upper"},
  {"cyc-a", "cyc-b"},
  {"cyc-b", "cyc-a"},
]

describe "Fuzz::Plan chain refusal" do
  it "refuses a plan whose position names a self-referential saved chain" do
    with_library(CHAINS) do
      ex = expect_raises(F::ChainError) do
        plan_for("GET /q?a=§P¦selfref§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
      ex.message.not_nil!.should contain "selfref"
      ex.message.not_nil!.should contain "recursive"
      # It says what would otherwise have happened, and where to look.
      ex.message.not_nil!.should contain "untransformed"
      ex.message.not_nil!.should contain "gori run decoder list"
    end
  end

  it "refuses a plan whose position names a CYCLIC saved chain (either leg)" do
    with_library(CHAINS) do
      ["cyc-a", "cyc-b"].each do |name|
        ex = expect_raises(F::ChainError) do
          plan_for("GET /q?a=§P¦#{name}§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
        end
        ex.message.not_nil!.should contain "recursive"
      end
    end
  end

  it "refuses a plan whose position names an over-MAX_TOKENS saved chain" do
    deep = [{"z0", "upper"}]
    (1..9).each { |i| deep << {"z#{i}", "z#{i - 1} > z#{i - 1}"} }
    with_library(deep) do
      ex = expect_raises(F::ChainError) do
        plan_for("GET /q?a=§P¦z9§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
      ex.message.not_nil!.should contain "expands past 256 steps"
    end
  end

  it "refuses a plan whose position names an UNKNOWN converter" do
    with_library(CHAINS) do
      ex = expect_raises(F::ChainError) do
        plan_for("GET /q?a=§P¦nosuchconv§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
      ex.message.not_nil!.should contain "nosuchconv: unknown converter"
    end
  end

  it "names EVERY bad token in the template, not only the first" do
    with_library(CHAINS) do
      ex = expect_raises(F::ChainError) do
        plan_for("GET /q?a=§P¦selfref§&b=§P¦nosuchconv§&c=§P¦myenc§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
      msg = ex.message.not_nil!
      msg.should contain "selfref"
      msg.should contain "nosuchconv"
      msg.should_not contain "myenc" # the one that works is not blamed
    end
  end

  it "refuses on a bad token ANYWHERE in a multi-step chain, not just the first step" do
    with_library(CHAINS) do
      expect_raises(F::ChainError, /nosuchconv/) do
        plan_for("GET /q?a=§P¦upper > nosuchconv§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
    end
  end

  # ── the complements: everything that must STILL build and still transform ───────────
  it "builds, and TRANSFORMS, a chain that works" do
    with_library(CHAINS) do
      plan = plan_for("GET /q?a=§P¦myenc§ HTTP/1.1\r\nHost: t.test\r\n\r\n")
      # base64("ff00") = ZmYwMA== , uppercased.
      first_request(plan).should contain("a=ZMYWMA==")
    end
  end

  it "builds a chain naming only BUILT-INS" do
    with_library(CHAINS) do
      plan = plan_for("GET /q?a=§P¦upper§ HTTP/1.1\r\nHost: t.test\r\n\r\n", "ffab")
      first_request(plan).should contain("a=FFAB")
    end
  end

  it "builds a template with NO chains at all" do
    with_library(CHAINS) do
      first_request(plan_for("GET /q?a=§P§ HTTP/1.1\r\nHost: t.test\r\n\r\n")).should contain("a=ff00")
    end
  end

  it "does NOT refuse a usable chain that merely fails on THIS payload" do
    # The line the refusal must not cross. `base64-decode` is a perfectly good converter and
    # `!!!!` is not base64 — that is a property of the payload, not of the template, and the
    # next payload in the same set may well succeed. There is nothing to refuse up front, so
    # `apply_chains`' documented per-payload passthrough still owns it.
    with_library(CHAINS) do
      plan = plan_for("GET /q?a=§P¦base64-decode§ HTTP/1.1\r\nHost: t.test\r\n\r\n", "!!!!")
      first_request(plan).should contain("a=!!!!")
    end
  end

  it "does not refuse when an unusable chain is merely SAVED and no position names it" do
    # The library still registers `selfref`/`cyc-a` so their names resolve and their reason is
    # visible in the Decoder tab. Having them in the library must not refuse unrelated runs.
    with_library(CHAINS) do
      first_request(plan_for("GET /q?a=§P§ HTTP/1.1\r\nHost: t.test\r\n\r\n")).should contain("a=ff00")
    end
  end

  it "refuses BEFORE the no-positions / no-payloads checks stop mattering" do
    # Ordering guard: the chain check reads `template.positions`, so it must sit after the
    # parse. A template with no positions still reports NoPositions, not a chain error.
    with_library(CHAINS) do
      ex = expect_raises(F::PlanError) do
        plan_for("GET /q?a=1 HTTP/1.1\r\nHost: t.test\r\n\r\n")
      end
      ex.reason.should eq F::PlanError::Reason::NoPositions
    end
  end
end
