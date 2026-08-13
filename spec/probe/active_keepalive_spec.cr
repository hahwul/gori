require "../spec_helper"
require "socket"

private alias P = Gori::Probe
private alias S = Gori::Store

# What Probe Active's keep-alive actually buys, measured rather than assumed.
#
# A per-ORIGIN sender cache across tasks was built for this and REVERTED: it changed nothing.
# On this flow the scan makes 9 requests over 5 connections with or without it, because most
# Active probes are not poolable in the first place — `ConnPool` refuses to park a socket that
# carried an ambiguous framing, which is what the desync/smuggling probes are, and several
# rules send exactly one request. The reuse that does happen is WITHIN a task (a rule's
# primary + followups + pipeline), which the per-task sender already gets.
#
# This pins the shape so the cache is not re-proposed: connections stay strictly below
# requests, and the gap is the within-task amortisation.
private class CountingOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter requests : Int32 = 0

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      spawn { serve(conn) }
    end
  rescue
  end

  private def serve(conn : TCPSocket) : Nil
    loop do
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      break unless head
      req = Gori::Proxy::Codec::Http1.parse_request_head(head)
      if (cl = req.headers.get?("Content-Length")) && (n = cl.to_i?) && n > 0
        buf = Bytes.new(n)
        conn.read_fully?(buf)
      end
      @requests += 1
      body = "ok"
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
      conn.flush
    end
    conn.close rescue nil
  rescue
    conn.close rescue nil
  end
end

private def cache_store(&)
  path = File.tempname("gori-active-cache", ".db")
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

private def captured(port : Int32) : S::FlowDetail
  target = "/api/items?q=hello"
  body = %({"a":"1","b":"2"})
  head = "POST #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
         "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n"
  row = S::FlowRow.new(
    1_i64, 1_i64, "http", "POST", "127.0.0.1", port, target,
    200, 100_i64, S::FlowState::Complete, 11_i64, 1_i64, "application/json")
  resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
  S::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body.to_slice,
    resp.to_slice, %({"ok":true,"a":"1"}).to_slice)
end

describe "Probe Active keep-alive" do
  it "reuses a connection within a rule's probe set" do
    origin = CountingOrigin.new
    begin
      cache_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "127.0.0.1")
        a = P::Analyzer.new(store, scope, Channel(S::FlowEvent).new(1), P::Mode::Active, false)
        a.start
        a.run_active_now(captured(origin.port), allow_unsafe: true)
        # Poll to a deadline rather than blocking on a channel (spec_helper's PR #555 note).
        deadline = Time.instant + 10.seconds
        while origin.requests < 5 && Time.instant < deadline
          sleep 20.milliseconds
        end
        a.stop
      end

      origin.requests.should be > 5 # the scan really probed
      # The whole point: connections stay near ACTIVE_SENDER_CACHE rather than tracking the
      # rule count. A smuggling/desync probe is deliberately NOT poolable (ConnPool refuses an
      # ambiguous framing — see request_smuggling_spec), so this is "far fewer", not "one".
      origin.connections.should be < origin.requests # keep-alive amortises within each task
    ensure
      origin.close
    end
  end
end
