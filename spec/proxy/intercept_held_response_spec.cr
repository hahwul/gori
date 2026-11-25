require "../spec_helper"
require "socket"

# A held RESPONSE row names the request it answers. When the operator edited that request at
# the hold, the row must name the request that went on the wire, not the one the client sent:
# the response hold is already GATED on `sent_req` (a `method:` catch rule follows the edit),
# and labelling the row from the client's `req` left `RES GET … → 200` in the queue for a flow
# that had gone out as DELETE (#1433). h2 holds both from the same projection already.

private class HeldResponseSink < Gori::Proxy::FlowSink
  getter responses = Channel(Gori::Store::CapturedResponse).new(4)

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.send(resp)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private def with_held_response_store(&)
  path = File.tempname("gori-held-resp", ".db")
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

private def next_pending(ic : Gori::Interceptor, kind : Gori::Interceptor::Kind) : Gori::Interceptor::Item
  found = Channel(Gori::Interceptor::Item).new(1)
  spawn do
    50.times do
      if item = ic.pending.find(&.kind.==(kind))
        found.send(item)
        break
      end
      sleep 50.milliseconds
    end
  end
  receive_within(found, what: "the held #{kind}")
end

# One response held and forwarded as `edit` gives (nil = unedited): what the client read and what
# the sink was handed for the flow.
private def held_response_round(edit : String?) : {String, Gori::Store::CapturedResponse}
  with_held_response_store do |store|
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle
    ic.set_direction(Gori::Interceptor::Direction::ResponseOnly)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        conn.read_timeout = 10.seconds
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\norigin"
        conn.flush
        sleep 3.seconds
        conn.close rescue nil
      end
    rescue
    end
    sink = HeldResponseSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: ic)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 10.seconds
      client << "GET /r HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
      client.flush
      item = next_pending(ic, Gori::Interceptor::Kind::Response)
      ic.forward(item.id, edit ? edit.to_slice : item.raw)
      got = client.gets_to_end
      client.close
      {got, receive_within(sink.responses, what: "the recorded response")}
    ensure
      proxy.stop
      origin.close rescue nil
    end
  end
end

describe "intercept held response" do
  # The client gets the operator's bytes, the flow records them, and the origin's own response is
  # kept beside it as the original (V54) — the request edit's twin (#1378).
  it "keeps the origin's response as the original of an edited one" do
    edit = "HTTP/1.1 100 Edited\r\nContent-Length: 6\r\nConnection: close\r\n\r\nedited"
    got, resp = held_response_round(edit)
    got.should eq(edit)
    resp.status.should eq(100)
    String.new(resp.body.not_nil!).should eq("edited")
    String.new(resp.intercept_original.not_nil!).should eq("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\norigin")
  end

  it "keeps no original when the held response is forwarded unedited" do
    got, resp = held_response_round(nil)
    got.should end_with("origin")
    resp.intercept_original.should be_nil
  end

  it "labels the response with the EDITED request's method" do
    with_held_response_store do |store|
      ic = Gori::Interceptor.new(Gori::Scope.load(store))
      ic.toggle # enable
      ic.set_direction(Gori::Interceptor::Direction::Both)
      origin = TCPServer.new("127.0.0.1", 0)
      origin_port = origin.local_address.port
      seen = Channel(String).new(1)
      spawn do
        if conn = origin.accept?
          conn.read_timeout = 10.seconds
          head = Gori::Proxy::Codec::Http1.read_head(conn)
          seen.send(head ? String.new(head) : "origin-eof")
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
          conn.flush
          sleep 3.seconds
          conn.close rescue nil
        end
      rescue ex
        seen.send("origin-err:#{ex.class}") rescue nil
      end

      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, HeldResponseSink.new, interceptor: ic)
      proxy.start
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /item/1 HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush

      req_item = next_pending(ic, Gori::Interceptor::Kind::Request)
      req_item.method.should eq("GET")
      edited = "DELETE /item/1 HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      ic.forward(req_item.id, edited.to_slice)
      receive_within(seen, what: "the forwarded request head").should start_with("DELETE /item/1")

      resp_item = next_pending(ic, Gori::Interceptor::Kind::Response)
      resp_item.method.should eq("DELETE")
      ic.forward(resp_item.id, resp_item.raw)

      client.close
      proxy.stop
      origin.close rescue nil
    end
  end
end
