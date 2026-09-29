require "../spec_helper"
require "../support/macro_origin"

private alias RM = Gori::RequestMacro

# The steps of a request-time macro (#1350), driven directly: what one run puts on the wire, what
# it records, and every gate it passes on the way. The Fuzzer, Miner, MCP and CLI specs drive
# whole runs through this; here it is judged alone.

private def runner_for(store : Gori::Store, steps, outbound : Gori::Outbound = ungated_outbound,
                       expect = [] of String) : RM::Runner
  RM::Runner.build(RM::Spec.new(steps, expect: expect), store, outbound)
end

# A budget that pays for `n` requests and then refuses, recording every claim.
private class CountingBudget
  include RM::Budget
  getter claims = [] of Int64
  getter refunds = [] of Int64

  def initialize(@left : Int64)
  end

  def reserve(n : Int64) : Bool
    @claims << n
    return false if n > @left
    @left -= n
    true
  end

  def refund(n : Int64) : Nil
    @refunds << n
  end
end

describe Gori::RequestMacro::Runner do
  it "sends the step, rebinds the extract rule, and records the step in History as source macro" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, bindings, _|
      res = runner_for(store, ["csrf-fetch"]).run(nil, nil)
      res.ok.should be_true
      res.requests.should eq(1)
      res.rebound.should eq(["CSRF"])
      res.flow_ids.size.should eq(1)
      bindings.values["CSRF"].should eq("T1")
      # Never a value in the sentence a surface prints.
      res.message.should eq("macro ok · $CSRF rebound")
      res.message.should_not contain("T1")
      row = store.@db.query_one("SELECT source, source_ref, source_surface FROM flows WHERE id = ?", res.flow_ids.first,
        as: {String, String?, String?})
      row[0].should eq("macro")
      row[1].should eq("macro step 1")
    end
    origin.close
  end

  it "runs every step in order and stops at the first that fails" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, csrf|
      origin.fail_forms = Set{2}
      second = store.insert_repeater("http://127.0.0.1:#{origin.port}",
        "GET /form?again=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
      third = store.insert_repeater("http://127.0.0.1:#{origin.port}",
        "GET /form?third=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 2)
      r = runner_for(store, ["#{csrf}", "#{second}", "#{third}"])
      res = r.run(nil, nil)
      res.ok.should be_false
      res.failed_step.should eq(2)
      res.status.should eq(500)
      res.requests.should eq(2) # the third never went out
      origin.paths.should eq(["/form", "/form?again=1"])
      res.detail.should contain("failed at step 2 (GET /form?again=1 → 500)")
    end
    origin.close
  end

  it "sends the steps as the ACTIVE session slot, overlay included" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, bindings, _|
      slots = bindings.slots.not_nil!
      slots.save([Gori::SessionSlot.new("acme", set_headers: [{"X-Who", "acme-admin"}], rules: ["CSRF"])])
      slots.activate("acme")
      res = runner_for(store, ["csrf-fetch"]).run(nil, nil)
      res.ok.should be_true
      origin.form_heads.first.should contain("X-Who: acme-admin")
      # …and the rebind lands in THAT slot's table, which is the one the candidates resolve from.
      bindings.values["CSRF"].should eq("T1")
      bindings.rows.find { |r| r.slot == "acme" }.not_nil!.bound?.should be_true
    end
    origin.close
  end

  it "holds each step to the run's rate and charges it to the run's budget" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, csrf|
      second = store.insert_repeater("http://127.0.0.1:#{origin.port}",
        "GET /form?b=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
      paced = 0
      budget = CountingBudget.new(10_i64)
      res = runner_for(store, ["#{csrf}", "#{second}"]).run(budget, -> { paced += 1; nil })
      res.ok.should be_true
      paced.should eq(2)
      budget.claims.should eq([1_i64, 1_i64])
    end
    origin.close
  end

  it "reports a spent budget as the budget, sending nothing it could not pay for" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, csrf|
      second = store.insert_repeater("http://127.0.0.1:#{origin.port}",
        "GET /form?b=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
      res = runner_for(store, ["#{csrf}", "#{second}"]).run(CountingBudget.new(1_i64), nil)
      res.ok.should be_false
      res.budget_exhausted.should be_true
      res.requests.should eq(1) # the first step was paid for and went out
      res.error_text.should eq(RM::BUDGET_ERROR)
      origin.paths.should eq(["/form"])
    end
    origin.close
  end

  it "stops between steps when the run was stopped, and calls it neither a failure nor an error" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, csrf|
      second = store.insert_repeater("http://127.0.0.1:#{origin.port}",
        "GET /form?b=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
      asked = 0
      res = runner_for(store, ["#{csrf}", "#{second}"]).run(nil, nil, -> { (asked += 1) > 1 })
      res.stopped.should be_true
      res.requests.should eq(1)
      origin.paths.should eq(["/form"])
      # Through the lane, a stop between steps is a cancelled candidate — not a skipped one, and
      # not a failure. (The lane asks once before opening an epoch and once after the drain, so
      # the third question lands between the steps.)
      stops = 0
      lane = RM::Lane.new(RM::Spec.new(["csrf-fetch"]), runner_for(store, ["#{csrf}", "#{second}"]))
        .attach(nil, nil, -> { (stops += 1) > 3 })
      e = lane.enter
      e.cancelled?.should be_true
      e.refused?.should be_false
      lane.tally.failed.should eq(0)
      lane.tally.skipped.should eq(0)
      lane.aborted?.should be_false
    end
    origin.close
  end

  describe "which bindings it looks at" do
    it "sees the unclaimed rules and the active slot's, and no other slot's" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |_, bindings, _|
        bindings.add("NONCE", "", Gori::ExtractKind::Header, "x-nonce").should be_nil
        bindings.add("OTHER", "", Gori::ExtractKind::Header, "x-other").should be_nil
        slots = bindings.slots.not_nil!
        slots.save([Gori::SessionSlot.new("acme", rules: ["NONCE"]), Gori::SessionSlot.new("beta", rules: ["OTHER"])])
        RM::Runner.visible(bindings).keys.sort!.should eq(["CSRF"]) # as captured: a claimed rule is another identity's
        slots.activate("acme")
        RM::Runner.visible(bindings).keys.sort!.should eq(["CSRF", "NONCE"])
        slots.activate("beta")
        RM::Runner.visible(bindings).keys.sort!.should eq(["CSRF", "OTHER"])
      end
      origin.close
    end

    it "refuses an expected binding the active slot cannot see" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, bindings, _|
        bindings.add("OTHER", "", Gori::ExtractKind::Header, "x-other").should be_nil
        slots = bindings.slots.not_nil!
        slots.save([Gori::SessionSlot.new("acme"), Gori::SessionSlot.new("beta", rules: ["OTHER"])])
        slots.activate("acme")
        err = expect_raises(RM::Error) { runner_for(store, ["csrf-fetch"], expect: ["OTHER"]) }
        err.message.not_nil!.should contain("expects $OTHER")
        err.message.not_nil!.should contain("visible: $CSRF")
      end
      origin.close
    end
  end

  describe "Layer 2" do
    it "refuses a step Sandbox does not allow, at run time and before the socket" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "elsewhere.test")
        scope.enable_sandbox
        r = runner_for(store, ["csrf-fetch"], Gori::Outbound.interactive(scope))
        res = r.run(nil, nil)
        res.ok.should be_false
        res.reason.should eq(Gori::Outbound::SANDBOX_SWEEP_ERROR)
        origin.paths.should be_empty
        res.requests.should eq(0)
      end
      origin.close
    end

    it "holds an explicit exclude for the macro, which is a sweep's traffic, as it does for the candidates" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        scope = Gori::Scope.load(store)
        scope.add("exclude", "host", "127.0.0.1")
        r = runner_for(store, ["csrf-fetch"], Gori::Outbound.interactive(scope))
        res = r.run(nil, nil)
        res.ok.should be_false
        res.reason.should eq(Gori::Outbound::EXCLUDE_SWEEP_ERROR)
        origin.paths.should be_empty
      end
      origin.close
    end

    it "re-asks Layer 1 on every run, so a scope edited mid-run stops the next one" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "127.0.0.1")
        r = runner_for(store, ["csrf-fetch"], Gori::Outbound.agent(scope, false))
        r.run(nil, nil).ok.should be_true
        # A scope that no longer covers the host is refused on the next run.
        scope.add("include", "host", "someone-else.test")
        scope.rules.select { |rule| rule.pattern == "127.0.0.1" }.each { |rule| scope.remove(rule.id) }
        res = r.run(nil, nil)
        res.ok.should be_false
        res.reason.not_nil!.should contain("out of the project scope")
        origin.paths.size.should eq(1)
      end
      origin.close
    end
  end

  describe "what it refuses to build" do
    it "a WebSocket handshake, which is one request and no response" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        ws = store.insert_repeater("http://127.0.0.1:#{origin.port}",
          "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".to_slice,
          false, true, nil, 1)
        expect_raises(RM::Error, /WebSocket handshake/) { runner_for(store, ["#{ws}"]) }
      end
      origin.close
    end

    it "a session whose target cannot be built, naming the step" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        bad = store.insert_repeater("", "GET /form HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
        err = expect_raises(RM::Error) { runner_for(store, ["csrf-fetch", "#{bad}"]) }
        err.message.not_nil!.should contain("macro step 2")
        err.message.not_nil!.should contain("could not be built")
      end
      origin.close
    end

    it "a run with no bindings loaded at all" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        Gori::Env.layer = nil
        expect_raises(RM::Error, /session bindings/) { runner_for(store, ["csrf-fetch"]) }
      end
      origin.close
    end
  end
end
