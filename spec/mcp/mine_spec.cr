require "../spec_helper"
require "socket"

# An origin that holds every request `hold` before answering, so a mine is still sampling its
# baseline when its status is read.
private def holding_origin(hold : Time::Span) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while accepted = origin.accept?
      spawn_with(accepted) do |conn|
        Gori::Proxy::Codec::Http1.read_head(conn)
        sleep hold
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
      rescue
      ensure
        conn.close rescue nil
      end
    end
  end
  origin.local_address.port
end

describe "MCP mine_status" do
  # The job defaulted to `baseline_stable: true`, so a run that had sampled nothing yet (or
  # never would) claimed a stable baseline, which reads as "findings here are trustworthy".
  it "reports baseline_stable null until a baseline was sampled" do
    with_store do |store|
      port = holding_origin(3.seconds)
      tools = tools_for(store)
      started = tools.call("mine_start", JSON.parse({
        template: "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url: "http://127.0.0.1:#{port}", concurrency: 1, allow_unscoped: true,
      }.to_json))
      fail started.text if started.is_error
      job_id = JSON.parse(started.text)["job_id"].as_s
      st = JSON.parse(tools.call("mine_status", JSON.parse({job_id: job_id}.to_json)).text)
      st["status"].as_s.should eq("running")
      st["baseline_stable"].raw.should be_nil
      tools.call("stop_job", JSON.parse({job_id: job_id}.to_json))
      # A run still going claims nothing, so it carries no `note` either.
      st["note"]?.should be_nil
    end
  end

  # Every value the miner sends is a random canary, so a `debug=1` switch reads as absent —
  # and an agent given `found:0` concluded there were no hidden parameters.
  it "notes what a finished run that found nothing cannot see" do
    with_store do |store|
      port = holding_origin(0.seconds)
      tools = tools_for(store)
      started = tools.call("mine_start", JSON.parse({
        template: "GET /t HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
        url: "http://127.0.0.1:#{port}", allow_unscoped: true,
      }.to_json))
      fail started.text if started.is_error
      job_id = JSON.parse(started.text)["job_id"].as_s
      st = JSON.parse(tools.call("mine_status", JSON.parse({job_id: job_id, wait_ms: 20_000}.to_json)).text)
      st["status"].as_s.should eq("done")
      st["found"].as_i.should eq(0)
      st["note"].as_s.should eq(Gori::Miner::NOTHING_FOUND_NOTE)
      res = JSON.parse(tools.call("mine_results", JSON.parse({job_id: job_id}.to_json)).text)
      res["note"].as_s.should eq(Gori::Miner::NOTHING_FOUND_NOTE)
    end
  end
end
