require "../spec_helper"
require "file_utils"

private def fi_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "fi.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: fi.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def fi_response(id : Int64, interims : Gori::Store::Interims?) : Gori::Store::CapturedResponse
  Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_slice, interims: interims)
end

# One flow with a single 103 on its record; returns its id.
private def fi_seed(store : Gori::Store, target : String) : Int64
  id = store.insert_flow(fi_request(target))
  interims = Gori::Store::Interims.new
  interims.add(103, FI_HINT.to_slice)
  store.update_response(fi_response(id, interims))
  id
end

private def fi_rows(store : Gori::Store) : Array(Int64)
  store.@db.query_all("SELECT DISTINCT flow_id FROM flow_interims ORDER BY flow_id", as: Int64)
end

private FI_HINT = "HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n"
private FI_CONT = "HTTP/1.1 100 Continue\r\n\r\n"

# The interim 1xx heads that preceded a flow's final response live in `flow_interims` (V45),
# beside the flow and never inside `response_head`.
describe "Store flow interims (V45)" do
  it "keeps the interim heads beside the response, in wire order, and nothing for a flow without" do
    with_store do |store|
      hinted = store.insert_flow(fi_request("/with"))
      plain = store.insert_flow(fi_request("/without"))
      interims = Gori::Store::Interims.new
      interims.add(100, FI_CONT.to_slice)
      interims.add(103, FI_HINT.to_slice)
      store.update_response(fi_response(hinted, interims))
      store.update_response(fi_response(plain, nil))

      got = store.interims(hinted).not_nil!
      got.heads.map(&.status).should eq([100, 103])
      got.heads.map { |h| String.new(h.head) }.should eq([FI_CONT, FI_HINT])
      got.omitted.should eq(0)
      String.new(got.wire).should eq(FI_CONT + FI_HINT)
      String.new(store.get_flow(hinted).not_nil!.response_head.not_nil!).should start_with("HTTP/1.1 200 OK")
      store.interims(plain).should be_nil
    end
  end

  it "carries the omitted count through the store" do
    with_store do |store|
      id = store.insert_flow(fi_request("/flood"))
      interims = Gori::Store::Interims.new
      (Gori::Store::Interims::MAX_KEPT + 2).times { interims.add(103, FI_HINT.to_slice) }
      store.update_response(fi_response(id, interims))

      got = store.interims(id).not_nil!
      got.heads.size.should eq(Gori::Store::Interims::MAX_KEPT)
      got.omitted.should eq(2)
    end
  end

  it "goes with its flow on delete and on clear" do
    with_store do |store|
      a = store.insert_flow(fi_request("/a"))
      b = store.insert_flow(fi_request("/b"))
      [a, b].each do |id|
        interims = Gori::Store::Interims.new
        interims.add(103, FI_HINT.to_slice)
        store.update_response(fi_response(id, interims))
      end

      store.delete_flow(a).should be_true
      store.interims(a).should be_nil
      store.interims(b).should_not be_nil

      store.clear_flows.should be_true
      store.@db.scalar("SELECT COUNT(*) FROM flow_interims").as(Int64).should eq(0)
    end
  end

  it "goes with its flow when retention prunes it" do
    path = File.tempname("gori-flow-interims", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    Gori::Store::Schema.migrate!(db)
    store = Gori::Store.new(db, nil, retention_flows: 2, prune_interval: 1)
    begin
      ids = (0...5).map { |i| fi_seed(store, "/r#{i}") }
      store.flush
      store.count.should eq(2)
      fi_rows(store).should eq(ids.last(2))
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "goes with its flow when compact keeps only the newest" do
    dir = File.tempname("gori-flow-interims-compact")
    Dir.mkdir_p(dir)
    path = File.join(dir, "gori.db")
    begin
      ids = [] of Int64
      store = Gori::Store.open(path)
      begin
        5.times { |i| ids << fi_seed(store, "/c#{i}") }
      ensure
        store.close
      end

      Gori::Store.compact(path, Gori::Store::CompactPlan.new(keep_flows: 2)).not_nil!

      store = Gori::Store.open(path)
      begin
        fi_rows(store).should eq(ids.last(2))
      ensure
        store.close
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "keeps whether each head reached the client" do
    with_store do |store|
      id = store.insert_flow(fi_request("/10"))
      interims = Gori::Store::Interims.new
      interims.add(103, FI_HINT.to_slice, relayed: false)
      interims.add(100, FI_CONT.to_slice)
      store.update_response(fi_response(id, interims))

      got = store.interims(id).not_nil!
      got.heads.map(&.relayed?).should eq([false, true])
      String.new(got.relayed_wire).should eq(FI_CONT)
      got.unrelayed_note.not_nil!.should contain("1 of the recorded interim 1xx responses was not relayed")
    end
  end
end

describe Gori::Store::Interims do
  it "keeps the first head whatever its size, then stops at the byte budget" do
    big = Bytes.new(Gori::Store::Interims::MAX_BYTES + 10, 'a'.ord.to_u8)
    interims = Gori::Store::Interims.new
    interims.add(103, big)
    interims.add(103, FI_HINT.to_slice)
    interims.heads.size.should eq(1)
    interims.omitted.should eq(1)
    interims.omitted_note.not_nil!.should contain("kept the first 1")
  end

  it "keeps a prefix: once one is omitted, every later one is too" do
    big = Bytes.new(Gori::Store::Interims::MAX_BYTES, 'a'.ord.to_u8)
    interims = Gori::Store::Interims.new
    interims.add(103, FI_HINT.to_slice)
    interims.add(103, big) # does not fit beside the first
    interims.accepting?.should be_false
    interims.add(100, FI_CONT.to_slice) # would fit, but is after the gap
    interims.heads.map { |h| String.new(h.head) }.should eq([FI_HINT])
    interims.omitted.should eq(2)
  end

  it "says nothing when nothing was cut" do
    interims = Gori::Store::Interims.new
    interims.add(103, FI_HINT.to_slice)
    interims.omitted_note.should be_nil
    interims.empty?.should be_false
    Gori::Store::Interims.new.empty?.should be_true
  end
end
