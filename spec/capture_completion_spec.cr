require "./spec_helper"

private def capture_row(status : Int32?, state : Gori::Store::FlowState,
                        connect_protocol : String? = nil) : Gori::Store::FlowRow
  Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "socket.test", 443, "/ws",
    status, 0_i64, state, connect_protocol: connect_protocol)
end

describe Gori::CaptureCompletion do
  it "waits for an h1 upgrade tunnel to close before counting its 101 flow" do
    completion = Gori::CaptureCompletion.new
    row = capture_row(101, Gori::Store::FlowState::Complete)

    completion.awaits_tunnel?(row).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(1_i64, :updated), row).should be_false
    completion.ready?(Gori::Store::FlowEvent.new(1_i64, :tunnel_completed), row).should be_true
  end

  it "waits for an accepted h2 WebSocket tunnel, including its final response update" do
    completion = Gori::CaptureCompletion.new
    row = capture_row(200, Gori::Store::FlowState::Complete, "websocket")

    completion.awaits_tunnel?(row).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(1_i64, :updated), row).should be_false
    completion.ready?(Gori::Store::FlowEvent.new(1_i64, :tunnel_completed), row).should be_true
  end

  it "counts ordinary or aborted flows on their response update" do
    completion = Gori::CaptureCompletion.new
    ordinary = capture_row(200, Gori::Store::FlowState::Complete)
    aborted_upgrade = capture_row(101, Gori::Store::FlowState::Aborted)

    completion.awaits_tunnel?(ordinary).should be_false
    completion.awaits_tunnel?(aborted_upgrade).should be_false
    completion.ready?(Gori::Store::FlowEvent.new(2_i64, :updated), ordinary).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(3_i64, :updated), aborted_upgrade).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(2_i64, :tunnel_completed), ordinary).should be_false
  end

  it "waits for an accepted h2 WebSocket even when the stream ends as aborted" do
    completion = Gori::CaptureCompletion.new
    row = capture_row(200, Gori::Store::FlowState::Aborted, "websocket")

    completion.awaits_tunnel?(row).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(4_i64, :updated), row).should be_false
    completion.ready?(Gori::Store::FlowEvent.new(4_i64, :tunnel_completed), row).should be_true
  end
end
