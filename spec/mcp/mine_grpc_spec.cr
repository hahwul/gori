require "../spec_helper"
require "socket"

# Round 8 — the MCP half of the Miner gRPC-blindness wiring. `mine_results` had the same
# `name/location/evidence/confidence/canary/status/delta` shape as the CLI row and the same
# gap: `status` is the h2 `:status`, which is 200 for every gRPC response, so an agent mining
# a gRPC service through MCP could not tell an isolated candidate the target GRANTED from one
# it PERMISSION_DENIED — both read as a plain 200 finding.
#
# Real TCP origin (not a FakeBackend) so this exercises the actual MCP job pipeline: mine_start
# → the live send → mine_results, the same path `spec/mcp/wiring_spec.cr` uses for its own
# gaps. The origin denies (grpc-status 7) every query unless it carries `secret=`, which it
# grants (grpc-status 0) AND grows the body — the metric signal Miner's bisection isolates.

private def with_store(&)
  path = File.tempname("gori-mcpmine-grpc", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_json(tools, name, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def poll_until_done(tools, job_id : String, seconds = 20) : JSON::Any
  deadline = Time.instant + seconds.seconds
  loop do
    st = call_json(tools, "mine_status", %({"job_id":#{job_id.to_json}}))
    return st unless st["status"].as_s == "running"
    fail "mine_status #{job_id} never left :running within #{seconds}s" if Time.instant > deadline
    sleep 0.02.seconds
  end
end

# Grants (grpc-status 0, grown body) only a query carrying `secret=`; denies (grpc-status 7)
# everything else, deterministically — a stable baseline for calibration.
private def grpc_mine_origin : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    while conn = server.accept?
      spawn do
        begin
          conn.read_timeout = 2.seconds
          while head = Gori::Proxy::Codec::Http1.read_head(conn)
            line = String.new(head).lines.first? || ""
            target = line.split(' ')[1]? || ""
            granted = target.includes?("secret=")
            body = granted ? "OK" + "X" * 40 : "OK"
            code = granted ? 0 : 7
            msg = granted ? nil : "nope; you may not"
            resp = String.build do |io|
              io << "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\n"
              io << "Content-Length: #{body.bytesize}\r\ngrpc-status: #{code}\r\n"
              io << "grpc-message: #{msg}\r\n" if msg
              io << "\r\n" << body
            end
            conn << resp
            conn.flush
          end
        rescue
        end
        conn.close rescue nil
      end
    end
  end
  port
end

private GRPC_MINE_ORIGIN_PORT = grpc_mine_origin

describe "MCP mine_results over gRPC" do
  it "carries grpc_status/grpc_status_name/grpc_message on the isolated Finding row" do
    port = GRPC_MINE_ORIGIN_PORT
    wl = File.tempname("gori-mine-grpc-wl", ".txt")
    File.write(wl, "alpha\nbeta\ngamma\nsecret\ndelta\nepsilon\nzeta\neta\n")
    begin
      with_store do |store|
        tools = tools_for(store)
        # `bucket` deliberately LARGE (not forced small): `wordlist` is MERGED with the
        # built-in ~400-name list (the same merge `mine_status{skipped}` above pins), so a
        # small bucket here would fan out into a couple hundred real TCP round trips through
        # this origin — still correct, but needlessly slow under a busy full-suite run. A
        # big bucket keeps clean buckets at ONE request each; only the bucket holding
        # `secret` bisects, which is all this spec needs to exercise. `concurrency` 1: the
        # single-threaded fiber scheduler serializes everything anyway, and a busy 6000+
        # example run can starve a concurrent job's dispatcher fiber past a short deadline.
        start = call_json(tools, "mine_start",
          {"template" => "GET /pkg.Svc/Method HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
           "url" => "http://127.0.0.1:#{port}", "locations" => "query",
           "wordlist" => wl, "bucket" => 128, "concurrency" => 1,
           "allow_unscoped" => true}.to_json)
        poll_until_done(tools, start["job_id"].as_s, 90)
        res = call_json(tools, "mine_results", %({"job_id":#{start["job_id"].as_s.to_json}}))
        findings = res["findings"].as_a
        secret = findings.find { |f| f["name"].as_s == "secret" }
        fail "expected a finding for 'secret' — got #{findings.map(&.["name"])}" unless secret
        secret["status"].as_i.should eq(200) # h2 :status is 200 for the granted call too
        secret["grpc_status"].as_i.should eq(0)
        secret["grpc_status_name"].as_s.should eq("OK")
        secret["grpc_message"]?.should be_nil

        # Complement: a plain (non-gRPC) mine's rows carry no grpc_* fields at all.
        findings.each { |f| f.as_h.has_key?("delta").should be_true }
      end
    ensure
      File.delete?(wl)
    end
  end
end
