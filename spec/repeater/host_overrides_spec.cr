require "../spec_helper"
require "socket"

private def with_ov_store(&)
  path = File.tempname("gori-repov", ".db")
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

# One-shot loopback HTTP responder; returns {server, port}. Caller closes the server.
private def loopback_responder(reply : String) : {TCPServer, Int32}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  spawn do
    if conn = server.accept?
      while (line = conn.gets("\r\n", chomp: true)) && !line.empty?
      end
      conn << reply
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  {server, port}
end

describe "Repeater engines honor project host overrides (R2-1)" do
  it "Repeater::Engine.send dials the project override IP for an otherwise-unresolvable host" do
    server, port = loopback_responder("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
    begin
      with_ov_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("nonexistent.invalid", "127.0.0.1").should be_true
        req = "GET / HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n".to_slice
        result = Gori::Repeater::Engine.send(req, scheme: "http", host: "nonexistent.invalid",
          port: port, verify_upstream: false, timeout: 2.seconds, overrides: ov)
        result.ok?.should be_true
        result.response.not_nil!.status.should eq(200)
      end
    ensure
      server.close
    end
  end

  it "Repeater::Engine.send WITHOUT overrides cannot reach the unresolvable host (proves the override is load-bearing)" do
    req = "GET / HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n".to_slice
    result = Gori::Repeater::Engine.send(req, scheme: "http", host: "nonexistent.invalid",
      port: 80, verify_upstream: false, timeout: 1.second)
    result.ok?.should be_false
  end

  it "Fuzz::Sender threads the override through to the send engine (covers fuzz/mine/sequence)" do
    server, port = loopback_responder("HTTP/1.1 204 No Content\r\n\r\n")
    begin
      with_ov_store do |store|
        ov = Gori::HostOverrides.load(store)
        ov.add("nonexistent.invalid", "127.0.0.1").should be_true
        origin = Gori::Fuzz::Origin.new("http", "nonexistent.invalid", port)
        sender = Gori::Fuzz::Sender.new(origin, http2: false, verify: false, timeout: 2.seconds, overrides: ov)
        result = sender.send("GET / HTTP/1.1\r\nHost: nonexistent.invalid\r\nConnection: close\r\n\r\n".to_slice)
        result.ok?.should be_true
        result.response.not_nil!.status.should eq(204)
      end
    ensure
      server.close
    end
  end
end
