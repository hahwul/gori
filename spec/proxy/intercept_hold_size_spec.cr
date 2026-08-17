require "../spec_helper"
require "log/spec"
require "socket"

# An intercept HOLD buffers the whole entity so the human can see and edit it
# (`Codec::Body.read_complete`, no `max_bytes`). With intercept on, a page POSTing a multi-GB
# body — or a multi-GB download with the response direction held — grew the proxy heap by the
# whole declared length before anyone was shown anything, and did it BEFORE `@sink.on_request`,
# so the eventual raise lost the flow from History as well.
#
# Every sibling buffering path in `client_conn.cr` already has the ceiling (`MAX_REWRITE_BODY`
# via `rewritable_body_size?`), and the h2 half of this very feature fails a hold open past
# `MAX_DEFERRED_BYTES` (`H2::StreamGate#fail_open`). The h1 hold now does the same: over the
# ceiling the message is NOT held and takes the byte-exact streaming path, with one warning so
# the operator learns why nothing appeared in the queue.
#
# h2 gained its own, LOWER ceiling on the same question in PR #6 (`H2::StreamGate::MAX_HOLD_BODY`,
# 1 MiB): under it a held stream's body is buffered and editable, over it the hold covers the
# head only and DATA streams past. The two numbers differ because an h1 connection carries one
# request and an h2 connection multiplexes ~100 streams — see that constant's comment.
# `spec/proxy/h2/stream_gate_spec.cr` covers the h2 side; this file is the h1 hold's ceiling.
#
# The tests key on "did the head reach the other side promptly?" rather than on shipping 16 MiB:
# a hold reads the body BEFORE writing anything onward, so a held message shows the peer nothing.

private class HoldSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private def with_hold_store(&)
  path = File.tempname("gori-hold", ".db")
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

# An origin that reports the request head it received, then answers `resp`.
private def start_head_reporting_origin(seen : Channel(String), resp : String) : {Int32, TCPServer}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    if conn = origin.accept?
      conn.read_timeout = 10.seconds
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      seen.send(head ? String.new(head) : "origin-eof")
      conn << resp
      conn.flush
      sleep 3.seconds # keep the socket up so the client can read what arrived
      conn.close rescue nil
    end
  rescue ex
    seen.send("origin-err:#{ex.class}") rescue nil
  end
  {port, origin}
end

# The declared length used for the over-ceiling cases. Only the DECLARED size is gated, so no
# test ever has to move 16 MiB.
private def over_ceiling : Int32
  64 * 1024 * 1024
end

describe "intercept hold body ceiling" do
  it "does NOT hold a request whose declared body is over the ceiling — it streams, and says so" do
    with_hold_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle # enable, both directions
      seen = Channel(String).new(1)
      origin_port, origin = start_head_reporting_origin(seen,
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, HoldSink.new, interceptor: ic)
      proxy.start

      Log.capture do |logs|
        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "POST /upload HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
                  "Content-Length: #{over_ceiling}\r\n\r\n"
        client << "partial"
        client.flush

        # Held, the head would sit in gori's heap behind a body that never finishes arriving and
        # the origin would see nothing at all.
        receive_within(seen, what: "the forwarded request head").should contain("POST /upload")
        ic.pending_count.should eq(0)
        logs.check(:warn, /over the .* hold ceiling/).entry.message.should contain("request")

        client.close
      end

      proxy.stop
      origin.close rescue nil
    end
  end

  it "still holds a small request (the ceiling is the only thing that changed)" do
    with_hold_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      seen = Channel(String).new(1)
      origin_port, origin = start_head_reporting_origin(seen,
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")

      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, HoldSink.new, interceptor: ic)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "POST /upload HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
                "Content-Length: 4\r\n\r\nBODY"
      client.flush

      held = Channel(Gori::Interceptor::Item).new(1)
      spawn do
        20.times do
          if item = ic.pending.first?
            held.send(item)
            break
          end
          sleep 100.milliseconds
        end
      end
      item = receive_within(held, what: "the held request")
      item.kind.should eq(Gori::Interceptor::Kind::Request)
      String.new(item.raw).should contain("BODY")

      ic.forward(item.id, item.raw)
      receive_within(seen, what: "the forwarded request head").should contain("POST /upload")

      client.close
      proxy.stop
      origin.close rescue nil
    end
  end

  it "does NOT hold a response whose declared body is over the ceiling — it streams to the client" do
    with_hold_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle
      ic.set_direction(Gori::Interceptor::Direction::ResponseOnly) # the request must not be held
      seen = Channel(String).new(1)
      origin_port, origin = start_head_reporting_origin(seen,
        "HTTP/1.1 200 OK\r\nX-Big: yes\r\nContent-Length: #{over_ceiling}\r\n\r\npartial")

      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, HoldSink.new, interceptor: ic)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 10.seconds
      client << "GET /download HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      receive_within(seen, what: "the forwarded request head").should contain("GET /download")

      # Held, gori would buffer 64 MiB before writing a byte back and the client would see
      # nothing; streaming, the head arrives at once.
      head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
      String.new(head).should contain("X-Big: yes")
      ic.pending_count.should eq(0)

      client.close
      proxy.stop
      origin.close rescue nil
    end
  end
end
