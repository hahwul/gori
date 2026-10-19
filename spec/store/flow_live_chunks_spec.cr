require "../spec_helper"

private LC_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

private def lc_request(target : String = "/events") : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "lc.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: lc.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def lc_head(id : Int64) : Gori::Store::CapturedResponse
  Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: LC_HEAD.to_slice,
    content_type: "text/event-stream", state: Gori::Store::FlowState::Pending)
end

private def lc_final(id : Int64, body : String, live : Bool = true) : Gori::Store::CapturedResponse
  resp = Gori::Store::CapturedResponse.new(flow_id: id, status: 200, head: LC_HEAD.to_slice,
    body: body.to_slice, content_type: "text/event-stream")
  resp.live = live
  resp
end

private def lc_chunks(store : Gori::Store) : Int64
  store.@db.scalar("SELECT COUNT(*) FROM flow_live_chunks").as(Int64)
end

private def lc_body(store : Gori::Store, id : Int64) : String?
  store.get_flow(id).try(&.response_body).try { |b| String.new(b) }
end

# An event stream's body while the proxy is still relaying it lives in `flow_live_chunks`
# (V50, #1631): `get_flow` reads it, the final write deletes it, abandon folds it.
describe "Store live chunks (V50)" do
  it "shows the head and the events so far on a Pending flow, then the canonical body alone" do
    events = Channel(Gori::Store::FlowEvent).new(16)
    path = File.tempname("gori-spec", ".db")
    store = Gori::Store.open(path, events: events)
    begin
      id = store.insert_flow(lc_request)
      events.receive.kind.should eq(:inserted)
      store.append_live(id, 0_i64, Bytes.empty, lc_head(id)).should be_true
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, nil).should be_true
      store.append_live(id, 11_i64, "data: two\n\n".to_slice, nil).should be_true
      store.flush

      detail = store.get_flow(id).not_nil!
      detail.row.state.should eq(Gori::Store::FlowState::Pending)
      detail.row.status.should eq(200)
      String.new(detail.response_head.not_nil!).should eq(LC_HEAD)
      lc_body(store, id).should eq("data: one\n\ndata: two\n\n")
      String.new(store.get_flow(id, body_max: 5).not_nil!.response_body.not_nil!).should eq("data:")
      # The head publishes; the chunks do not.
      events.receive.should eq(Gori::Store::FlowEvent.new(id, :updated))
      select
      when ev = events.receive
        fail "unexpected #{ev}"
      else
      end
      # QL / FTS read the column, which stays NULL until the stream closes.
      store.@db.scalar("SELECT response_body IS NULL FROM flows WHERE id = ?", id).should eq(1)

      store.update_response(lc_final(id, "data: one\n\ndata: two\n\ndata: three\n\n"))
      lc_chunks(store).should eq(0)
      detail = store.get_flow(id).not_nil!
      detail.row.state.should eq(Gori::Store::FlowState::Complete)
      lc_body(store, id).should eq("data: one\n\ndata: two\n\ndata: three\n\n")
    ensure
      store.close
      delete_db_files(path)
    end
  end

  it "leaves no chunks behind a flow deleted mid-stream" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.flush
      lc_chunks(store).should eq(1)
      store.delete_flow(id)
      lc_chunks(store).should eq(0)
      # The stream goes on after the delete: neither its later appends nor its final write
      # leave a row.
      store.append_live(id, 11_i64, "data: two\n\n".to_slice, nil)
      store.flush
      lc_chunks(store).should eq(0)
      store.append_live(id, 22_i64, "data: three\n\n".to_slice, nil)
      store.update_response(lc_final(id, "data: one\n\n"))
      lc_chunks(store).should eq(0)
    end
  end

  it "deletes chunks that were still stored when the flow was deleted at its final write" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.flush
      store.@db.exec("DELETE FROM flows WHERE id = ?", id) # the row only, as a crash in a clear might
      store.update_response(lc_final(id, "data: one\n\n"))
      lc_chunks(store).should eq(0)
    end
  end

  it "folds the chunks into the body when the flow is abandoned (crash or shutdown)" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      other = store.insert_flow(lc_request("/plain"))
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.append_live(id, 11_i64, "data: two\n\n".to_slice, nil)
      store.abandon_pending!("orphaned by a previous session").should eq(2)
      lc_chunks(store).should eq(0)
      detail = store.get_flow(id).not_nil!
      detail.row.state.should eq(Gori::Store::FlowState::Error)
      lc_body(store, id).should eq("data: one\n\ndata: two\n\n")
      store.get_flow(other).not_nil!.response_body.should be_nil
      store.@db.scalar("SELECT fts_dirty FROM flows WHERE id = ?", id).should eq(1)
      detail.row.response_size.should eq(LC_HEAD.bytesize + 22)
      # The head the stream showed stays, and the body says it was cut off; a flow that never
      # got a head is a failure with no status, as before.
      detail.row.status.should eq(200)
      detail.response_body_truncated?.should be_true
      store.get_flow(other).not_nil!.row.status.should eq(0)
    end
  end

  # A rolled-back batch takes its appends with it while the proxy's offset moved on.
  it "joins only the contiguous prefix when a chunk went missing" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.append_live(id, 22_i64, "data: three\n\n".to_slice, nil) # 11..22 never landed
      store.flush
      lc_body(store, id).should eq("data: one\n\n")
      store.abandon_pending!("orphaned by a previous session")
      lc_body(store, id).should eq("data: one\n\n")
      lc_chunks(store).should eq(0)
    end
  end

  it "never moves an abandoned flow back to Pending with a late head" do
    events = Channel(Gori::Store::FlowEvent).new(16)
    path = File.tempname("gori-spec", ".db")
    store = Gori::Store.open(path, events: events)
    begin
      id = store.insert_flow(lc_request)
      store.abandon_pending!("proxy stopped before response")
      2.times { events.receive } # :inserted, the abandon's :updated
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.flush
      store.get_flow(id).not_nil!.row.state.should eq(Gori::Store::FlowState::Error)
      lc_chunks(store).should eq(0)
      select
      when ev = events.receive
        fail "unexpected #{ev}"
      else
      end
    ensure
      store.close
      delete_db_files(path)
    end
  end

  it "never touches the chunk table for a response that was not live" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.flush
      # Not the store's to guess: only a live write deletes them.
      store.update_response(lc_final(id, "data: one\n\n", live: false))
      lc_chunks(store).should eq(1)
    end
  end

  it "reports a dropped append when the writer queue is full" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      # No yield between sends, so the writer fiber drains nothing and the queue fills.
      queued = 0
      while store.append_live(id, queued.to_i64, "x".to_slice, nil)
        queued += 1
        break if queued > 100_000
      end
      queued.should be < 100_000
      store.flush
      lc_chunks(store).should eq(queued)
    end
  end

  it "is cleared with history" do
    with_store do |store|
      id = store.insert_flow(lc_request)
      store.append_live(id, 0_i64, "data: one\n\n".to_slice, lc_head(id))
      store.flush
      store.clear_flows.should be_true
      lc_chunks(store).should eq(0)
    end
  end
end
