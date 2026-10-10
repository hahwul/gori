require "../spec_helper"

private def rules_plan(raw : String) : Gori::Repeater::Plan
  Gori::Repeater::Plan.build(Gori::Repeater::PlanOptions.new([raw.to_slice], target: "http://t.test",
    auto_content_length: false, expand_request: false), ungated_outbound)
end

private def head_rule(match : String, replace : String) : Gori::Store::MatchRule
  Gori::Store::MatchRule.new(0_i64, true, Gori::Store::RuleTarget::Request,
    Gori::Store::RulePart::Head, match, replace)
end

private def body_rule(match : String, replace : String) : Gori::Store::MatchRule
  Gori::Store::MatchRule.new(0_i64, true, Gori::Store::RuleTarget::Request,
    Gori::Store::RulePart::Body, match, replace)
end

describe Gori::Repeater::RequestRules do
  # `apply_rules` builds with auto-CL OFF on purpose, so a wrong length is the operator's
  # probe. An enabled rule that matched nothing used to re-sync it anyway and report a change.
  it "leaves a deliberately wrong Content-Length alone when no rule matched" do
    with_store do |store|
      plan = rules_plan("POST /x HTTP/1.1\r\nHost: t.test\r\nContent-Length: 99\r\n\r\nab")
      sent, changed = Gori::Repeater::RequestRules.apply(plan, Gori::Rules.new(store, [head_rule("X-Absent", "X-Other")]))
      changed.should be_false
      sent.bytes.should eq(plan.bytes)
    end
  end

  it "re-syncs the length when a rule changed the body's size" do
    with_store do |store|
      plan = rules_plan("POST /x HTTP/1.1\r\nHost: t.test\r\nContent-Length: 2\r\n\r\nab")
      sent, changed = Gori::Repeater::RequestRules.apply(plan, Gori::Rules.new(store, [body_rule("ab", "abcd")]))
      changed.should be_true
      String.new(sent.bytes).should eq("POST /x HTTP/1.1\r\nHost: t.test\r\nContent-Length: 4\r\n\r\nabcd")
    end
  end
end
