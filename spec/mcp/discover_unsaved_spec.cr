require "../spec_helper"

# MCP discover — a persist flush the writer rolled back.
#
# `flush_discover_persist` handed `insert_import_batch` the job's buffer and cleared it without
# reading the committed count, so a batch refused under a peer's write lock lost up to 64
# findings' rows with nothing on `discover_status`: the finding stayed in `results`, `get_flow`
# on it answered not-found, and an agent had no way to tell "not flushed yet" from "never will
# be". The job now counts the loss and both readers report it as `unsaved_flows`. The CLI twin
# is `spec/cli/run/discover_spec.cr`.
module Gori::MCP
  class Tools
    def flush_discover_persist_for_spec(djob : DiscoverJob) : Nil
      @discover_jobs[djob.id] = djob
      flush_discover_persist(djob)
    end
  end
end

private def idle_job(id : String) : Gori::MCP::Tools::DiscoverJob
  engine = Gori::Discover::Engine.new("http://t/", [] of String,
    Gori::Discover::Sender.new(verify: false), Gori::Discover::Config.new)
  audit = Gori::MCP::Tools::JobAudit.new("http://t/", nil, 1, nil, 0_i64)
  Gori::MCP::Tools::DiscoverJob.new(id, engine, audit, nil)
end

private def buffer(djob : Gori::MCP::Tools::DiscoverJob, n : Int32) : Nil
  (1..n).each do |i|
    f = Gori::Discover::Finding.new("http://t/#{i}", "GET", 200, 2_i64, "text/plain",
      Gori::Discover::Source::Bruteforced, 1, 0.9, nil)
    p = Gori::Discover::Persist.flow_pair(f, i.to_i64, surface: Gori::FlowSource::Surface::Mcp)
    djob.persist_buf << {p.request, p.response}
  end
end

private def with_contended_store(&)
  path = File.tempname("gori-mcp-discover-contended", ".db")
  store = Gori::Store.open(path, busy_timeout_ms: 1)
  peer = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=1")
  begin
    hold = ->(blk : ->) do
      lock = peer.checkout
      begin
        lock.exec("BEGIN IMMEDIATE")
        blk.call
      ensure
        lock.exec("ROLLBACK") rescue nil
        lock.release rescue nil
      end
    end
    yield store, hold
  ensure
    peer.close rescue nil
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
    File.delete?("#{path}.open.lock")
  end
end

describe "MCP discover — findings whose rows could not be written" do
  it "counts a rolled-back flush and reports it on status and results" do
    with_contended_store do |store, hold|
      tools = tools_for(store)
      djob = idle_job("d-unsaved")
      buffer(djob, 3)
      hold.call(-> { tools.flush_discover_persist_for_spec(djob) })
      djob.unsaved.should eq(3)
      djob.persist_buf.should be_empty
      store.count.should eq(0_i64)

      st = JSON.parse(tools.call("discover_status", JSON.parse(%({"job_id":"d-unsaved"}))).text)
      st["unsaved_flows"].as_i.should eq(3)
      rs = JSON.parse(tools.call("discover_results", JSON.parse(%({"job_id":"d-unsaved"}))).text)
      rs["unsaved_flows"].as_i.should eq(3)

      # The next flush lands once the peer lets go, and the count stays what was lost.
      buffer(djob, 2)
      tools.flush_discover_persist_for_spec(djob)
      djob.unsaved.should eq(3)
      store.count.should eq(2_i64)
    end
  end

  it "reports 0 for a job that lost nothing" do
    with_contended_store do |store, _hold|
      tools = tools_for(store)
      djob = idle_job("d-clean")
      buffer(djob, 2)
      tools.flush_discover_persist_for_spec(djob)
      djob.unsaved.should eq(0)
      JSON.parse(tools.call("discover_status", JSON.parse(%({"job_id":"d-clean"}))).text)["unsaved_flows"].as_i.should eq(0)
    end
  end
end
