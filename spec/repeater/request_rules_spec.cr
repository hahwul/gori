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

  # The raw chunked wire form used to go to the body rules: a literal grew a chunk past its
  # stated size (broken framing on the wire) and a json op never parsed.
  it "rewrites a chunked body's entity, as the proxy does, and re-chunks it" do
    with_store do |store|
      json = Gori::Store::MatchRule.new(0_i64, true, Gori::Store::RuleTarget::Request,
        Gori::Store::RulePart::Body, "role", %("admin"), Gori::Store::RuleOp::JsonSet)
      plan = rules_plan("POST /x HTTP/1.1\r\nHost: t.test\r\nTransfer-Encoding: chunked\r\n\r\nE\r\n{\"role\":\"abc\"}\r\n0\r\n\r\n")
      sent, changed = Gori::Repeater::RequestRules.apply(plan, Gori::Rules.new(store, [json, body_rule("abc", "abcdef")]))
      changed.should be_true
      String.new(sent.bytes).should eq("POST /x HTTP/1.1\r\nHost: t.test\r\nTransfer-Encoding: chunked\r\n\r\n" \
                                       "10\r\n{\"role\":\"admin\"}\r\n0\r\n\r\n")
      rw = sent.rewrite.not_nil!
      rw.hits.size.should eq(1) # the json op; the literal then had no `abc` left to match
      String.new(rw.body.not_nil!).should eq("E\r\n{\"role\":\"abc\"}\r\n0\r\n\r\n")
    end
  end

  it "leaves a chunked body alone when a re-chunk would drop its extensions, trailer or tail" do
    with_store do |store|
      raw = "POST /x HTTP/1.1\r\nHost: t.test\r\nTransfer-Encoding: chunked\r\n\r\n" \
            "5;ext=1\r\nhello\r\n0\r\nX-Trailer: t\r\n\r\nGET /admin HTTP/1.1\r\nHost: t.test\r\n\r\n"
      sent, changed = Gori::Repeater::RequestRules.apply(rules_plan(raw), Gori::Rules.new(store, [body_rule("hello", "HELLO")]))
      changed.should be_false
      sent.bytes.should eq(raw.to_slice)
    end
  end

  it "names only the rules whose change was sent, as the proxy does" do
    with_store do |store|
      plan = rules_plan("POST /x HTTP/1.1\r\nHost: t.test\r\nX-A: 1\r\nContent-Length: 2\r\n\r\nab")
      rules = Gori::Rules.new(store, store.match_rules)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body, "ab", "zz")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Body, "zz", "ab")
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A: 1", "X-A: 2")
      sent, changed = Gori::Repeater::RequestRules.apply(plan, rules)
      changed.should be_true
      sent.rewrite.not_nil!.hits.size.should eq(1) # the head rule; the body rules cancelled out
    end
  end

  it "leaves a compressed body alone, as the proxy does" do
    with_store do |store|
      plan = rules_plan("POST /x HTTP/1.1\r\nHost: t.test\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nab")
      sent, changed = Gori::Repeater::RequestRules.apply(plan, Gori::Rules.new(store, [body_rule("ab", "abcd")]))
      changed.should be_false
      sent.bytes.should eq(plan.bytes)
    end
  end
end
