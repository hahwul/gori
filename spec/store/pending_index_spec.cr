require "../spec_helper"

# Schema V36 adds `idx_flows_pending`, the partial index `Store#abandon_all_pending` reads
# instead of scanning every flow (and walking every row's body overflow) at each session open
# and close. A partial index is used only when the query carries the same literal WHERE, so
# the one thing that can silently regress is the two drifting apart — a plan check, not a
# timing, is what catches that.

private def pending_request(target : String) : Gori::Store::CapturedRequest
  Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "http", host: "pending.test", port: 80, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: pending.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy)
end

private def query_plan(store : Gori::Store, sql : String) : String
  store.@db.query_all("EXPLAIN QUERY PLAN #{sql}", as: {Int64, Int64, Int64, String}).map(&.[3]).join(" | ")
end

describe "pending-flow index schema V36" do
  it "matches the literal Pending value the index was created with" do
    Gori::Store::FlowState::Pending.value.should eq(0)
    Gori::Store::PENDING_WHERE.should eq("state = 0 AND unsent = 0")
  end

  it "serves abandon_all_pending's SELECT from the partial index" do
    with_store do |store|
      plan = query_plan(store, "SELECT id FROM flows WHERE #{Gori::Store::PENDING_WHERE}")
      # "SCAN … USING COVERING INDEX": it walks only the (tiny) index, never a `flows` row.
      plan.should contain("COVERING INDEX idx_flows_pending")
    end
  end

  it "migrates a V35 project and finalises only its sent Pending flows" do
    path = File.tempname("gori-pending-v36", ".db")
    begin
      store = Gori::Store.open(path)
      sent = store.insert_flow(pending_request("/in-flight"))
      unsent = store.insert_flow(pending_request("/imported"))
      done = store.insert_flow(pending_request("/done"))
      store.update_response(Gori::Store::CapturedResponse.new(flow_id: done, status: 200,
        head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, state: Gori::Store::FlowState::Complete))
      store.flush
      # Back to the V35 shape: no index, an older user_version.
      store.@db.exec("UPDATE flows SET unsent = 1 WHERE id = ?", unsent)
      store.@db.exec("DROP INDEX idx_flows_pending")
      store.@db.exec("PRAGMA user_version = 35")
      store.close

      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64).should eq(Gori::Store::Schema::VERSION.to_i64)
        store.@db.query_all("SELECT id FROM flows WHERE #{Gori::Store::PENDING_WHERE}", as: Int64).should eq([sent])

        store.abandon_pending!("orphaned").should eq(1)
        store.flush
        store.get_flow(sent).not_nil!.row.state.should eq(Gori::Store::FlowState::Error)
        store.get_flow(unsent).not_nil!.row.state.should eq(Gori::Store::FlowState::Pending)
        store.get_flow(done).not_nil!.row.state.should eq(Gori::Store::FlowState::Complete)
        # The finalised row left the index with its state; a second pass finds nothing.
        store.abandon_pending!("again").should eq(0)
      ensure
        store.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
