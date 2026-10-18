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

  # An event stream publishes `:updated` when its head lands, while still Pending (#1631).
  it "does not count a flow on an update that leaves it Pending" do
    completion = Gori::CaptureCompletion.new
    row = capture_row(200, Gori::Store::FlowState::Pending)

    completion.ready?(Gori::Store::FlowEvent.new(5_i64, :updated), row).should be_false
  end

  it "waits for an accepted h2 WebSocket even when the stream ends as aborted" do
    completion = Gori::CaptureCompletion.new
    row = capture_row(200, Gori::Store::FlowState::Aborted, "websocket")

    completion.awaits_tunnel?(row).should be_true
    completion.ready?(Gori::Store::FlowEvent.new(4_i64, :updated), row).should be_false
    completion.ready?(Gori::Store::FlowEvent.new(4_i64, :tunnel_completed), row).should be_true
  end

  # The printer reads the row when it receives the event, so an event stream that closes at once
  # has its head's `:updated` and its final one both read Complete (#1631). Counted once.
  it "counts a short event stream once, though both its updates read it Complete" do
    events = Channel(Gori::Store::FlowEvent).new(16)
    path = File.tempname("gori-spec", ".db")
    store = Gori::Store.open(path, events: events)
    begin
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_000_i64, scheme: "http", host: "cc.test", port: 80, method: "GET",
        target: "/events", http_version: "HTTP/1.1",
        head: "GET /events HTTP/1.1\r\nHost: cc.test\r\n\r\n".to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: head, state: Gori::Store::FlowState::Pending))
      final = Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: head, body: "data: one\n\n".to_slice)
      final.live = true
      store.update_response(final)

      completion = Gori::CaptureCompletion.new
      counted = 0
      3.times do # :inserted, the head's :updated, the final :updated
        ev = events.receive
        row = store.flow_row(ev.id).not_nil!
        row.state.should eq(Gori::Store::FlowState::Complete)
        counted += 1 if completion.count?(ev, row)
      end
      counted.should eq(1)
    ensure
      store.close
      delete_db_files(path)
    end
  end
end
