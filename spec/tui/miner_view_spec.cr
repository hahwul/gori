require "../spec_helper"

describe Gori::Tui::MinerView do
  it "round-trips notify mode in session config JSON" do
    view = Gori::Tui::MinerView.new
    view.load("http://h.test", "GET /a HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, false, nil,
      Gori::Miner::Config.new(notify: Gori::Miner::NotifyMode::WhenFound))
    json = view.config_json
    restored = Gori::Tui::MinerView.new
    restored.restore(Gori::Store::MinerSessionRecord.new(
      id: 1, target: "http://h.test", request: Bytes.empty, http2: false, sni: nil,
      config: json, flow_id: nil, position: 0, name: nil))
    restored.config.notify.should eq(Gori::Miner::NotifyMode::WhenFound)
  end
end