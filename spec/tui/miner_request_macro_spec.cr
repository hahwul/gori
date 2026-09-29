require "../spec_helper"
require "../support/macro_origin"

# The Miner tab's request-time macro (#1350): the overlay picks the step (its own spec), and what
# these pin is the part around the engine — the choice survives a session round-trip, the run
# builds through the shared plan with the project the controller hands over, and the plan's line
# reaches the controller.

private def macro_miner(origin : MacroTokenOrigin, spec : Gori::RequestMacro::Spec?,
                        text : String = "GET /submit?a=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: $CSRF\r\n\r\n") : Gori::Tui::MinerView
  config = Gori::Miner::Config.new
  config.locations = [Gori::Miner::Location::Query]
  config.keep_alive = false
  config.max_requests = 30_i64
  config.request_macro = spec
  view = Gori::Tui::MinerView.new
  view.load("http://127.0.0.1:#{origin.port}", text.to_slice, false, nil, config)
  view
end

describe "Miner request-time macro" do
  it "round-trips through the session config, and stays out of a config that has none" do
    origin = MacroTokenOrigin.new
    spec = Gori::RequestMacro::Spec.new(["3"], Gori::RequestMacro::Cadence.new(5), Gori::RequestMacro::OnFailure::Stop)
    view = macro_miner(origin, spec)
    JSON.parse(view.config_json)["request_macro"]["every"].as_s.should eq("5")

    restored = Gori::Tui::MinerView.new
    restored.restore(Gori::Store::MinerSessionRecord.new(
      id: 1, target: "http://h.test", request: Bytes.empty, http2: false, sni: nil,
      config: view.config_json, flow_id: nil, position: 0, name: nil))
    back = restored.config.request_macro.not_nil!
    back.steps.should eq(["3"])
    back.cadence.every.should eq(5)
    back.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)

    plain = macro_miner(origin, nil)
    JSON.parse(plain.config_json).as_h.has_key?("request_macro").should be_false
    origin.close
  end

  it "builds through the shared plan with the project it is handed, and reports the plan's line" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, csrf|
      view = macro_miner(origin, Gori::RequestMacro::Spec.new(["#{csrf}"]))
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      err.should be_nil
      engine.not_nil!.request_macro.should_not be_nil
      info = view.macro_info.not_nil!
      info.line.should contain("csrf-fetch")
      info.line.should contain("one request at a time")
      info.concurrency.should eq(1)
      done = false
      engine.not_nil!.run { |ev| done = true if ev.is_a?(Gori::Miner::DoneEvent) }
      done.should be_true
      origin.submits.map(&.[1]).uniq!.should eq([200])
      origin.forms.should eq(origin.submits.size)
    end
    origin.close
  end

  it "names the plan's refusal instead of a 'config error'" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_miner(origin, Gori::RequestMacro::Spec.new(["nope"]))
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      engine.should be_nil
      err.not_nil!.should contain("no Repeater session is named \"nope\"")
      err.not_nil!.should_not contain("config error")
      view.macro_info.should be_nil

      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, nil)
      engine.should be_nil
      err.not_nil!.should contain("no project attached")
    end
    origin.close
  end
end
