require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"

# PROVENANCE inside a WebSocket FRAME.
#
# `Env.expand_bindings` scans a whole message by design, and `Fuzz::Sender#send` has excluded
# the run's PAYLOAD spans from that scan since the HTTP half of this was fixed: a payload is the
# operator's TEST CASE, not a draft, so `--payloads '$TOKEN'` must go out as those six characters
# rather than as the live session credential (which would put a real credential in an arbitrary
# position of a request aimed at the target, and land it in the target's access log).
#
# A frame had no implementation of that rule. `Repeater::Sender#expand_messages` reaches for the
# String overload with `guard_boundary: false` — correct for a frame, which is all body — but
# that overload takes no `verbatim`, so there was nowhere for the exclusion to go.
# `Env.expand_bindings_frame` is the door this spec exists for: SSTI / env-reflection payload
# sets are made of `$X` strings, and a WebSocket app is as reachable by them as an HTTP one.
private alias Fuzz = Gori::Fuzz
private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

private def with_ws_env(&)
  prev = Gori::Settings.env_prefix
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  yield
ensure
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = prev || "$"
end

private def with_ws_bindings(&)
  path = File.tempname("gori-fuzz-wsbind", ".db")
  store = Gori::Store.open(path)
  previous = Gori::Env.layer
  begin
    with_ws_env do
      b = Gori::Bindings.load(store)
      b.add("TOKEN", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      head = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=LIVESECRET; Path=/\r\nContent-Length: 0\r\n\r\n"
      parsed = Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice)
      b.observe(Gori::Repeater::Result.new(head.to_slice, Bytes.empty, parsed, 1_i64, nil),
        Gori::InterceptFilter::Subject.new(method: "GET", host: "w.test", target: "/login",
          scheme: "https", status: 200))
      b.values["TOKEN"]?.should eq("LIVESECRET")
      Gori::Env.layer = b
      yield
    end
  ensure
    Gori::Env.layer = previous
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Records the frames the client actually put on the wire.
private def start_recording_ws_origin(count : Int32) : {Int32, Array(String)}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  got = [] of String
  spawn do
    count.times do
      break unless accepted = origin.accept?
      spawn_with(accepted) do |conn|
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
        key = String.new(head).each_line
          .find(&.downcase.starts_with?("sec-websocket-key:"))
          .try { |l| l.split(':', 2)[1].strip } || ""
        accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
        conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        conn.flush
        if (f = WS.read_frame(conn)) && f.data?
          got << String.new(f.payload)
        end
        conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
        conn.flush
        conn.close
      rescue
      end
    end
  rescue
  end
  {port, got}
end

private def sweep_frame(port : Int32, frame_text : String, payloads : Array(String)) : Nil
  hs = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
       "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
       "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  plan = Fuzz::Plan.build(
    Fuzz::PlanOptions.new(hs,
      default_target: "http://127.0.0.1:#{port}",
      sources: [Fuzz::InlineList.new(payloads)] of Fuzz::PayloadSource,
      config: Fuzz::Config.new(concurrency: 1),
      matcher: Fuzz::Matcher.new(keep_bodies: :none),
      ws_messages: [Fuzz::WsMessageSource.new(1, frame_text)]),
    ungated_outbound)
  plan.engine.run { |_| }
end

describe "session bindings inside a fuzz WebSocket frame" do
  # The security property. Without `verbatim`, `Env.expand_bindings_frame` would rewrite the
  # payload — the operator's test case — into the live credential.
  it "does NOT substitute a binding that IS the payload" do
    with_ws_bindings do
      port, got = start_recording_ws_origin(1)
      sweep_frame(port, %({"q":"§v§"}), ["$TOKEN"])
      got.should eq([%({"q":"$TOKEN"})])
      got[0].should_not contain("LIVESECRET")
    end
  end

  # …while the frame TEXT around it is a draft the operator authored, so its `$NAME` resolves.
  # Both halves matter: an implementation that simply skipped the pass for frames would ship a
  # literal `$TOKEN` in the template and every session would go out unauthenticated.
  it "DOES substitute a binding in the frame text around the payload" do
    with_ws_bindings do
      port, got = start_recording_ws_origin(1)
      sweep_frame(port, %({"auth":"$TOKEN","q":"§v§"}), ["probe"])
      got.should eq([%({"auth":"LIVESECRET","q":"probe"})])
    end
  end

  # A CAPTURED frame is evidence: its `$where` / `$ref` / `$filter` are bytes the origin saw,
  # not references to resolve. `Repeater::Sender#expand_messages` draws the same line, and its
  # comment records what resolving them did — `{"$where":"this.a==1"}` became unreplayable.
  it "leaves an evidence frame's $NAME literal" do
    with_ws_bindings do
      port, got = start_recording_ws_origin(1)
      hs = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
           "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      plan = Fuzz::Plan.build(
        Fuzz::PlanOptions.new(hs,
          default_target: "http://127.0.0.1:#{port}",
          sources: [Fuzz::InlineList.new(["x"])] of Fuzz::PayloadSource,
          config: Fuzz::Config.new(concurrency: 1),
          matcher: Fuzz::Matcher.new(keep_bodies: :none),
          marks: ["MARKME"],
          ws_messages: [Fuzz::WsMessageSource.new(1, %({"$TOKEN":"MARKME"}), evidence: true)]),
        ungated_outbound)
      plan.engine.run { |_| }
      got.should eq([%({"$TOKEN":"x"})])
    end
  end
end
