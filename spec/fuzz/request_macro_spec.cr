require "../spec_helper"
require "../support/macro_origin"

private alias F = Gori::Fuzz
private alias RM = Gori::RequestMacro

# Request-time macros in the Fuzzer (#1350). The origin below is a real socket, because the
# property under test is what reaches the WIRE: a form token that is invalidated the moment it
# is redeemed, handed out by `GET /form` and redeemed by `GET /submit`.

private def template(origin : MacroTokenOrigin, token : String = "$CSRF") : String
  "GET /submit?v=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: #{token}\r\n\r\n"
end

private def plan_for(origin : MacroTokenOrigin, store : Gori::Store, spec : RM::Spec?, *,
                     payloads : Int32 = 5, concurrency : Int32 = 1, retries : Int32 = 0,
                     max_requests : Int64? = nil, race : Int32? = nil,
                     text : String = template(origin), evidence : Bool = false,
                     calibrate : Bool = false, throttle_ms : Int32? = nil) : F::Plan
  values = (1..payloads).map { |i| "p#{i}" }
  config = F::Config.new(concurrency: concurrency, retries: retries, retry_pause: 1.millisecond,
    keep_alive: false, max_requests: max_requests, race_count: race, request_macro: spec,
    auto_calibrate: calibrate, throttle_ms: throttle_ms)
  options = F::PlanOptions.new(text, target: "http://127.0.0.1:#{origin.port}",
    sources: [F::InlineList.new(values).as(F::PayloadSource)],
    config: config, matcher: F::Matcher.new(keep_bodies: :none), project: store, evidence: evidence)
  F::Plan.build(options, ungated_outbound)
end

# Drain a run: its rows (in the order they were reported), its last progress and every error.
private record Ran, rows : Array(F::Result), progress : F::Progress, errors : Array(String)

private def drain(plan : F::Plan) : Ran
  rows = [] of F::Result
  errors = [] of String
  last = F::Progress.new(0_i64, nil, 0_i64, 0_i64)
  plan.engine.run do |ev|
    case ev
    in F::ResultEvent   then rows << ev.result
    in F::ProgressEvent then last = ev.progress
    in F::DoneEvent     then last = ev.progress
    in F::ErrorEvent    then errors << ev.message
    end
  end
  Ran.new(rows.sort_by(&.index), last, errors)
end

private def spec_for(steps = ["csrf-fetch"], every = 1, on_failure = RM::OnFailure::Skip,
                     expect = [] of String) : RM::Spec
  RM::Spec.new(steps, RM::Cadence.new(every), on_failure, expect)
end

describe "Fuzz request-time macro" do
  it "control: a captured token works for one candidate and 403s the rest" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, bindings, _|
      # Bind the token the way a real session would have — by observing a response — and sweep.
      head = "HTTP/1.1 200 OK\r\nX-CSRF: #{origin.mint}\r\nContent-Length: 0\r\n\r\n".to_slice
      bindings.observe(Gori::Repeater::Result.new(head, Bytes.empty,
        Gori::Proxy::Codec::Http1.parse_response_head(head), 1_i64, nil),
        Gori::InterceptFilter::Subject.new(method: "GET", host: "127.0.0.1", target: "/form",
          scheme: "http", status: 200))
      ran = drain(plan_for(origin, store, nil, payloads: 3))
      ran.rows.map(&.status).should eq([200, 403, 403])
    end
    origin.close
  end

  it "gives every candidate a fresh token when the cadence is every request" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      ran = drain(plan_for(origin, store, spec_for, payloads: 5))
      ran.errors.should be_empty
      ran.rows.map(&.status).should eq([200] * 5)
      origin.forms.should eq(5)
      origin.submits.map(&.[0]).uniq!.size.should eq(5) # no candidate reused a response's value
      ran.progress.request_macro.not_nil!.runs.should eq(5)
      ran.progress.request_macro.not_nil!.requests.should eq(5)
    end
    origin.close
  end

  it "does the same at any concurrency, because a one-time token is never shared" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, spec_for, payloads: 12, concurrency: 8)
      plan.request_macro_info.not_nil!.concurrency.should eq(1)
      ran = drain(plan)
      ran.rows.map(&.status).should eq([200] * 12)
      origin.forms.should eq(12)
    end
    origin.close
  end

  it "shares one value among N candidates and counts them in dispatch order" do
    origin = MacroTokenOrigin.new
    origin.max_uses = 2
    with_macro_project(origin) do |store, _, _|
      ran = drain(plan_for(origin, store, spec_for(every: 2), payloads: 5))
      ran.rows.map(&.status).should eq([200] * 5)
      origin.forms.should eq(3) # candidates 0,2,4 open an epoch
      origin.submits.map(&.[0]).should eq(["T1", "T1", "T2", "T2", "T3"])
    end
    origin.close
  end

  it "keeps the epochs apart under concurrency" do
    origin = MacroTokenOrigin.new
    origin.max_uses = 3
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, spec_for(every: 3), payloads: 9, concurrency: 8)
      plan.request_macro_info.not_nil!.concurrency.should eq(3)
      ran = drain(plan)
      ran.rows.map(&.status).should eq([200] * 9)
      origin.forms.should eq(3)
      origin.submits.group_by(&.[0]).each_value(&.size.should(eq(3)))
    end
    origin.close
  end

  it "keeps a candidate's worth of budget when calibration shares a tight cap with the macro" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      # cap 5, one step per sample: two requests a sample, and one candidate plus its step
      # held back. One sample fits; the sweep still has a request to send.
      plan = plan_for(origin, store, spec_for, payloads: 3, calibrate: true, max_requests: 5_i64)
      plan.engine.calibrate_baseline
      origin.forms.should eq(1)
      origin.paths.size.should eq(2)
      ran = drain(plan)
      ran.rows.any? { |row| row.status == 200 }.should be_true
      origin.paths.size.should be <= 5
    end
    origin.close
  end

  it "gives a calibration sample a fresh value too, or the baseline it draws would be a baseline of 403s" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, spec_for, payloads: 3, calibrate: true)
      plan.engine.calibrate_baseline
      origin.submits.size.should eq(F::Engine::CALIBRATION_SAMPLES)
      origin.submits.map(&.[1]).uniq!.should eq([200])
      ran = drain(plan)
      ran.rows.map(&.status).should eq([200] * 3)
      origin.forms.should eq(F::Engine::CALIBRATION_SAMPLES + 3)
      origin.submits.map(&.[0]).uniq!.size.should eq(F::Engine::CALIBRATION_SAMPLES + 3)
    end
    origin.close
  end

  it "holds the macro's steps to the run's rate, since they are its traffic" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      # 3 candidates and 3 macro runs are 6 requests on one clock: 5 gaps of 80 ms. Without the
      # steps on that clock the run is 2 gaps.
      plan = plan_for(origin, store, spec_for, payloads: 3, throttle_ms: 80)
      started = Time.instant
      ran = drain(plan)
      elapsed = Time.instant - started
      ran.rows.map(&.status).should eq([200] * 3)
      elapsed.should be > 300.milliseconds
    end
    origin.close
  end

  it "stops sending when the run is stopped: a candidate waiting at the gate runs no login" do
    origin = MacroTokenOrigin.new
    origin.submit_delay = 250.milliseconds
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, spec_for, payloads: 10, concurrency: 8)
      rows = [] of F::Result
      errors = [] of String
      finished = Channel(Nil).new
      spawn do
        plan.engine.run do |ev|
          rows << ev.result if ev.is_a?(F::ResultEvent)
          errors << ev.message if ev.is_a?(F::ErrorEvent)
        end
        finished.send(nil)
      end
      # The first candidate is in flight (it holds the gate); seven more wait behind it.
      100.times do
        break if origin.paths.size >= 2
        sleep 5.milliseconds
      end
      origin.paths.size.should eq(2) # /form, then the candidate
      plan.engine.stop
      finished.receive
      origin.forms.should eq(1) # nobody logged in after the stop
      rows.size.should eq(1)    # …and the waiting candidates left no rows: nothing was sent for them
      rows.first.status.should eq(200)
      errors.should be_empty
      plan.request_macro.not_nil!.tally.failed.should eq(0)
    end
    origin.close
  end

  describe "when the macro fails" do
    it "never sends the candidate, never retries it, and ends the run after three failures in a row" do
      origin = MacroTokenOrigin.new
      origin.form_status = 500
      with_macro_project(origin) do |store, _, _|
        ran = drain(plan_for(origin, store, spec_for, payloads: 10, retries: 2))
        ran.rows.size.should eq(3)
        ran.rows.each do |row|
          row.status.should be_nil
          row.error.not_nil!.should start_with(RM::ERROR_PREFIX)
          row.error.not_nil!.should contain("the candidate was not sent")
          row.error.not_nil!.should contain("csrf-fetch → 500")
        end
        origin.submits.should be_empty                           # nothing was sent with an empty or stale token
        origin.paths.count(&.starts_with?("/form")).should eq(3) # and the steps were not re-run per retry
        ran.errors.size.should eq(1)
        ran.errors.first.should contain("3 failures in a row")
        ran.progress.errors.should eq(3)
        tally = ran.progress.request_macro.not_nil!
        {tally.runs, tally.failed, tally.skipped}.should eq({3_i64, 3_i64, 3_i64})
        tally.first_error.not_nil!.should contain("the step answered 500")
        # One event per failure, filed under the fuzzer, and one for the abort.
        events = store.@db.scalar("SELECT COUNT(*) FROM events WHERE source = 'fuzzer' AND kind = 'macro_failed'").as(Int64)
        events.should eq(3)
        store.@db.scalar("SELECT COUNT(*) FROM events WHERE kind = 'macro_aborted'").as(Int64).should eq(1)
      end
      origin.close
    end

    it "ends the run on the first failure when told to stop" do
      origin = MacroTokenOrigin.new
      origin.form_status = 500
      with_macro_project(origin) do |store, _, _|
        ran = drain(plan_for(origin, store, spec_for(on_failure: RM::OnFailure::Stop), payloads: 10))
        ran.rows.size.should eq(1)
        ran.errors.first.should contain("stop the run on a failure")
        origin.submits.should be_empty
      end
      origin.close
    end

    it "does not take a step that answered but bound nothing for a fresh token" do
      origin = MacroTokenOrigin.new
      origin.omit_token = true
      with_macro_project(origin) do |store, _, _|
        ran = drain(plan_for(origin, store, spec_for(on_failure: RM::OnFailure::Stop), payloads: 4))
        ran.rows.size.should eq(1)
        ran.rows.first.error.not_nil!.should contain("none of the bindings")
        origin.submits.should be_empty
        origin.paths.should eq(["/form"])
      end
      origin.close
    end

    it "names a binding the steps were expected to rebind and did not" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, bindings, _|
        # A second rule that a /form response can never satisfy: any binding rebounding is not
        # enough once the operator said which one must.
        bindings.add("NONCE", "", Gori::ExtractKind::Header, "x-nonce").should be_nil
        ran = drain(plan_for(origin, store, spec_for(on_failure: RM::OnFailure::Stop, expect: ["CSRF", "NONCE"]),
          payloads: 3, text: template(origin, "$CSRF$NONCE")))
        ran.errors.first.should contain("NONCE was not rebound")
        origin.submits.should be_empty
      end
      origin.close
    end

    it "carries on after a failure that was not part of a streak, skipping only the candidate it failed" do
      origin = MacroTokenOrigin.new
      origin.fail_forms = Set{2}
      with_macro_project(origin) do |store, _, _|
        ran = drain(plan_for(origin, store, spec_for, payloads: 4))
        ran.errors.should be_empty
        ran.rows.map(&.status).should eq([200, nil, 200, 200])
        ran.rows[1].error.not_nil!.should start_with(RM::ERROR_PREFIX)
        ran.progress.errors.should eq(1)
        tally = ran.progress.request_macro.not_nil!
        {tally.runs, tally.failed, tally.skipped}.should eq({4_i64, 1_i64, 1_i64})
        origin.submits.size.should eq(3)
      end
      origin.close
    end
  end

  describe "budget" do
    it "charges the macro's requests to max_requests, so the cap is the traffic the target saw" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        ran = drain(plan_for(origin, store, spec_for, payloads: 10, max_requests: 6))
        origin.paths.size.should eq(6) # 3 macro fetches + 3 candidates
        ran.progress.requests.should eq(6)
        ran.rows.first(3).map(&.status).should eq([200] * 3)
        # Jobs already dispatched when the budget ran out answer the cap's own error — the macro
        # that could not be paid for is not a macro failure, and is not counted as one.
        ran.rows[3..].each(&.error.should(eq(F::CappedBackend::CAP_ERROR)))
        ran.progress.request_macro.not_nil!.failed.should eq(0)
        ran.errors.should be_empty
      end
      origin.close
    end
  end

  describe "race" do
    it "refuses a race the cap can hold only before the macro's step is counted" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        ex = expect_raises(F::PlanError, /macro step/) do
          plan_for(origin, store, spec_for(every: 2), race: 2, max_requests: 2_i64)
        end
        ex.reason.should eq(F::PlanError::Reason::BadRaceCount)
        # The group alone fits. The step is what puts it over.
        plan_for(origin, store, spec_for(every: 2), race: 2, max_requests: 3_i64)
      end
      origin.close
    end

    it "refuses a cadence shorter than the group, because the members can only share one value" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        [1, 2].each do |every|
          err = expect_raises(RM::Error) { plan_for(origin, store, spec_for(every: every), race: 3) }
          err.message.not_nil!.should contain("at least 3")
        end
      end
      origin.close
    end

    it "runs the steps once before the group and hands every member the same single-use value" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        plan = plan_for(origin, store, spec_for(every: 3), race: 3)
        plan.request_macro_info.not_nil!.line.should contain("all 3 members share it")
        ran = drain(plan)
        origin.forms.should eq(1)
        origin.submits.map(&.[0]).uniq!.should eq(["T1"])
        ran.rows.map(&.status.not_nil!).sort!.should eq([200, 403, 403]) # a one-time token redeemed three times
      end
      origin.close
    end
  end

  describe "what the plan refuses" do
    it "a run with no project to read the steps from" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |_, _, _|
        options = F::PlanOptions.new(template(origin), target: "http://127.0.0.1:#{origin.port}",
          sources: [F::InlineList.new(["a"]).as(F::PayloadSource)],
          config: F::Config.new(request_macro: spec_for), matcher: F::Matcher.new(keep_bodies: :none))
        err = expect_raises(RM::Error) { F::Plan.build(options, ungated_outbound) }
        err.message.not_nil!.should contain("no project attached")
      end
      origin.close
    end

    it "a step that does not exist, by name or by id" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, csrf|
        expect_raises(RM::Error, /no Repeater session is named "nope"/) { plan_for(origin, store, spec_for(["nope"])) }
        expect_raises(RM::Error, /there is no Repeater session #999/) { plan_for(origin, store, spec_for(["#999"])) }
        # …and the same session by id is fine.
        plan_for(origin, store, spec_for(["#{csrf}"])).request_macro.should_not be_nil
        plan_for(origin, store, spec_for(["##{csrf}"])).request_macro.should_not be_nil
      end
      origin.close
    end

    it "an ambiguous name, and no steps at all" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        twin = store.insert_repeater("http://127.0.0.1:#{origin.port}", "GET /form HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
        store.set_repeater_name(twin, "csrf-fetch")
        err = expect_raises(RM::Error) { plan_for(origin, store, spec_for(["csrf-fetch"])) }
        err.message.not_nil!.should contain("2 Repeater sessions are named")
        expect_raises(RM::Error, /has no steps/) { plan_for(origin, store, spec_for([] of String)) }
      end
      origin.close
    end

    it "a step that still holds fuzz markers" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        marked = store.insert_repeater("http://127.0.0.1:#{origin.port}", "GET /form?a=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice, false, true, nil, 1)
        expect_raises(RM::Error, /holds §…§ fuzz markers/) { plan_for(origin, store, spec_for(["#{marked}"])) }
      end
      origin.close
    end

    it "a project with no extract rule to rebind" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, bindings, _|
        bindings.rules.each { |r| bindings.remove(r.id) }
        expect_raises(RM::Error, /no enabled extract rule/) { plan_for(origin, store, spec_for) }
      end
      origin.close
    end

    it "an expected binding that no rule provides" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        err = expect_raises(RM::Error) { plan_for(origin, store, spec_for(expect: ["MISSING"])) }
        err.message.not_nil!.should contain("expects $MISSING")
      end
      origin.close
    end

    it "a step outside the project scope, on the surface's own Layer 1" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "elsewhere.test")
        options = F::PlanOptions.new(template(origin), target: "http://127.0.0.1:#{origin.port}",
          sources: [F::InlineList.new(["a"]).as(F::PayloadSource)],
          config: F::Config.new(request_macro: spec_for), matcher: F::Matcher.new(keep_bodies: :none),
          project: store)
        err = expect_raises(RM::Error) { F::Plan.build(options, Gori::Outbound.agent(scope, false)) }
        err.message.not_nil!.should contain("out of the project scope")
        # The waived surface (--allow-unscoped) gets through Layer 1, as it does for the candidates.
        F::Plan.build(options, Gori::Outbound.agent(scope, true)).request_macro.should_not be_nil
      end
      origin.close
    end

    it "does nothing at all when the cadence is off, whatever else is configured" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        plan = plan_for(origin, store, spec_for(["nope"], every: 0))
        plan.request_macro.should be_nil
        plan.request_macro_info.should be_nil
      end
      origin.close
    end
  end

  describe "where the value has to be able to land" do
    it "refuses a captured template, which is sent exactly as captured and substitutes nothing" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        err = expect_raises(RM::Error) { plan_for(origin, store, spec_for, evidence: true) }
        err.message.not_nil!.should contain("captured evidence")
      end
      origin.close
    end

    it "refuses a request that never names a binding the macro rebinds" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        err = expect_raises(RM::Error) { plan_for(origin, store, spec_for, text: template(origin, "static")) }
        err.message.not_nil!.should contain("never references it")
      end
      origin.close
    end

    it "accepts a request that reaches the value through the active session slot's header" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, bindings, _|
        slots = bindings.slots.not_nil!
        slots.save([Gori::SessionSlot.new("acme", set_headers: [{"X-Token", "$CSRF"}], rules: ["CSRF"])])
        slots.activate("acme")
        # The template carries no token of its own — and is captured evidence, which substitutes
        # nothing — so only the slot's overlay can put the value on the wire.
        plan = plan_for(origin, store, spec_for, text: "GET /submit?v=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
          evidence: true, payloads: 3)
        ran = drain(plan)
        ran.rows.map(&.status).should eq([200, 200, 200])
        origin.forms.should eq(3)
      end
      origin.close
    end
  end

  describe "visibility" do
    it "records every step in History with its own source, and says what the run did to itself" do
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        plan = plan_for(origin, store, spec_for, payloads: 4)
        plan.request_macro_info.not_nil!.line.should eq(
          "macro: csrf-fetch · before every request · one candidate at a time — a value is never shared · on failure: skip the candidate")
        drain(plan)
        store.@db.scalar("SELECT COUNT(*) FROM flows WHERE source = 'macro'").as(Int64).should eq(4)
        store.@db.scalar("SELECT COUNT(*) FROM flows WHERE source = 'macro' AND source_ref = 'macro step 1'").as(Int64).should eq(4)
        # The candidates are not recorded (record_history is opt-in), so the macro's rows are the only ones.
        store.@db.scalar("SELECT COUNT(*) FROM flows").as(Int64).should eq(4)
      end
      origin.close
    end
  end
end
