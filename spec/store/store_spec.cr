require "../spec_helper"

private def with_store(events : Channel(Gori::Store::FlowEvent)? = nil, &)
  path = File.tempname("gori-test", ".db")
  store = Gori::Store.open(path, events)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def sample_request(method = "GET", host = "acme.test", target = "/")
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64,
    scheme: "http",
    host: host,
    port: 80,
    method: method,
    target: target,
    http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: nil,
  )
end

describe Gori::Store do
  it "applies the v1 migration (user_version = 1)" do
    with_store do |store|
      # count works => schema exists
      store.count.should eq(0)
    end
  end

  it "inserts a Pending flow and lists it newest-first with nil status" do
    with_store do |store|
      id1 = store.insert_flow(sample_request(target: "/first"))
      id2 = store.insert_flow(sample_request(target: "/second"))
      id2.should be > id1

      rows = store.recent_flows(10)
      rows.size.should eq(2)
      rows[0].id.should eq(id2) # newest first
      rows[0].target.should eq("/second")
      rows[0].status.should be_nil
      rows[0].state.should eq(Gori::Store::FlowState::Pending)
    end
  end

  it "round-trips raw request/response BLOBs byte-exact through get_flow (P7)" do
    with_store do |store|
      req = sample_request(method: "POST", target: "/api")
      id = store.insert_flow(req)

      resp_head = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n".to_slice
      resp_body = %({"ok":true}).to_slice
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 201, head: resp_head, body: resp_body,
        reason: "Created", content_type: "application/json", duration_us: 4200_i64))

      detail = store.get_flow(id).not_nil!
      detail.request_head.should eq(req.head)
      detail.response_head.should eq(resp_head)
      detail.response_body.should eq(resp_body)
      detail.row.status.should eq(201)
      detail.row.state.should eq(Gori::Store::FlowState::Complete)
    end
  end

  it "publishes :inserted then :updated events after commit" do
    events = Channel(Gori::Store::FlowEvent).new(16)
    with_store(events) do |store|
      id = store.insert_flow(sample_request)
      inserted = events.receive
      inserted.kind.should eq(:inserted)
      inserted.id.should eq(id)

      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
      updated = events.receive
      updated.kind.should eq(:updated)
      updated.id.should eq(id)
    end
  end

  it "pages older rows via the before_id cursor" do
    with_store do |store|
      ids = (1..5).map { |i| store.insert_flow(sample_request(target: "/#{i}")) }
      page1 = store.recent_flows(2)
      page1.map(&.id).should eq([ids[4], ids[3]])
      page2 = store.recent_flows(2, before_id: page1.last.id)
      page2.map(&.id).should eq([ids[2], ids[1]])
    end
  end
end
