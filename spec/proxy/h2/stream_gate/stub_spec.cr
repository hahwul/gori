require "../../../spec_helper"
require "../../../support/h2_flow_rig"

# #1635: a Match&Replace SHORT-CIRCUIT rule is answered on HTTP/2 instead of downgrading the
# host. A real h2 client and origin sit on either side of `H2::Relay` (`H2FlowRig`), so a stub
# that leaked to the origin, stranded credit or overran a window fails here rather than passing.

private alias Peer = H2FlowRig::Peer
private alias Rig = H2FlowRig::Rig

private STUB = Gori::Store::RuleOp::ShortCircuit
private REQ  = Gori::Store::RuleTarget::Request
private HEAD = Gori::Store::RulePart::Head

private def req(path : String, method = "GET") : Array({String, String})
  [{":method", method}, {":scheme", "https"}, {":authority", "127.0.0.1"}, {":path", path}]
end

private def field(fields : Array({String, String}), name : String) : String?
  fields.find { |(n, _)| n == name }.try(&.[1])
end

private def from_origin(stream : UInt32, peer : Peer) : H2FlowRig::Answer
  {[{":status", "200"}], "from-origin".to_slice, nil}
end

# At rest, the sender's view of the receiver's connection window is the receiver's own.
private def settled(sender : Peer, receiver : Peer) : Nil
  50.times do
    break if sender.send_conn == receiver.recv_conn
    sleep 10.milliseconds
  end
  sender.send_conn.should eq(receiver.recv_conn)
end

private def with_rules(&)
  with_store do |store|
    yield Gori::Rules.load(store), Gori::Interceptor.new(Gori::Scope.load(store))
  end
end

private def stub(rules : Gori::Rules, path : String, answer : String, args = "",
                 respond = Gori::Store::RespondKind::Inline) : Nil
  rules.add(REQ, HEAD, path, answer, op: STUB, respond: respond, respond_args: args).should be_true
end

describe "H2::StreamGate short-circuit rules (#1635)" do
  it "answers on the client leg and never opens the stream upstream" do
    with_rules do |rules, ic|
      stub(rules, "/stubbed", "201 Created\nX-Stub: yes\nConnection: close\n\nFROM-RULE")
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/stubbed"), Bytes.empty)
        rig.client.send(3_u32, req("/real"), Bytes.empty)
        rig.client.wait_done(1_u32).should be_true
        rig.client.wait_done(3_u32).should be_true
        origin = rig.wait_origin

        head = rig.client.heads[1_u32]
        field(head, ":status").should eq("201")
        field(head, "x-stub").should eq("yes")
        field(head, "content-length").should eq("9")
        field(head, "connection").should be_nil # forbidden on h2 (RFC 9113 §8.2.2)
        rig.client.body_of(1_u32).should eq("FROM-RULE")
        rig.client.body_of(3_u32).should eq("from-origin")
        origin.heads.keys.should eq([3_u32])
        (rig.client.errors + origin.errors).should be_empty

        stubbed = rig.sink.requests.find! { |r| r.target == "/stubbed" }
        stubbed.short_circuited?.should be_true
        stubbed.source_ref.not_nil!.should start_with("project rule #")
        rig.sink.requests.find! { |r| r.target == "/real" }.short_circuited?.should be_false
        answered = rig.sink.responses.find! { |r| r.status == 201 }
        String.new(answered.body.not_nil!).should eq("FROM-RULE")
        answered.ttfb_us.should be_nil
        settled(origin, rig.client)
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  # h1 drains the body before it answers, and so does this — an upload bigger than the origin's
  # window only finishes if gori credits the client back on the stream and the connection.
  it "drains a request body past the origin's window, records it, then answers" do
    with_rules do |rules, ic|
      stub(rules, "/upload", "200 OK\n\ndrained")
      rig = Rig.new(rules, ic, origin_window: 16_384_i64) { |s, p| from_origin(s, p) }
      begin
        body = "a" * 200_000
        rig.client.send(1_u32, req("/upload", "POST") + [{"content-length", "200000"}], body.to_slice)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("drained")
        rig.client.send(3_u32, req("/after"), Bytes.empty)
        rig.client.wait_done(3_u32).should be_true
        origin = rig.wait_origin
        origin.heads.keys.should eq([3_u32])
        (rig.client.errors + origin.errors).should be_empty
        rig.sink.requests.find! { |r| r.target == "/upload" }.body_size.should eq(200_000)
        settled(rig.client, origin)
      ensure
        rig.close
      end
    end
  end

  # The answer spends the client's windows, so it is paced by them, and the client's credit for
  # it is gori's: forwarded to the origin it would let the origin overrun the client.
  it "paces a stub body by the client's windows and keeps the origin's view of them true" do
    with_rules do |rules, ic|
      stub(rules, "/big", "200 OK\n\n" + "b" * 150_000)
      rig = Rig.new(rules, ic, client_window: 16_384_i64) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/big"), Bytes.empty)
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("b" * 150_000)
        rig.client.send(3_u32, req("/after"), Bytes.empty)
        rig.client.wait_done(3_u32).should be_true
        origin = rig.wait_origin
        (rig.client.errors + origin.errors).should be_empty
        settled(origin, rig.client)
      ensure
        rig.close
      end
    end
  end

  # gori's own 502 for a stub it cannot honour names why on the flow, as h1 does.
  it "records why a stub could not answer as authored" do
    with_rules do |rules, ic|
      rules.add(REQ, HEAD, "/gone", "200 OK", op: STUB, body_file: "/nonexistent/gori-1635.bin").should be_true
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/gone"), Bytes.empty)
        rig.client.wait_done(1_u32).should be_true
        field(rig.client.heads[1_u32], ":status").should eq("502")
        20.times { break unless rig.sink.responses.empty?; sleep 10.milliseconds }
        rig.sink.responses.first.error.not_nil!.should_not be_empty
      ensure
        rig.close
      end
    end
  end

  # The client holds its body back for a 100 that a stub never sends, so it is answered at once.
  it "answers a request that asks for 100-continue without waiting for its body" do
    with_rules do |rules, ic|
      stub(rules, "/upload", "200 OK\n\nnot-needed")
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        head = req("/upload", "POST") + [{"content-length", "5"}, {"expect", "100-continue"}]
        rig.client.send_head(1_u32, head, false)
        rig.client.wait_done(1_u32, 2.seconds).should be_true
        rig.client.body_of(1_u32).should eq("not-needed")
      ensure
        rig.close
      end
    end
  end

  it "answers HEAD with the length and no body" do
    with_rules do |rules, ic|
      stub(rules, "/h", "200 OK\n\nfour")
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/h", "HEAD"), Bytes.empty)
        rig.client.wait_done(1_u32).should be_true
        field(rig.client.heads[1_u32], "content-length").should eq("4")
        rig.client.data_frames[1_u32]?.should be_nil
        rig.client.errors.should be_empty
      ensure
        rig.close
      end
    end
  end

  {"reset", "close"}.each do |kind|
    it "injects a #{kind} fault as a reset of that one stream" do
      with_rules do |rules, ic|
        stub(rules, "/pay", "", %({"fault":"#{kind}"}), Gori::Store::RespondKind::Fault)
        rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
        begin
          rig.client.send(1_u32, req("/pay"), Bytes.empty)
          50.times { break unless rig.client.resets.empty?; sleep 10.milliseconds }
          rig.client.resets.should eq([1_u32])
          rig.client.send(3_u32, req("/after"), Bytes.empty) # the connection carries on
          rig.client.wait_done(3_u32).should be_true
          rig.wait_origin.heads.keys.should eq([3_u32])
          aborted = rig.sink.responses.find! { |r| r.error.try(&.starts_with?("injected #{kind}")) }
          aborted.error.not_nil!.should contain("by project rule #")
        ensure
          rig.close
        end
      end
    end
  end

  # A delay holds the one stream, not the pump: another exchange finishes while it waits.
  it "waits out a delay without holding the connection" do
    with_rules do |rules, ic|
      stub(rules, "/slow", "200 OK\n\nslow", %({"delay_ms":300}))
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/slow"), Bytes.empty)
        rig.client.send(3_u32, req("/fast"), Bytes.empty)
        rig.client.wait_done(3_u32).should be_true
        rig.client.done.includes?(1_u32).should be_false
        rig.client.wait_done(1_u32).should be_true
        rig.client.body_of(1_u32).should eq("slow")
      ensure
        rig.close
      end
    end
  end

  it "answers nothing to a stream the client reset while it waited" do
    with_rules do |rules, ic|
      stub(rules, "/slow", "200 OK\n\nslow", %({"delay_ms":200}))
      rig = Rig.new(rules, ic) { |s, p| from_origin(s, p) }
      begin
        rig.client.send(1_u32, req("/slow"), Bytes.empty)
        sleep 20.milliseconds
        rig.client.send_rst(1_u32)
        sleep 400.milliseconds
        rig.client.heads.has_key?(1_u32).should be_false
        rig.sink.responses.any?(&.error.try(&.includes?("reset by the client before the short-circuit answer"))).should be_true
        rig.client.send(3_u32, req("/after"), Bytes.empty)
        rig.client.wait_done(3_u32).should be_true
        rig.wait_origin.heads.keys.should eq([3_u32])
        rig.client.errors.should be_empty
      ensure
        rig.close
      end
    end
  end
end
