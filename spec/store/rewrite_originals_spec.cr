require "../spec_helper"

private P4 = Gori::Store::RuleRef.new(Gori::Store::RuleScope::Project, 4_i64)
private G4 = Gori::Store::RuleRef.new(Gori::Store::RuleScope::Global, 4_i64)

private def rw_request(target : String, rewrite : Gori::Store::Rewrite? = nil) : Gori::Store::CapturedRequest
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "rw.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: rw.test\r\nX-Added: 1\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
  req.rewrite = rewrite
  req
end

private def rw_response(flow_id : Int64, rewrite : Gori::Store::Rewrite? = nil) : Gori::Store::CapturedResponse
  resp = Gori::Store::CapturedResponse.new(flow_id: flow_id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".to_slice, body: "new".to_slice)
  resp.rewrite = rewrite
  resp
end

private def ids(store, q : String) : Array(Int64)
  store.search(Gori::QL.parse(q), 50).map(&.id).sort!
end

# A Match&Replace rule's record beside the flow it changed (#1589, V49): the `{scope, id}` of
# each rule that fired, in `flow_rule_hits`, and the side's bytes before it did, in
# `rewrite_originals`. The flow itself keeps what went on each wire (P7).
describe "Store rewrite originals (V49)" do
  client_head = "GET /a HTTP/1.1\r\nHost: rw.test\r\n\r\n".to_slice
  origin_head = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".to_slice

  it "keeps each side's original and flags every read of the row with the rules that fired" do
    with_store do |store|
      changed = store.insert_flow(rw_request("/a", Gori::Store::Rewrite.new([P4], client_head)))
      store.update_response(rw_response(changed, Gori::Store::Rewrite.new([G4], origin_head, "old".to_slice)))
      plain = store.insert_flow(rw_request("/plain"))
      store.update_response(rw_response(plain))

      store.rewrite_original(changed, Gori::Store::RuleTarget::Request).should eq({client_head, nil})
      store.rewrite_original(changed, Gori::Store::RuleTarget::Response).should eq({origin_head, "old".to_slice})
      store.rewrite_original(plain, Gori::Store::RuleTarget::Request).should be_nil

      store.flow_row(changed).not_nil!.rewritten_by.not_nil!.sort_by(&.to_s).should eq([G4, P4])
      store.flow_row(plain).not_nil!.rewritten?.should be_false
      store.get_flow(changed).not_nil!.row.rewritten?.should be_true
      store.recent_flows(10).map(&.rewritten?).should eq([false, true])
      # What went on the wire is still the flow.
      String.new(store.get_flow(changed).not_nil!.response_body.not_nil!).should eq("new")
    end
  end

  # NULL means "the stored body", so an empty original must not read as one: a 204 whose
  # response was edited at Intercept to carry a body would show the operator's body as the origin's.
  it "keeps an empty original body apart from one that matched the stored body" do
    with_store do |store|
      id = store.insert_flow(rw_request("/a"))
      store.update_response(rw_response(id, Gori::Store::Rewrite.new([P4], origin_head, Bytes.empty)))

      store.rewrite_original(id, Gori::Store::RuleTarget::Response).should eq({origin_head, Bytes.empty})
      d = store.get_flow(id).not_nil!
      Gori::Interceptor.original(store, d, Gori::Store::RuleTarget::Response).should eq({origin_head, Bytes.empty})
    end
  end

  it "answers rewritten: — any rule, or one rule by scope and id" do
    with_store do |store|
      a = store.insert_flow(rw_request("/a", Gori::Store::Rewrite.new([P4], client_head)))
      b = store.insert_flow(rw_request("/b", Gori::Store::Rewrite.new([G4])))
      c = store.insert_flow(rw_request("/c"))

      ids(store, "rewritten:true").should eq([a, b])
      ids(store, "-rewritten:true").should eq([c])
      ids(store, "rewritten:false").should eq([c])
      ids(store, "rewritten:project/4").should eq([a]) # global rule 4 is a different rule
      ids(store, "rewritten:global/4").should eq([b])
      ids(store, "-rewritten:global/4").should eq([a, c])
    end
  end

  it "records a WebSocket rule once per rule, on an existing flow" do
    with_store do |store|
      id = store.insert_flow(rw_request("/ws"))
      store.record_rule_hits(id, Gori::Store::RuleTarget::Response, [P4])
      store.record_rule_hits(id, Gori::Store::RuleTarget::Response, [P4])
      store.flow_row(id).not_nil!.rewritten_by.should eq([P4])
      store.rewrite_original(id, Gori::Store::RuleTarget::Response).should be_nil # hits only
    end
  end

  it "goes with its flow when retention prunes it" do
    path = File.tempname("gori-rewrite-originals", ".db")
    db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
    Gori::Store::Schema.migrate!(db)
    store = Gori::Store.new(db, nil, retention_flows: 2, prune_interval: 1)
    begin
      5.times { |i| store.insert_flow(rw_request("/r#{i}", Gori::Store::Rewrite.new([P4], client_head))) }
      store.flush
      store.@db.scalar("SELECT COUNT(*) FROM flow_rule_hits").as(Int64).should eq(2)
      store.@db.scalar("SELECT COUNT(*) FROM rewrite_originals").as(Int64).should eq(2)
    ensure
      store.close
      delete_db_files(path)
    end
  end

  it "goes with its flow on delete and clear" do
    with_store do |store|
      a = store.insert_flow(rw_request("/a", Gori::Store::Rewrite.new([P4], client_head)))
      b = store.insert_flow(rw_request("/b", Gori::Store::Rewrite.new([P4], client_head)))

      store.delete_flow(a).should be_true
      store.rewrite_original(a, Gori::Store::RuleTarget::Request).should be_nil
      store.rewrite_original(b, Gori::Store::RuleTarget::Request).should_not be_nil

      store.clear_flows.should be_true
      store.@db.scalar("SELECT COUNT(*) FROM flow_rule_hits").as(Int64).should eq(0)
      store.@db.scalar("SELECT COUNT(*) FROM rewrite_originals").as(Int64).should eq(0)
    end
  end
end
