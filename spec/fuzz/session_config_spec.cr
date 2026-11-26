require "../spec_helper"

private def session_fixture(name : String) : String
  File.read(File.join(__DIR__, "../fixtures/fuzz_session_config", "#{name}.json"))
end

describe Gori::Fuzz::SessionConfig do
  it "writes the exact default bytes the view wrote before extraction" do
    Gori::Fuzz::SessionConfig.new.to_json.should eq(session_fixture("default"))
    Gori::Tui::FuzzerView.new.config_json.should eq(session_fixture("default"))
  end

  ["authored", "legacy"].each do |name|
    it "restores #{name} rows to the same state and bytes as the original view" do
      raw = session_fixture("#{name}-input")
      config = Gori::Fuzz::SessionConfig.new
      config.apply_json(raw).should be_true
      config.to_json.should eq(session_fixture(name))
      view = Gori::Tui::FuzzerView.new
      view.restore(Gori::Store::FuzzSessionRecord.new(1_i64, "https://h", "", false, nil, raw, nil, 0))
      view.config_json.should eq(session_fixture(name))
    end
  end

  it "tolerates malformed blobs and clears nullable values on a peer update" do
    config = Gori::Fuzz::SessionConfig.new
    ["", "{", "[]"].each { |raw| config.apply_json(raw).should be_false }
    config.apply_json(%({"timeout_s":12,"rps":2.0,"stop_on":"status:500"})).should be_true
    config.config.timeout.should eq(12.seconds)
    config.apply_json("{}").should be_true
    config.config.timeout.should be_nil
    config.config.rps.should be_nil
    config.stop_on.should eq("")
  end

  # gori never writes a timeout past Int32::MAX seconds, so a larger one is a foreign row: its
  # whole-second display raised OverflowError and the TUI could never open the project.
  it "reads a stored timeout back within the bound the tab writes" do
    {
      %({"timeout_ms":3000000000000})        => Int32::MAX.seconds,
      %({"timeout_ms":2147483648000})        => Int32::MAX.seconds,
      %({"timeout_ms":9223372036854775807})  => Int32::MAX.seconds,
      %({"timeout_ms":3000000000001})        => Int32::MAX.seconds,
      %({"timeout_ms":2147483647000})        => Int32::MAX.seconds,
      %({"timeout_ms":1500})                 => 1.5.seconds,
      %({"timeout_s":3000000000})            => Int32::MAX.seconds,
      %({"timeout_ms":-3000000000000})       => nil,
      %({"timeout_ms":-9223372036854775808}) => nil,
      %({"timeout_ms":0})                    => nil,
      %({"timeout_s":-5})                    => nil,
    }.each do |raw, expected|
      config = Gori::Fuzz::SessionConfig.new
      config.apply_json(raw).should be_true
      config.config.timeout.should eq(expected)
      again = Gori::Fuzz::SessionConfig.new
      again.apply_json(config.to_json).should be_true
      again.config.timeout.should eq(expected)
    end
  end

  # A row from a newer gori or an imported archive: an unknown mode used to run as Sniper, an
  # uncompilable match regex as "match everything", and an unknown set kind shifted the others
  # onto the wrong positions — and a re-save erased all three.
  it "keeps unknown or malformed knobs, names them, and writes them back unchanged" do
    sets = [{"kind" => "future", "value" => "zzz"}, {"kind" => "list", "value" => "a\n"}]
    raw = {"mode" => "FutureMode", "sets" => sets, "match_regex" => "(", "filter_regex" => "["}.to_json
    config = Gori::Fuzz::SessionConfig.new
    config.apply_json(raw).should be_true
    config.sets.map(&.kind).should eq([:list])
    error = config.unread_error.not_nil!
    error.should contain(%(mode "FutureMode"))
    error.should contain("match_regex \"(\"")
    error.should contain("filter_regex \"[\"")
    error.should contain(%(kind "future"))
    saved = JSON.parse(config.to_json)
    saved["mode"].should eq("FutureMode")
    saved["match_regex"].should eq("(")
    saved["filter_regex"].should eq("[")
    saved["sets"].should eq(JSON.parse(sets.to_json))
    # A peer update the row fully reads clears them.
    config.apply_json(%({"mode":"Pitchfork","match_regex":"ok"})).should be_true
    config.unread_error.should be_nil
    config.config.mode.should eq(Gori::Fuzz::Mode::Pitchfork)
  end

  it "refuses a restored Fuzzer tab until the operator sets the knob again" do
    with_store do |store|
      raw = {"sets" => [{"kind" => "future", "value" => "zzz"}, {"kind" => "list", "value" => "a\n"}]}.to_json
      view = Gori::Tui::FuzzerView.new
      view.restore(Gori::Store::FuzzSessionRecord.new(1_i64, "http://127.0.0.1:9",
        "GET /?q=§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, nil, raw, nil, 0))
      engine, error = view.build_engine(false, Gori::Scope.load(store))
      engine.should be_nil
      error.not_nil!.should contain(%(kind "future"))
      JSON.parse(view.config_json)["sets"][0]["kind"].should eq("future")
      view.apply_set(nil, Gori::Tui::SetSpec.list(["p"]))
      engine, error = view.build_engine(false, Gori::Scope.load(store))
      error.should be_nil
      engine.should_not be_nil
      JSON.parse(view.config_json)["sets"].as_a.map(&.["kind"].as_s).should eq(["list", "list"])
    end
  end
end
