require "../spec_helper"
require "../support/macro_origin"

private alias M = Gori::Miner
private alias RM = Gori::RequestMacro

# Request-time macros in the Miner (#1350): every request the engine puts on the wire — the
# baseline calibration included — carries a token the macro just minted. See
# `Miner::MacroBackend`.

private REQUEST = "GET /submit?a=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: $CSRF\r\n\r\n"

private def miner_config(spec : RM::Spec?, max_requests : Int64? = 40_i64) : M::Config
  c = M::Config.new
  c.locations = [M::Location::Query]
  c.bucket_size = M::Config::DEFAULT_BUCKETS.dup
  c.bucket_size[M::Location::Query] = 4
  c.concurrency = 5
  c.stability_rounds = 2
  c.confirm_rounds = 1
  c.retries = 0
  c.keep_alive = false
  c.max_requests = max_requests
  c.request_macro = spec
  c
end

private def plan_for(origin : MacroTokenOrigin, store : Gori::Store, config : M::Config,
                     text : String = REQUEST, evidence : Bool = false) : M::Plan
  options = M::PlanOptions.new(text, target: "http://127.0.0.1:#{origin.port}", config: config,
    locations: [M::Location::Query], project: store, evidence: evidence)
  M::Plan.build(options, ungated_outbound)
end

private record Ran, findings : Array(M::Finding), errors : Array(String), progress : M::Progress

private def drain(plan : M::Plan) : Ran
  findings = [] of M::Finding
  errors = [] of String
  last = M::Progress.new(0_i64, 0_i64, 0_i64, 0, 0_i64)
  plan.engine.run do |ev|
    case ev
    in M::FindingEvent  then findings << ev.finding
    in M::ProgressEvent then last = ev.progress
    in M::DoneEvent     then last = ev.progress
    in M::ErrorEvent    then errors << ev.message
    in M::BaselineEvent then nil
    end
  end
  Ran.new(findings, errors, last)
end

describe "Miner request-time macro" do
  it "puts a fresh token on the baseline and on every probe, one request at a time" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, miner_config(RM::Spec.new(["csrf-fetch"])))
      plan.request_macro_info.not_nil!.concurrency.should eq(1)
      ran = drain(plan)
      ran.errors.should be_empty
      origin.submits.size.should be > 5 # the baseline, then probes
      origin.submits.map(&.[1]).uniq!.should eq([200])
      origin.submits.map(&.[0]).uniq!.size.should eq(origin.submits.size)
      origin.forms.should eq(origin.submits.size)
      origin.peak.should eq(1)
      ran.progress.request_macro.not_nil!.runs.should eq(origin.forms.to_i64)
      # The macro's requests are charged to the same cap the probes are.
      origin.paths.size.should be <= 40
      ran.progress.sent.should eq(origin.paths.size.to_i64)
    end
    origin.close
  end

  it "shares a value among N requests" do
    origin = MacroTokenOrigin.new
    origin.max_uses = 4
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, miner_config(RM::Spec.new(["csrf-fetch"], RM::Cadence.new(4))))
      ran = drain(plan)
      ran.errors.should be_empty
      origin.submits.map(&.[1]).uniq!.should eq([200])
      origin.forms.should eq((origin.submits.size / 4.0).ceil.to_i)
      origin.peak.should be <= 4
    end
    origin.close
  end

  it "refuses to mine on a baseline whose probes never carried a fresh value, and says why" do
    origin = MacroTokenOrigin.new
    origin.form_status = 500
    with_macro_project(origin) do |store, _, _|
      ran = drain(plan_for(origin, store, miner_config(RM::Spec.new(["csrf-fetch"]))))
      ran.errors.size.should be >= 1
      ran.errors.join(" ").should contain("macro")
      ran.findings.should be_empty
      origin.submits.should be_empty # nothing was sent with a stale or empty token
      ran.progress.request_macro.not_nil!.failed.should be >= 1
    end
    origin.close
  end

  it "ends the run on the first failure when told to stop" do
    origin = MacroTokenOrigin.new
    origin.form_status = 500
    with_macro_project(origin) do |store, _, _|
      spec = RM::Spec.new(["csrf-fetch"], on_failure: RM::OnFailure::Stop)
      ran = drain(plan_for(origin, store, miner_config(spec)))
      ran.errors.join(" ").should contain("stop the run on a failure")
      origin.paths.count(&.starts_with?("/form")).should eq(1)
    end
    origin.close
  end

  it "ends the mine, with the macro's own sentence, when the macro starts failing after the baseline" do
    origin = MacroTokenOrigin.new
    origin.fail_forms = (15..400).to_set # the baseline and the first probes get a value; then the login breaks
    with_macro_project(origin) do |store, _, _|
      config = miner_config(RM::Spec.new(["csrf-fetch"]), 300_i64)
      config.retries = 2
      ran = drain(plan_for(origin, store, config))
      ran.errors.size.should eq(1)
      ran.errors.first.should contain("#{RM::Lane::FAILURE_LIMIT} failures in a row")
      ran.errors.first.should contain("csrf-fetch → 500")
      # Stopped at the third failure: not one more login, and no probe sent without its value.
      origin.paths.count(&.starts_with?("/form")).should eq(14 + RM::Lane::FAILURE_LIMIT)
      origin.submits.map(&.[1]).uniq!.should eq([200])
      ran.progress.request_macro.not_nil!.failed.should eq(RM::Lane::FAILURE_LIMIT.to_i64)
    end
    origin.close
  end

  it "refuses a request that never names the binding" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      expect_raises(RM::Error, /never references it/) do
        plan_for(origin, store, miner_config(RM::Spec.new(["csrf-fetch"])),
          text: "GET /submit?a=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: static\r\n\r\n")
      end
    end
    origin.close
  end

  it "does nothing when the cadence is off" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      plan = plan_for(origin, store, miner_config(RM::Spec.new(["nope"], RM::Cadence.off)))
      plan.request_macro.should be_nil
      plan.request_macro_info.should be_nil
    end
    origin.close
  end

  it "stops when the budget cannot pay for the next macro step, instead of marking every name tested" do
    # The cap charged the probe before the step could be reserved. Refunding that charge used
    # to un-trip cap_reached?, and the mine then marked the rest of the wordlist done.
    [{1, 7_i64}, {5, 8_i64}].each do |conc, cap|
      origin = MacroTokenOrigin.new
      with_macro_project(origin) do |store, _, _|
        config = miner_config(RM::Spec.new(["csrf-fetch"]), cap)
        config.concurrency = conc
        config.stability_rounds = 1
        ran = drain(plan_for(origin, store, config))
        ran.progress.names_done.should be < ran.progress.names_total
        ran.progress.sent.should eq(origin.paths.size.to_i64)
        ran.progress.sent.should be <= cap
        ran.errors.should be_empty
        ran.progress.request_macro.not_nil!.failed.should eq(0)
      end
      origin.close
    end
  end

  it "does not count probes still waiting at the macro gate when the run is stopped" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      config = miner_config(RM::Spec.new(["csrf-fetch"]), 400_i64)
      config.concurrency = 4
      plan = plan_for(origin, store, config)
      errors = [] of String
      last = M::Progress.new(0_i64, 0_i64, 0_i64, 0, 0_i64)
      plan.engine.run do |ev|
        case ev
        in M::ProgressEvent
          last = ev.progress
          plan.engine.stop if ev.progress.sent >= 6
        in M::DoneEvent
          last = ev.progress
        in M::ErrorEvent
          errors << ev.message
        in M::FindingEvent, M::BaselineEvent
          nil
        end
      end
      errors.should be_empty
      last.errors.should eq(0_i64)
      last.names_done.should be < last.names_total
      last.names_done.should be > 0
    end
    origin.close
  end

  it "never retries a probe the macro failed — the steps would only fail again" do
    Gori::Miner.permanent_refusal?("#{RM::ERROR_PREFIX}failed at step 1 (csrf-fetch → 500) — the candidate was not sent").should be_true
    Gori::Miner.permanent_refusal?("connection refused").should be_false
  end
end
