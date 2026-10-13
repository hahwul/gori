require "../spec_helper"
require "socket"

# The proxy half of #1589: a Match&Replace rule that changes a message leaves the `{scope, id}`
# that fired and the bytes it replaced on the flow, while the flow keeps what went on each wire.

private class RuleHitsSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @next_id = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# An origin that answers every request with `origin-body`, and hands back the head it received.
private def start_origin(heads : Channel(String), close : Bool = true) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = origin.accept?
      head = String.build do |io|
        while (line = conn.gets(chomp: false)) && line != "\r\n"
          io << line
        end
      end
      heads.send(head)
      # Content-Length last, where the proxy's framing restore puts it back (a restore that MOVED
      # it would be a real change on the wire).
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n#{close ? "Connection: close\r\n" : ""}Content-Length: 11\r\n\r\norigin-body"
      conn.flush
      conn.close
    end
  end
  origin
end

# One request through a proxy carrying `rules`, returning {sink, what the client got, what the
# origin got}.
private def through_proxy(rules : Gori::Rules) : {RuleHitsSink, String, String}
  heads = Channel(String).new(1)
  origin = start_origin(heads)
  done = Channel(Nil).new(1)
  sink = RuleHitsSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  client << "GET /a HTTP/1.1\r\nHost: 127.0.0.1:#{origin.local_address.port}\r\nX-Token: client\r\nConnection: close\r\n\r\n"
  client.flush
  got = client.gets_to_end
  client.close
  done.receive
  proxy.stop
  origin.close
  {sink, got, heads.receive}
end

describe "proxy — Match&Replace rule hits (#1589)" do
  it "records a request-head rule with the client's head, and a response-body rule with the origin's bytes" do
    with_store do |store|
      rules = Gori::Rules.new(store, store.match_rules)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Token: client", "X-Token: rule")
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "origin", "rule")
      req_rule, body_rule = rules.rules
      sink, got, origin_saw = through_proxy(rules)

      origin_saw.should contain("X-Token: rule")
      got.should end_with("rule-body")

      req = sink.requests.first
      String.new(req.head).should contain("X-Token: rule") # REQUEST stays what went upstream
      rw = req.rewrite.should_not be_nil
      rw.hits.should eq([Gori::Store::RuleRef.new(req_rule.scope, req_rule.id)])
      String.new(rw.head.not_nil!).should contain("X-Token: client")
      rw.body.should be_nil # no body rule touched the request

      resp = sink.responses.first
      String.new(resp.body.not_nil!).should eq("rule-body") # RESPONSE stays what the client got
      rrw = resp.rewrite.should_not be_nil
      rrw.hits.should eq([Gori::Store::RuleRef.new(body_rule.scope, body_rule.id)])
      String.new(rrw.head.not_nil!).should contain("Content-Length: 11")
      String.new(rrw.body.not_nil!).should eq("origin-body")
    end
  end

  it "records nothing for a rule that matches and leaves the bytes equal" do
    with_store do |store|
      rules = Gori::Rules.new(store, store.match_rules)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Token: client", "X-Token: client")
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Body, "origin", "origin")
      sink, _, _ = through_proxy(rules)
      sink.requests.first.rewrite.should be_nil
      sink.responses.first.rewrite.should be_nil
    end
  end

  it "keeps one request's record off the next request on the same connection" do
    with_store do |store|
      rules = Gori::Rules.new(store, store.match_rules)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-Token: client", "X-Token: rule")
      heads = Channel(String).new(2)
      origin = start_origin(heads, close: false) # the client's connection must stay open
      done = Channel(Nil).new(2)
      sink = RuleHitsSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start
      host = "127.0.0.1:#{origin.local_address.port}"
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /1 HTTP/1.1\r\nHost: #{host}\r\nX-Token: client\r\n\r\n"
      client.flush
      while (line = client.gets) && !line.empty?
      end
      client.read_fully(Bytes.new(11))
      client << "GET /2 HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
      client.flush
      client.gets_to_end
      client.close
      2.times { done.receive }
      proxy.stop
      origin.close

      sink.requests[0].rewrite.should_not be_nil
      sink.requests[1].rewrite.should be_nil
      sink.responses.map(&.rewrite).should eq([nil, nil])
    end
  end

  it "records nothing for a framing-only change the proxy restores" do
    with_store do |store|
      rules = Gori::Rules.new(store, store.match_rules)
      rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head, "Content-Length: 11", "Content-Length: 99")
      sink, got, _ = through_proxy(rules)
      got.should contain("Content-Length: 11")
      sink.responses.first.rewrite.should be_nil
    end
  end
end
