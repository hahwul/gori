require "../spec_helper"
require "socket"

# Two ways the MCP surface used to answer a question it had not actually got to ask, both of
# them reachable only with a second gori on the same project — which is the normal deployment
# (a TUI capturing, an agent driving `gori mcp` beside it).
#
#   * `drain_fts_or_error` drained the off-commit trigram index (Store V4) and returned nil
#     unconditionally on a WRITABLE store. But `index_pending!` reports a batch that lost
#     SQLite's single writer slot as "0 indexed" and takes its `break if n == 0` there — that
#     contract is deliberate (a contended write must never hang capture) and it means the drain
#     RETURNS with rows still dirty. So `body:` answered off a partial index, and an agent got
#     "2 flows" with nothing saying the other 40 were never looked at. The read-only branch has
#     always refused exactly this; the writable branch is the same silence by the other door.
#   * `send_request` raised `Gori::Error` when the History row would not commit, and the tool's
#     own rescue codes that INVALID_ARGUMENT — "fix your arguments" for a call whose arguments
#     were fine. An agent's error policy rewrites the request instead of retrying it.
#
# The peer connection here stands in for that second gori: SQLite locks per CONNECTION, so one
# pool holding BEGIN IMMEDIATE is the same contention a second process produces. `busy_timeout=1`
# is what makes these examples fast — the real 5 s wait is the thing being skipped, not tested.
# Shape borrowed from spec/store/concurrent_writer_recovery_spec.cr, which proves the store-level
# halves (`insert_flow` answers 0, `index_pending!` answers 0 with the backlog intact).
private def contended_store(&)
  path = File.tempname("gori-mcp-fts", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  # The idle indexer would drain the backlog out from under these examples within one FAST tick
  # (5 ms), so the only reliable order — dirty the row, THEN take the peer lock — is unreachable
  # with it running. Pausing it is a real product state (a view-only Session that lost the
  # capture lock does exactly this, #752); explicit `index_pending!` is an op on the write
  # channel and still runs, which is what these examples call.
  store.pause_background_index
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    # On a fiber with a timeout: the failures behind these examples leave the writer wedged, and
    # a spec that reproduces THAT by hanging reports nothing at all (crystal spec block-buffers).
    done = Channel(Nil).new(1)
    spawn do
      store.close
      done.send(nil)
    end
    select
    when done.receive
      # closed cleanly
    when timeout(20.seconds)
      # leaked on purpose: a wedged writer must fail the example, never hang the run
    end
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Takes the WAL write lock the way a peer gori's writer would, runs the block, gives it back.
private def while_peer_writes(peer : DB::Database, &)
  lock = peer.checkout
  lock.exec("BEGIN IMMEDIATE")
  begin
    yield
  ensure
    lock.exec("ROLLBACK") rescue nil
    lock.release rescue nil
  end
end

# A completed flow whose RESPONSE body carries `needle` — the ≥3-char FTS path (QL `body_cond`),
# not the `instr` fallback, so the match genuinely depends on the trigram index. Left DIRTY:
# nothing here flushes, and the idle indexer is paused.
private def seed_body_flow(store, needle : String, target : String = "/a") : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
  body = "<html><body>#{needle} lives here</body></html>"
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: body.to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  id
end

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_result(tools, name, args : String) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args))
end

# An origin that accepts and immediately closes, counting every connection it saw. The COUNT is
# the assertion for "without sending": a PROJECT_BUSY code proves what the tool answered, not
# that it kept the request off the wire.
private class CountingOrigin
  getter accepts = 0
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        @accepts += 1
        conn.close rescue nil
      end
    end
  end

  def close : Nil
    @server.close rescue nil
  end
end

describe "MCP drain_fts_or_error on a WRITABLE store whose drain lost the writer slot" do
  it "refuses list_history with a retryable FTS_BACKLOG instead of answering off a partial index" do
    contended_store do |store, peer|
      seed_body_flow(store, "needleone")
      store.fts_backlog.should be > 0 # the drain has real work to fail at

      tools = tools_for(store)
      r = uninitialized Gori::MCP::Tools::Result
      while_peer_writes(peer) do
        r = call_result(tools, "list_history", %({"query":"body:needleone"}))
      end

      r.is_error.should be_true
      # The SAME code and retryability the read-only branch answers: one condition, one contract.
      r.error_code.should eq("FTS_BACKLOG")
      r.retryable.should be_true
      r.text.should contain("1 flow")
      r.text.should contain("writer was busy")
      # HEAD returned `[]` here — a well-formed empty answer to a question about a row that was
      # sitting in the store the whole time.
      r.text.should_not contain("\"id\"")
    end
  end

  it "refuses list_sitemap the same way — the other caller of the same helper" do
    contended_store do |store, peer|
      seed_body_flow(store, "needletwo", target: "/sitemapped")
      tools = tools_for(store)
      r = uninitialized Gori::MCP::Tools::Result
      while_peer_writes(peer) do
        r = call_result(tools, "list_sitemap", %({"query":"body:needletwo"}))
      end
      r.error_code.should eq("FTS_BACKLOG")
      r.retryable.should be_true
      r.text.should_not contain("/sitemapped")
    end
  end

  # The complement, and it is what stops the guard from being unconditional: with nothing holding
  # the writer the drain finishes, the backlog is empty, and the SAME query answers the row.
  it "still answers a body: query when the drain actually completes" do
    contended_store do |store, _peer|
      id = seed_body_flow(store, "needlethree")
      tools = tools_for(store)
      r = call_result(tools, "list_history", %({"query":"body:needlethree"}))
      r.is_error.should be_false
      rows = JSON.parse(r.text).as_a
      rows.size.should eq(1)
      rows[0]["id"].as_i64.should eq(id)
      store.fts_backlog.should eq(0) # the drain did happen — this is not a pre-indexed pass
    end
  end

  # A query that never reads `flows_fts` must not pay for, or be refused by, a backlog it does
  # not depend on — the `return nil unless uses_fts` short-circuit.
  it "leaves a non-FTS query alone while the backlog is stuck" do
    contended_store do |store, peer|
      seed_body_flow(store, "needlefour")
      tools = tools_for(store)
      r = uninitialized Gori::MCP::Tools::Result
      while_peer_writes(peer) do
        r = call_result(tools, "list_history", %({"query":"host:acme.test"}))
      end
      r.is_error.should be_false
      JSON.parse(r.text).as_a.size.should eq(1)
    end
  end
end

describe "MCP send_request when the History row cannot commit" do
  it "answers a retryable PROJECT_BUSY and sends NOTHING" do
    origin = CountingOrigin.new
    begin
      contended_store do |store, peer|
        tools = tools_for(store)
        r = uninitialized Gori::MCP::Tools::Result
        while_peer_writes(peer) do
          r = call_result(tools, "send_request",
            %({"url":"http://127.0.0.1:#{origin.port}/pay","method":"POST","body":"charge=1",) +
            %("timeout_ms":400,"allow_unscoped":true}))
        end

        r.is_error.should be_true
        # HEAD: INVALID_ARGUMENT, from `call`'s Gori::Error arm — an agent reads that as "my
        # arguments are wrong" and rewrites a request that was correct.
        r.error_code.should eq("PROJECT_BUSY")
        r.retryable.should be_true
        r.text.should contain("NOTHING was sent")

        # The half a code cannot prove. `record_outbound_request` runs BEFORE `plan.send_wire`,
        # so the refusal has to be the reason the socket was never opened.
        origin.accepts.should eq(0)
        store.count.should eq(0)
      end
    ensure
      origin.close
    end
  end

  # The complement: with the writer free the same call records its flow and does send. Without
  # this, a guard that refused every send would pass the example above.
  it "records the flow and sends when the writer is free" do
    origin = CountingOrigin.new
    begin
      contended_store do |store, _peer|
        tools = tools_for(store)
        r = call_result(tools, "send_request",
          %({"url":"http://127.0.0.1:#{origin.port}/pay","method":"POST","body":"charge=1",) +
          %("timeout_ms":400,"allow_unscoped":true}))
        # The origin closes without answering, so the SEND fails — `is_error` tracks that, not
        # the recording. What matters here is that the row exists and the socket was opened.
        r.error_code.should_not eq("PROJECT_BUSY")
        store.count.should eq(1)
        origin.accepts.should eq(1)
      end
    ensure
      origin.close
    end
  end
end
