require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"

private alias Fuzz = Gori::Fuzz
private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

# A minimal WS origin that serves `count` SESSIONS, one per connection — a fuzz sweep dials a
# fresh socket per variation, unlike `spec/repeater/ws_engine_spec.cr`'s single-shot origin.
# Each session upgrades, echoes every client data frame back unmasked, then sends CLOSE so the
# drain ends immediately instead of waiting out the idle timeout.
#
# Returns {port, the payloads the origin RECEIVED}. The received list is what proves a payload
# reached the frame it was marked in — asserting only on the echo would pass for an origin that
# echoed the template.
private def start_ws_sweep_origin(count : Int32, close_code : Int32 = 1000) : {Int32, Array(String)}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  got = [] of String
  spawn do
    count.times do
      break unless conn = origin.accept?
      spawn_with(conn) do |conn|
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
        key = String.new(head).each_line
          .find(&.downcase.starts_with?("sec-websocket-key:"))
          .try { |l| l.split(':', 2)[1].strip } || ""
        accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
        conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        conn.flush
        while (f = WS.read_frame(conn)) && f.data?
          got << String.new(f.payload)
          conn.write(WS.encode(f.opcode, f.payload, mask: false))
          conn.flush
          break
        end
        code = Bytes[(close_code >> 8).to_u8, (close_code & 0xff).to_u8]
        conn.write(WS.encode(WS::OP_CLOSE, code, mask: false))
        conn.flush
        conn.close
      rescue
      end
    end
  rescue
  end
  {port, got}
end

private def ws_handshake(port : Int32) : String
  "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
  "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
end

private def ws_plan(port : Int32, frames : Array(Fuzz::WsMessageSource),
                    payloads : Array(String), matcher = Fuzz::Matcher.new(keep_bodies: :all),
                    config = Fuzz::Config.new(concurrency: 2)) : Fuzz::Plan
  Fuzz::Plan.build(
    Fuzz::PlanOptions.new(ws_handshake(port),
      default_target: "http://127.0.0.1:#{port}",
      sources: [Fuzz::InlineList.new(payloads)] of Fuzz::PayloadSource,
      config: config, matcher: matcher,
      ws_messages: frames),
    ungated_outbound)
end

private def run_plan(plan : Fuzz::Plan) : {Array(Fuzz::Result), Fuzz::Progress?}
  results = [] of Fuzz::Result
  done = nil.as(Fuzz::Progress?)
  plan.engine.run do |ev|
    case ev
    when Fuzz::ResultEvent then results << ev.result
    when Fuzz::DoneEvent   then done = ev.progress
    end
  end
  {results.sort_by(&.index), done}
end

describe "fuzz over WebSocket" do
  it "sweeps a frame's marked position, one full session per payload" do
    port, got = start_ws_sweep_origin(3)
    plan = ws_plan(port, [Fuzz::WsMessageSource.new(1, %({"op":"sub","q":"§term§"}))], ["aaa", "bbb", "ccc"])
    results, done = run_plan(plan)

    results.size.should eq(3)
    done.not_nil!.sent.should eq(3)
    done.not_nil!.errors.should eq(0)
    # The payload reached the FRAME, not the handshake — three distinct frames on the wire.
    got.sort.should eq([%({"op":"sub","q":"aaa"}), %({"op":"sub","q":"bbb"}), %({"op":"sub","q":"ccc"})])
    results.each do |r|
      r.error.should be_nil
      # The handshake's 101 is what `status` carries, so `--mc 101` and `--mh` keep working
      # against a WebSocket row with no matcher change at all.
      r.status.should eq(101)
      # …and the two facts the 101 cannot express.
      r.ws_frames_in.should eq(1)
      r.ws_close_code.should eq(1000)
    end
  end

  # The adapter's whole claim: `Fuzz::Matcher` needs no WebSocket branch, because the inbound
  # frames ARE the body it already reads.
  it "matches on the inbound frames as the response body" do
    port, _ = start_ws_sweep_origin(2)
    matcher = Fuzz::Matcher.new(keep_bodies: :all)
    matcher.match_regex = /HIT/
    plan = ws_plan(port, [Fuzz::WsMessageSource.new(1, "§v§")], ["HIT-one", "miss"], matcher)
    results, _ = run_plan(plan)
    results.select(&.matched?).flat_map(&.payloads).should eq(["HIT-one"])
    hit = results.find(&.matched?).not_nil!
    String.new(hit.body.not_nil!).should eq("HIT-one")
    hit.length.should eq(7)
  end

  it "extracts out of the inbound frames" do
    port, _ = start_ws_sweep_origin(1)
    matcher = Fuzz::Matcher.new(keep_bodies: :all)
    matcher.extract = /id=(\w+)/
    plan = ws_plan(port, [Fuzz::WsMessageSource.new(1, "§v§")], ["id=abc123"], matcher)
    results, _ = run_plan(plan)
    results[0].extracted.should eq("abc123")
  end

  # A close code is the WS answer to "did the origin accept this payload", and it is the one a
  # sweep is looking for: 101 is constant across every row, granted or refused.
  it "carries a non-1000 close code onto the row" do
    port, _ = start_ws_sweep_origin(1, close_code: 1008)
    plan = ws_plan(port, [Fuzz::WsMessageSource.new(1, "§v§")], ["x"])
    results, _ = run_plan(plan)
    results[0].ws_close_code.should eq(1008)
  end

  it "sweeps a position in the HANDSHAKE of a WebSocket script" do
    port, got = start_ws_sweep_origin(2)
    hs = "GET /ws?room=§lobby§ HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
         "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    plan = Fuzz::Plan.build(
      Fuzz::PlanOptions.new(hs,
        default_target: "http://127.0.0.1:#{port}",
        sources: [Fuzz::InlineList.new(["a", "b"])] of Fuzz::PayloadSource,
        config: Fuzz::Config.new(concurrency: 1),
        matcher: Fuzz::Matcher.new(keep_bodies: :all),
        ws_messages: [Fuzz::WsMessageSource.new(1, "fixed")]),
      ungated_outbound)
    # The handshake is part 0 of the position space, so marking a header or a query value in
    # the upgrade is a first-class WebSocket test rather than something to refuse.
    plan.position_count.should eq(1)
    results, _ = run_plan(plan)
    results.size.should eq(2)
    got.should eq(["fixed", "fixed"])
    results.each { |r| r.status.should eq(101) }
  end

  # gori's own `[gori] …` advisory rows are diagnostics it wrote ABOUT the socket. Letting one
  # into the matched body would make `--mr` report a finding the origin never sent.
  it "keeps gori advisory rows out of the matched body" do
    port, _ = start_ws_sweep_origin(1)
    matcher = Fuzz::Matcher.new(keep_bodies: :all)
    matcher.match_regex = /gori/
    plan = ws_plan(port, [Fuzz::WsMessageSource.new(1, "§v§")], ["plain"], matcher)
    results, _ = run_plan(plan)
    results.select(&.matched?).should be_empty
  end
end
