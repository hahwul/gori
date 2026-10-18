require "../spec_helper"

private ET_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

private def et_request : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "et.test", port: 80, method: "GET",
    target: "/events", http_version: "HTTP/1.1",
    head: "GET /events HTTP/1.1\r\nHost: et.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def et_head(id : Int64) : Gori::Store::CapturedResponse
  Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: ET_HEAD.to_slice,
    content_type: "text/event-stream", state: Gori::Store::FlowState::Pending)
end

private def et_pack(*times : Int64) : Bytes
  Gori::Sse::Arrivals.pack(times.to_a)
end

private def et_rows(store : Gori::Store) : Int64
  store.@db.scalar("SELECT COUNT(*) FROM flow_event_times").as(Int64)
end

# When each event of an event stream arrived (V52, #1631): the live appends carry the times,
# `get_flow` reads them, and the final write keeps them all after the stream closes.
describe "Store event times (V52)" do
  it "reads the times the appends carried, and keeps them all after the final write" do
    with_store do |store|
      id = store.insert_flow(et_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, et_head(id), 0, et_pack(10_i64)).should be_true
      store.append_live(id, 11_i64, "data: two\n\n".to_slice, nil, 1, et_pack(20_i64)).should be_true
      store.flush
      store.get_flow(id).not_nil!.event_times.should eq([10_i64, 20_i64])
      store.live_event_count(id).should eq(2)

      final = Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: ET_HEAD.to_slice,
        body: "data: one\n\ndata: two\n\ndata: three\n\n".to_slice, content_type: "text/event-stream")
      final.live = true
      final.event_times = et_pack(10_i64, 20_i64, 35_i64)
      store.update_response(final)
      store.get_flow(id).not_nil!.event_times.should eq([10_i64, 20_i64, 35_i64])
      et_rows(store).should eq(1)
    end
  end

  it "stops at the first gap, as the live body does, but counts past it" do
    with_store do |store|
      id = store.insert_flow(et_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, et_head(id), 0, et_pack(10_i64))
      store.append_live(id, 22_i64, "data: three\n\n".to_slice, nil, 2, et_pack(30_i64))
      store.flush
      store.get_flow(id).not_nil!.event_times.should eq([10_i64])
      store.live_event_count(id).should eq(3)
    end
  end

  it "has none for a stream that was not timed, or a response that is not an event stream" do
    with_store do |store|
      id = store.insert_flow(et_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, et_head(id))
      store.flush
      store.get_flow(id).not_nil!.event_times.should be_nil
      store.live_event_count(id).should be_nil

      plain = store.insert_flow(et_request)
      store.@db.exec("INSERT INTO flow_event_times (flow_id, first, times) VALUES (?, 0, ?)", plain, et_pack(1_i64))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: plain, status: 200,
        head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice, body: "x".to_slice,
        content_type: "text/plain"))
      store.get_flow(plain).not_nil!.event_times.should be_nil
    end
  end

  it "ignores a trailing partial time in a crafted row" do
    with_store do |store|
      id = store.insert_flow(et_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, et_head(id))
      store.flush
      store.@db.exec("INSERT INTO flow_event_times (flow_id, first, times) VALUES (?, 0, ?)", id,
        Bytes.new(11, 1_u8))
      store.get_flow(id).not_nil!.event_times.not_nil!.size.should eq(1)
    end
  end

  it "goes with the flow on delete and clear" do
    with_store do |store|
      a = store.insert_flow(et_request)
      b = store.insert_flow(et_request)
      store.append_live(a, 0_i64, "data: one\n\n".to_slice, et_head(a), 0, et_pack(1_i64))
      store.append_live(b, 0_i64, "data: one\n\n".to_slice, et_head(b), 0, et_pack(1_i64))
      store.flush
      et_rows(store).should eq(2)
      store.delete_flow(a)
      et_rows(store).should eq(1)
      store.clear_flows.should be_true
      et_rows(store).should eq(0)
    end
  end
end
