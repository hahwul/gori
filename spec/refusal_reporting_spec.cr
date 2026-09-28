require "./spec_helper"

# "The run was refused" must never render as "the run found nothing."
#
# For a security tool that is the worst failure mode there is: a false negative wearing a
# clean bill of health. Four separate paths landed on it, and all four are pinned here.
describe "refusal reporting" do
  describe "Gori::Outbound::Verdict#excluded?" do
    it "separates an EXCLUDE match from 'no include matched'" do
      # Both used to arrive as a bare out_of_scope, and every surface then advised "add a
      # scope include rule" — advice that cannot work against an exclude, because an
      # include never overrides one. The rule to NAME is the one to delete.
      store = Gori::Store.open(File.tempname("gori-excl", ".db"))
      begin
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.add("exclude", "string", "/logout")
        ob = Gori::Outbound.agent(scope, false)

        excluded = ob.check("http://acme.test/logout", "acme.test")
        excluded.blocked?.should be_true
        excluded.excluded?.should be_true

        no_include = ob.check("http://other.test/", "other.test")
        no_include.blocked?.should be_true
        no_include.excluded?.should be_false

        allowed = ob.check("http://acme.test/ok", "acme.test")
        allowed.blocked?.should be_false
        allowed.excluded?.should be_false
      ensure
        store.close
      end
    end

    it "phrases the remedy from the reason, not from the block" do
      excluded = Gori::Outbound::Verdict.new("out_of_scope", "h", nil, true, true)
      plain = Gori::Outbound::Verdict.new("out_of_scope", "h", nil, true, false)

      Gori::Outbound.remedy(excluded, "--allow-unscoped").should contain("EXCLUDE")
      Gori::Outbound.remedy(excluded, "--allow-unscoped").should_not contain("add a scope include rule")
      Gori::Outbound.remedy(plain, "--allow-unscoped").should eq("add a scope include rule or pass --allow-unscoped")
      Gori::Outbound.remedy(plain, nil).should eq("add a scope include rule")
    end

    it "hands a fix the reader cannot make to the operator, one fix at a time" do
      excluded = Gori::Outbound::Verdict.new("out_of_scope", "h", nil, true, true)
      plain = Gori::Outbound::Verdict.new("out_of_scope", "h", nil, true, false)

      Gori::Outbound.remedy(plain, "allow_unscoped:true", add_include: false)
        .should eq("pass allow_unscoped:true, or ask the operator to add a scope include rule")
      Gori::Outbound.remedy(plain, nil, add_include: false).should eq("ask the operator to add a scope include rule")
      # No waiver lifts an exclude, so the operator is the only fix offered.
      Gori::Outbound.remedy(excluded, "allow_unscoped:true", edit_exclude: false)
        .should eq("ask the operator to delete or narrow the scope EXCLUDE rule that matches it (an include rule cannot override an exclude)")
      # Each fix is judged on its own: a reader that may add an include but not delete one
      # is still told to add one.
      Gori::Outbound.remedy(plain, "allow_unscoped:true", edit_exclude: false)
        .should eq("add a scope include rule or pass allow_unscoped:true")
      Gori::Outbound.remedy(excluded, nil, add_include: false).should contain("delete or narrow")
      Gori::Outbound.remedy(excluded, nil, add_include: false).should_not contain("ask the operator")
    end
  end

  describe "Gori::Fuzz::Backend#blocked" do
    it "counts refused sends and keeps the first reason, so a fully-refused run is legible" do
      # Without this a run where every send was refused reported `sent:N, matched:0` with an
      # empty result list — indistinguishable from "the payloads were tried and nothing
      # matched". The refusals DID produce errored Results, but `errors` also covers
      # timeouts and 500s, so the number could not carry the distinction.
      store = Gori::Store.open(File.tempname("gori-blk", ".db"))
      begin
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.enable_sandbox
        sender = Gori::Fuzz::Sender.new(
          Gori::Fuzz::Origin.new("http", "evil.test", 80),
          Gori::Outbound.agent(scope, true), false, false)

        sender.blocked.should eq(0)
        sender.blocked_reason.should be_nil

        res = sender.send("GET /x HTTP/1.1\r\nHost: evil.test\r\n\r\n".to_slice)
        res.error.should_not be_nil
        sender.blocked.should eq(1)
        sender.blocked_reason.should eq(res.error)
      ensure
        store.close
      end
    end

    it "is delegated by CappedBackend, which is what the Engine actually holds" do
      # A default-0 stopping at the outermost wrapper would report "nothing was blocked"
      # for every gated run there is.
      store = Gori::Store.open(File.tempname("gori-blk2", ".db"))
      begin
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        scope.enable_sandbox
        inner = Gori::Fuzz::Sender.new(
          Gori::Fuzz::Origin.new("http", "evil.test", 80),
          Gori::Outbound.agent(scope, true), false, false)
        capped = Gori::Fuzz::CappedBackend.new(inner, nil)

        capped.send("GET /x HTTP/1.1\r\nHost: evil.test\r\n\r\n".to_slice)
        capped.blocked.should eq(1)
        capped.blocked_reason.should_not be_nil
      ensure
        store.close
      end
    end

    it "leaves an ungated backend at zero" do
      Gori::Fuzz::CappedBackend.new(SilentBackend.new, nil).blocked.should eq(0)
    end
  end
end

# A Backend that neither gates nor dials — the "nothing was refused" control.
private class SilentBackend < Gori::Fuzz::Backend
  def origin : Gori::Fuzz::Origin
    Gori::Fuzz::Origin.new("http", "h", 80)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, nil)
  end
end
