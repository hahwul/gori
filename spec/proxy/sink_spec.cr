require "../spec_helper"

private def ws_flow(store : Gori::Store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "ws.test", port: 80, method: "GET", target: "/ws",
    http_version: "HTTP/1.1", head: "GET /ws HTTP/1.1\r\nHost: ws.test\r\n\r\n".to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
end

describe Gori::Proxy::StoreSink do
  # A captured WebSocket message used to cost the relay one commit before its next read.
  it "queues a socket's messages without waiting, and completes the tunnel after all of them" do
    events = Channel(Gori::Store::FlowEvent).new(1024)
    path = File.tempname("gori-spec", ".db")
    store = Gori::Store.open(path, events)
    begin
      sink = Gori::Proxy::StoreSink.new(store)
      id = ws_flow(store)
      200.times { |i| sink.on_ws_message(id, i.even? ? "out" : "in", 1, "m#{i}".to_slice) }
      store.ws_messages(id).size.should eq(0) # nothing yielded to the writer yet

      sink.on_tunnel_complete(id)
      store.ws_messages(id).map { |m| String.new(m.payload) }.should eq((0...200).map { |i| "m#{i}" })
      # The flow's :inserted, one :updated per message, then the completion — last.
      kinds = (1..202).map { events.receive.kind }
      kinds.last.should eq(:tunnel_completed)
      kinds.count(:updated).should eq(200)
    ensure
      store.close
      delete_db_files(path)
    end
  end
end
