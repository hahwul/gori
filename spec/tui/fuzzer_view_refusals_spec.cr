require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `build_engine` refusals that used to be silent fallbacks: a match spec that can never fire
# ran the sweep as `N sent · 0 hit`; a numeric Advanced field that did not parse ran with the
# default while the row kept showing what was typed.

private def fuzzer_with(snap_edit : AdvancedSnapshot -> AdvancedSnapshot) : FuzzerView
  view = FuzzerView.new
  view.load_request("http://127.0.0.1:9", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view.apply_set(nil, Gori::Tui::SetSpec.list(["a"]))
  view.apply_advanced(snap_edit.call(view.advanced_snapshot))
  view
end

private def with_scope(&)
  path = File.tempname("gori-fuzz-refusals", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Scope.load(store)
  ensure
    store.close
    File.delete?(path)
  end
end

private def refusal(view : FuzzerView) : String?
  with_scope do |scope|
    engine, err = view.build_engine(false, scope, nil)
    engine.should be_nil
    return err
  end
end

describe "FuzzerView#build_engine refusals" do
  it "refuses a match/filter spec that can never fire, naming the term" do
    err = refusal(fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(m_status: "2OO") }))
    err.not_nil!.should contain("2OO")
    err = refusal(fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(f_size: ">1O0") }))
    err.not_nil!.should contain("1O0")
  end

  it "refuses a numeric Advanced field that does not parse instead of running the default" do
    refusal(fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(timeout: "1.5") })).not_nil!.should contain("Timeout")
    refusal(fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(conc: "50x") })).not_nil!.should contain("Concurrency")
    refusal(fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(retries: "3 x") })).not_nil!.should contain("Retries")
  end

  it "still builds on blank numeric fields (blank = default / off) and valid specs" do
    view = fuzzer_with(->(s : AdvancedSnapshot) { s.copy_with(timeout: "", rate: "", m_status: "2xx,>=500", m_size: ">10") })
    with_scope do |scope|
      engine, err = view.build_engine(false, scope, nil)
      err.should be_nil
      engine.should_not be_nil
    end
  end

  it "runs a List set whose value carries a comma as ONE payload" do
    view = FuzzerView.new
    view.load_request("http://127.0.0.1:9", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.apply_set(nil, Gori::Tui::SetSpec.list([%({"id":1,"role":"admin"})]))
    with_scope do |scope|
      engine, err = view.build_engine(false, scope, nil)
      err.should be_nil
      engine.not_nil!.total.should eq(1)
    end
  end

  it "clears the timeout on a peer sync whose config carries none" do
    view = FuzzerView.new
    view.load_request("http://127.0.0.1:9", "GET /?x=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.apply_advanced(view.advanced_snapshot.copy_with(timeout: "7"))
    view.apply_set(nil, Gori::Tui::SetSpec.list(["a"]))
    with_scope { |scope| view.build_engine(false, scope, nil) } # commits the buffers
    view.config.timeout.should eq(7.seconds)
    peer = view.config_json.gsub(/"timeout_s":7/, %("timeout_s":null))
    peer.should contain(%("timeout_s":null))
    view.apply_peer_session(Gori::Store::FuzzSessionRecord.new(
      id: 1, target: view.target, template: view.template_text, http2: false, sni: nil,
      config: peer, flow_id: nil, position: 0, name: nil))
    view.config.timeout.should be_nil
  end
end
