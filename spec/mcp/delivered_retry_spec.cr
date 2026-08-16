require "../spec_helper"

# `Repeater::Result#delivered?` is the one bit that separates "safe to send again" from "the
# origin already has this request and has acted on it". Both engines compute it; until this
# spec it reached NO surface (`grep -rn '"delivered"' src/` was empty), so MCP answered
# `retryable: true` for exactly the failures the engines flag as delivered — and an agent
# driving a POST doubled the side effect.
#
# The complements matter as much as the cases: a plain silent origin and a plain connect
# refusal MUST stay retryable, or the fix has traded one wrong answer for another.

private def with_store(&)
  path = File.tempname("gori-delivered", ".db")
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

private def drive(store, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

private def tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

# An h1 origin that reads a request head and then either answers `100 Continue` and holds the
# socket open, or holds it open saying nothing at all. `hold` keeps the socket from closing —
# a close would take the "upstream closed after interim 1xx" branch instead of the timeout one
# this exercises. `done` lets the example stop the fiber without a bare `Channel#receive`.
private def start_holding_origin(interim : Bool, done : Channel(Nil)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    conn = origin.accept?
    if conn
      conn.read_timeout = 5.seconds
      begin
        Gori::Proxy::Codec::Http1.read_head(conn)
      rescue
        # a body may follow; the head is all this origin needs
      end
      if interim
        conn.write("HTTP/1.1 100 Continue\r\n\r\n".to_slice)
        conn.flush
      end
    end
    select
    when done.receive?
    when timeout(6.seconds)
    end
    conn.try(&.close) rescue nil
    origin.close rescue nil
  rescue
    origin.close rescue nil
  end
  port
end

private def send_call(port : Int32, method : String = "POST") : String
  %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_request","arguments":) +
    %({"url":"http://127.0.0.1:#{port}/x","method":"#{method}","body":"charge=1",) +
    %("timeout_ms":400,"allow_unscoped":true}}})
end

describe "MCP send_request delivered/retryable" do
  # The pure function, both terms, so a later `error_kind` addition cannot land in the
  # retryable bucket by accident and a delivered failure cannot become retryable by reword.
  describe "Tools.send_retryable?" do
    it "is retryable only for an undelivered NETWORK_ERROR" do
      Gori::MCP::Tools.send_retryable?("NETWORK_ERROR", false).should be_true
      Gori::MCP::Tools.send_retryable?("NETWORK_ERROR", true).should be_false
      Gori::MCP::Tools.send_retryable?("PROTOCOL_ERROR", false).should be_false
      Gori::MCP::Tools.send_retryable?("REQUEST_TRUNCATED", false).should be_false
    end
  end

  it "reports an h1 failure AFTER an interim 1xx as delivered and NOT retryable, naming the origin" do
    with_store do |store|
      done = Channel(Nil).new
      port = start_holding_origin(true, done)
      payload = tool_payload(drive(store, send_call(port))[0])
      done.close
      err = payload["error"].as_s
      # The bare `"Read timed out"` this used to be named neither the origin nor the one
      # fact that decides what a caller may do next. Its h2 twin (`H2Engine.no_response`)
      # has said all of it since round 4; these two are siblings now.
      err.should contain("no response from 127.0.0.1:#{port}")
      err.should contain("interim 100")
      err.should contain("read timed out")
      err.should contain("RFC 9110 §15.2")
      payload["error_kind"].as_s.should eq("timeout")
      payload["error_code"].as_s.should eq("NETWORK_ERROR")
      payload["delivered"].as_bool.should be_true
      payload["retryable"].as_bool.should be_false
    end
  end

  # COMPLEMENT of the interim: the same silence, the same timeout, the same error_kind —
  # and nothing was delivered, so this one must still be retryable. Without it the fix
  # would read as "a timeout is never retryable", which is a different (and wrong) rule.
  it "keeps a silent origin with NO interim retryable" do
    with_store do |store|
      done = Channel(Nil).new
      port = start_holding_origin(false, done)
      payload = tool_payload(drive(store, send_call(port))[0])
      done.close
      payload["error_kind"].as_s.should eq("timeout")
      payload["error_code"].as_s.should eq("NETWORK_ERROR")
      payload["delivered"].as_bool.should be_false
      payload["retryable"].as_bool.should be_true
      # No interim, so no sentence is invented: gori knows nothing here `ex.message` does not.
      payload["error"].as_s.should_not contain("RFC 9110")
    end
  end

  # COMPLEMENT: a genuine network error, nothing delivered, must stay retryable.
  it "keeps a refused connection retryable and marks it undelivered" do
    with_store do |store|
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.local_address.port
      closed.close
      payload = tool_payload(drive(store, send_call(port))[0])
      payload["error_kind"].as_s.should eq("connect")
      payload["error_code"].as_s.should eq("NETWORK_ERROR")
      payload["delivered"].as_bool.should be_false
      payload["retryable"].as_bool.should be_true
    end
  end

  # The engine half, straight on `Engine.exchange`, so the h1 sentence is pinned where it is
  # written rather than only through MCP's kind table.
  describe "Repeater::Engine.exchange" do
    it "marks an interim-then-timeout delivered, and an immediate timeout not" do
      done = Channel(Nil).new
      port = start_holding_origin(true, done)
      sock = TCPSocket.new("127.0.0.1", port)
      sock.read_timeout = 400.milliseconds
      sock.write_timeout = 400.milliseconds
      r = Gori::Repeater::Engine.exchange(sock,
        "POST /x HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 0\r\n\r\n".to_slice,
        "127.0.0.1", port, Time.instant)
      sock.close rescue nil
      done.close
      r.delivered?.should be_true
      r.error.not_nil!.should contain("interim 100")

      done2 = Channel(Nil).new
      port2 = start_holding_origin(false, done2)
      sock2 = TCPSocket.new("127.0.0.1", port2)
      sock2.read_timeout = 400.milliseconds
      sock2.write_timeout = 400.milliseconds
      r2 = Gori::Repeater::Engine.exchange(sock2,
        "POST /x HTTP/1.1\r\nHost: 127.0.0.1:#{port2}\r\nContent-Length: 0\r\n\r\n".to_slice,
        "127.0.0.1", port2, Time.instant)
      sock2.close rescue nil
      done2.close
      r2.delivered?.should be_false
      r2.error.not_nil!.should_not contain("interim")
    end
  end
end
