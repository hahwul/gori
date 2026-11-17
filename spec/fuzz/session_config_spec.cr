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
end
