require "../spec_helper"
require "../support/memory_backend"
require "../support/macro_origin"

include Gori::Tui

# The Fuzzer tab's request-time macro (#1350): four ADVANCED rows that reach the same
# `Fuzz::Config#request_macro` `gori run fuzz --macro*` and MCP `macro_*` set, and the same
# `Plan.build` behind them. What these pin on the TUI is the part around the engine: the rows
# survive a session round-trip, a value that does not read is NAMED rather than applied as the
# default, and the plan's line reaches the controller.

private def macro_view(origin : MacroTokenOrigin, text : String? = nil) : FuzzerView
  view = FuzzerView.new
  view.load_request("http://127.0.0.1:#{origin.port}",
    text || "GET /submit?v=§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Token: $CSRF\r\n\r\n", false, "")
  view.apply_set(nil, SetSpec.new(:list, "a\nb\nc\n"))
  view
end

private def with_macro_rows(view : FuzzerView, steps = "", every = "", expect = "", on_failure = "") : Nil
  s = view.advanced_snapshot
  view.apply_advanced(AdvancedSnapshot.new(
    conc: s.conc, rate: s.rate, timeout: s.timeout, retries: s.retries, max_requests: s.max_requests,
    race: s.race, follow: s.follow, calibrate: s.calibrate, keep_alive: s.keep_alive, update_cl: s.update_cl,
    reframe_grpc: s.reframe_grpc, m_status: s.m_status, m_size: s.m_size, m_words: s.m_words, m_regex: s.m_regex,
    f_status: s.f_status, f_size: s.f_size, f_words: s.f_words, f_regex: s.f_regex,
    macro_steps: steps, macro_every: every, macro_expect: expect, macro_on_failure: on_failure))
end

private def drain(engine : Gori::Fuzz::Engine) : Array(Gori::Fuzz::Result)
  rows = [] of Gori::Fuzz::Result
  engine.run { |ev| rows << ev.result if ev.is_a?(Gori::Fuzz::ResultEvent) }
  rows.sort_by(&.index)
end

describe "Fuzzer request-time macro" do
  it "asks for no macro until steps are named" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      err.should be_nil
      engine.not_nil!.request_macro.should be_nil
      view.macro_info.should be_nil
      view.config.request_macro.should be_nil
    end
    origin.close
  end

  it "builds the macro off the ADVANCED rows and runs each candidate with a fresh value" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      view.config.keep_alive = false
      with_macro_rows(view, steps: "csrf-fetch")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      err.should be_nil
      view.config.request_macro.not_nil!.steps.should eq(["csrf-fetch"])
      view.config.request_macro.not_nil!.cadence.every.should eq(1)
      info = view.macro_info.not_nil!
      info.line.should contain("csrf-fetch")
      info.concurrency.should eq(1)
      drain(engine.not_nil!).map(&.status).should eq([200, 200, 200])
      origin.forms.should eq(3)
      origin.submits.map(&.[0]).uniq!.size.should eq(3)
    end
    origin.close
  end

  it "reads the cadence, the expected binding and the policy off their rows" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      with_macro_rows(view, steps: "csrf-fetch, 1", every: "3", expect: "CSRF", on_failure: "stop")
      _, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      err.should be_nil
      spec = view.config.request_macro.not_nil!
      spec.steps.should eq(["csrf-fetch", "1"])
      spec.cadence.every.should eq(3)
      spec.expect.should eq(["CSRF"])
      spec.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)
    end
    origin.close
  end

  it "names a value that does not read instead of running the default" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      with_macro_rows(view, steps: "csrf-fetch", every: "sometimes")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      engine.should be_nil
      err.not_nil!.should contain("invalid Macro cadence: sometimes")

      with_macro_rows(view, steps: "csrf-fetch", on_failure: "carry-on")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      engine.should be_nil
      err.not_nil!.should contain("invalid Macro on failure: carry-on")
    end
    origin.close
  end

  it "names a companion row typed beside no steps, which would silently do nothing" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      with_macro_rows(view, every: "5")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      engine.should be_nil
      err.not_nil!.should contain("Macro cadence only apply to a macro")
    end
    origin.close
  end

  it "shows the plan's own refusal for a step that does not exist" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      with_macro_rows(view, steps: "nope")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
      engine.should be_nil
      err.not_nil!.should contain("no Repeater session is named \"nope\"")
      view.macro_info.should be_nil
    end
    origin.close
  end

  it "refuses a macro when the tab has no project to read its steps from" do
    origin = MacroTokenOrigin.new
    with_macro_project(origin) do |store, _, _|
      view = macro_view(origin)
      with_macro_rows(view, steps: "csrf-fetch")
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil, nil)
      engine.should be_nil
      err.not_nil!.should contain("no project attached")
    end
    origin.close
  end

  it "survives a session round-trip as typed, blank rows included" do
    origin = MacroTokenOrigin.new
    src = macro_view(origin)
    with_macro_rows(src, steps: "csrf-fetch,7", every: "off", expect: "CSRF,NONCE", on_failure: "stop")
    dst = FuzzerView.new
    dst.duplicate_from(src) # config_json → apply_config_json
    back = dst.advanced_snapshot
    back.macro_steps.should eq("csrf-fetch,7")
    back.macro_every.should eq("off")
    back.macro_expect.should eq("CSRF,NONCE")
    back.macro_on_failure.should eq("stop")

    bare = FuzzerView.new
    bare.duplicate_from(macro_view(origin))
    bare.advanced_snapshot.macro_steps.should eq("")
    bare.advanced_snapshot.macro_every.should eq("")
    origin.close
  end
end
